#############################################################################
# The part string, in one place.
#
# xc7a35tifgg484-1L is what this machine's Vivado install currently has for the
# FGG484/industrial-grade combination. The board is XC7A35T-2FGG484I per ALINX
# (manual + product page) and per distributor listings - swap this the instant
# the -2I device pack is installed via Vivado's "Add Design Tools or Devices".
#
# It lives in its own file because it was written twice: build.tcl called itself
# the single point of truth for it while synth_module.tcl carried a second copy,
# and the two would have drifted the first time one of them was updated. The
# same rule the RTL follows for sized constants (gem_mac_params.vh) applies to
# the build scripts.
#############################################################################

set PART "xc7a35tifgg484-1L"
