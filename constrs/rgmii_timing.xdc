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

create_clock -name rgmii_rx_clk_virt -period 8.000

set rx_data_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

set_input_delay -clock rgmii_rx_clk_virt -max 3.000 $rx_data_ports
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -max 3.000 -clock_fall $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 -clock_fall $rx_data_ports -add_delay

set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -fall_to [get_clocks rgmii_rx_clk] -setup
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -rise_to [get_clocks rgmii_rx_clk] -setup
set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -rise_to [get_clocks rgmii_rx_clk] -hold
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -fall_to [get_clocks rgmii_rx_clk] -hold

# (TX section added in Task 2, same file.)
