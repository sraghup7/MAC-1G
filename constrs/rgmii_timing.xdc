# RGMII I/O delay constraints (R14, R20, closes V-2's static half).
# Derivation: Documents/RGMII I-O Timing Derivation.md.
#
# Structure follows reference/verilog-ethernet/syn/quartus/rgmii_io.sdc: a
# virtual reference clock stands in for the driving PHY's own undelayed
# clock, set_input_delay/set_output_delay are expressed against it on both
# edges (RGMII is DDR), and the non-corresponding edge pairs between the
# virtual clock and the real one are false-pathed so static timing does not
# check capture events that cannot occur.

#############################################################################
# RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk (already
# create_clock'd in constrs/clocks.xdc)
#############################################################################

# rgmii_rx_clk_virt is the PHY's own *undelayed* reference: edge-aligned with
# RXD/RX_DV, phase 0, driving nothing. The real rgmii_rx_clk is that clock
# delayed 2.000 ns by the PHY, and constrs/clocks.xdc declares it
# -waveform {2.000 6.000} to say exactly that. The two numbers below are
# derived from that 2.000 ns and the RGMII v2.0 receive window, and they only
# mean what they say while that waveform is present:
#
#   max = phase - TsetupR_min       = 2.000 - 1.000 =  1.000 ns
#   min = phase - (UI - TholdR_min) = 2.000 - 3.000 = -1.000 ns
#
# max - min = 2.000 ns of transition uncertainty per 4.000 ns unit interval,
# i.e. a declared eye of exactly TsetupR_min + TholdR_min = 2.000 ns, which is
# the guarantee the datasheet actually gives.
#
# CORRECTION (B.5 bring-up, 2026-08-27): the phase term was 1.200, the
# KSZ9031RNX's assumed default RX_CLK delay. B.5 found the physical chip is a
# JLSemi JL2121(D) (spec/PROJECT_SPEC.md A.2's correction), whose RXDLY strap
# is confirmed populated for +2.000 ns, not a continuously-adjustable ~1.2 ns
# default (Manuals/AX7035B_UG.pdf Table 8-1). TsetupR_min/TholdR_min = 1.000
# ns did NOT change -- the JL2121(D)'s own datasheet (DS009-JL2121(D)-v1.09-
# Preliminary, Table "RGMII Timing With Delay Integrated At Transmitter")
# gives the identical 1.0/2.0 ns min/typ figures, since both chips target the
# same RGMII v2.0 receive window. Only the phase term moved, shifting max/min
# by +0.800 ns each while the 2.000 ns eye width is unchanged.
create_clock -name rgmii_rx_clk_virt -period 8.000

set rx_data_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

set_input_delay -clock rgmii_rx_clk_virt -max 1.000 $rx_data_ports
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -max 1.000 -clock_fall $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 -clock_fall $rx_data_ports -add_delay

# The capture clock is the DESKEWED MMCM output (u_clk_rst/u_rx_mmcm's
# CLKOUT0 through u_bufg_rx), not the raw pin clock. Addressing it by object,
# because a hierarchical path that goes stale would make these exceptions
# silently apply to nothing -- the "the tool reports success and is checking
# nothing" class this whole chain started from.
#
# XDC has no control flow, so the ASSERTION that the lookup matched exactly
# one clock cannot be written here -- an `if` in this file is itself a
# CRITICAL WARNING and gate 0 refuses it (measured). The assertion lives in
# scripts/build.tcl instead, which re-runs this exact lookup after synthesis
# and refuses unless it resolved to one clock. Until that check ran and
# passed, these four lines mean nothing either way -- which is why the check
# is a gate and not a comment.
set rx_cap_clk [get_clocks -quiet -of_objects \
    [get_pins -quiet u_clk_rst/u_rx_mmcm/u_bufg_rx/O]]

set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -fall_to $rx_cap_clk -setup
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -rise_to $rx_cap_clk -setup
set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -rise_to $rx_cap_clk -hold
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -fall_to $rx_cap_clk -hold

