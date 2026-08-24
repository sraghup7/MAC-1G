#############################################################################
# make_project.tcl -- generate a throwaway Vivado GUI project.
#
# This repository builds in NON-PROJECT MODE (scripts/build.tcl): there is
# deliberately no committed .xpr. The flow doc's organising rule applies --
# "if the build can regenerate it, it does not go in version control", and
# the Vivado project file is in the ignored column. This script exists so a
# human can still browse the design in the GUI: run it once, then open
#
#     build/proj/gem_mac_proj.xpr
#
# Regenerate any time; -force overwrites without asking. Nothing here is
# load-bearing for the real build: scripts/build.tcl remains the only thing
# that produces bitstreams and runs the gates.
#
# Usage (from repo root):
#   D:/Vivado/2024.2/bin/vivado.bat -mode batch -source scripts/make_project.tcl
#
# The part string comes from scripts/part.tcl -- the same single point of
# truth the real build uses. Constraints follow the gem_top default exactly
# as build.tcl orders them. Testbenches are deliberately NOT added: they are
# driven by scripts/run_sim.py with their own harness, and dropping them into
# a GUI project invites Vivado to elaborate them its own way.
#############################################################################

source scripts/part.tcl

set PROJ_DIR "build/proj"
set TOP      "gem_top"

create_project gem_mac_proj $PROJ_DIR -part $PART -force

set rtl {}
foreach f [lsort [glob rtl/*.v]] {
    lappend rtl $f
}
add_files $rtl
set_property top $TOP [current_fileset]

add_files -fileset constrs_1 [list \
    constrs/clocks.xdc \
    constrs/pins.xdc \
    constrs/exceptions.xdc \
    constrs/rgmii_timing.xdc]

puts "==> Project created: $PROJ_DIR/gem_mac_proj.xpr"
puts "==> Top: $TOP on $PART, [llength $rtl] RTL files, 4 constraint files."
puts "==> Open it with:"
puts "    D:/Vivado/2024.2/bin/vivado.bat $PROJ_DIR/gem_mac_proj.xpr"
exit
