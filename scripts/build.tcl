#############################################################################
# Non-project-mode build script - gem_mac Stage-2 skeleton (skeleton_top).
#
# Why non-project mode (fpga_project_flow.md Stage 2, "Project mode vs
# non-project mode"): no .xpr project file, no GUI-tracked state that can't
# be reviewed. This script IS the build - read it top to bottom and you know
# exactly what Vivado did, on any machine, every time.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/build.tcl -tclargs <target>
#   target: synth | impl | bitstream   (default: bitstream)
#
# Each target reuses the checkpoint from the previous stage's work within
# this same run - there is no cross-invocation checkpoint reuse (every
# invocation starts a fresh in-memory design). That's deliberate for a
# skeleton this small; a real gem_mac build would read back post_synth.dcp
# for an `impl`-only re-run instead of re-synthesizing.
#############################################################################

# ---- 0. Config -------------------------------------------------------------

# Single point of truth for the part string. xc7a35tifgg484-1L is what this
# machine's Vivado install currently has for the FGG484/industrial-grade
# combination. The board is XC7A35T-2FGG484I per ALINX (manual + product
# page) and per distributor listings (DigiKey/Mouser/LCSC all stock it) -
# swap this the instant the -2I device pack is installed via Vivado's "Add
# Design Tools or Devices". See spec/PROJECT_SPEC.md changelog for the note.
set PART       "xc7a35tifgg484-1L"
set TOP         skeleton_top
set BUILD_DIR   "build"
set RTL_SOURCES [list rtl/skeleton_top.v]
set XDC_SOURCES [list constrs/clocks.xdc constrs/pins.xdc constrs/exceptions.xdc]

set TARGET "bitstream"
if {[llength $argv] > 0} { set TARGET [lindex $argv 0] }

file mkdir $BUILD_DIR

# ---- 1. Read sources --------------------------------------------------------

puts "==> Reading RTL sources: $RTL_SOURCES"
read_verilog $RTL_SOURCES

puts "==> Reading constraints: $XDC_SOURCES"
read_xdc $XDC_SOURCES

# ---- 2. Synthesis -----------------------------------------------------------

puts "==> Synthesizing (part=$PART top=$TOP)"
synth_design -top $TOP -part $PART

write_checkpoint -force "$BUILD_DIR/post_synth.dcp"

# Gate 1: zero inferred latches, no exceptions. (Stage 2: "fail on inferred
# latches"; Stage 4 sidebar: "any inferred latch is a bug, no exceptions.")
set latches [get_cells -hierarchical -filter {PRIMITIVE_SUBGROUP == "latch"}]
if {[llength $latches] > 0} {
    puts "FATAL: inferred latch(es) detected:"
    foreach l $latches { puts "  $l" }
    puts "Build refused: inferred latches present."
    exit 1
}

# Gate 1b: the synthesiser SAID it inferred a latch, even if optimisation then
# removed the cell so gate 1 could not see it.
#
# This is not hypothetical. An incomplete always @(*) whose output happens to be
# dead -- unused, or overridden by another driver -- is reported as
# "[Synth 8-327] inferring latch for variable ..." and then quietly deleted, so
# the netlist is clean and gate 1 passes. The RTL is still wrong: the same
# incomplete assignment becomes a real latch the moment that signal starts being
# used, and the change that makes it load-bearing will be somewhere else
# entirely. The flow doc's rule is "any inferred latch is a bug, no exceptions",
# and that means the inference, not merely the surviving cell.
if {[catch {set latch_msgs [get_msg_config -id "Synth 8-327" -count]} err]} {
    puts "FATAL: cannot query latch-inference messages: $err"
    puts "Build refused: gate 1b could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
if {$latch_msgs > 0} {
    puts "FATAL: synthesis inferred $latch_msgs latch(es) (Synth 8-327)."
    puts "They may have been optimised away -- that does not make the RTL"
    puts "correct. Search the log above for 'inferring latch for variable'."
    puts "Build refused: latch inferred during synthesis."
    exit 1
}

puts "==> Latch check: PASS (0 inferred latches, 0 inference warnings)"

# Resource inference counts. (Stage 2: "print resource inference counts, so
# unexpected changes surface at synthesis." Trivial today - a counter and
# some wires - but this is the line that will catch a CRC generator quietly
# becoming LUT logic instead of a DSP block once the real gem_mac RTL lands.)
set util_rpt [report_utilization -return_string]
puts "==> Post-synthesis utilization:"
puts $util_rpt
set fh [open "$BUILD_DIR/post_synth_utilization.rpt" w]
puts $fh $util_rpt
close $fh

if {$TARGET eq "synth"} {
    puts "==> Target 'synth' reached. Stopping."
    return
}

# ---- 3. Implementation -------------------------------------------------------

puts "==> Optimizing / placing / routing"
opt_design
place_design
route_design

write_checkpoint -force "$BUILD_DIR/post_route.dcp"

set util_rpt [report_utilization -return_string]
set fh [open "$BUILD_DIR/post_route_utilization.rpt" w]
puts $fh $util_rpt
close $fh

set timing_rpt [report_timing_summary -return_string]
set fh [open "$BUILD_DIR/post_route_timing.rpt" w]
puts $fh $timing_rpt
close $fh

# Gate 2: WNS/WHS >= 0. (Stage 2: "fail on negative slack - the tool will
# otherwise write a broken bitstream and report success"; Stage 7: "never
# program a bitstream with negative slack.")
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold] 0]]
puts "==> WNS (setup) = $wns ns, WHS (hold) = $whs ns"
if {$wns < 0} {
    puts "Build refused: negative setup slack (WNS = $wns ns)."
    exit 1
}
if {$whs < 0} {
    puts "Build refused: negative hold slack (WHS = $whs ns)."
    exit 1
}
puts "==> Timing check: PASS (WNS=$wns ns, WHS=$whs ns)"

if {$TARGET eq "impl"} {
    puts "==> Target 'impl' reached. Stopping."
    return
}

# ---- 4. Bitstream -------------------------------------------------------------

puts "==> Writing bitstream"
write_bitstream -force "$BUILD_DIR/${TOP}.bit"
puts "==> DONE: $BUILD_DIR/${TOP}.bit"
