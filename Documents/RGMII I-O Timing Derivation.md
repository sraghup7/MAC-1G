# RGMII I/O timing derivation

Closes V-2's static half. Numbers sourced from `spec/PROJECT_SPEC.md` B.1b,
which cites the KSZ9031RNX datasheet (Microchip Rev 2.2) Table 19.

## RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk

The PHY delays RX_CLK 1.2 ns (typical) relative to RXD/RX_DV so the clock
edge lands inside the data eye rather than at its boundary. RGMII v2.0's
TsetupR/TholdR window is 1.0-2.0 ns -- the guaranteed minimum setup and hold
margin at the receiving pin once that delay is applied. This design uses the
window's worst-case bound, 1.0 ns, as the guaranteed budget: a design that
only requires the datasheet's stated minimum is safe across the PHY's full
1.0-2.0 ns delay range, not merely at its typical 1.2 ns value.

Using the virtual-clock method (matching
reference/verilog-ethernet/syn/quartus/rgmii_io.sdc's structure): a virtual
clock rgmii_rx_clk_virt, period 8.000 ns, phase 0, stands for the PHY's own
undelayed reference. Data transitions relative to that virtual clock's edges
by the datasheet's guaranteed window:

  max = period/2 - Tsetup_min = 4.000 - 1.0 = 3.000 ns
  min = -(Thold_min)           = -1.0 ns

applied on both -clock and -clock_fall (RGMII DDR carries data on both edges),
and constrained against rgmii_rx_clk's *own* falling/rising 90-degree-esque
sampling structure via the same set_false_path edge-pairing the reference
uses -- because rgmii_rx_clk_virt and rgmii_rx_clk are not the same clock and
Vivado would otherwise check non-corresponding edge pairs that do not
represent a real capture event.

## TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by gtx_clk_shifted

rgmii_gtx_clk is a *generated* clock: gem_rgmii_tx.v's u_oddr_gtx forwards
gtx_clk_shifted (the MMCM's phase-shifted CLKOUT1, corrected to -73.125 deg /
1.625 ns in Stage 6 part 1) straight to the pin through an ODDR. The output
delay is bounded by the PHY's required TsetupT/TholdT window, 1.2-2.0 ns, at
the PHY's pins -- i.e. it is a receiver requirement on this design's output,
not a margin this design measures on itself:

  max = 2.0 ns   (the window's upper bound: data may arrive no later than this
                   before the PHY's own sampling edge)
  min = 1.2 ns   (the window's lower bound: data must be held at least this
                   long after the PHY's edge)

applied against the generated clock on rgmii_gtx_clk, both -clock and
-clock_fall, with the same DDR edge-pairing false paths as RX.

## What this cannot check

Both derivations assume the datasheet's stated PHY-side numbers hold on the
physical board -- board trace length/skew is not in this budget because B.1b
never had trace-length data to put there. That is V-2's bench half: an ILA or
scope on GTX_CLK/TXD0 once the board is in hand. What Stage 6 closes is the
static half -- that the design's own clock relationships, as built, meet the
PHY's stated requirements before anything is placed on a real board.
