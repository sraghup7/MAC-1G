#!/usr/bin/env python3
"""Stage-1 rate/cycle/FIFO-depth arithmetic for gem_mac.

Re-derives every number in PROJECT_SPEC.md B.3 and B.3a from first
principles, so the spec's numbers are checked by running this script,
not just typed into a table. No dependencies.
"""

LINE_RATE_BPS = 1_000_000_000          # 1000BASE-T, R18
CLOCK_HZ = 125_000_000                 # tx_clk / rx_clk, R19
DATAPATH_BITS = 8                      # AXI-S tdata width, R15

MIN_FRAME_BYTES = 64                   # DA..FCS inclusive, 802.3 Table 4-2
MAX_FRAME_BYTES = 1518                 # DA..FCS inclusive, 802.3 Table 4-2
PREAMBLE_BYTES = 8                     # 7B preamble + 1B SFD
IFG_BYTES = 12                         # 96 bit-times, 802.3 Table 4-2

RGMII_CLOCK_TOLERANCE_PPM = 100        # 802.3 Clause 40, 1000BASE-T, each side
CDC_SYNC_LATENCY_BYTES = 4             # dual-flop gray-code pointer sync, w/ margin
FIFO_DEPTH_CHOSEN = 64                 # spec's chosen depth (1 BRAM18 @ 8-bit width)

PHY_TX_SETUP_HOLD_NS = (1.2, 2.0)      # KSZ9031RNX datasheet Table 19, TsetupT/TholdT
PHY_RX_SETUP_HOLD_NS = (1.0, 2.0)      # KSZ9031RNX datasheet Table 19, TsetupR/TholdR
PHY_RX_DEFAULT_DELAY_NS = 1.2          # KSZ9031RNX default RX_CLK-to-RXD delay
CLOCK_PERIOD_NS = 1e9 / CLOCK_HZ       # 8.0 ns at 125 MHz

R21_LATENCY_CEILING_CYCLES = 32        # spec requirement, 256 ns @ 125 MHz
FCS_BYTES = 4                          # 802.3 Clause 3.2.9

RX_PIPELINE_STAGES = [                 # (name, cycles) -- B.1b bottom-up latency check
    ("IDDR capture + nibble combine", 1),
    ("SFD hunt / deframer FSM", 2),
    # Added v0.3, found in Stage 3. The RX port delivers DA..pad and must not
    # emit the FCS, but cut-through cannot know which four octets those are
    # until RX_DV drops -- so the datapath holds four octets back and discards
    # whatever is still in the register at end of frame. Pure latency, bought
    # to satisfy the delivery contract.
    ("FCS holdback register", FCS_BYTES),
    ("CRC-32 verdict generation at EOF", 1),
    ("Async FIFO CDC (rx_clk -> sys_clk)", CDC_SYNC_LATENCY_BYTES),
    ("Registered AXI-S egress stage", 1),
]


def line(label, value, unit=""):
    print(f"  {label:<38} {value}{unit}")


def rate_and_cycle_budget():
    print("== B.3 Rate and cycle budget ==")
    byte_rate = LINE_RATE_BPS / 8
    cycles_per_byte = CLOCK_HZ / byte_rate
    line("Line rate", f"{LINE_RATE_BPS/1e9:.3f}", " Gbps")
    line("Datapath width", DATAPATH_BITS, " bits/cycle")
    line("Cycles per byte", cycles_per_byte)
    assert cycles_per_byte == 1.0, "datapath width does not match line rate at 125 MHz"

    min_frame_cycle_time = MIN_FRAME_BYTES + PREAMBLE_BYTES + IFG_BYTES
    frame_rate = LINE_RATE_BPS / (min_frame_cycle_time * 8)
    line("Worst-case frame rate (min frames)", f"{frame_rate/1e6:.3f}", " Mframes/s")

    slack_cycles = PREAMBLE_BYTES + IFG_BYTES
    line("Slack per min-size frame", f"{slack_cycles} cycles / {MIN_FRAME_BYTES} payload-path cycles")
    print()


