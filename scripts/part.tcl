#############################################################################
# The part string, in one place.
#
# The board is an XC7A35T-2FGG484I. This install offers xc7a35ti/fgg484 in
# -1L only (data/parts/installed_devices.txt, confirmed live with
# `get_parts -filter {DEVICE =~ "xc7a35t*" && PACKAGE == "fgg484"}`, which
# returned xc7a35tfgg484-1/-2/-2L/-3, xc7a35tifgg484-1L, xc7a35tlfgg484-2L and
# nothing else), so that is what is targeted until the -2I device pack is
# added via Vivado's "Add Design Tools or Devices".
#
# The mismatch is deliberate and its direction is the point: -1L is SLOWER
# than the board's -2I, so every slack number measured here is pessimistic.
# Timing that closes on -1L closes on the real part. The opposite substitution
# -- the commercial xc7a35tfgg484-2, which this install does have -- would be
# faster than the board and would let a design that cannot make 125 MHz sign
# off as though it could. Speed grade may be wrong in the safe direction only.
#
# It lives in its own file because it was written twice: build.tcl called itself
# the single point of truth for it while synth_module.tcl carried a second copy,
# and the two would have drifted the first time one of them was updated. The
# same rule the RTL follows for sized constants (gem_mac_params.vh) applies to
# the build scripts.
#############################################################################

set PART "xc7a35tifgg484-1L"
