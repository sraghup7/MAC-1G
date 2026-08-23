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
create_clock -name rgmii_rx_clk -period 8.000 -waveform {1.200 5.200} \
    [get_ports rgmii_rx_clk]

# The 1.200 ns waveform shift is not cosmetic. It is the KSZ9031RNX's default
# RX_CLK delay (B.1b: 1.2 ns typical relative to RXD/RX_DV, out of reset, no
# MDIO write), declared relative to the idealised zero-delay launch reference
# that constrs/rgmii_timing.xdc calls rgmii_rx_clk_virt. It is a modelling
# phase, not a claim about an externally observable absolute: this clock has no
# defined phase relationship to anything else in the design -- it is grouped
# asynchronous to clk50's tree below, and every rx_clk-internal
# register-to-register check is expressed against this clock's own edges, so
# shifting all of them together changes none of those checks. The one place the
# number is load-bearing is the RX input-delay check in
# constrs/rgmii_timing.xdc, which reads it as "the real clock's edges arrive
# 1.200 ns after where the PHY's own undelayed edges would be". Do not drop the
# waveform without re-deriving that file's RX section with it.
#
# The input delays in constrs/rgmii_timing.xdc are derived from this 1.200 and
# the RGMII v2.0 receive window; the two files must change together.

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
#
# The RX group is taken WITH its generated clocks: since Stage 6 part 2 the RX
# domain runs on the deskew MMCM's output, which is a new clock object derived
# from rgmii_rx_clk and is NOT named by a bare [get_clocks rgmii_rx_clk]. A
# bare name here would leave every clk50-tree <-> RX-domain path -- the FIFO's
# Gray pointers, the five pulse synchronisers, all of them correct by
# construction -- timed as if synchronous, failing on paths that cannot be
# fixed by placement. -include_generated_clocks matches the form the clk50
# group already uses.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk50] \
    -group [get_clocks -include_generated_clocks rgmii_rx_clk]
