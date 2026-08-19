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

# The part string lives in scripts/part.tcl, which both this script and
# synth_module.tcl source. It used to be written here and again there, under a
# comment in this file claiming to be its single point of truth.
source scripts/part.tcl
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

# Gate 0: zero CRITICAL WARNINGs, and it comes first because it catches the
# one class of failure every other gate here structurally cannot -- a
# constraint that matched nothing.
#
# When get_ports finds no port, Vivado says "'set_property' expects at least
# one object", raises a CRITICAL WARNING, and carries on to a clean exit 0.
# The design is then unpinned, or unclocked, or both, and gates 1, 1b and 2
# pass on it exactly as they pass on a correct build -- gate 2 especially,
# because WNS >= 0 is nearly free when no path is constrained enough to have
# negative slack (V-14 found precisely that, the hard way).
#
# Measured on this repository at the close of Stage 5: `make synth` emitted 68
# CRITICAL WARNINGs and exited 0, because constrs/ described gem_top while
# this script still built skeleton_top. That is the defect this gate was
# written against; it did not need planting.
if {[catch {set crit [get_msg_config -severity {CRITICAL WARNING} -count]} err]} {
    puts "FATAL: cannot query critical-warning count: $err"
    puts "Build refused: gate 0 could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
if {$crit > 0} {
    puts "FATAL: $crit CRITICAL WARNING(s) during read and synthesis."
    puts "Search vivado.log for 'CRITICAL WARNING'. The usual cause is a"
    puts "constraint whose get_ports/get_clocks matched nothing, which leaves"
    puts "the design unconstrained while every later gate still passes."
    puts "Build refused: the build is not clean."
    exit 1
}
puts "==> Critical-warning check: PASS (0 critical warnings)"

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
# Fetch the worst path for each check, and refuse plainly if there is not one.
#
# get_timing_paths returns an empty list when the design has no analysable
# paths -- most often because no clock is defined. get_property SLACK on that
# yields "", and Tcl compares "" < 0 as *strings*, which is true, so the build
# was refused with "negative setup slack (WNS =  ns)". Refusing was the right
# direction by luck; the diagnosis was wrong, and "negative slack" would send
# someone hunting a timing problem that does not exist instead of a missing
# create_clock.
proc gem_worst_slack {kind} {
    set paths [get_timing_paths -max_paths 1 -nworst 1 -$kind]
    if {[llength $paths] == 0} {
        puts "FATAL: the design has no $kind timing paths to analyse."
        puts "Almost always this means no clock is defined -- check"
        puts "constrs/clocks.xdc. A design with nothing to analyse must not"
        puts "pass a timing gate."
        puts "Build refused: no $kind timing paths."
        exit 1
    }
    set s [get_property SLACK [lindex $paths 0]]
    if {![string is double -strict $s]} {
        puts "FATAL: worst $kind slack came back as '$s', which is not a number."
        puts "A path object exists but carries no slack, which means timing was"
        puts "never analysed for it -- check that constrs/clocks.xdc defines a"
        puts "clock covering this design."
        puts "Build refused: gate 2 could not evaluate slack, and a gate that"
        puts "cannot evaluate must not report success."
        exit 1
    }
    return $s
}

set wns [gem_worst_slack setup]
set whs [gem_worst_slack hold]
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

# Gate 3: nothing important may be unconstrained.
#
# WNS >= 0 is worth very little on its own, because a path nobody constrained
# has no slack to be negative. On the Stage 2 skeleton Vivado said so directly:
#
#   WARNING: [Place 30-2953] Timing driven mode will be turned off because no
#                            critical terminals were found.
#
# The build was reporting a healthy 17.2 ns while the placer had timing
# analysis switched off. R20 asks for "WNS >= 0, RGMII I/O constrained", and
# the second half is the half that a passing WNS can hide -- which is precisely
# how a wrongly-constrained pin reaches the bench having passed every check.
#
# So check_timing runs, and the two conditions that are unambiguous bugs at any
# stage refuse the build: a register with no clock reaching it, and an internal
# endpoint with nothing constraining it. Ports with no I/O delay are listed
# rather than refused, because on this skeleton the LEDs legitimately have none
# -- they are declared as false paths in constrs/exceptions.xdc. When Stage 6
# adds the RGMII I/O constraints, this becomes a refusal too.
set ct_report "$BUILD_DIR/check_timing.rpt"
check_timing -file $ct_report -verbose

if {![file exists $ct_report]} {
    puts "FATAL: check_timing produced no report at $ct_report."
    puts "Build refused: gate 3 could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}

set fh [open $ct_report r]
set ct_text [read $fh]
close $fh

# The report's table of contents carries every check and its count as
# "N. checking <name> (COUNT)", which is the stable thing to parse -- the prose
# in each section varies with singular/plural and with sub-cases.
proc gem_check_count {text name} {
    if {[regexp "checking ${name} \\((\\d+)\\)" $text -> n]} { return $n }
    # A check that is missing from the report did not run, which is not the
    # same as a clean result and must not be treated as one.
    puts "FATAL: check_timing report has no '$name' entry."
    puts "Build refused: gate 3 cannot confirm that check ran."
    exit 1
}

# Unambiguous bugs at any stage: sequential logic with no clock, endpoints
# timing analysis never reaches, combinational or latch loops, and a register
# fed by more than one clock.
foreach {check description} {
    no_clock                          "register/latch pin(s) with no clock reaching them"
    constant_clock                    "register/latch pin(s) clocked by a constant"
    unconstrained_internal_endpoints  "internal endpoint(s) unconstrained for maximum delay"
    multiple_clock                    "register/latch pin(s) reached by multiple clocks"
    loops                             "combinational loop(s)"
    latch_loops                       "latch loop(s)"
} {
    set n [gem_check_count $ct_text $check]
    if {$n > 0} {
        puts "FATAL: check_timing reports $n $description ($check)."
        puts "See $ct_report."
        puts "Build refused: the design is not fully covered by timing analysis."
        exit 1
    }
}

# Reported, not refused. On this skeleton the LEDs genuinely have no timing
# requirement and are declared as false paths in constrs/exceptions.xdc --
# check_timing recognises that and says so ("no output delay but user has a
# false path constraint"). Once Stage 6 adds R20's RGMII I/O constraints, an
# unconstrained port becomes a refusal here, because at that point every pin
# that reaches the PHY has a real timing relationship to meet.
foreach {check description} {
    no_input_delay       "input port(s) with no input delay"
    no_output_delay      "output port(s) with no output delay"
    partial_input_delay  "input port(s) with only a partial input delay"
    partial_output_delay "output port(s) with only a partial output delay"
} {
    set n [gem_check_count $ct_text $check]
    if {$n > 0} {
        puts "==> check_timing: $n $description (see $ct_report)"
    }
}

puts "==> Constraint coverage check: PASS (see $ct_report)"

if {$TARGET eq "impl"} {
    puts "==> Target 'impl' reached. Stopping."
    return
}

# ---- 4. Bitstream -------------------------------------------------------------

puts "==> Writing bitstream"
write_bitstream -force "$BUILD_DIR/${TOP}.bit"
puts "==> DONE: $BUILD_DIR/${TOP}.bit"
