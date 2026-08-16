#############################################################################
# Out-of-context synthesis of one module - Stage 4 step 6.
#
# "Synthesise this module alone - check area and rough timing against the
# Stage 1 estimate. Step 6 is the one beginners skip and seniors never do. Two
# minutes tells you whether your area estimate was right. Discovering a block
# is 3x your estimate is manageable now; discovering it after instantiating it
# thirty-two times is not."  (fpga_project_flow.md, Stage 4)
#
# It also settles something the specification openly does not know. B.7's
# closing paragraph admits that the LUT/FF/BRAM line items in B.2's resource
# table are "estimates whose derivation predates this revision and isn't
# traceable ... inherited, plausible-looking per-block guesses" - unlike the
# FIFO depth, the GTX_CLK phase and the R21 latency sum, which were derived
# bottom-up and checked. It names this exact step as where that gets fixed.
# So the numbers this script prints are evidence, and it refuses the build if
# the design has outgrown the budget rather than printing a number nobody reads.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/synth_module.tcl -tclargs [module]
#   default module: gem_mac  (the whole design, out of context)
#
# Out of context means no I/O buffers and no board: the point is the logic, not
# the pinout. Pin placement and I/O timing are Stage 6's job, and constrs/ is
# where they live.
#############################################################################

source scripts/part.tcl
set BUILD_DIR "build"

set TOP "gem_mac"
if {[llength $argv] > 0} { set TOP [lindex $argv 0] }

file mkdir $BUILD_DIR

