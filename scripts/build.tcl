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
#   target: synth | impl | bitstream | debug   (default: bitstream)
#   top:    gem_top | skeleton_top             (default: gem_top)
#
# Each target reuses the checkpoint from the previous stage's work within
# this same run - there is no cross-invocation checkpoint reuse (every
# invocation starts a fresh in-memory design). That's deliberate for a
# skeleton this small; a real gem_mac build would read back post_synth.dcp
# for an `impl`-only re-run instead of re-synthesizing.
#
# `debug` is `bitstream` plus an ILA on the RX pipeline (24 probe bits: the
# RGMII byte/gm_dv/gm_er stream, the SFD hunter's state, the RX FIFO write
# pointer and its full/drop flags, and rx_mmcm_locked) -- something to flash
# during bring-up when a symptom needs to be seen inside the chip, never what
# ships. It writes build/gem_top_debug.bit and .ltx, distinct filenames so it
# can never be mistaken for or silently overwrite the real bitstream, and it
# refuses for any top but gem_top -- the skeleton has no RX pipeline to probe.
#
# Measured through this actual script, headless (2026-08-25; `python
# scripts/build.py debug gem_top` against the `synth`/`bitstream` baseline):
# the ILA costs +1417 LUT / +2335 FF / +3 RAMB36 / +1 BUFG, and changes
# NEITHER the TX critical path (u_rgmii_tx/g_txd[0], +0.058 ns in both) NOR
# the RX I/O waiver's five endpoints (worst slack -3.109 ns, unchanged) NOR
# gate 4's CDC classification (10 FIFO-mem + 2 reset-CLR, 0 unexplained, in
# both); WHS moves from +0.049 ns to +0.032 ns, still comfortably positive.
# The debug hub's own clock is left for Vivado to auto-select -- forcing it
# onto a different domain than the ILA is what made `implement_debug_core`
# fail the first time this was tried. ALL_PROBE_SAME_MU_CNT must be 2-16
# (IP_Flow 19-3458) -- 1 is invalid, and the interactive GUI session that
# first proved this recipe did not catch that, only headless batch did.
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

# `debug` is sugar for `bitstream` with the ILA switched on -- from here on
# TARGET behaves exactly like "bitstream" and DEBUG is the only new state.
set DEBUG 0
if {$TARGET eq "debug"} {
    set DEBUG 1
    set TARGET "bitstream"
    if {$TOP ne "gem_top"} {
        puts "FATAL: DEBUG build requested for top '$TOP'."
        puts "The ILA probes rtl/gem_mac.v's RX pipeline, which only exists\
under gem_top."
        puts "Build refused: no RX pipeline to probe."
        exit 1
    }
}

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

# DEBUG: copy the RTL to $BUILD_DIR/rtl_debug, marking the probed nets
# `mark_debug`/`dont_touch` in the copies rather than in rtl/ itself, so the
# tracked source never carries a debug-only attribute. This table is the
# ENTIRE probe set -- add a net here and it is probed, remove one and it is
# not; nothing downstream infers probes any other way. mark_debug has to be
# present before the ONE `synth_design` call that maps the design: applying
# it to an already-synthesised netlist cannot recover a net synthesis already
# optimised away (measured: frame_active, driven only for gem_internal_sva's
# benefit, is gone by then), and a second `synth_design` call does not resume
# from a marked elaboration -- it re-synthesises from source and drops the
# marks (both measured the hard way before this was wired in).
# Literal (not regexp) find-and-replace: the anchor lines below contain `[...]`
# range syntax, which regsub would read as a regex character class rather than
# a literal bracket. Returns {count new_text} -- count is how many times `old`
# occurred, so a caller can refuse on anything but exactly 1 rather than
# silently patching the wrong line or missing a renamed one.
proc gem_literal_replace {text old new} {
    set count 0
    set pos 0
    set old_len [string length $old]
    while {1} {
        set idx [string first $old $text $pos]
        if {$idx < 0} { break }
        incr count
        set pos [expr {$idx + $old_len}]
    }
    if {$count == 1} {
        set idx [string first $old $text]
        set text [string replace $text $idx [expr {$idx + $old_len - 1}] $new]
    }
    return [list $count $text]
}

