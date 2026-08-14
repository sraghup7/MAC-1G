# Physical pin locations and I/O standards only (see clocks.xdc / exceptions.xdc).
#
# Source: ALINX AX7035B User Manual (manualslib.com/manual/2994570, ALINX's
# own product page confirms the same board). Pin numbers cross-checked
# against the XC7A35T-2FGG484I package database in Vivado (bank assignments
# below), not just copied from the manual text.
#
# Voltage: manual Part 4 "FPGA power supply system" states BANK34 (DDR3) is
# 1.5V and "the voltage of other BANK is 3.3V"; BANK16 is LDO-supplied and
# "can be changed by replacing the LDO chip" but the manual gives no evidence
# the board ships with anything other than the default 3.3V. ASSUMPTION,
# not yet confirmed against the physical board - re-check (e.g. probe the
# LDO output or read back IO after program) at first bring-up if LEDs don't
# light as expected. Same caution as A.2's PHY-identity correction in the
# spec: trust the physical board over any document the moment they disagree.

# Clock input - bank 14, 3.3V
set_property PACKAGE_PIN  Y18 [get_ports clk50]
set_property IOSTANDARD   LVCMOS33 [get_ports clk50]

# User LEDs LED1-LED4 - bank 16, 3.3V (assumed, see note above)
set_property PACKAGE_PIN  F19 [get_ports {led[0]}]
set_property PACKAGE_PIN  E21 [get_ports {led[1]}]
set_property PACKAGE_PIN  D20 [get_ports {led[2]}]
set_property PACKAGE_PIN  C20 [get_ports {led[3]}]
set_property IOSTANDARD   LVCMOS33 [get_ports {led[*]}]
