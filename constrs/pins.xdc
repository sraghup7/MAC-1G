# Physical pin locations and I/O standards (see clocks.xdc / exceptions.xdc),
# plus -- since Stage 6 part 2 -- the RX clock region's placement pblock at
# the bottom of this file, which lives here rather than in a separate file
# because it is a board-geometry statement like the pins themselves.
#
# Source: the real ALINX AX7035B User Manual, now in hand at
# Manuals/AX7035B_UG.pdf (Rev 1.0, 33 pages) — superseding the earlier
# ManualsLib text-extract-plus-third-party-mirror reconstruction this file
# used to cite. Every pin below has been cross-checked against the
# XC7A35T-2FGG484I package database in Vivado (bank assignments noted), not
# just copied from a document. Provenance and the corroboration argument are
# in Manuals/AX7035B_pinout_notes.md; V-21 records how it was settled. All
# fifteen RGMII/MDIO pins and both UART pins below were re-verified directly
# against the real manual's tables (pages 14-15, 22-23) and match exactly —
# nothing here needed correcting when the real PDF arrived.
#
# Voltage: manual Part 4 "FPGA power supply system", page 6-7, states BANK34
# (DDR3) is 1.5V and "the voltage of other BANK is 3.3V"; BANK16 is supplied
# by a dedicated LDO, SPX3819M5-3.3 (a fixed-3.3V part by its own part
# number), which "can be changed by replacing the LDO chip" but ships as
# 3.3V. **Confirmed**, not an assumption — this used to be inferred from a
# general rule and ALINX demo constraints alone; the real manual states it
# for BANK16 specifically and names the populated LDO's part number.

#############################################################################
# Clock and reset
#############################################################################

# 50 MHz oscillator — bank 14, 3.3V, MRCC-capable
set_property PACKAGE_PIN  Y18 [get_ports clk50]
set_property IOSTANDARD   LVCMOS33 [get_ports clk50]

# Reset key — bank 16. Active low: pressed pulls the pin to ground.
set_property PACKAGE_PIN  F20 [get_ports rst_key_n]
set_property IOSTANDARD   LVCMOS33 [get_ports rst_key_n]

# KEY1, the counter-clear button — bank 15, active low
set_property PACKAGE_PIN  M13 [get_ports key_clear_n]
set_property IOSTANDARD   LVCMOS33 [get_ports key_clear_n]

#############################################################################
# RGMII to the JL2121(D) — all bank 15
#############################################################################
#
# The nibble order here is the design's, not a convention to be second-guessed:
# rgmii_txd[0] carries TXD0. This section was originally written for a
# KSZ9031RNX per an earlier (mistaken) reading of the manual — see A.2's B.5
# correction in spec/PROJECT_SPEC.md. The physical chip is a JLSemi
# JL2121(D); its RX/TX clock delay is set by the RXDLY/TXDLY strap pins, both
# confirmed populated to add 2 ns (manual Table 8-1, Manuals/AX7035B_UG.pdf
# page 14) — not the 1.2 ns MDIO-transparent default this comment used to
# claim. The I/O DELAY constraints that account for this belong to Stage 6
# and are deliberately not here yet (V-2); their numeric derivation still
# needs redoing against the JL2121(D)'s own AC timing (datasheet Ch. 4.7)
# with these confirmed 2 ns delays as input.