def fifo_depth_derivation():
    print("== B.3a RX FIFO depth derivation ==")
    max_frame_time_s = (MAX_FRAME_BYTES * 8) / LINE_RATE_BPS
    line("Max frame time (1518 B)", f"{max_frame_time_s*1e6:.2f}", " us")

    relative_ppm = 2 * RGMII_CLOCK_TOLERANCE_PPM  # worst case: both sides off in opposite directions
    drift_bytes = relative_ppm * 1e-6 * MAX_FRAME_BYTES
    line("Worst-case relative clock skew", relative_ppm, " ppm")
    line("Drift over one max frame", f"{drift_bytes:.3f}", " bytes")

    min_depth = drift_bytes + CDC_SYNC_LATENCY_BYTES
    line("CDC pointer-sync latency term", CDC_SYNC_LATENCY_BYTES, " bytes")
    line("Derived minimum depth", f"{min_depth:.2f}", " bytes")
    line("Chosen depth", FIFO_DEPTH_CHOSEN, " entries (1 BRAM18)")
    headroom = FIFO_DEPTH_CHOSEN / min_depth
    line("Headroom over derived minimum", f"{headroom:.1f}x")
    assert FIFO_DEPTH_CHOSEN > min_depth, "chosen FIFO depth is below the derived minimum"
    print()


def rgmii_timing():
    print("== B.1b RGMII skew targets (KSZ9031RNX datasheet Table 19) ==")
    tx_lo, tx_hi = PHY_TX_SETUP_HOLD_NS
    rx_lo, rx_hi = PHY_RX_SETUP_HOLD_NS

    # Center of the window, not the edge -- a naive 90deg/2.0ns shift sits exactly on
    # tx_hi with zero margin. Centering trades that for equal margin on both sides.
    tx_center_ns = (tx_lo + tx_hi) / 2
    tx_phase_deg = (tx_center_ns / CLOCK_PERIOD_NS) * 360
    margin_lo = tx_center_ns - tx_lo
    margin_hi = tx_hi - tx_center_ns
    line("TX required window (TsetupT/TholdT)", f"{tx_lo}-{tx_hi}", " ns")
    line("Chosen MMCM phase shift for GTX_CLK", f"{tx_center_ns:.2f}", f" ns (-{tx_phase_deg:.0f} deg)")
    line("Margin to window edges", f"{margin_lo:.2f} ns low / {margin_hi:.2f} ns high")
    assert margin_lo > 0 and margin_hi > 0, "chosen TX phase shift leaves no margin against the PHY's window"

    line("RX required window (TsetupR/TholdR)", f"{rx_lo}-{rx_hi}", " ns")
    line("PHY default RX_CLK delay (no FPGA action)", PHY_RX_DEFAULT_DELAY_NS, " ns")
    assert rx_lo <= PHY_RX_DEFAULT_DELAY_NS <= rx_hi, "PHY's default RX delay falls outside its own required window"
    print()


def rx_latency_budget():
    print("== B.1b R21 latency budget: bottom-up pipeline sum ==")
    total = 0
    for name, cycles in RX_PIPELINE_STAGES:
        line(name, cycles, " cycle(s)")
        total += cycles
    margin = R21_LATENCY_CEILING_CYCLES / total
    total_ns = total * CLOCK_PERIOD_NS
    ceiling_ns = R21_LATENCY_CEILING_CYCLES * CLOCK_PERIOD_NS
    line("Total", f"{total} cycles = {total_ns:.0f} ns")
    line("R21 ceiling", f"{R21_LATENCY_CEILING_CYCLES} cycles = {ceiling_ns:.0f} ns")
    line("Margin", f"{margin:.1f}x")
    assert total < R21_LATENCY_CEILING_CYCLES, "bottom-up pipeline sum exceeds R21's latency ceiling"
    print()


if __name__ == "__main__":
    rate_and_cycle_budget()
    fifo_depth_derivation()
    rgmii_timing()
    rx_latency_budget()
    print("All derived numbers self-consistent with PROJECT_SPEC.md.")
