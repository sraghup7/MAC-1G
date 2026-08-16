# Clock definitions only. Split from pins.xdc and exceptions.xdc per B.6 -
# each file reviewable on its own (fpga_project_flow.md Stage 6).
#
# 50 MHz Sitime active crystal oscillator, the board's only clock source for
# this skeleton (ALINX AX7035B User Manual, Part 5 "50M Active Crystal
# Oscillator": "The crystal output is connected to the FPGA's global clock
# (GCLK Pin Y18)."). Stage 6's rule applies from the first build: an
# undeclared clock is not checked, and the tool reports success anyway - so
# even a throwaway blinky gets a real create_clock.
create_clock -name clk50 -period 20.000 [get_ports clk50]

#############################################################################
# Stage 5: the design's real clocks
#############################################################################
#
# rx_clk is recovered by the KSZ9031RNX's CDR from the link partner and driven
# in on RX_CLK. It is asynchronous to everything the MMCM makes (R19, B.1b) --
# different oscillators, no phase relationship, and the FIFO in gem_rx_fifo is
# the only place multi-bit data crosses between them.
create_clock -name rgmii_rx_clk -period 8.000 [get_ports rgmii_rx_clk]

# tx_clk and gtx_clk_shifted are MMCM outputs and are NOT declared here.
# create_generated_clock would be wrong twice over: Vivado derives both from
# create_clock on clk50 through the MMCM automatically, and hand-writing them
# means two descriptions of one circuit that drift the first time a parameter
# changes. What must be declared by hand is only what enters the chip.
#
# The two domains are asynchronous, and saying so is not optional: without it
# the tools will try to time paths between them, and the RX FIFO's Gray-coded
# pointers -- which are correct precisely because they tolerate arriving at any
# phase -- would be reported as failures that cannot be fixed.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk50] \
    -group [get_clocks rgmii_rx_clk]