set_property PACKAGE_PIN  L14 [get_ports rgmii_gtx_clk]
set_property PACKAGE_PIN  J21 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN  M20 [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN  L18 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN  L20 [get_ports {rgmii_txd[3]}]
set_property PACKAGE_PIN  L19 [get_ports rgmii_tx_ctl]

set_property PACKAGE_PIN  K18 [get_ports rgmii_rx_clk]
set_property PACKAGE_PIN  K19 [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN  M15 [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN  J17 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN  J20 [get_ports {rgmii_rxd[3]}]
set_property PACKAGE_PIN  M21 [get_ports rgmii_rx_ctl]

set_property IOSTANDARD   LVCMOS33 [get_ports rgmii_gtx_clk]
set_property IOSTANDARD   LVCMOS33 [get_ports {rgmii_txd[*]}]
set_property IOSTANDARD   LVCMOS33 [get_ports rgmii_tx_ctl]
set_property IOSTANDARD   LVCMOS33 [get_ports rgmii_rx_clk]
set_property IOSTANDARD   LVCMOS33 [get_ports {rgmii_rxd[*]}]
set_property IOSTANDARD   LVCMOS33 [get_ports rgmii_rx_ctl]

# B.5-TX-1 experiment: these six TX outputs took Vivado's default SLEW SLOW,
# which was never set explicitly. On a 125 MHz DDR source-synchronous
# interface with a 4 ns nibble, SLOW's edge rate is a significant fraction of
# the unit interval, and rise/fall times are not symmetric under SLOW -- that
# asymmetry displaces one clock edge relative to the other by a per-bit,
# intermittent amount, matching the falling-edge-nibble-sampled-late signature
# in B.5-TX-1 (docs/reports/stage9/known-issues.md) in a way the CLKOUT1_PHASE
# sweep (d8e48aa) could not, since phase moves both edges together.
set_property SLEW FAST [get_ports rgmii_gtx_clk]
set_property SLEW FAST [get_ports {rgmii_txd[*]}]
set_property SLEW FAST [get_ports rgmii_tx_ctl]

# Measured on hardware: SLEW FAST alone cut the B.5-TX-1 payload mismatch rate
# from ~24% of returned frames to 6.0% (30/499), and the echo return rate went
# from 71-83 frames of 100 to a full 100 -- a chunk of what used to look like
# the echo path's by-design one-at-a-time dropping was actually frames
# corrupted past recognition. Right mechanism; it does not reach zero.
#
# DRIVE 16, RAISED FROM THE DEFAULT 12, AND IT EARNS ITS PLACE -- but only
# 500-frame runs can see that, which is the point worth carrying forward.
#
#   SLEW FAST, DRIVE 12    30 mismatches /  499 returned   6.0%
#   SLEW FAST, DRIVE 16     9 mismatches /  500 returned   1.8%
#   SLEW FAST, DRIVE 16    14 mismatches /  500 returned   2.8%  (2nd session)
#   -> DRIVE 16 pooled     23 mismatches / 1000 returned   2.3%
#
# More drive current means steeper edges, pushing the same direction as
# SLEW FAST rather than fighting it, and it roughly halves the residual.
#
# THE MEASUREMENT TRAP, because it produced a wrong conclusion once already.
# At `--count 100` this signal is unreadable: three consecutive runs of the
# DRIVE 12 build gave 6, 12 and 8 per 100, and three of the DRIVE 16 build
# gave 2, 6 and 5. A 300-frame sample cannot separate 2.8% from 6.0%, and a
# 3x100 measurement of DRIVE 12 landed at ~2.7/100 by chance, which read as
# "DRIVE 16 adds nothing" and nearly got it reverted. Anything comparing two
# I/O settings here needs `--count 500` at minimum, and both numbers must come
# from the same sample size -- comparing a 3x100 against a 500 is what went
# wrong. Poisson error on 14 counts is already +/-3.7.
#
# The residual 2.8% is NOT explained by either lever pins.xdc exposes; both
# are now at their useful limit. B.5-TX-1 stays open on the per-pin I/O DELAY
# work (V-2), not on further SLEW/DRIVE tuning.
set_property DRIVE 16 [get_ports rgmii_gtx_clk]
set_property DRIVE 16 [get_ports {rgmii_txd[*]}]
set_property DRIVE 16 [get_ports rgmii_tx_ctl]

# PER-LINE DRIVE TRIMS WERE HERE AND ARE GONE. THEY WERE TREATING A SYMPTOM.
#
# When the residual corruption collapsed onto individual lines, txd[3] and
# then txd[2] were each held one drive step slower to compensate. It worked:
# ~24% -> 1.1% -> 0.22% -> 0.075%. But it was correcting a skew that a wrong
# TX clock phase was producing. Fixing the phase instead (rtl/gem_mmcm.v,
# CLKOUT1_PHASE 70 -> 60) took the error to ZERO in 12000 frames with all six
# lines back at a uniform DRIVE 16, and the trims had nothing left to correct.
#
# They were also board-specific calibration -- they compensated ONE physical
# board's trace lengths, and nothing detected when that stopped being true.
# The phase fix is not. DO NOT REINTRODUCE PER-LINE TRIMS WITHOUT FIRST
# CONFIRMING THE PHASE IS RIGHT; they mask exactly the defect that matters.
#
# SLEW FAST and the uniform DRIVE 16 above stay: both were measured to matter
# on their own (~24% -> 1.1%, and 6.0% -> 2.3%, at the then-current phase),
# neither has been retested at phase 60, and SLEW FAST is in any case correct
# for a source-synchronous DDR output whose 4 ns nibble a SLOW edge eats into.

#############################################################################
# PHY management and reset — bank 15
#############################################################################

set_property PACKAGE_PIN  K17 [get_ports mdc]
set_property IOSTANDARD   LVCMOS33 [get_ports mdc]

# Bidirectional, with the board's pull-up. gem_top's tristate becomes the IOBUF.
set_property PACKAGE_PIN  K16 [get_ports mdio]
set_property IOSTANDARD   LVCMOS33 [get_ports mdio]

# E1_RESET. Held low for >= 10 ms after power-up by gem_clk_rst (sourced to
# the KSZ9031RNX's tSR — see A.2's B.5 correction; the JL2121(D)'s own reset
# timing is not yet checked against this figure); the pin is active low and
# the PHY must not be spoken to before it rises.
set_property PACKAGE_PIN  L15 [get_ports phy_rst_n]
set_property IOSTANDARD   LVCMOS33 [get_ports phy_rst_n]

#############################################################################
# Status readout — bank 15
#############################################################################
#
# UART_TXD on the schematic: the FPGA's transmit, into the CP2102GM's receive.
# The direction is not a guess — ALINX's own uart_test declares `output
# uart_tx` on this pin (V-21).
set_property PACKAGE_PIN  G16 [get_ports uart_tx]
set_property IOSTANDARD   LVCMOS33 [get_ports uart_tx]

#############################################################################
# User LEDs LED1-LED4 — bank 16, 3.3V (confirmed, see note above)
#############################################################################
#
# Active low: driving a pin low lights its LED, which gem_top inverts once.
set_property PACKAGE_PIN  F19 [get_ports {led[0]}]
set_property PACKAGE_PIN  E21 [get_ports {led[1]}]
set_property PACKAGE_PIN  D20 [get_ports {led[2]}]
set_property PACKAGE_PIN  C20 [get_ports {led[3]}]
set_property IOSTANDARD   LVCMOS33 [get_ports {led[*]}]

#############################################################################
# RX clock region confinement (Stage 6 part 2, BUFH deskew variant)
#############################################################################
#
# A BUFH reaches only its own clock region (UG472 p.14), so every cell the
# deskewed receive clock touches is confined to X0Y1 -- the region that
# already holds the RX I/O bank, its IDDR cells, and the RX MMCM's CMT. See
# Documents/RX Clock Deskew BUFH Variant.md Step 3 for why each instance is
# listed. Whole hierarchies are constrained rather than individual flops:
# splitting u_rx_fifo or a pulse synchroniser by domain at flop level would be
# bookkeeping with no benefit at ~5% utilization.
#
# Mechanism note: CLOCK_REGION as a cell property exists only for global clock
# buffers ("must be set on a global clock buffer", Vivado 12-4190 -- measured);
# regular cells are confined through a pblock whose range is a clock region.
create_pblock pblock_rx_domain
resize_pblock pblock_rx_domain -add {CLOCKREGION_X0Y1}
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_rgmii_rx]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_rx_ctrl]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_rx_crc]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_rx_fifo]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_ev_rx_ok]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_ev_rx_badfcs]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_ev_rx_runt]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_ev_rx_oversize]
add_cells_to_pblock pblock_rx_domain [get_cells u_mac/u_ev_rx_rxer]
add_cells_to_pblock pblock_rx_domain [get_cells u_ev_fifo_drop]
