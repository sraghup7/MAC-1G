# Physical pin locations and I/O standards (see clocks.xdc / exceptions.xdc),
# plus -- since Stage 6 part 2 -- the RX clock region's placement pblock at
# the bottom of this file, which lives here rather than in a separate file
# because it is a board-geometry statement like the pins themselves.
#
# Source: ALINX AX7035B User Manual (manualslib.com/manual/2994570, ALINX's
# own product page confirms the same board), and — for the pins the manual
# leaves in schematic figures — the board schematic itself and ALINX's own
# demo constraints. Every pin below has been cross-checked against the
# XC7A35T-2FGG484I package database in Vivado (bank assignments noted), not
# just copied from a document. Provenance and the corroboration argument are
# in Manuals/AX7035B_pinout_notes.md; V-21 records how it was settled.
#
# Voltage: manual Part 4 "FPGA power supply system" states BANK34 (DDR3) is
# 1.5V and "the voltage of other BANK is 3.3V"; BANK16 is LDO-supplied and
# "can be changed by replacing the LDO chip" but the manual gives no evidence
# the board ships with anything other than the default 3.3V. ASSUMPTION,
# not yet confirmed against the physical board — the schematic labels the bank
# but supplies it from the power tree rather than annotating a voltage, and
# ALINX's own demos constrain these pins LVCMOS33, which corroborates without
# proving. Re-check (e.g. probe the LDO output or read back IO after program)
# at first bring-up if LEDs don't light as expected. Same caution as A.2's
# PHY-identity correction in the spec: trust the physical board over any
# document the moment they disagree.

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
# RGMII to the KSZ9031RNX — all bank 15
#############################################################################
#
# The nibble order here is the design's, not a convention to be second-guessed:
# rgmii_txd[0] carries TXD0. The RX side's electrical timing depends on the
# PHY's 1.2 ns RX_CLK delay, which is a datasheet default requiring no MDIO
# write (B.1b) — the I/O DELAY constraints that check all of this belong to
# Stage 6 and are deliberately not here yet (V-2).

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

#############################################################################
# PHY management and reset — bank 15
#############################################################################

set_property PACKAGE_PIN  K17 [get_ports mdc]
set_property IOSTANDARD   LVCMOS33 [get_ports mdc]

# Bidirectional, with the board's pull-up. gem_top's tristate becomes the IOBUF.
set_property PACKAGE_PIN  K16 [get_ports mdio]
set_property IOSTANDARD   LVCMOS33 [get_ports mdio]

# E1_RESET. Held low for >= 10 ms after power-up by gem_clk_rst (KSZ9031RNX
# tSR); the pin is active low and the PHY must not be spoken to before it rises.
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
# User LEDs LED1-LED4 — bank 16, 3.3V (assumed, see note above)
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