#############################################################################
# TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by
# gtx_clk_shifted (the MMCM's CLKOUT1, forwarded through its own ODDR --
# gem_rgmii_tx.u_oddr_gtx).
#############################################################################
#
# CORRECTION (B.5 bring-up, 2026-08-27): the output-delay values below were
# 2.000/1.200, the KSZ9031RNX's assumed TsetupT/TholdT window -- the
# requirement AT THE PHY's OWN PINS when the PHY itself does not delay its
# GTX_CLK input, so the FPGA must generate the whole skew (which
# rtl/gem_mmcm.v's now-historical -55 deg phase shift did). B.5 found the
# physical chip is a JLSemi JL2121(D) (spec/PROJECT_SPEC.md A.2's
# correction), whose TXDLY strap is confirmed populated: "add 2 ns delay to
# rgmii TX_CLK" (Manuals/AX7035B_UG.pdf Table 8-1; JL2121(D) datasheet Table
# 16). TX_CLK/TXC is an INPUT to the PHY, so that describes the PHY delaying
# its OWN internal use of the clock it receives before latching TXD --
# industry-standard RGMII-ID convention -- not a launch requirement on the
# FPGA. The FPGA-side target is instead the OTHER RGMII timing table in the
# same datasheet chapter (4.7.3 "RGMII Timing", not "...With Delay
# Integrated At Transmitter"): TskewT, data-to-clock output skew at the
# launching device, -500 to +500 ps, which the values below check for
# directly. Reaching it is NOT simply "launch GTX_CLK and TXD/TX_CTL from the
# same clock phase" -- that first attempt (CLKOUT1_PHASE = 0.000) measured a
# TX hold failure post-route, because GTX_CLK is itself forwarded through an
# extra ODDR+OBUF hop that TXD/TX_CTL's own launch reference does not carry,
# a ~1.1 ns native FPGA-internal asymmetry TskewT's window cannot absorb.
# rtl/gem_mmcm.v's CLKOUT1_PHASE = +70.000 (+1.5556 ns) cancels that measured
# asymmetry; see its header for the swept, measured margins at each phase
# tried.
create_generated_clock -name rgmii_gtx_clk_gen \
    -source [get_pins u_mac/*u_rgmii_tx/u_oddr_gtx/*/C] \
    -divide_by 1 \
    [get_ports rgmii_gtx_clk]

set tx_data_ports [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

# WARNING (B.5 bring-up, 2026-08-27): SETUP SLACK AGAINST THESE FOUR
# CONSTRAINTS IS ANTI-CORRELATED WITH WHETHER THE TX LINK ACTUALLY WORKS.
# Measured on hardware across a CLKOUT1_PHASE sweep -- WNS rose monotonically
# (+0.019, +0.130, +0.241, +0.322, +0.574 ns) while the echo payload error
# rate rose with it (0, 0, 0.075%, 1.1%, ~27%). The reason is stated plainly
# a few lines up and in Documents/RGMII I-O Timing Derivation.md: this budget
# models FPGA-INTERNAL skew only, because "board trace length/skew is not in
# this budget -- B.1b never had trace-length data to put there." The real
# limit on this board is that missing term, and it moves the opposite way.
#
# So these checks passing is necessary and NOT sufficient, and improving the
# number is not an improvement. Never retune rtl/gem_mmcm.v's CLKOUT1_PHASE
# by maximising WNS here -- that is how it ended up at +70.000, which built
# with more margin than the +60.000 that actually works. Retune it with
# sw/host/gem_host.py echo over thousands of frames instead.
set_output_delay -clock rgmii_gtx_clk_gen -max 0.500 $tx_data_ports
set_output_delay -clock rgmii_gtx_clk_gen -min -0.500 $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -max 0.500 -clock_fall $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -min -0.500 -clock_fall $tx_data_ports -add_delay
