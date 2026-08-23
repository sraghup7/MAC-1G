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
# delayed 1.200 ns by the PHY, and constrs/clocks.xdc declares it
# -waveform {1.200 5.200} to say exactly that. The two numbers below are
# derived from that 1.200 ns and the RGMII v2.0 receive window, and they only
# mean what they say while that waveform is present:
#
#   max = phase - TsetupR_min       = 1.200 - 1.000 =  0.200 ns
#   min = phase - (UI - TholdR_min) = 1.200 - 3.000 = -1.800 ns
#
# max - min = 2.000 ns of transition uncertainty per 4.000 ns unit interval,
# i.e. a declared eye of exactly TsetupR_min + TholdR_min = 2.000 ns, which is
# the guarantee the datasheet actually gives.
create_clock -name rgmii_rx_clk_virt -period 8.000

set rx_data_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

set_input_delay -clock rgmii_rx_clk_virt -max 0.200 $rx_data_ports
set_input_delay -clock rgmii_rx_clk_virt -min -1.800 $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -max 0.200 -clock_fall $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -min -1.800 -clock_fall $rx_data_ports -add_delay

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

create_generated_clock -name rgmii_gtx_clk_gen \
    -source [get_pins u_mac/*u_rgmii_tx/u_oddr_gtx/*/C] \
    -divide_by 1 \
    [get_ports rgmii_gtx_clk]

set tx_data_ports [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

set_output_delay -clock rgmii_gtx_clk_gen -max 2.000 $tx_data_ports
set_output_delay -clock rgmii_gtx_clk_gen -min 1.200 $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -max 2.000 -clock_fall $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -min 1.200 -clock_fall $tx_data_ports -add_delay
