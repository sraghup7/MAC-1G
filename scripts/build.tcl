#############################################################################
# Non-project-mode build script. Builds rtl/gem_top.v -- the board -- by
# default, or rtl/skeleton_top.v for B.5 step 1.
#
# Why non-project mode (fpga_project_flow.md Stage 2, "Project mode vs
# non-project mode"): no .xpr project file, no GUI-tracked state that can't
# be reviewed. This script IS the build - read it top to bottom and you know
# exactly what Vivado did, on any machine, every time.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/build.tcl -tclargs <target> [<top>]
#   target: synth | impl | bitstream   (default: bitstream)
#   top:    gem_top | skeleton_top     (default: gem_top)
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
set BUILD_DIR "build"

# Which top to build. Stage 6 makes gem_top the default: the board is the
# thing being built now, and a default that still pointed at the blinker is
# how `make bitstream` produced a Stage 2 artefact for a whole stage after the
# design existed.
set TOP    "gem_top"
set TARGET "bitstream"
if {[llength $argv] > 0} { set TARGET [lindex $argv 0] }
if {[llength $argv] > 1} { set TOP    [lindex $argv 1] }

# Sources AND constraints both follow the top -- see constrs/skeleton.xdc for
# why the blinker cannot simply borrow the board's.
switch -exact -- $TOP {
    gem_top {
        # Every design file except the Stage 2 skeleton, which is a different
        # top with nothing to do with the MAC. Same rule as
        # scripts/synth_module.tcl, so the two cannot drift about what the
        # design consists of.
        set RTL_SOURCES {}
        foreach f [lsort [glob rtl/*.v]] {
            if {[file tail $f] ne "skeleton_top.v"} { lappend RTL_SOURCES $f }
        }
        set XDC_SOURCES [list constrs/clocks.xdc constrs/pins.xdc \
                              constrs/exceptions.xdc constrs/rgmii_timing.xdc]
    }
    skeleton_top {
        set RTL_SOURCES [list rtl/skeleton_top.v]
        set XDC_SOURCES [list constrs/skeleton.xdc]
    }
    default {
        puts "FATAL: unknown top '$TOP'."
        puts "Known tops: gem_top (the board), skeleton_top (the Stage 2 blinker)."
        exit 1
    }
}

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
#
# This count is taken after synthesis only. The bitstream stage re-queries it
# (gate 0b), because implementation can emit criticals of its own and this
# query never sees them.
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

# Gate 1c: the RX capture clock must resolve, exactly once. constrs/
# rgmii_timing.xdc false-paths its RX input-delay exceptions against the
# deskewed MMCM's output clock, addressed by object -- and XDC has no control
# flow, so the assertion the design document calls for (Documents/RX Clock
# Deskew Design.md, constraints step 2) cannot live there. It lives here,
# after synthesis when the netlist hierarchy exists: if the instance path
# ever goes stale, the four set_false_path lines would silently apply to
# nothing while every gate stayed green -- the exact failure class V-14 was.
set rx_cap_clk [get_clocks -quiet -of_objects \
    [get_pins -quiet u_clk_rst/u_rx_mmcm/u_bufg_rx/O]]
if {[llength $rx_cap_clk] != 1} {
    puts "FATAL: the RX capture-clock lookup resolved to [llength $rx_cap_clk]\
clock(s), expected exactly 1."
    puts "constrs/rgmii_timing.xdc's RX exceptions would silently apply to\
nothing. Fix the path u_clk_rst/u_rx_mmcm/u_bufg_rx/O in both files or"
    puts "rename the instances together."
    puts "Build refused: the RGMII receive exceptions are not anchored."
    exit 1
}
puts "==> RX capture-clock anchor check: PASS ([get_property NAME [lindex $rx_cap_clk 0]])"

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

# Gate 3: nothing important may be unconstrained. It runs BEFORE the timing
# gate, on purpose: WNS >= 0 is worth nothing on a path nobody constrained --
# a path outside timing analysis has no slack to be negative -- so coverage is
# the more fundamental check, and its verdict has to come first. It also lets
# this script prove both halves honestly while the design is deliberately red
# at gate 2 (Stage 6 part 2: the RX hold violation awaits the deskew fix): this
# gate still runs, passes on the fully-constrained design, and can be shown to
# refuse the moment any constraint line is deleted.
#
# On the Stage 2 skeleton Vivado said directly what an unconstrained design
# gets away with:
#
#   WARNING: [Place 30-2953] Timing driven mode will be turned off because no
#                            critical terminals were found.
#
# The build was reporting a healthy 17.2 ns while the placer had timing
# analysis switched off. R20 asks for "WNS >= 0, RGMII I/O constrained", and
# the second half is the half that a passing WNS can hide -- which is precisely
# how a wrongly-constrained pin reaches the bench having passed every check.
#
# Every check_timing condition refuses. For ports that means: constrained
# with real values (the RGMII pins, constrs/rgmii_timing.xdc) or declared
# exempt with a written justification (constrs/exceptions.xdc). A port that
# lands in neither pile is not a style problem; it is a pin whose timing
# relationship nobody stated, and the build stops until somebody does.
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

# For the I/O-delay checks the TOC count alone cannot be used: check_timing
# lumps deliberately-exempted ports into it. A port carrying only a false path
# still appears under no_input_delay/no_output_delay -- measured here on the
# first fully-wired build: rst_key_n/key_clear_n/mdio and the LEDs counted
# there despite their written justifications in constrs/exceptions.xdc. The
# section body is where Vivado separates the two cases, and only the first
# sentence of each section counts ports constrained by nothing at all:
#
#   There are 0 input ports with no input delay specified.        <- refuses
#   There are 3 input ports with no input delay but user has a     <- accepted,
#   false path constraint. (MEDIUM)                                   justified
#   There is 1 port with no output delay but with a timing clock   <- accepted,
#   defined on it or propagating through it (LOW)                forwarded clk
#
# Singular/plural both occur ("There is 1 port..." / "There are N ports..."),
# so the match allows either verb.
proc gem_check_unconstrained {text name} {
    # Anchor to the DETAILED section, not the table of contents: both carry
    # "checking <name> (N)", but only the detailed heading is followed by a
    # dashed underline. Matching the TOC entry instead silently captures every
    # section before this one, and the first "delay specified" sentence found
    # then belongs to whichever section precedes -- measured here as
    # partial_input_delay reading no_input_delay's zero. A parser that returns
    # a number is not the same as a parser that read the right section.
    if {![regexp "checking ${name} \\(\\d+\\)\n-+\n(.*?)\n\\d+\\. checking" \
              $text -> body]} {
        puts "FATAL: check_timing report has no '$name' section."
        puts "Build refused: gate 3 cannot confirm that check ran."
        exit 1
    }
    if {![regexp {(?:There are|There is) (\d+) [^\n]*delay specified\.} \
              $body -> n]} {
        puts "FATAL: check_timing's '$name' section has no 'delay specified'"
        puts "count. The report format may have changed; read"
        puts "$BUILD_DIR/check_timing.rpt and update this parser rather than"
        puts "widening the match until it passes."
        puts "Build refused: gate 3 cannot evaluate this check."
        exit 1
    }
    return $n
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

# Ports: every one must be either constrained with real values or exempted
# with a justification in constrs/exceptions.xdc. What refuses is a port with
# neither -- a timing relationship nobody has stated.
foreach {check description} {
    no_input_delay       "input port(s) with no input delay specified"
    no_output_delay      "output port(s) with no output delay specified"
    partial_input_delay  "input port(s) with only a partial input delay"
    partial_output_delay "output port(s) with only a partial output delay"
} {
    set n [gem_check_unconstrained $ct_text $check]
    if {$n > 0} {
        puts "FATAL: check_timing reports $n $description ($check)."
        puts "See $ct_report. Every port must be either constrained with real"
        puts "values or exempted with a justification in constrs/exceptions.xdc;"
        puts "an unlisted port means a timing relationship nobody has stated."
        puts "Build refused: the design is not fully covered by timing analysis."
        exit 1
    }
}

puts "==> Constraint coverage check: PASS (see $ct_report)"

# Gate 2: WNS/WHS >= 0 -- with ONE documented exception. (Stage 2: "fail on
# negative slack - the tool will otherwise write a broken bitstream and report
# success"; Stage 7: "never program a bitstream with negative slack.")
#
# THE EXCEPTION, AND WHY IT IS NOT THE THIN END OF A WEDGE. Task 4e
# (docs/reports/stage6-part2/task-4e-report.md) proved, by measuring the
# routed feedback path against the arc the tool applies, that Vivado's ZHOLD
# model freezes this MMCM's capture-clock arrival at a constant independent of
# routing (-1.452/-0.817 ns vs the physical +2.636/+0.950), injecting ~2.3 ns
# of phantom spread that lands entirely on the five RX input-delay checks.
# No constraint lever removes it: manual generated-clock override leaves the
# arc intact (measured), COMPENSATION=EXTERNAL is rejected for any on-chip
# feedback loop ([Timing 38-290], measured). The physical margins -- loop
# fixed point, per corner, same-corner pairing -- close at CLKOUT0_PHASE =
# -45 deg with worst-case +0.669 ns (+~0.5 after uncertainty); R20's RX half
# is therefore signed off by derivation plus bench measurement, not by WNS,
# and this gate counts the five RX input-delay paths separately instead of
# letting them fail the whole build.
#
# The waiver is fenced four ways, because a waiver without fences is how a
# gate rots into rubber:
#   1. It matches EXACTLY five named endpoints. Four or six resolve, the
#      build refuses -- a renamed IDDR instance cannot silently widen it.
#   2. Only endpoints inside the fence are waived; ANY other violating path
#      refuses the build exactly as before, named individually.
#   3. A waived slack beyond -5.000 ns refuses: the derivation predicts about
#      -3.1 ns of pure modeling artifact (task-4d measured -2.109 at phase 0;
#      the -45 deg trim moves the modeled edge another -1.0). Slack beyond
#      the envelope means the design moved and the derivation is stale.
#   4. If violations cannot be enumerated completely, the build refuses
#      rather than passing on a partial list.
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

# The waiver exists only for the board top. The skeleton has no RX pins, and
# a fence that refuses the blinker would just teach everyone to bypass gates.
if {$TOP eq "gem_top"} {
    # Five exact names, not a wildcard pattern: four data cells under the
    # g_rxd generate block (dot-separated: g_rxd[0].u_iddr) and the CTL cell
    # beside them. Exactness IS the fence -- an instance rename resolves to
    # fewer than five and refuses the build below.
    set rx_waiver_pins [get_pins -quiet {
        u_mac/u_rgmii_rx/g_rxd[0].u_iddr/u_iddr/D
        u_mac/u_rgmii_rx/g_rxd[1].u_iddr/u_iddr/D
        u_mac/u_rgmii_rx/g_rxd[2].u_iddr/u_iddr/D
        u_mac/u_rgmii_rx/g_rxd[3].u_iddr/u_iddr/D
        u_mac/u_rgmii_rx/u_iddr_ctl/u_iddr/D
    }]
    if {[llength $rx_waiver_pins] != 5} {
        puts "FATAL: the RX I/O waiver endpoint lookup resolved to\
[llength $rx_waiver_pins] pin(s), expected exactly 5."
        puts "The waiver may only cover the five RGMII receive data/CTL IDDR\
inputs (task-4e). An instance rename under rtl/gem_rgmii_rx.v changes what"
        puts "this matches -- resolve it there and here together, never by\
widening the pattern."
        puts "Build refused: the RX I/O timing waiver is not anchored."
        exit 1
    }
    set rx_waiver_names {}
    foreach p $rx_waiver_pins { lappend rx_waiver_names [get_property NAME $p] }
} else {
    set rx_waiver_names {}
}

# Split every violating path of one check into waived (endpoint is one of the
# five fenced IDDR inputs) and real. Refuses when the enumeration cannot be
# proven complete: -max_paths caps the query, and hitting the cap means more
# violations may exist unseen, which is not a passable state.
# Endpoint identity needs care: depending on tool version the path's
# endpoint property hands back a pin object or its name. Try NAME and fall
# back to the raw value rather than assuming either. (The properties are
# ENDPOINT_PIN/STARTPOINT_PIN on 2024.2 timing paths -- "ENDPOINT" does not
# exist, measured as [Common 17-54].)
proc gem_endpoint_name {ep} {
    if {[catch {get_property NAME $ep} n]} { return $ep }
    return $n
}

proc gem_partition_violations {kind waiver_names} {
    set cap 200
    set viol [get_timing_paths -$kind -slack_lesser_than 0 -max_paths $cap \
                  -nworst 1]
    if {[llength $viol] >= $cap} {
        puts "FATAL: $kind has reached the $cap-path enumeration cap while\
partitioning violations."
        puts "A design this far from closure cannot be waived piecemeal; the\
derivation in docs/reports/stage6-part2/task-4e-report.md does not cover it."
        puts "Build refused: $kind violations too numerous to partition."
        exit 1
    }
    set waived {}
    set real {}
    foreach p $viol {
        set ep [gem_endpoint_name [get_property ENDPOINT_PIN $p]]
        if {[lsearch -exact $waiver_names $ep] >= 0} {
            lappend waived $p
        } else {
            lappend real $p
        }
    }
    return [list $waived $real]
}

set wns [gem_worst_slack setup]
set whs [gem_worst_slack hold]
puts "==> WNS (setup) = $wns ns, WHS (hold) = $whs ns"

set gate2_refused 0
foreach kind {setup hold} {
    set worst [expr {$kind eq "setup" ? $wns : $whs}]
    if {$worst >= 0} { continue }
    lassign [gem_partition_violations $kind $rx_waiver_names] waived real

    if {[llength $real] > 0} {
        puts "FATAL: $kind violated on [llength $real] path(s) outside the\
RX I/O waiver:"
        foreach p $real {
            puts "    [gem_endpoint_name [get_property STARTPOINT_PIN $p]] ->\
[gem_endpoint_name [get_property ENDPOINT_PIN $p]] :\
[get_property SLACK $p] ns"
        }
        puts "The task-4e waiver covers only the five RGMII RX IDDR input\
checks; everything else must meet timing outright."
        puts "Build refused: negative $kind slack outside the documented\
waiver."
        set gate2_refused 1
        break
    }

    # Envelope: predicted artifact is ~-3.1 ns (see the comment above); past
    # -5.000 the design has moved and the derivation must be redone, not the
    # envelope widened.
    set worst_waived +inf
    foreach p $waived {
        set s [get_property SLACK $p]
        if {$s < $worst_waived} { set worst_waived $s }
    }
    if {$worst_waived < -5.000} {
        puts "FATAL: worst waived RX $kind slack is $worst_waived ns, past the\
-5.000 ns envelope."
        puts "The derivation predicts about -3.1 ns of ZHOLD-modeling artifact.\
Slack this far out means the design or constraints moved since task 4e;"
        puts "redo the derivation, never widen the number."
        puts "Build refused: RX I/O waiver envelope exceeded."
        set gate2_refused 1
        break
    }

    if {[llength $waived] > 0} {
        puts "==> RX I/O waiver ($kind): [llength $waived] path(s), worst\
$worst_waived ns -- signed off by derivation plus bench measurement\
(docs/reports/stage6-part2/task-4e-report.md)."
    }
}
if {$gate2_refused} { exit 1 }

puts "==> Timing check: PASS (WNS=$wns ns, WHS=$whs ns; RX I/O waived per\
task-4e where applicable)"

if {$TARGET eq "impl"} {
    puts "==> Target 'impl' reached. Stopping."
    return
}

# ---- 4. Bitstream -------------------------------------------------------------

# Gate 0b: zero CRITICAL WARNINGs at the end of the run. Gate 0 counts them
# after synthesis only, and opt_design / place_design / route_design can emit
# their own -- an unconstrained set_property, an unroutable placement rule --
# which landed after the count was taken and never refused anything. The
# counter is cumulative for this session, so by here it covers read, synthesis
# and implementation together; the same refusal as gate 0 applies.
if {[catch {set crit_impl [get_msg_config -severity {CRITICAL WARNING} -count]} err]} {
    puts "FATAL: cannot query critical-warning count after implementation: $err"
    puts "Build refused: gate 0b could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
if {$crit_impl > 0} {
    puts "FATAL: $crit_impl CRITICAL WARNING(s) across read, synthesis and"
    puts "implementation. Search vivado.log for 'CRITICAL WARNING'."
    puts "Build refused: the build is not clean."
    exit 1
}
puts "==> Critical-warning check (post-implementation): PASS (0 critical warnings)"

puts "==> Writing bitstream"
write_bitstream -force "$BUILD_DIR/${TOP}.bit"
puts "==> DONE: $BUILD_DIR/${TOP}.bit"