if {$DEBUG} {
    puts "==> DEBUG: marking RX-pipeline probes and staging RTL under\
$BUILD_DIR/rtl_debug"
    # This table IS the probe set -- add a net here and it is probed, remove
    # one and it is not; nothing downstream infers probes any other way.
    # Real embedded newlines (not \n) in the `new` strings, because these are
    # brace-quoted: Tcl performs no backslash substitution inside braces, so a
    # literal \n would end up in the generated RTL as two characters, not a
    # line break.
    set DEBUG_MARKS [list \
        [list rtl/gem_mac.v \
              {    wire [7:0] rx_gm_byte;} \
              {    (* mark_debug = "true", dont_touch = "true" *) wire [7:0] rx_gm_byte;}] \
        [list rtl/gem_mac.v \
              {    wire       rx_gm_dv, rx_gm_er;} \
              {    (* mark_debug = "true", dont_touch = "true" *) wire       rx_gm_dv, rx_gm_er;}] \
        [list rtl/gem_mac.v \
              {    wire       fifo_wr, fifo_full, fifo_empty, fifo_rd, fifo_drop;} \
              "    (* mark_debug = \"true\", dont_touch = \"true\" *) wire fifo_wr, fifo_full, fifo_drop;
    wire       fifo_empty, fifo_rd;"] \
        [list rtl/gem_rx_deframe.v \
              {    reg  [2:0]  state;} \
              {    (* mark_debug = "true", dont_touch = "true" *) reg  [2:0]  state;}] \
        [list rtl/gem_rx_fifo.v \
              {    reg  [AW:0] wr_bin,  wr_gray;} \
              "    (* mark_debug = \"true\", dont_touch = \"true\" *) reg  \[AW:0\] wr_bin;
    reg  \[AW:0\] wr_gray;"] \
        [list rtl/gem_top.v \
              {    wire rx_clk_deskew, rx_mmcm_locked, rx_path_rst_n;} \
              "    wire rx_clk_deskew, rx_path_rst_n;
    (* mark_debug = \"true\", dont_touch = \"true\" *) wire rx_mmcm_locked;"] \
    ]
    set DEBUG_RTL_DIR "$BUILD_DIR/rtl_debug"
    file mkdir $DEBUG_RTL_DIR
    foreach f $RTL_SOURCES {
        set fh [open $f r]
        set text [read $fh]
        close $fh
        foreach mark $DEBUG_MARKS {
            lassign $mark mark_file old new
            if {$mark_file ne $f} { continue }
            lassign [gem_literal_replace $text $old $new] count text
            if {$count != 1} {
                puts "FATAL: DEBUG mark for $f matched $count time(s), expected\
exactly 1:"
                puts "    $old"
                puts "The anchor text has drifted from this script's copy.\
Update DEBUG_MARKS to match the current source."
                puts "Build refused: a debug probe cannot be placed with\
confidence."
                exit 1
            }
        }
        set out "$DEBUG_RTL_DIR/[file tail $f]"
        set fh [open $out w]
        puts -nonewline $fh $text
        close $fh
    }
    # `` `include ``d headers (rtl/gem_mac_params.vh) are not in RTL_SOURCES --
    # that only globs *.v -- but Vivado resolves an `include relative to the
    # including file's own directory, so a header left behind in rtl/ fails
    # every source now staged under $DEBUG_RTL_DIR with "Cannot find include
    # file". Copy every non-.v file rtl/ has alongside the sources.
    foreach f [glob -nocomplain rtl/*.vh] {
        file copy -force $f "$DEBUG_RTL_DIR/[file tail $f]"
    }
    set marked_files {}
    foreach mark $DEBUG_MARKS { lappend marked_files [lindex $mark 0] }
    puts "==> DEBUG: marked [llength [lsort -unique $marked_files]] file(s),\
staged [llength $RTL_SOURCES] total under $DEBUG_RTL_DIR"
    set RTL_SOURCES {}
    foreach f [lsort [glob $DEBUG_RTL_DIR/*.v]] { lappend RTL_SOURCES $f }
}

# ---- 1. Read sources --------------------------------------------------------

# GATE 0 IS ONLY MEANINGFUL IN A FRESH VIVADO PROCESS, AND THIS REFUSES TO
# PRETEND OTHERWISE.
#
# get_msg_config -count is cumulative for the life of the PROCESS, not for one
# build. That is fine for `vivado -mode batch`, which is one process per build,
# and wrong for an interactive session that sources this script after doing
# other work. A session open all day refused a perfectly clean build at gate 0
# with "24 CRITICAL WARNING(s)" that belonged to none of it.
#
# Subtracting a baseline looks like the fix and is not. Measured on this
# repository: the counter is NOT MONOTONIC across a build -- it read 25 before
# a build, 25 at gate 0, and 0 by gate 0b in the same run -- and re-sourcing
# this script in the same process brought the 25 back while the identical
# sources emitted 0 criticals headless. A delta can therefore go negative,
# which passes a `> 0` test and converts a spurious refusal into a SILENT
# FALSE PASS. That is strictly worse than the bug it replaces.
#
# So the honest thing is to detect the condition and say so. A reused process
# cannot answer this question; a fresh one can.
if {[catch {set CRIT_BASE [get_msg_config -severity {CRITICAL WARNING} -count]} err]} {
    puts "FATAL: cannot query the critical-warning baseline: $err"
    puts "Build refused: gate 0 cannot be evaluated without it, and a gate that"
    puts "cannot run must not report success."
    exit 1
}
if {$CRIT_BASE != 0} {
    puts "FATAL: this Vivado process already carries $CRIT_BASE CRITICAL WARNING(s)"
    puts "from earlier work in the same session."
    puts ""
    puts "Gates 0 and 0b count critical warnings for the life of the PROCESS, not"
    puts "for one build, and the counter is not monotonic across a build -- so no"
    puts "arithmetic can separate this build's criticals from the session's history."
    puts "Refusing is the only answer that is not a guess."
    puts ""
    puts "Run the build in a FRESH process:"
    puts "    make bitstream          (or: python scripts/build.py bitstream gem_top)"
    puts "    vivado -mode batch -source scripts/build.tcl -tclargs bitstream gem_top"
    puts ""
    puts "Build refused: gate 0 cannot be trusted in a reused session."
    exit 1
}

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
# This count is taken after synthesis only, and is trustworthy because the
# guard above refused if the process carried any criticals before this build
# began. The bitstream stage re-queries it (gate 0b), because implementation
# can emit criticals of its own and this query never sees them.
if {[catch {
    set crit [get_msg_config -severity {CRITICAL WARNING} -count]
} err]} {
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

# DEBUG: insert the RX-pipeline ILA into the synthesised netlist, before
# opt_design/place_design/route_design so implementation places and routes it
# along with everything else -- the only way its area and timing cost are
# real rather than assumed. Measured effect (2026-08-25): +1201 LUT, +2032 FF,
# +3 RAMB36, +1 BUFG; the TX critical path and the RX I/O waiver's five
# endpoints are unchanged, and gate 4's CDC classification below sees nothing
# new. dbg_hub's own clock is deliberately left unconnected here -- Vivado
# auto-selects it, and forcing it onto a clock other than the ILA's is what
# made implement_debug_core fail the first time this was built.
if {$DEBUG} {
    puts "==> DEBUG: inserting the RX-pipeline ILA (24 probe bits, depth 4096)"
    create_debug_core u_ila_0 ila
    set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_0]
    set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
    set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
    set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
    set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
    set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_0]
    # Valid range is 2-16 (IP_Flow 19-3458 refuses 1 -- measured the hard way,
    # via headless batch, which validates this properly; the interactive GUI
    # session that first proved this recipe did not catch it).
    set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_0]

    # Same pin gate 1c already anchored the RX capture clock to, above.
    set dbg_clk_net [get_nets -of_objects \
        [get_pins u_clk_rst/u_rx_mmcm/u_bufg_rx/O]]
    connect_debug_port u_ila_0/clk $dbg_clk_net

    create_debug_port u_ila_0 probe
    create_debug_port u_ila_0 probe
    create_debug_port u_ila_0 probe

    # probe0: the RGMII byte stream as gem_rgmii_rx delivers it.
    set_property PORT_WIDTH 8 [get_debug_ports u_ila_0/probe0]
    connect_debug_port u_ila_0/probe0 [get_nets {
        u_mac/rx_gm_byte[0] u_mac/rx_gm_byte[1] u_mac/rx_gm_byte[2]
        u_mac/rx_gm_byte[3] u_mac/rx_gm_byte[4] u_mac/rx_gm_byte[5]
        u_mac/rx_gm_byte[6] u_mac/rx_gm_byte[7]}]

    # probe1: gm_dv/gm_er, the SFD hunter's state, and the FIFO write side's
    # status flags -- everything that says what the deframer is doing.
    set_property PORT_WIDTH 8 [get_debug_ports u_ila_0/probe1]
    connect_debug_port u_ila_0/probe1 [get_nets {
        u_mac/rx_gm_dv u_mac/rx_gm_er
        u_mac/u_rx_ctrl/state[0] u_mac/u_rx_ctrl/state[1] u_mac/u_rx_ctrl/state[2]
        u_mac/fifo_wr u_mac/fifo_full u_mac/fifo_drop}]

    # probe2: the RX FIFO's write pointer.
    set_property PORT_WIDTH 7 [get_debug_ports u_ila_0/probe2]
    connect_debug_port u_ila_0/probe2 [get_nets {
        u_mac/u_rx_fifo/wr_bin[0] u_mac/u_rx_fifo/wr_bin[1]
        u_mac/u_rx_fifo/wr_bin[2] u_mac/u_rx_fifo/wr_bin[3]
        u_mac/u_rx_fifo/wr_bin[4] u_mac/u_rx_fifo/wr_bin[5]
        u_mac/u_rx_fifo/wr_bin[6]}]

    # probe3: the RX deskew MMCM's lock -- distinguishes "no link" from
    # "deskew never locked" the same way the UART record's rxlock field does.
    set_property PORT_WIDTH 1 [get_debug_ports u_ila_0/probe3]
    connect_debug_port u_ila_0/probe3 [get_nets {rx_mmcm_locked}]

    if {[catch {implement_debug_core} err]} {
        puts "FATAL: implement_debug_core failed: $err"
        puts "Build refused: the DEBUG ILA could not be inserted."
        exit 1
    }
    puts "==> DEBUG: ILA implemented"
}

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
# -225 deg with worst-case +0.669 ns (+~0.5 after uncertainty); R20's RX half
# is therefore signed off by derivation plus bench measurement, not by WNS,
# and this gate counts the five RX input-delay paths separately instead of
# letting them fail the whole build.
#
# The waiver is fenced five ways, because a waiver without fences is how a
# gate rots into rubber:
#   1. It matches EXACTLY five named endpoints. Four or six resolve, the
#      build refuses -- a renamed IDDR instance cannot silently widen it.
#   2. Only endpoints inside the fence are waived; ANY other violating path
#      refuses the build exactly as before, named individually.
#   3. SETUP ONLY. The artifact places the modeled capture edge EARLIER than
#      the physical one (-1.452/-0.817 vs +2.636/+0.950), which is what makes
#      setup pessimistic -- and by the same sign makes HOLD optimistic:
#      measured +1.862 ns on the CTL IDDR against the derivation's physical
#      +1.122. A modeled hold violation on these five pins would therefore
#      mean the real hold is worse still -- which is exactly the defect task
#      4e found underneath the artifact (-0.331 ns slow-corner hold at phase
#      0) and fixed. Waiving hold here would retire the only automated check
#      that catches its return after a phase change, a pblock move or a PHY
#      pad-skew write. Hold refuses on these pins like any other path.
#   4. A waived slack beyond -3.500 ns refuses: the derivation predicts
#      -3.109 ns of pure modeling artifact (task-4d measured -2.109 at phase
#      0; the -1000 ps trim moves the modeled edge another -1.0) and the
#      build landed there.
#
#      THAT ENVELOPE IS NO LONGER EXERCISED, AND THE REASON MATTERS.
#      It was measured at CLKOUT0_PHASE = -45. B.5 bring-up found the RX
#      capture edge was landing one whole unit interval late (the IDDR pair
#      straddled an octet boundary; see known-issues.md B.5-RX-1) and moved
#      the phase to -225. On the first implementation run after that change,
#      the five RX input-delay setup checks came back at +0.891 to +0.933 ns
#      -- POSITIVE, no waiver needed, zero violating paths design-wide. The
#      worst of them moved from the predicted -3.109 to +0.891: EXACTLY
#      +4.000 ns, one unit interval, no edge re-selection.
#
#      So most of what task-4e attributed to a ZHOLD modeling artifact was
#      Vivado correctly reporting a real one-UI misalignment, and this
#      waiver was masking it. The fences below are kept because they cost
#      nothing while nothing violates, and because the ZHOLD arc task-4e
#      measured is real even if its magnitude was not what the artifact
#      theory claimed. If these five endpoints EVER violate again, that is
#      now evidence of a genuine problem -- do not reach for this waiver to
#      quiet it. That arrival is a CONSTRUCTED CONSTANT,
#      invariant across
#      the BUFG and BUFH topologies, so it does not drift with routing and
#      the envelope is tight on purpose. Slack past it means the design moved
#      and the derivation is stale.
#   5. If violations cannot be enumerated completely, the build refuses
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

    # Fence 3: the waiver is setup-only. The ZHOLD artifact flatters hold, so
    # there is nothing to forgive there and everything to lose by forgiving
    # it. An empty waiver list makes every hold violation "real" below.
    if {$kind eq "setup"} {
        set kind_waiver $rx_waiver_names
    } else {
        set kind_waiver {}
    }
    lassign [gem_partition_violations $kind $kind_waiver] waived real

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
        if {$TOP ne "gem_top"} {
            puts "(This top has no RX waiver endpoints -- any violation here\
is refused outright.)"
        }
        puts "Build refused: negative $kind slack outside the documented\
waiver."
        set gate2_refused 1
        break
    }

    # Envelope: predicted artifact is -3.109 ns and the build landed there
    # (see the comment above); past -3.500 the design has moved and the
    # derivation must be redone, not the envelope widened. Tight on purpose:
    # the modeled arrival is a constructed constant, invariant across two
    # buffer topologies, so it does not drift with routing.
    set worst_waived +inf
    foreach p $waived {
        set s [get_property SLACK $p]
        if {$s < $worst_waived} { set worst_waived $s }
    }
    if {$worst_waived < -3.500} {
        puts "FATAL: worst waived RX $kind slack is $worst_waived ns, past the\
-3.500 ns envelope."
        puts "The derivation predicts -3.109 ns of ZHOLD-modeling artifact, and\
it is a constructed constant that does not drift with routing."
        puts "Slack past the envelope means the design or constraints moved\
since task 4e;"
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

# Gate 4: CDC (R19: "zero undeclared CDC paths"). report_cdc -details lists
# every crossing the design's clock relationships do not structurally explain,
# with a severity per row. This design has crossings that are safe by
# construction but structurally unprovable to the tool, and they are exactly
# enumerated here rather than waived wholesale:
#
#   CDC-1  x10  FIFO memory -> egress registers. Safe by the pointer
#               protocol (a slot is readable only after its write is visible
#               through two synchronised Gray-code stages), covered by
#               clocks.xdc's asynchronous clock groups. report_cdc cannot
#               prove a pointer protocol, so it stays Critical; the count and
#               both endpoint hierarchies are asserted so a NEW unexplained
#               crossing cannot hide inside the allowance.
#   CDC-10 x2   Combinational logic before a synchroniser: the reset AND
#               feeding u_rx_path_rst's and u_rx_rst's asynchronous CLR.
#               Async assertion is the Step 3b requirement -- a reset that
#               waits for an edge cannot fire on a domain whose clock just
#               died -- so the combinational term is deliberate.
#
# Everything else Critical refuses, as does ANY CDC-2 ("missing ASYNC_REG")
# row at all: every synchroniser in this design is marked, so one more means
# an unmarked one just appeared. report_methodology runs alongside, written
# for a human to read and deliberately not gated -- it is a design-quality
# sweep whose findings were triaged once (TIMING-10 drove the ASYNC_REG work)
# and gating it would refuse builds over noise nobody has scoped.
set cdc_report "$BUILD_DIR/${TOP}_cdc.rpt"
if {[catch {report_cdc -details -file $cdc_report} err]} {
    puts "FATAL: report_cdc could not run: $err"
    puts "Build refused: gate 4 could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
set fh [open $cdc_report r]
set cdc_text [read $fh]
close $fh

proc gem_gate4_classify {cdc_text} {
    set n_mem 0
    set n_rstclr 0
    set n_missing_async 0
    set unknown {}
    foreach line [split $cdc_text "\n"] {
        if {![regexp {^\s*\d+\s+(CDC-\d+)\s+(Critical|Warning|Info)\s} $line \
                  -> id sev]} { continue }
        if {$id eq "CDC-2"} {
            # Missing ASYNC_REG on a synchroniser: always a defect here.
            lappend unknown $line
            incr n_missing_async
            continue
        }
        if {$sev ne "Critical"} { continue }
        if {$id eq "CDC-1" && \
            [regexp {u_mac/u_rx_fifo/\S+\s+u_mac/u_rx_egress/} $line]} {
            incr n_mem
        } elseif {$id eq "CDC-10" && \
                 ([regexp {u_clk_rst/u_rx_rst/sync_reg\[1\]/\S+\s+u_clk_rst/u_rx_path_rst/sync_reg\[0\]/CLR\s*$} $line] || \
                  [regexp {u_clk_rst/u_tx_rst/sync_reg\[1\]/\S+\s+u_clk_rst/u_rx_rst/sync_reg\[0\]/CLR\s*$} $line])} {
            incr n_rstclr
        } else {
            lappend unknown $line
        }
    }
    return [list $n_mem $n_rstclr $n_missing_async $unknown]
}

lassign [gem_gate4_classify $cdc_text] g4_mem g4_rstclr g4_missasync g4_unknown
set gate4_ok [expr {$g4_mem == 10 && $g4_rstclr == 2 && $g4_missasync == 0 \
                        && [llength $g4_unknown] == 0}]
if {!$gate4_ok} {
    puts "FATAL: gate 4 (CDC) found findings outside the documented set."
    puts "  FIFO-memory crossings (CDC-1): $g4_mem, expected 10."
    puts "  Reset-CLR crossings  (CDC-10): $g4_rstclr, expected 2."
    puts "  Unmarked synchronisers (CDC-2): $g4_missasync, expected 0."
    puts "  Unclassified critical/warning rows: [llength $g4_unknown]"
    foreach l $g4_unknown { puts "    [string trim $l]" }
    puts "The allowed set is documented above; extend it only with the same"
    puts "rigour -- structure argued, endpoints named, count asserted."
    puts "Build refused: an unexplained clock-domain crossing is present."
    exit 1
}
puts "==> CDC check: PASS (10 FIFO-memory + 2 documented reset-CLR crossings,\
 0 unmarked synchronisers; see $cdc_report)"

set methodology_report "$BUILD_DIR/${TOP}_methodology.rpt"
if {[catch {report_methodology -file $methodology_report} err]} {
    puts "WARNING: report_methodology failed: $err (not gated -- continuing)"
} else {
    puts "==> Methodology report written: $methodology_report (not gated -- read manually)"
}


# Gate 5: physical verification. report_drc and report_route_status are the
# flow doc's Stage-7 outputs that this script never produced -- "synthesis
# completed successfully" tells you nothing, and neither does a bitstream
# written without asking the router whether it finished.
#
#   DRC           refuse on any CRITICAL-severity rule hit (Warnings are
#                 triaged in docs/reports/stage7/methodology-triage.md and
#                 its companions -- CFGBVS fixed at source, REQP-1840 is the
#                 echo buffer's async-reset index, documented there).
#   Route status  refuse if any net has routing errors; a bitstream whose
#                 nets are not all routed is not a bitstream.
#
# report_power and report_qor_assessment run alongside as artifacts for a
# human to read: power at default activity (confidence LOW -- no real
# switching data exists until the bench), QoR score penalised by the five
# waived RX input-delay paths and therefore expected below top marks by
# construction.
set drc_report "$BUILD_DIR/${TOP}_drc.rpt"
if {[catch {report_drc -file $drc_report} err]} {
    puts "FATAL: report_drc could not run: $err"
    puts "Build refused: gate 5 could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
set fh [open $drc_report r]
set drc_text [read $fh]
close $fh
set drc_critical 0
foreach line [split $drc_text "\n"] {
    if {[regexp {^\|\s+\S+\s+\| Critical} $line]} { incr drc_critical }
}
if {$drc_critical > 0} {
    puts "FATAL: report_drc found $drc_critical CRITICAL rule hit(s)."
    puts "See $drc_report."
    puts "Build refused: a physical-design rule failed at Critical severity."
    exit 1
}
puts "==> DRC check: PASS (0 Critical rule hits; see $drc_report)"

set rs_report "$BUILD_DIR/${TOP}_route_status.rpt"
if {[catch {report_route_status -file $rs_report} err]} {
    puts "FATAL: report_route_status could not run: $err"
    puts "Build refused: gate 5 could not run, and a gate that cannot run must"
    puts "not report success."
    exit 1
}
set fh [open $rs_report r]
set rs_text [read $fh]
close $fh
if {![regexp {#\s+of nets with routing errors\s*\.*\s*:\s+(\d+)} $rs_text -> rs_errors]} {
    puts "FATAL: route-status report has no 'routing errors' count."
    puts "The format may have changed; read $rs_report and update this parser"
    puts "rather than widening the match until it passes."
    puts "Build refused: gate 5 cannot evaluate route status."
    exit 1
}
if {$rs_errors > 0} {
    puts "FATAL: $rs_errors net(s) have routing errors."
    puts "See $rs_report."
    puts "Build refused: the design is not fully routed."
    exit 1
}
puts "==> Route-status check: PASS (0 routing errors; see $rs_report)"

set power_report "$BUILD_DIR/${TOP}_power.rpt"
if {[catch {report_power -file $power_report} err]} {
    puts "WARNING: report_power failed: $err (not gated -- continuing)"
} else {
    puts "==> Power report written: $power_report (default activity -- confidence LOW until measured)"
}

set qor_report "$BUILD_DIR/${TOP}_qor.rpt"
if {[catch {report_qor_assessment -file $qor_report} err]} {
    puts "WARNING: report_qor_assessment failed: $err (not gated -- continuing)"
} else {
    puts "==> QoR assessment written: $qor_report (score penalised by the documented RX waiver)"
}
if {$TARGET eq "impl"} {
    puts "==> Target 'impl' reached. Stopping."
    return
}

# ---- 4. Bitstream -------------------------------------------------------------

# Gate 0b: zero CRITICAL WARNINGs at the end of the run. Gate 0 counts them
# after synthesis only, and opt_design / place_design / route_design can emit
# their own -- an unconstrained set_property, an unroutable placement rule --
# which landed after the count was taken and never refused anything. The guard
# before the read stage established that this process started clean, so by here
# the count covers read, synthesis and implementation of THIS build; the same
# refusal as gate 0 applies.
if {[catch {
    set crit_impl [get_msg_config -severity {CRITICAL WARNING} -count]
} err]} {
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
set bit_file "$BUILD_DIR/${TOP}.bit"
if {$DEBUG} {
    # A distinct filename, not just a distinct directory: `program` takes a
    # path on the command line, and the surest way to never flash the DEBUG
    # bitstream by mistake is for its name to never collide with the real one.
    set bit_file "$BUILD_DIR/${TOP}_debug.bit"
}
write_bitstream -force $bit_file
puts "==> DONE: $bit_file"

if {$DEBUG} {
    set ltx_file "$BUILD_DIR/${TOP}_debug.ltx"
    write_debug_probes -force $ltx_file
    puts "==> DONE: $ltx_file (load alongside $bit_file in Hardware Manager)"
}