# Every design file except the Stage 2 skeleton, which is a different top with
# nothing to do with the MAC.
set RTL_SOURCES {}
foreach f [lsort [glob rtl/*.v]] {
    if {[file tail $f] ne "skeleton_top.v"} { lappend RTL_SOURCES $f }
}

puts "==> Reading RTL: $RTL_SOURCES"
read_verilog $RTL_SOURCES

# No GEM_BEHAVIORAL_IO here, deliberately. Synthesis gets the Xilinx ODDR/IDDR
# primitives; the behavioural models exist for simulators that have no source
# for them. This run is therefore also the check that the primitive path
# elaborates at all, which no simulation covers.
puts "==> Synthesizing $TOP out of context (part=$PART)"
synth_design -top $TOP -part $PART -mode out_of_context

write_checkpoint -force "$BUILD_DIR/ooc_${TOP}.dcp"

# ---- Latch gates, same two as the main build ------------------------------
set latches [get_cells -hierarchical -filter {PRIMITIVE_SUBGROUP == "latch"}]
if {[llength $latches] > 0} {
    puts "FATAL: inferred latch(es) detected:"
    foreach l $latches { puts "  $l" }
    puts "Build refused: inferred latches present (R23)."
    exit 1
}
if {[catch {set latch_msgs [get_msg_config -id "Synth 8-327" -count]} err]} {
    puts "FATAL: cannot query latch-inference messages: $err"
    puts "Build refused: the latch gate could not run."
    exit 1
}
if {$latch_msgs > 0} {
    puts "FATAL: synthesis inferred $latch_msgs latch(es) (Synth 8-327)."
    puts "Build refused: latch inferred during synthesis (R23)."
    exit 1
}
puts "==> Latch check: PASS (0 inferred latches, 0 inference warnings)"

# ---- Gate: no memory may dissolve into flip-flops -------------------------
#
# Vivado cannot build a RAM whose contents have an asynchronous reset, so an
# array written inside a reset block silently becomes discrete registers plus a
# multiplexer tree. It says so and carries on:
#
#   [Synth 8-4767] Trying to implement RAM 'mem_reg' in registers.
#   RAM "mem_reg" dissolved into registers
#
# gem_rx_fifo did exactly this: 64 x 10 bits became 648 flip-flops and a
# MUXF7/MUXF8 tree -- roughly half the design's registers -- while the
# specification claimed distributed RAM. The build passed every gate, because
# nothing was wrong except the shape of the result, and nobody read the log.
#
# This gate is the flow doc's "print resource inference counts, so unexpected
# changes surface at synthesis" turned into a refusal. It has been demonstrated
# to fail: it is the check that would have caught the defect that motivated it.
if {[catch {set ram_msgs [get_msg_config -id "Synth 8-4767" -count]} err]} {
    puts "FATAL: cannot query RAM-inference messages: $err"
    puts "Build refused: the memory gate could not run."
    exit 1
}
if {$ram_msgs > 0} {
    puts "FATAL: $ram_msgs memory array(s) could not be implemented as RAM"
    puts "(Synth 8-4767) and were built from registers instead. Search the log"
    puts "for 'dissolved into registers'. The usual cause is a memory written"
    puts "inside a block with an asynchronous reset -- RAM contents cannot be"
    puts "reset, so move the write into its own reset-free always block and"
    puts "leave the pointers' resets alone."
    puts "Build refused: a memory dissolved into flip-flops."
    exit 1
}
puts "==> Memory inference check: PASS (0 arrays dissolved into registers)"

# ---- Area -----------------------------------------------------------------
set util_rpt [report_utilization -return_string]
puts $util_rpt
set fh [open "$BUILD_DIR/ooc_${TOP}_utilization.rpt" w]
puts $fh $util_rpt
close $fh

proc gem_count {pattern} {
    return [llength [get_cells -hierarchical -filter $pattern -quiet]]
}

set n_lut  [gem_count {PRIMITIVE_GROUP == LUT}]
set n_ff   [gem_count {PRIMITIVE_GROUP == FLOP_LATCH}]
set n_dsp  [gem_count {PRIMITIVE_GROUP == DSP}]
set n_bram [gem_count {PRIMITIVE_GROUP == BLOCKRAM}]

puts ""
puts "==> $TOP, out of context:"
puts "      LUTs   $n_lut"
puts "      FFs    $n_ff"
puts "      DSPs   $n_dsp"
puts "      BRAMs  $n_bram"

# ---- Rough timing ---------------------------------------------------------
#
# Post-synthesis timing is an estimate: nothing is placed, so routing delay is
# a model rather than a measurement. It is still the number step 6 wants,
# because a block that misses 125 MHz before placement is not going to be
# rescued by placement - and finding that now costs minutes instead of a
# restructure after everything is built on top of it.
create_clock -name tx_clk  -period 8.000 [get_ports tx_clk]
create_clock -name rx_clk  -period 8.000 [get_ports rgmii_rx_clk]
create_clock -name gtx_clk -period 8.000 [get_ports gtx_clk_shifted]
set_clock_groups -asynchronous \
    -group [get_clocks tx_clk] -group [get_clocks rx_clk]

set timing_rpt [report_timing_summary -return_string -delay_type max]
set fh [open "$BUILD_DIR/ooc_${TOP}_timing.rpt" w]
puts $fh $timing_rpt
close $fh

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
if {[llength $paths] == 0} {
    puts "FATAL: no setup paths to analyse - the clocks above did not reach the"
    puts "design, so this run proves nothing about timing."
    puts "Build refused: nothing to analyse."
    exit 1
}
set wns [get_property SLACK [lindex $paths 0]]
puts "      WNS    $wns ns (post-synthesis estimate, 125 MHz)"
if {![string is double -strict $wns]} {
    puts "FATAL: worst slack came back as '$wns', which is not a number."
    puts "Build refused: timing was never analysed."
    exit 1
}
if {$wns < 0} {
    puts "Build refused: $TOP does not make 125 MHz even before placement"
    puts "(WNS = $wns ns). Stage 4's habit is to pipeline for the target"
    puts "frequency from the start, because deciding pipeline depth after"
    puts "timing fails means restructuring verified code."
    exit 1
}

# ---- Against B.2's budget -------------------------------------------------
if {$TOP eq "gem_mac"} {
    set over 0
    foreach {name actual budget} [list \
        LUTs  $n_lut  2000 \
        FFs   $n_ff   3000 \
        BRAM  $n_bram 4    \
        DSPs  $n_dsp  0    ] {
        set verdict [expr {$actual <= $budget ? "ok" : "OVER"}]
        puts [format "      %-6s %6d  budget %6d   %s" $name $actual $budget $verdict]
        if {$actual > $budget} { incr over }
    }
    if {$over > 0} {
        puts ""
        puts "Build refused: $over resource line(s) past the B.2 budget."
        puts "That budget is a Stage 1 estimate and B.7 says plainly that it was"
        puts "not derived, so the right answer may be to amend the estimate - but"
        puts "that is a decision to make in the specification, not a number to"
        puts "quietly exceed here."
        exit 1
    }
    puts ""
    puts "==> Resource check: PASS (inside every B.2 line item)"
}

puts "==> DONE: $TOP"
