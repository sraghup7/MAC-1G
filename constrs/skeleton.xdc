# Constraints for rtl/skeleton_top.v only -- the Stage 2 blinker, which B.5
# step 1 loads to prove power, JTAG and a clock reaching the fabric before any
# of the real design is trusted.
#
# It has its own file because constraints follow the top. Reading the board's
# full pin set against a module with two ports leaves every get_ports empty,
# and Vivado's response is a CRITICAL WARNING per line and a clean exit 0 --
# which is how this repository spent Stage 5 with a build that constrained
# nothing and said it had succeeded. Gate 0 in scripts/build.tcl now refuses
# that, so the skeleton needs constraints that match the skeleton.
#
# The five pin numbers below are duplicated from constrs/pins.xdc, which is
# the copy to change first if a board revision moves them. That is a knowing
# exception to "no constant is written twice": the alternative was dropping
# the skeleton build entirely, and a bring-up step whose bitstream cannot be
# rebuilt is a worse trade than five repeated numbers.

# 50 MHz Sitime active oscillator -- bank 14, 3.3V, MRCC-capable.
create_clock -name clk50 -period 20.000 [get_ports clk50]
set_property PACKAGE_PIN Y18      [get_ports clk50]
set_property IOSTANDARD  LVCMOS33 [get_ports clk50]

# User LEDs LED1-LED4 -- bank 16, active low. Deliberately unconstrained for
# timing and said out loud, exactly as constrs/exceptions.xdc says it for the
# real design: these drive human eyes at ~0.4 Hz and there is no external
# device sampling them.
set_property PACKAGE_PIN F19      [get_ports {led[0]}]
set_property PACKAGE_PIN E21      [get_ports {led[1]}]
set_property PACKAGE_PIN D20      [get_ports {led[2]}]
set_property PACKAGE_PIN C20      [get_ports {led[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]
