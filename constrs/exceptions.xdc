# Timing exceptions (false paths, multicycle paths, CDC-crossing set_max_delay
# constraints). Split out per B.6 so every exception is reviewable on its own
# - Stage 6's rule: "never write an exception you cannot justify out loud."
#
# Empty for the Stage 2 skeleton: a single free-running counter driving LEDs
# has no path that needs excepting. This file exists now so later stages
# (the rx_clk/tx_clk crossings in B.1b, the MDIO clock domain) have an
# obvious home instead of exceptions accreting into pins.xdc or clocks.xdc.
