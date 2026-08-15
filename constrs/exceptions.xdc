# Timing exceptions (false paths, multicycle paths, CDC-crossing set_max_delay
# constraints). Split out per B.6 so every exception is reviewable on its own
# - Stage 6's rule: "never write an exception you cannot justify out loud."
#
# Later stages (the rx_clk/tx_clk crossings in B.1b, the MDIO clock domain) get
# their exceptions here rather than letting them accrete into pins.xdc.

#-----------------------------------------------------------------------------
# LED indicators -- deliberately unconstrained, said out loud.
#-----------------------------------------------------------------------------
#
# These drive human eyes at a few Hz. There is no setup or hold relationship to
# meet, and no external device sampling them, so there is genuinely nothing to
# constrain.
#
# The point of saying so explicitly is that "unconstrained because it does not
# matter" and "unconstrained because somebody forgot" look identical in a
# timing report, and the second one is how an RGMII pin reaches the bench with
# no constraint on it -- exactly the failure B.1 opens by warning about. An
# output that is not constrained should be an output somebody decided not to
# constrain, in a file a reviewer reads.
#
# Vivado's own view of the un-excepted design was blunt about it:
#   WARNING: [Place 30-2953] Timing driven mode will be turned off because no
#                            critical terminals were found.
# The build was reporting WNS = 17.2 ns while the placer had timing switched
# off entirely.
set_false_path -to [get_ports {led[*]}]
