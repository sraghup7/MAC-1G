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
