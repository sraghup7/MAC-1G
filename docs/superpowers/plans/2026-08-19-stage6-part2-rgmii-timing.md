# Stage 6 Part 2 Implementation Plan — RGMII I/O timing, gate 3 refusal, CDC/methodology, closeout

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** write the RGMII I/O delay constraints B.1b already derived the numbers
for but `constrs/` never encoded, make gate 3 refuse instead of report on an
unconstrained port, add CDC/methodology gates, close V-2's static-timing half,
and update the documentation to match — completing Stage 6 as `fpga_project_flow.md`
defines it.

**Architecture:** each task adds one XDC concept and proves it with a report
Vivado itself produces, never with hand arithmetic alone. The RGMII constraints
(Task 1, 2) are the substance of the stage and the place a sign error is
invisible in every report but the timing report itself — so every numeric claim
in this plan is checked twice: once by reading `report_timing`'s own printed
"Requirement" line against the derivation, and once by deliberately breaking a
sign and confirming the reported slack moves the predicted direction. Tasks 3–4
close the gate the constraints exist to feed. Task 5 is a second, independent
class of timing hazard (CDC) that static timing alone cannot see. Task 6–7 read
the first fully-constrained bitstream's reports and bring the documentation into
agreement with what was actually measured.

**Tech stack:** Vivado 2024.2 non-project mode (Tcl/XDC), the same `make`/Python
driver chain Stage 6 part 1 built.

**Spec:** `fpga_project_flow.md` Stage 6 · `spec/PROJECT_SPEC.md` B.1b (R14, R19,
R20) · `verification_plan.md` V-2, V-14, R14/R20 rows · `rtl/gem_mmcm.v` (the
phase-shift derivation this plan's TX constraint has to agree with) ·
`reference/verilog-ethernet/syn/quartus/rgmii_io.sdc` (the vendored reference
that establishes the virtual-clock XDC pattern this plan follows — read its
`constrain_rgmii_input_pins`/`constrain_rgmii_output_pins` procs before Task 1).

## Global constraints

- **Branch: `charan/dev`.** Never commit to `main`, never push without being
  asked. Everything here follows the six commits Stage 6 part 1 already made.
- **PowerShell 5.1 is the primary shell** — one command per line, no `&&`.
- **Every gate must be proven to fail**, with the demonstration recorded in the
  commit message, matching the habit `README.md`'s own table documents.
- **A sign error here is invisible in every report except the timing report
  itself.** No numeric constraint in this plan is considered done until
  `report_timing`'s own "Requirement" line has been read and matches the
  derivation, and until a deliberate sign flip has been shown to move slack the
  predicted direction. Passing is not sufficient evidence; a constraint that
  passes for the wrong reason (too loose to ever bind) is not caught by a
  passing gate — only by the sign-flip check.
- **No constant is written twice.** The RGMII timing numbers below all trace to
  B.1b in `spec/PROJECT_SPEC.md`; do not re-derive them differently in the XDC.
- **Error messages may not name a file, script or command without confirming it
  exists** (`CLAUDE.md`).
- Full check command, run after every task:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Full bitstream build, run after any task that touches `constrs/` or
`scripts/build.tcl`:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

---

## The numbers this plan is built on

All from `spec/PROJECT_SPEC.md` B.1b, already derived, not re-derived here:

| | RX (`rgmii_rx_clk` → `rgmii_rxd[*]`/`rgmii_rx_ctl`) | TX (`gtx_clk_shifted` → `rgmii_txd[*]`/`rgmii_tx_ctl`/`rgmii_gtx_clk`) |
|---|---|---|
| Mechanism | KSZ9031RNX delays `RX_CLK` **1.2 ns typical** relative to `RXD`/`RX_DV`, by default, no MDIO write | MMCM `CLKOUT1` (`gtx_clk_shifted`) is phase-shifted **−73.125° = 1.625 ns** from `tx_clk` (corrected in Stage 6 part 1 from the unachievable −72°; `rtl/gem_mmcm.v:158`) |
| RGMII v2.0 window | `TsetupR`/`TholdR` = **1.0–2.0 ns** | `TsetupT`/`TholdT` = **1.2–2.0 ns** (at the PHY pins) |
| What this repo already banked | 1.2 ns sits inside the 1.0–2.0 ns window | 1.625 ns is the numeric centre of 1.2–2.0 ns, ±0.4 ns margin from either edge before place-and-route |

**Reading the window correctly, spelled out because getting it backwards is the
whole risk this plan exists to manage:** `TsetupR`/`TholdR` (1.0–2.0 ns) is not a
tolerance band around 1.2 ns — it is the datasheet's stated *guaranteed minimum*
setup and hold margin a compliant receiver gets at the pin once the PHY has
delayed its clock into that window. A design using **1.0 ns** (the window's
worst-case lower bound) as the guaranteed setup and hold budget is the
conservative, defensible reading, and is what Task 1 uses. The TX side is
different in kind: 1.625 ns is not a margin, it is the actual programmed skew,
and B.1b's own ±0.4 ns margin claim is against the *window edges* (1.2 ns and
2.0 ns), not against a required minimum the way RX's number is — Task 2 encodes
this as an output delay bounded by that same 1.2–2.0 ns window.

**The XDC pattern**, taken structurally from the vendored
`reference/verilog-ethernet/syn/quartus/rgmii_io.sdc` (Task 1/2 read it before
writing anything): a **virtual clock**, unconnected to any pin, with the RGMII
period and no phase shift, stands in for "where the driving PHY launches data
relative to its own un-delayed reference." `set_input_delay`/`set_output_delay`
are expressed against that virtual clock, on both `-clock` and `-clock_fall`
(DDR carries data on both edges of the period). Because the *real* physical
clock the design also declares (`rgmii_rx_clk`, already `create_clock`'d in
`constrs/clocks.xdc`; `rgmii_gtx_clk`, generated in Task 2) has its own phase
relationship to the virtual one, Vivado's static timing engine would otherwise
check every rise-to-fall and fall-to-rise combination between the two — most of
which do not correspond to a real DDR sampling event and would produce false
failures. `set_false_path` on those non-corresponding edge pairs is what the
reference file's `set_false_path -rise_from ... -fall_to ...` block does; Task
1/2 reproduce that structure with this project's own clock names.

---

## Task 1: RX input-delay constraints

**Files:**
- Create: `constrs/rgmii_timing.xdc`
- Create: `Documents/RGMII I-O Timing Derivation.md`

**Interfaces:**
- Consumes: `rgmii_rx_clk` (already declared in `constrs/clocks.xdc:20`).
- Produces: `set_input_delay` on `rgmii_rxd[*]`/`rgmii_rx_ctl`, which Task 4's
  gate-3 refusal and Task 6's report reading both depend on being present and
  correctly signed.

- [ ] **Step 1: Read the reference pattern**

```bash
cat reference/verilog-ethernet/syn/quartus/rgmii_io.sdc
```

Note precisely which edge-pairs the reference false-paths for setup vs. hold
(`-rise_from ... -fall_to ...` for setup, `-rise_from ... -rise_to ...` for
hold) — Vivado XDC uses the same `set_false_path` syntax as Quartus SDC for
this, so the translation is direct.

- [ ] **Step 2: Write the derivation document**

Create `Documents/RGMII I-O Timing Derivation.md`:

```markdown
# RGMII I/O timing derivation

Closes V-2's static half. Numbers sourced from `spec/PROJECT_SPEC.md` B.1b,
which cites the KSZ9031RNX datasheet (Microchip Rev 2.2) Table 19.

## RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk

The PHY delays RX_CLK 1.2 ns (typical) relative to RXD/RX_DV so the clock
edge lands inside the data eye rather than at its boundary. RGMII v2.0's
TsetupR/TholdR window is 1.0-2.0 ns -- the guaranteed minimum setup and hold
margin at the receiving pin once that delay is applied. This design uses the
window's worst-case bound, 1.0 ns, as the guaranteed budget: a design that
only requires the datasheet's stated minimum is safe across the PHY's full
1.0-2.0 ns delay range, not merely at its typical 1.2 ns value.

Using the virtual-clock method (matching
reference/verilog-ethernet/syn/quartus/rgmii_io.sdc's structure): a virtual
clock rgmii_rx_clk_virt, period 8.000 ns, phase 0, stands for the PHY's own
undelayed reference. Data transitions relative to that virtual clock's edges
by the datasheet's guaranteed window:

  max = period/2 - Tsetup_min = 4.000 - 1.0 = 3.000 ns
  min = -(Thold_min)           = -1.0 ns

applied on both -clock and -clock_fall (RGMII DDR carries data on both edges),
and constrained against rgmii_rx_clk's *own* falling/rising 90-degree-esque
sampling structure via the same set_false_path edge-pairing the reference
uses -- because rgmii_rx_clk_virt and rgmii_rx_clk are not the same clock and
Vivado would otherwise check non-corresponding edge pairs that do not
represent a real capture event.

## TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by gtx_clk_shifted

rgmii_gtx_clk is a *generated* clock: gem_rgmii_tx.v's u_oddr_gtx forwards
gtx_clk_shifted (the MMCM's phase-shifted CLKOUT1, corrected to -73.125 deg /
1.625 ns in Stage 6 part 1) straight to the pin through an ODDR. The output
delay is bounded by the PHY's required TsetupT/TholdT window, 1.2-2.0 ns, at
the PHY's pins -- i.e. it is a receiver requirement on this design's output,
not a margin this design measures on itself:

  max = 2.0 ns   (the window's upper bound: data may arrive no later than this
                   before the PHY's own sampling edge)
  min = 1.2 ns   (the window's lower bound: data must be held at least this
                   long after the PHY's edge)

applied against the generated clock on rgmii_gtx_clk, both -clock and
-clock_fall, with the same DDR edge-pairing false paths as RX.

## What this cannot check

Both derivations assume the datasheet's stated PHY-side numbers hold on the
physical board -- board trace length/skew is not in this budget because B.1b
never had trace-length data to put there. That is V-2's bench half: an ILA or
scope on GTX_CLK/TXD0 once the board is in hand. What Stage 6 closes is the
static half -- that the design's own clock relationships, as built, meet the
PHY's stated requirements before anything is placed on a real board.
```

- [ ] **Step 3: Write the RX constraint**

Create `constrs/rgmii_timing.xdc`:

```tcl
# RGMII I/O delay constraints (R14, R20, closes V-2's static half).
# Derivation: Documents/RGMII I-O Timing Derivation.md.
#
# Structure follows reference/verilog-ethernet/syn/quartus/rgmii_io.sdc: a
# virtual reference clock stands in for the driving PHY's own undelayed
# clock, set_input_delay/set_output_delay are expressed against it on both
# edges (RGMII is DDR), and the non-corresponding edge pairs between the
# virtual clock and the real one are false-pathed so static timing does not
# check capture events that cannot occur.

#############################################################################
# RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk (already
# create_clock'd in constrs/clocks.xdc)
#############################################################################

create_clock -name rgmii_rx_clk_virt -period 8.000

set rx_data_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

set_input_delay -clock rgmii_rx_clk_virt -max 3.000 $rx_data_ports
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -max 3.000 -clock_fall $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -min -1.000 -clock_fall $rx_data_ports -add_delay

set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -fall_to [get_clocks rgmii_rx_clk] -setup
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -rise_to [get_clocks rgmii_rx_clk] -setup
set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -rise_to [get_clocks rgmii_rx_clk] -hold
set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -fall_to [get_clocks rgmii_rx_clk] -hold
```

(TX section added in Task 2, same file.)

- [ ] **Step 4: Build and read the report Vivado actually produced**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe synth
```

Then, from a Vivado batch session against the resulting checkpoint (or add a
temporary `report_timing` call at the end of `scripts/build.tcl`'s synth
section and re-run):

```tcl
open_checkpoint build/post_synth.dcp
report_timing -from [get_ports {rgmii_rxd[0]}] -max_paths 2 -delay_type min_max
```

Read the printed "Requirement" line for both the max (setup) and min (hold)
check. It must read **3.000 ns** for setup and **-1.000 ns** for hold, exactly
the values written in Step 3 — if it does not, the constraint did not attach
where intended (commonly: the port name pattern did not match, or `-add_delay`
was missing and a later call silently overwrote an earlier one). Record both
slack numbers; they must be non-negative.

- [ ] **Step 5: The sign-flip sanity check**

Temporarily change `-max 3.000` to `-max 30.000` on the RX max delay (an
obviously-wrong, much later arrival time) and re-run Step 4's `report_timing`.
Expected: setup slack becomes strongly negative, and by roughly the same 27 ns
the constraint moved. This confirms the constraint is load-bearing — a
constraint that reports the same slack regardless of the value written is not
actually attached to the path being measured, and would have passed gate 2
silently. Revert to `3.000` afterward.

```bash
git diff constrs/rgmii_timing.xdc
```

Expected after revert: no diff against what Step 3 wrote.

- [ ] **Step 6: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 (this task touches no RTL, no simulation input).

```bash
git add constrs/rgmii_timing.xdc "Documents/RGMII I-O Timing Derivation.md"
```

```bash
git commit -m "Write the RX half of the RGMII I/O timing budget B.1b already derived"
```

Commit message must include the two `report_timing` Requirement lines read in
Step 4 and the sign-flip result from Step 5 — this is the evidence, not the
algebra alone.

---

## Task 2: TX output-delay constraints and the generated clock

**Files:**
- Modify: `constrs/rgmii_timing.xdc`

**Interfaces:**
- Consumes: `gtx_clk_shifted` (the MMCM's `CLKOUT1`, internal to `gem_top`, not
  a top-level port — the generated clock is created *from the pin the ODDR
  drives*, sourced from that ODDR's own clock pin, which is the standard
  Vivado idiom for a clock-forwarding cell).
- Produces: `create_generated_clock -name rgmii_gtx_clk_gen` and
  `set_output_delay` on `rgmii_txd[*]`/`rgmii_tx_ctl`, which Task 4 and Task 6
  depend on.

- [ ] **Step 1: Find the ODDR's clock pin to source the generated clock from**

```bash
grep -n "u_oddr_gtx" rtl/gem_rgmii_tx.v
```

Confirms `gem_rgmii_tx.u_oddr_gtx` is clocked by `gtx_clk_shifted` and drives
`rgmii_gtx_clk`. The generated clock is created on the **port**
`rgmii_gtx_clk`, sourced from the **pin** driving it — `-source` must name the
`u_oddr_gtx` instance's clock pin, reached through `gem_top/u_mac`'s hierarchy
(the MAC instance is named in `rtl/gem_top.v` — confirm the instance path):

```bash
grep -n "gem_rgmii_tx\|u_rgmii_tx\|u_mac " rtl/gem_mac.v rtl/gem_top.v
```

- [ ] **Step 2: Append the TX section to `constrs/rgmii_timing.xdc`**

```tcl
#############################################################################
# TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by
# gtx_clk_shifted (the MMCM's CLKOUT1, forwarded through its own ODDR --
# gem_rgmii_tx.u_oddr_gtx).
#############################################################################

create_generated_clock -name rgmii_gtx_clk_gen \
    -source [get_pins */u_mac/*u_rgmii_tx/u_oddr_gtx/*/C] \
    -divide_by 1 \
    [get_ports rgmii_gtx_clk]

set tx_data_ports [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

set_output_delay -clock rgmii_gtx_clk_gen -max 2.000 $tx_data_ports
set_output_delay -clock rgmii_gtx_clk_gen -min 1.200 $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -max 2.000 -clock_fall $tx_data_ports -add_delay
set_output_delay -clock rgmii_gtx_clk_gen -min 1.200 -clock_fall $tx_data_ports -add_delay
```

The `-source` glob (`*/u_mac/*u_rgmii_tx/u_oddr_gtx/*/C`) is written loose on
purpose — `get_pins` errors loudly if it matches zero or more than one pin,
which is the desired failure mode for a hierarchy path guessed from Step 1
rather than confirmed by running it. Do not hand-tighten it without first
running Step 3 and seeing it resolve to exactly one pin.

- [ ] **Step 3: Build and confirm the generated clock actually attached**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe synth
```

If `create_generated_clock` cannot resolve `-source`, Vivado errors at
`read_xdc` time with "no valid object(s) found," which gate 0 (Stage 6 part 1)
will also catch as a `CRITICAL WARNING` and refuse the build on — so a wrong
hierarchy path fails loudly here, not silently later. If it errors, open the
checkpoint and search interactively:

```tcl
open_checkpoint build/post_synth.dcp
get_cells -hierarchical -filter {NAME =~ "*u_oddr_gtx*"}
```

and correct the `-source` path to match what that returns.

- [ ] **Step 4: Read the report, exactly as Task 1 Step 4**

```tcl
open_checkpoint build/post_synth.dcp
report_timing -to [get_ports {rgmii_txd[0]}] -max_paths 2 -delay_type min_max
```

Confirm the Requirement lines read **2.000 ns** (setup) and **1.200 ns**
(hold), and both slacks are non-negative.

- [ ] **Step 5: The sign-flip check, and the one that also closes V-2**

Change `rtl/gem_mmcm.v:158`'s `CLKOUT1_PHASE` from `-73.125` to `-45.000` (a
large, deliberately wrong shift — inside the achievable 5.625° grid, so it
will not trip the DRC gate the way `-72.000` did) and re-run Step 4. Expected:
the TX setup/hold slack changes measurably, in the direction the phase shift
predicts (a smaller magnitude shift moves the sampling edge away from the
window's centre, tightening one of setup/hold and loosening the other).
Revert:

```bash
git checkout -- rtl/gem_mmcm.v
```

This is the same check the original Stage 6 audit named as the way to verify
a phase-shift constraint measures what it claims — "deliberately change
CLKOUT1_PHASE and confirm the reported slack moves the direction you
predicted."

- [ ] **Step 6: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28.

```bash
git add constrs/rgmii_timing.xdc
```

```bash
git commit -m "Write the TX half of the RGMII I/O timing budget, and prove the phase shift is load-bearing"
```

Include in the message: the resolved `-source` pin path, both Requirement
lines from Step 4, and the Step 5 sign-flip result.

---

## Task 2b: TX phase margin — empirical sweep and re-derivation

**Why this task exists, inserted after Task 2 landed:** Task 2's own
verification (its required sign-flip check) found that the TX setup path is
genuinely timing-violated at the current `CLKOUT1_PHASE = -73.125` (1.625 ns) —
−0.161 ns at synthesis, **−0.351 ns fully routed** (worse, not better, so not
an estimation artifact). Hold is comfortably met both ways (+2.056 to
+2.260 ns). Task 2's sign-flip experiment (reducing the shift magnitude from
1.625 ns to 1.000 ns) showed setup improving by exactly 0.625 ns and hold
worsening by exactly 0.625 ns — meaning the fix direction is a **smaller**
shift magnitude, the opposite of what "centre the window, so move toward its
edges for more margin" naively suggests. That inversion is itself the reason
this task derives the new value empirically rather than by hand: B.1b's
"centring gives ±0.4 ns margin on both edges" reasoning was computed before
place-and-route, from clock skew alone, and the real routed system does not
match that idealised model closely enough to trust a second hand-derived
number.

**The one bound that is not negotiable, and why Vivado's own gate cannot
enforce it:** the chosen magnitude must stay inside B.1b's cited
`TsetupT`/`TholdT` = **1.2–2.0 ns** window, because that is the KSZ9031RNX's
actual electrical requirement at its pins — not merely a Vivado modelling
convenience. `report_timing`'s `set_output_delay -max 2.000 -min 1.200`
constraint (Task 2) does not independently check "is the chosen phase
magnitude between 1.2 and 2.0 ns" — it checks "does data-plus-phase-shifted-
clock satisfy a 1.2/2.0 ns setup/hold budget," which is a related but
different question, and a magnitude outside 1.2–2.0 ns could in principle
still show positive slack on that check while violating the PHY's real
requirement in a way no report here would ever surface. Candidates in this
task are therefore restricted to grid points inside 1.2–2.0 ns, full stop,
even if a tempting out-of-window value were to test cleaner.

**Files:**
- Modify: `rtl/gem_mmcm.v` (`CLKOUT1_PHASE` value and its header derivation)
- Modify: `Documents/RGMII I-O Timing Derivation.md` (record the sweep
  methodology and result — this is the derivation the file's TX section
  currently lacks)

**Interfaces:**
- Consumes: `constrs/rgmii_timing.xdc`'s TX section (Task 2, unchanged by this
  task), the generated clock it declares on `rgmii_gtx_clk`.
- Produces: a `CLKOUT1_PHASE` value with post-route setup AND hold slack both
  confirmed non-negative, which Task 4/6 depend on for `make bitstream` to
  succeed once the RGMII constraints are wired into the real build.

- [ ] **Step 1: Enumerate the grid points inside the window**

The achievable step is 45°/`CLKOUT1_DIVIDE`(8) = 5.625°. Compute every grid
point whose magnitude falls inside 1.2–2.0 ns (period 8.000 ns):

```
magnitude(ns) = |phase(deg)| / 360 * 8.000
```

Candidates strictly inside the window, excluding the current 1.625 ns
(13 steps, −73.125°) since that one is already measured and violates:

| Steps | Phase (deg) | Magnitude (ns) |
|---|---|---|
| 9  | −50.625 | 1.125 (below 1.2 ns floor — **excluded**) |
| 10 | −56.250 | 1.250 |
| 11 | −61.875 | 1.375 |
| 12 | −67.500 | 1.500 |
| 13 | −73.125 | 1.625 (current, measured, violates) |

Confirm this table by running the arithmetic yourself before proceeding —
do not trust it copied verbatim, the same discipline `gem_mmcm.v`'s own
header already applies to its own numbers.

- [ ] **Step 2: Measure each candidate at the post-route corner**

For each of the three in-window candidates (1.250, 1.375, 1.500 ns —
steps 10, 11, 12), in turn:

1. Edit `rtl/gem_mmcm.v`'s `CLKOUT1_PHASE` to the candidate's degree value.
2. Build to the routed checkpoint:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream 2>&1 | tail -40
```

(This runs the whole pipeline including bitgen — slower than `impl` alone,
but confirms nothing else regresses. If it is too slow across three
candidates, `python scripts/build.py impl gem_top` alone is sufficient since
this task only needs `build/post_route.dcp`, and bitgen at DRC-clean phase
values is not itself in question here — Task 2's own bitstream write already
proved DRC accepts any grid-aligned value.)

3. Against the resulting checkpoint, apply the RGMII timing XDC (it is still
   not wired into `scripts/build.tcl` — same throwaway-script approach Tasks
   1/2 used) and read `report_timing` for both the setup and hold paths on
   `rgmii_txd[0]`, exactly as Task 2 Step 4 did. Record both slack numbers.
4. Revert `rtl/gem_mmcm.v` before moving to the next candidate, so each
   measurement starts from a clean baseline and no stale edit leaks into the
   next candidate's build.

- [ ] **Step 3: Also re-measure the current value at 1.625 ns for a same-methodology baseline**

Task 2 already measured 1.625 ns post-route (−0.351 ns setup, +2.056 ns
hold) — but via a slightly different path (that measurement happened before
this task's exact throwaway-script procedure was fixed). Re-run it once more
with this task's exact Step 2 procedure to confirm the number reproduces
before trusting cross-candidate comparisons. If it does not reproduce
closely (within a few ps — process-corner and tool run-to-run variation is
real but small), stop and report the discrepancy rather than proceeding on
an unreliable baseline.

- [ ] **Step 4: Pick the value**

From the four measured points (1.250, 1.375, 1.500, 1.625 ns), select the
smallest magnitude among those where **both** setup and hold slack are
positive with a margin you would not call razor-thin (a few hundred ps at
minimum — if every in-window candidate is either violated or within ~50 ps
of zero on one check, that is itself a finding to report, not a value to
force a choice from). Preferring the smallest passing magnitude, rather than
the one nearest the window's geometric centre, follows directly from what
Step 1 found: smaller magnitude helped setup and the violation is on setup,
so the smallest candidate that still passes both checks keeps the most
margin on the check that is actually tight, while every candidate here is
already confirmed to sit inside the PHY's required window regardless of
where in that window it falls.

If **no** in-window candidate closes both checks, do not force a choice —
report BLOCKED with all four measured points and let the controller decide
whether to widen the search (values are not literally forbidden below
1.2 ns by Vivado, only by the PHY's real requirement per this task's own
stated bound — so widening the search past that bound is not this task's
call to make unilaterally) or escalate the finding differently.

- [ ] **Step 5: Write the chosen value into `rtl/gem_mmcm.v`, with the derivation rewritten to match**

Update `CLKOUT1_PHASE` to the chosen value. Rewrite the header block (the one
Stage 6 part 1 already corrected once, `-72` → `-73.125`) to add — not
replace — the reasoning: state plainly that centring at 1.625 ns was the
pre-place-and-route estimate, that Task 2 of Stage 6 part 2 measured a real
−0.351 ns post-route setup violation there, that this task swept the
in-window grid at the post-route corner and is picking `<chosen>` ns because
it is the smallest in-window magnitude that closes both checks with margin,
per the same measured evidence recorded in this task's commit message. Cite
the actual measured numbers for the chosen candidate, not the whole sweep
table, in the header — the full sweep belongs in the commit message and the
derivation document, not repeated a third time in RTL.

- [ ] **Step 6: Update the derivation document**

Append a "TX phase margin — post-route revision" section to
`Documents/RGMII I-O Timing Derivation.md`'s TX section: the sweep table from
Step 2/3 (candidate, setup slack, hold slack), the choice made and why,
explicit acknowledgement that this revises the "centred, ±0.4 ns margin"
claim in `spec/PROJECT_SPEC.md` B.1b (do not edit the spec here — that is
Task 7's job, but flag it in this document so Task 7 does not miss it).

- [ ] **Step 7: Full verification with the final chosen value**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 — this task touches only `CLKOUT1_PHASE`, which the
`GEM_BEHAVIORAL_IO` simulation branch never reads (confirmed already in
Stage 6 part 1's DRC fix commit).

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: full pipeline succeeds through bitgen with the chosen phase (DRC
clean — confirmed already at every grid-aligned value tested).

- [ ] **Step 8: Commit**

```bash
git add rtl/gem_mmcm.v "Documents/RGMII I-O Timing Derivation.md"
```

```bash
git commit -m "Re-derive the TX phase shift from measured post-route skew, not just the pre-route estimate"
```

The message must include: the full sweep table (all four candidates, both
slacks each), which value was chosen and why, and the reproduced 1.625 ns
baseline from Step 3.

---

## Task 2c: Diagnose the TX data-path delay, and fix it if it is placement, not logic

**Why this task exists, inserted after Task 2b came back BLOCKED:** Task 2b's
sweep found the setup slack crosses zero almost exactly at the 1.250 ns grid
point, clearing by only 24 ps — every candidate the PHY's 1.2–2.0 ns window
permits is either violated or razor-thin, on a trend so linear (~0.125 ns of
slack per 0.125 ns of phase magnitude) that the 5.625° grid itself, not the
choice of point on it, is the limiting factor. Before reaching for a bigger
lever (finer phase-shift resolution, which changes the MMCM's configuration
mode), this task asks a cheaper, narrower question: how much of the TX
setup path's **4.015 ns Data Path Delay** (the number Task 2's `report_timing`
already captured but did not break down) is unavoidable silicon delay, and
how much is routing that a placement constraint could shrink?

**Why this is not simply "add `IOB=TRUE`."** `rtl/gem_oddr.v`'s own header
already states the reason: `ODDR` in this design is an explicit Xilinx
primitive, never an inferred register (UG901's own rule, quoted in the file:
"these primitives are instantiated, never inferred"). An instantiated `ODDR`
always maps to an `OLOGIC` site — there is no "fabric register" alternative
placement for it the way there would be for a plain flip-flop, so `IOB=TRUE`
is most likely already moot for these specific cells. The real open question
is narrower and worth stating precisely: is the `OLOGIC` each `ODDR` landed
on the one **co-located with the IOB the port itself uses** (near-zero route
from `ODDR`/`Q` to the pad), and is the route from the **upstream register
that drives `gem_rgmii_tx`'s `gm_byte`/`gm_dv`/`gm_er` inputs** (inside
`rtl/gem_tx_engine.v`, reached through plain wires — `rtl/gem_mac.v:167-208`
— with no register in between) short, or did the placer put that source flop
somewhere else in the fabric, forcing a long route into the `ODDR`'s D-input?
This project's own `fpga_project_flow.md` (Stage 7) names exactly this
failure mode: *"Routing delay dominant → endpoints physically far apart →
placement guidance, or restructure."* Diagnose which one this is before
assuming either "packing" language applies.

**Files:**
- Modify (conditionally, only if the diagnosis finds a fixable placement
  issue): `constrs/pins.xdc` or a new `constrs/rgmii_placement.xdc` (a
  `LOC`/pblock constraint on the identified cell), plus a note in
  `Documents/RGMII I-O Timing Derivation.md`
- No file changes at all is a legitimate outcome if the diagnosis finds the
  delay is already near its physical floor — report that honestly, the same
  way Task 2b reported BLOCKED honestly rather than forcing a result.

**Interfaces:**
- Consumes: `build/post_route.dcp` (from `python scripts/build.py impl
  gem_top` at the current committed `CLKOUT1_PHASE = -73.125`, the value on
  disk right now — Task 2b's sweep left it there, reverted).
- Produces: either (a) a placement fix plus a re-measured sweep at the same
  four magnitudes Task 2b used (1.250/1.375/1.500/1.625 ns), which feeds
  back into whether Task 2b's blocked decision changes, or (b) a documented
  "not a placement problem" finding that the controller carries into the
  next decision about finer phase-shift resolution.

- [ ] **Step 1: Get the full path breakdown, not just the summary**

Build `build/post_route.dcp` at the current committed phase value (no RTL
edit needed — it's already `-73.125`):

```bash
python scripts/build.py impl gem_top
```

Then, via a throwaway gitignored script under `build/` (same pattern every
prior task in this plan used):

```tcl
open_checkpoint build/post_route.dcp
read_xdc constrs/rgmii_timing.xdc
report_timing -to [get_ports {rgmii_txd[0]}] -max_paths 1 -delay_type max -detail
```

Read the **full path table**, not the summary lines Tasks 1/2 read — every
row is a cell or net with its own incremental and cumulative delay. Identify
each hop: the launching register (name and location), the net to
`gem_rgmii_tx`'s `d_rise`/`d_fall` input, the `ODDR` cell itself, and the net
from the `ODDR`'s `Q` to the port. Record every row's delay contribution.

- [ ] **Step 2: Confirm where the launching register and the ODDR actually landed**

```tcl
get_cells -hierarchical -filter {NAME =~ "*u_oddr_gtx/u_oddr" || NAME =~ "*rgmii_txd*u_oddr"}
```

For each matched cell, read its placed site:

```tcl
get_property LOC [get_cells <cell_name>]
get_property BEL [get_cells <cell_name>]
```

Separately, find the physical site of the port itself:

```tcl
get_property PACKAGE_PIN [get_ports {rgmii_txd[0]}]
```

Cross-reference: Vivado's package/site naming ties a given `PACKAGE_PIN` to
one `IOB` tile, and that `IOB` tile has exactly one `OLOGIC` site paired with
it. If the `ODDR`'s `LOC` is that paired `OLOGIC`, the cell is correctly
co-located and this half of the diagnosis is clear — record it as such and
move to the launching register.

For the launching register (the flop inside `rtl/gem_tx_engine.v` whose
output eventually reaches `gm_byte`/`gm_dv`/`gm_er` — find its instance name
from Step 1's path table, not by guessing from RTL), read the same `LOC`
property and compare its physical location to the `ODDR`'s. A register
placed in a distant slice relative to the pad's `IOB`/`OLOGIC` produces a
long, congestion-sensitive route — exactly Stage 7's "endpoints physically
far apart" symptom.

- [ ] **Step 3: Decide whether this is a placement problem**

From Steps 1–2, answer plainly:

- Is the `ODDR` cell at the `OLOGIC` co-located with its port's `IOB`? (Almost
  certainly yes, per the reasoning above — but confirm, don't assume.)
- What fraction of the 4.015 ns Data Path Delay is the **net** delay between
  the launching register and the `ODDR`'s D-input, versus the **cell** delays
  (register clock-to-Q, `ODDR` internal delay) that placement cannot change?
- If the net delay between the launching register and the `ODDR` is a large
  fraction of the total (a rough guide: more than ~1 ns on a design this
  small, where nothing should need to route far), this is a placement
  problem worth fixing. If it is a small fraction and most of the 4.015 ns is
  irreducible cell delay (clock-to-Q plus the `ODDR`'s own internal timing),
  placement cannot help further — report that as the finding and stop here;
  do not force a constraint that will not move the number.

- [ ] **Step 4: If it is a placement problem, fix the narrowest thing that addresses it**

The standard, minimal Vivado mechanism for "keep this specific register close
to this specific IOB" is a `LOC` constraint on the launching register pinning
it to a slice near the target `OLOGIC`/`IOB`, or (preferred, less brittle to a
future netlist change) a small `pblock` around the `ODDR` and its immediate
fan-in, using `create_pblock`/`add_cells_to_pblock`/`resize_pblock` scoped
tightly (a handful of slices, not a broad region — Stage 6's own habit
throughout this plan has been the narrowest constraint that addresses the
named problem, not a broad hint). Write it into a new
`constrs/rgmii_placement.xdc` (a new file, per this repo's existing pattern
of splitting constraints by purpose — clocks/pins/exceptions/timing/
placement, one concern per file) with a comment explaining exactly what Step
1–3 found and why this specific constraint addresses it.

- [ ] **Step 5: Re-measure across the same four points Task 2b tested**

Rebuild and re-measure setup/hold slack at 1.250, 1.375, 1.500 and 1.625 ns
magnitude, using the exact same procedure Task 2b's report documents
(edit `CLKOUT1_PHASE`, `python scripts/build.py impl gem_top`, throwaway
`report_timing` script, revert). This tells the controller whether the fix
moved the whole curve (every point improves by roughly the same amount,
since it addresses a fixed delay component) or only some of it.

- [ ] **Step 6: Full verification, whichever branch this task took**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 — no RTL or simulation input changes in either branch of
this task (a placement `pblock`/`LOC` constraint is XDC, not RTL).

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: succeeds (this task does not touch `CLKOUT1_PHASE`, which stays at
its currently-committed `-73.125` regardless of which branch this task took —
choosing a final phase value, if the placement fix reopens Task 2b's
decision, is a follow-up, not this task).

- [ ] **Step 7: Commit, and report which branch was taken**

If Step 4 produced a constraint:

```bash
git add constrs/rgmii_placement.xdc "Documents/RGMII I-O Timing Derivation.md"
```

```bash
git commit -m "Pin the TX launch register near its ODDR, closing most of the routing delay Task 2b's sweep exposed"
```

If Step 3 found no fixable placement issue, there is nothing to commit —
report the finding in full (the path breakdown, the LOC/BEL cross-reference,
the cell-vs-net delay split) so the controller has the evidence to decide the
next step without re-running this diagnosis.

The commit message (if any) or the final report (if not) must include: the
full Step 1 path table, the Step 2 LOC/BEL findings, the Step 3 reasoning,
and — if a constraint was written — the Step 5 re-measurement table.

---

## Task 2d: Finer TX phase resolution via `CLKOUT1_USE_FINE_PS`

**Why this task exists.** Task 2c ruled out placement definitively (0.061% of
the violated path's delay is routing; the rest is irreducible cell delay).
Task 2b's sweep of the 5.625° static phase-shift grid found no in-window
point with real margin — the best, 1.250 ns, clears setup by 24 ps, and the
project owner has decided to pursue finer phase resolution rather than
accept that margin or defer the decision further.

**The mechanism, and why it is different from what Tasks 2/2b did.** The
7-series `MMCME2_ADV` primitive's static phase shift (what `CLKOUT1_PHASE`
currently drives) is quantised to `45° / CLKOUT_DIVIDE` — 5.625° here, which
is where the coarse-grid problem comes from. The same primitive has a
**fine phase-shift** capability, enabled per-output via the
`CLKOUT1_USE_FINE_PS` generic. Per Xilinx UG472 (7 Series FPGAs Clocking
Resources), setting this to `"TRUE"` on `CLKOUT1` lets the tool synthesize
`CLKOUT1_PHASE` at a resolution of `VCO_period / (56 × CLKOUT1_DIVIDE)` —
roughly 2 orders of magnitude finer than the coarse grid — **without**
requiring the primitive's dynamic runtime phase-shift ports (`PSCLK`,
`PSEN`, `PSINCDEC`, `PSDONE`) to be driven at all, as long as no runtime
re-tuning is wanted. This design wants a fixed, well-chosen static value, not
runtime adjustment — so this task is a **static-only** use of fine phase
shift: one generic flipped, one more precise `CLKOUT1_PHASE` value, nothing
added to the port list.

**This claim is exactly the kind that must be verified against the real tool,
not trusted from documentation memory.** The primitive's exact behaviour when
`CLKOUT1_USE_FINE_PS = TRUE` and the dynamic ports are left tied off is the
first thing this task confirms — via Vivado's own DRC (which will refuse
loudly, the same way it refused the unachievable `-72°` phase in Stage 6 part
1, if the primitive genuinely needs something this task did not provide) —
before any measurement is trusted.

**The bound that still applies, unchanged from Tasks 2b/2c:** the chosen
magnitude must stay inside 1.2–2.0 ns — the KSZ9031RNX's real electrical
`TsetupT`/`TholdT` requirement, not a Vivado modelling artefact. Fine phase
shift changes how *precisely* a value in that range can be hit; it does not
move the range itself. Given Task 2b/2c's data (an almost perfectly linear
±1:1 ns/ns trade between setup and hold slack across the measured range, and
hold carrying far more slack than setup needs at every point tested), the
best achievable point is expected to sit near the window's own 1.2 ns floor
— but "expected" is not "measured," and this task measures it rather than
assuming the linear extrapolation holds exactly at the boundary.

**Files:**
- Modify: `rtl/gem_mmcm.v` (`CLKOUT1_USE_FINE_PS` added to the `MMCME2_ADV`
  instantiation, `CLKOUT1_PHASE` changed to the finer chosen value, header
  derivation rewritten)
- Modify: `Documents/RGMII I-O Timing Derivation.md` (the sweep/decision
  record Task 2b's report was never able to write, now written)

**Interfaces:**
- Consumes: the diagnostic evidence from Task 2b (`task-2b-report.md`) and
  Task 2c (`task-2c-report.md`) — read both before starting; they contain the
  measured baseline and the linear trend this task's target value is chosen
  from.
- Produces: a `CLKOUT1_PHASE` value with post-route setup AND hold slack both
  confirmed non-negative with real margin, unblocking Task 4 onward.

- [ ] **Step 1: Confirm the primitive accepts static-only fine phase shift**

Edit `rtl/gem_mmcm.v`'s `MMCME2_ADV` instantiation: add
`.CLKOUT1_USE_FINE_PS("TRUE")` alongside the existing `.CLKOUT1_PHASE(...)`,
`.CLKOUT1_DIVIDE(...)`, `.CLKOUT1_DUTY_CYCLE(...)` parameters — do not change
`CLKOUT1_PHASE`'s value yet, keep it at the current committed `-73.125` for
this first pass. Leave `PSCLK`, `PSEN`, `PSINCDEC` unconnected (tied to their
primitive defaults — check `gem_mmcm.v`'s existing port list for whether
these are already present and tied off, or need adding; if the module does
not currently instantiate them at all, that is fine only if Vivado's DRC
agrees a static-only `CLKOUT1_USE_FINE_PS` usage does not require them
connected — this is exactly the assumption Step 2 tests).

- [ ] **Step 2: Build and read what DRC says**

```bash
python scripts/build.py bitstream
```

If DRC refuses (an `ERROR` during `write_bitstream`'s DRC pass, the same
class of failure Stage 6 part 1 hit with the unachievable `-72°` phase),
read the exact error, and treat it as authoritative over this task's
documentation-derived assumption above — the fix is whatever the DRC message
says it needs (commonly: tying `PSEN` to a constant `1'b0` explicitly rather
than leaving it unconnected, or connecting `PSCLK` to a real clock even if
`PSEN` never pulses). Do not guess past a DRC error; read it, adjust, rebuild,
and confirm clean before proceeding. If a genuinely different port
connection is required, add the minimum needed to satisfy DRC and document
exactly what was required and why in the commit.

If DRC passes clean with `CLKOUT1_PHASE` still at `-73.125`, confirm the
fine-phase-shift mechanism is actually active (not silently ignored) by
checking `report_clocks` or the MMCM's post-synthesis attribute report for
evidence the primitive is configured for fine mode — read what Vivado
actually reports rather than assuming a clean DRC alone proves it.

- [ ] **Step 3: Find the finer value empirically**

With fine phase shift confirmed working, sweep `CLKOUT1_PHASE` in smaller
steps than the coarse 5.625° grid, working inward from the 1.2 ns floor
toward the region Task 2b/2c's data suggests is close to the crossover.
Reasonable starting points, computed the same way Task 2b's table was
(`magnitude(ns) = |phase(deg)| / 360 * 8.000`): try 1.200 ns
(`-54.000°`) first, since the linear trend predicts this is close to the best
achievable point within the hard floor; then 1.225 ns and 1.275 ns to bracket
it, adjusting further based on what the first three measurements show. Use
the exact same post-route measurement procedure Tasks 2b/2c used: edit
`CLKOUT1_PHASE`, `python scripts/build.py impl gem_top`, throwaway
`report_timing -to [get_ports {rgmii_txd[*] rgmii_tx_ctl}] -max_paths 10
-delay_type max` script, record all five TX ports' slack (Task 2c found they
vary by up to ~15 ps from each other — check the worst one, not just
`rgmii_txd[0]`), revert between candidates.

- [ ] **Step 4: Pick the value**

Same bar as Task 2b: both setup and hold must be positive with real margin,
not razor-thin (a few hundred ps, this time achievable given fine
resolution removes the grid-snapping penalty). If, after a reasonable search
within 1.2–2.0 ns, nothing clears more than roughly 100 ps on the tighter
check, report that plainly as the best achievable rather than continuing to
search indefinitely — this task's job is to remove the *grid* penalty, not
to promise an outcome the PHY's fixed window may not physically allow.

- [ ] **Step 5: Write the chosen value, with the derivation rewritten**

Update `CLKOUT1_PHASE` to the chosen value and add `CLKOUT1_USE_FINE_PS` to
`rtl/gem_mmcm.v`'s parameter list permanently. Rewrite the header block
(already corrected twice — `-72°` → `-73.125°` in Stage 6 part 1, and now
again here) to explain, in order: the original centred estimate, Task 2's
post-route violation, Task 2b's coarse-grid sweep and its 24 ps ceiling,
Task 2c's ruling-out of placement, and this task's fine-phase-shift
resolution with the actual chosen value and its measured margins. Cite Task
2b/2c's report files by name in the comment (matching this file's existing
habit of citing V-numbers and prior findings) rather than re-deriving their
numbers inline.

- [ ] **Step 6: Update the derivation document**

Append the full decision history to `Documents/RGMII I-O Timing Derivation.md`'s
TX section: Task 2's violation, Task 2b's sweep table, Task 2c's placement
ruling-out, this task's fine-phase-shift sweep and final choice. This is the
single place a future reader goes to understand why the TX phase is what it
is, rather than piecing it together from four task reports.

- [ ] **Step 7: Full verification**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 (the `GEM_BEHAVIORAL_IO` simulation branch never reads
`CLKOUT1_PHASE` or `CLKOUT1_USE_FINE_PS`, confirmed already in Stage 6 part
1's DRC fix and every RGMII task since).

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: DRC clean, bitgen succeeds, and — read this explicitly rather than
assuming — the post-route timing summary shows the chosen value's margin on
all five TX ports, not just the one path earlier tasks focused on.

- [ ] **Step 8: Commit**

```bash
git add rtl/gem_mmcm.v "Documents/RGMII I-O Timing Derivation.md"
```

```bash
git commit -m "Give the TX phase shift the fine resolution the 5.625 degree grid could not provide"
```

The message must include: the DRC finding from Step 2 (clean, or what was
needed to make it clean), the search from Step 3 with all measured
candidates, the chosen value and its margins on all five TX ports, and an
explicit note that this closes the finding Task 2b left BLOCKED and Task 2c
confirmed was not fixable by placement.

---

## Task 2e: Commit the VCO restructure, and name the bench-gated fallback

**Why this task exists.** Task 2d found that phase shift alone tops out at
58 ps of TX setup margin (up from Task 2b's 24 ps), reachable only by
restructuring the MMCM's VCO rather than the single generic Task 2d was
scoped to touch — and correctly declined to make that call unilaterally.
58 ps does not clear the "not razor-thin" bar any task in this plan has used,
but it is real, measured, and strictly better than the committed baseline's
outright violation (−0.351 ns). The project owner has decided to take it:
commit the VCO restructure now, since Vivado can fully verify it without
hardware, and document — rather than speculatively implement — the PHY-side
compensation B.1b already names as the mechanism for closing whatever gap
remains, because that mechanism can only be validated on a real board and
this project has none in hand (`MEMORY.md`).

**Why the PHY-side register is documentation only, not RTL, in this task.**
The KSZ9031RNX's `GTX_CLK` pad-skew register (B.1b: MMD address `2h`,
register `8h`, bits `[9:5]`, 0.06 ns/step, up to +1.38 ns) is reached through
an indirect MMD-access sequence (write the standard Clause 22 registers that
select the MMD device/register, then the ones that read/write its value) —
`rtl/gem_mdio.v` already exposes the general register-level primitive this
sequence would ride on (`req_valid`/`req_write`/`req_phyad`/`req_regad`/
`req_wdata`, confirmed present), but `rtl/gem_top.v` ties that port
permanently to `1'b0` — nothing drives it today. Building an automatic
power-on sequence that pokes this register with a value computed from a
datasheet step size nobody has confirmed against real silicon would commit
the design to an unvalidated correction on every single boot; if the step
size or direction is off, it makes timing worse, silently, with no gate here
able to catch it. That is a materially different risk than a Vivado-only
change gate 2/3 can fully check today. This task documents the exact
procedure and the arithmetic for computing the needed step count once a real
shortfall is measured at the bench (B.5 step 5) — it does not implement it.

**Files:**
- Modify: `rtl/gem_mmcm.v` (VCO/divider values, `CLKOUT1_PHASE`, header
  derivation — rewritten a fourth time, still additive to the existing
  history)
- Modify: `Documents/RGMII I-O Timing Derivation.md` (record the committed
  value and the PHY-register fallback procedure)
- Modify: `verification_plan.md` (R14 row: `open` → `green`, citing the real
  measured margin rather than the pre-route estimate; V-2 stays open for its
  bench half, reworded to name the fallback)
- Modify: `bringup_checklist.md` (a new note at step 5, where B.5 already
  asks for a scope on `GTX_CLK`/`TXD0` — this is where "if margin proves
  insufficient" gets a concrete next action rather than a dead end)

**Interfaces:**
- Consumes: Task 2d's Candidate B measurement (`task-2d-report.md`,
  `Documents/RGMII I-O Timing Derivation.md`'s existing table) — the exact
  values to commit: `CLKFBOUT_MULT_F 22.500`, `CLKOUT0_DIVIDE_F 9.000`,
  `CLKOUT1_DIVIDE 9`, `CLKOUT1_PHASE -55.000`.
- Produces: a `CLKOUT1_PHASE` configuration with post-route setup AND hold
  slack both positive on all five TX ports — 58 ps setup, ~1.65 ns hold —
  which unblocks Task 4 (gate 3's refusal) since `make bitstream` will no
  longer hit gate 2's WNS < 0 refusal on this path.

- [ ] **Step 1: Confirm the output frequency is preserved before touching anything**

Verify the arithmetic that made Candidate B safe in the first place: VCO =
50 MHz × `CLKFBOUT_MULT_F`(22.500) / `DIVCLK_DIVIDE`(1) = 1125 MHz — inside
the Artix-7 MMCM's 600–1200 MHz range. `tx_clk` = VCO / `CLKOUT0_DIVIDE_F`
(9.000) = 125 MHz, unchanged. `gtx_clk_shifted` = VCO / `CLKOUT1_DIVIDE`(9)
= 125 MHz, unchanged. Both output frequencies are identical to today's
committed configuration — only the VCO's internal frequency and both
dividers move together, the standard technique for finer phase-shift
granularity at a fixed output frequency. Confirm this arithmetic yourself
before editing the file, the same discipline the file's own header already
applies to every number in it.

- [ ] **Step 2: Update `rtl/gem_mmcm.v`**

Change the `MMCME2_BASE` instantiation's four parameters:

```verilog
.CLKFBOUT_MULT_F    (22.500),    // VCO = 1125 MHz
...
.CLKOUT0_DIVIDE_F   (9.000),     // 125 MHz, tx_clk
...
.CLKOUT1_DIVIDE     (9),         // 125 MHz, GTX_CLK copy
.CLKOUT1_PHASE      (-55.000),   // 1.2222 ns; measured 58 ps worst-case
                                  // TX setup post-route (Task 2d Candidate B)
```

Update the "THE ARITHMETIC, spelled out" comment block earlier in the file
(the one that currently derives `VCO = 1000 MHz`, `outputs = 125 MHz`,
`-72 degrees`) to show the new numbers with the same derivation style, not
just new values dropped into old prose.

Rewrite the phase-shift history paragraph (already rewritten twice — Stage 6
part 1's `-72°`→`-73.125°` DRC fix, Task 2d's fine-PS trap warning) to add,
not replace: this task's VCO restructure, citing Task 2d's report by name for
why phase shift alone could not do better than 58 ps, and this task's own
measured confirmation (Step 4) that the committed configuration achieves it.
Point to `Documents/RGMII I-O Timing Derivation.md` for the full table rather
than restating candidate comparisons inline — Task 2d's fix round exists
because a restated number drifted from its source once already; do not
repeat that mistake in the same file a fourth revision later.

- [ ] **Step 3: Confirm DRC and simulation are both unaffected**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 — `GEM_BEHAVIORAL_IO` never reads any MMCM parameter,
confirmed in every RGMII task so far.

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: DRC 0 errors (AVAL-139 legitimately silent — `-55.000°` is exactly
11 × the new 5° grid, `45/CLKOUT1_DIVIDE(9)`), bitgen succeeds.

- [ ] **Step 4: Re-measure all five TX ports post-route, on the real committed tree**

Same procedure every RGMII task in this plan has used: throwaway gitignored
script under `build/`, `open_checkpoint build/post_route.dcp`,
`read_xdc constrs/rgmii_timing.xdc`, `report_timing -to [get_ports
{rgmii_txd[*] rgmii_tx_ctl}] -max_paths 10 -delay_type max`. Confirm the
worst port (`rgmii_txd[0]` at every prior measurement point in this plan)
shows setup slack **positive**, and record the exact number — it should be
close to Task 2d's measured +58 ps, but this is the number that matters, not
the one from a different task's checkpoint. If it does not reproduce
closely (within a few ps), stop and report the discrepancy rather than
trusting Task 2d's number by inheritance.

- [ ] **Step 5: Document the PHY-side fallback procedure**

Append to `Documents/RGMII I-O Timing Derivation.md`'s TX section: the
committed VCO/phase configuration and its measured margin (from Step 4), then
a **"If 58 ps proves insufficient on the bench"** subsection with the exact
procedure — not implemented, but fully specified so a future bring-up session
can execute it without re-deriving anything:

1. Measure the actual shortfall with a scope on `GTX_CLK`/`TXD0` (B.5 step
   5, already in `bringup_checklist.md`).
2. Compute the needed additional delay in units of the register's 0.06 ns
   step (B.1b: KSZ9031RNX MMD `2h`/`8h`, bits `[9:5]`, up to +1.38 ns —
   `ceil(shortfall_ns / 0.06)` steps).
3. Issue the MMD indirect-access sequence over MDIO: write the Clause 22
   MMD Access Control register (standard register address, function code
   for "address," device address `2h`) with the target register `8h`; write
   the MMD Access Data register with `8h`'s current value; write MMD Access
   Control again with the function code for "data, no post-increment"; write
   MMD Access Data with the new value (current value with bits `[9:5]` set to
   the computed step count). Name the actual standard register addresses
   this MMD access convention uses (check the KSZ9031RNX datasheet's MDIO
   register map section, not just B.1b's summary, before writing the
   procedure down — do not invent register numbers this task has not
   confirmed).
4. `rtl/gem_mdio.v`'s existing `req_valid`/`req_write`/`req_phyad`/
   `req_regad`/`req_wdata` port is the primitive this sequence rides on —
   `rtl/gem_top.v` currently ties it to `1'b0` (confirmed, `gem_top.v:158`);
   wiring a bench-time-only debug path to it (e.g. behind a JTAG VIO, or a
   temporary RTL edit for the bring-up session) is a bring-up-time decision,
   not something this task commits permanently — say so explicitly rather
   than leaving it ambiguous whether this is "built" or "documented."

- [ ] **Step 6: Update `verification_plan.md`**

R14 row: change `open` → `green`, citing this task's Step 4 measured margin
(not Task 2d's, which was a diagnostic candidate, not the committed
configuration) and noting the bench half remains V-2's job.

V-2 row: it is not closing yet (that needs the board) — reword its `Plan`
column to name the fallback procedure from Step 5 by section reference,
rather than leaving "Stage 6 `report_timing`... then bring-up step 5" as the
only text, since Stage 6's `report_timing` half is now done and V-2's
remaining plan is specifically the bench measurement plus the documented
fallback if it's needed.

- [ ] **Step 7: Update `bringup_checklist.md`**

At B.5 step 5 (already `GTX_CLK`/`TXD0` scope/ILA), add a short note: if the
scope shows setup timing is not being met, `Documents/RGMII I-O Timing
Derivation.md`'s "If 58 ps proves insufficient" procedure is the next step —
point to it by name rather than re-explaining it in two places.

- [ ] **Step 8: Full verification, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

```bash
git add rtl/gem_mmcm.v "Documents/RGMII I-O Timing Derivation.md" verification_plan.md bringup_checklist.md
```

```bash
git commit -m "Restructure the MMCM's VCO for the phase margin the 1000 MHz grid could not give, and name the bench fallback if it is not enough"
```

The message must include: the Step 4 measured margin on all five TX ports
(the real, freshly-measured number, not inherited from Task 2d), confirmation
`tx_clk`/`gtx_clk_shifted` both stayed at 125 MHz, and an explicit statement
that this is a real, measured improvement but still short of the "not
razor-thin" bar every task in this chain has used — 58 ps is what shipped,
not what was aspired to, and the bench is still the final word.

---

## Task 3: False-path everything genuinely asynchronous

**Files:**
- Modify: `constrs/exceptions.xdc`

**Interfaces:**
- Consumes: nothing new.
- Produces: the remaining gate-3 findings resolved by explicit exception
  rather than by a numeric constraint, so Task 4's refusal has zero unexplained
  ports left when it goes live.

Six ports remain unconstrained after Tasks 1–2, none of them RGMII, all
genuinely asynchronous or too slow for static timing to say anything useful
about — confirmed by reading how each is consumed in `rtl/gem_top.v`:

| Port | Direction | Why false, not delayed |
|---|---|---|
| `rst_key_n` | in | Board reset button, feeds `gem_clk_rst`'s asynchronous-assert reset synchroniser (`rtl/gem_top.v:89`) — the synchroniser exists precisely so this input's arrival time relative to any clock is irrelevant |
| `key_clear_n` | in | Counter-clear button, feeds its own 2-flop synchroniser (`rtl/gem_top.v:272`) — same reasoning |
| `mdio` | in/out | Clause 22 bus, ≤ 2.5 MHz (R16) — two orders of magnitude below any domain's own margin; MDC itself is a gated enable on `tx_clk`, not a free-running clock, so there is no meaningful launch/capture relationship to bound |
| `mdc` | out | Same bus, same reasoning |
| `phy_rst_n` | out | Held low ≥ 10 ms by `gem_clk_rst`; nothing external samples it against a clock edge |
| `uart_tx` | out | 115200 baud serial, already proven at its true bit rate in `tb_gem_uart_tx`; nothing in this design's static timing analysis needs to know when a UART bit changes |

- [ ] **Step 1: Add the exceptions**

Append to `constrs/exceptions.xdc`:

```tcl
#-----------------------------------------------------------------------------
# Asynchronous board I/O -- buttons, PHY reset, MDIO, UART. None of these has
# a setup/hold relationship external timing analysis can usefully check; see
# the table in docs/superpowers/plans/2026-08-19-stage6-part2-rgmii-timing.md
# Task 3 for why each one specifically qualifies, following the same
# "unconstrained because it does not matter, and said so" principle the LED
# false path above already established.
#-----------------------------------------------------------------------------

set_false_path -from [get_ports rst_key_n]
set_false_path -from [get_ports key_clear_n]
set_false_path -from [get_ports mdio]
set_false_path -to   [get_ports mdio]
set_false_path -to   [get_ports mdc]
set_false_path -to   [get_ports phy_rst_n]
set_false_path -to   [get_ports uart_tx]
```

- [ ] **Step 2: Build and confirm the report count drops to zero**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

```bash
grep -A5 "checking no_input_delay\|checking no_output_delay" build/check_timing.rpt
```

Expected: `(0)` on both, with the report text confirming every previously-HIGH
port now shows only in the "false path constraint" (reported, not refused)
category, or does not appear at all.

- [ ] **Step 3: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

```bash
git add constrs/exceptions.xdc
```

```bash
git commit -m "Say out loud why six board pins have nothing to time against"
```

Include the before/after `no_input_delay`/`no_output_delay` counts from Step 2.

---

## Task 4a: Fix the RX hold violation Task 4 exposed

**Why this task exists.** Task 4's job was mechanical — wire
`constrs/rgmii_timing.xdc` into the real build. Doing that for the first time
ever (every earlier task deliberately used a throwaway `read_xdc`-against-
checkpoint script instead of the real build, precisely because wiring it in
was always Task 4's job) surfaced a real hold violation gate 2 has never been
able to see before: `WHS = -1.031 ns`, on `rgmii_rxd[1]`, a full nanosecond
deep — not a thin margin like the TX chain's, a structural error. Task 4
correctly stopped rather than working around it. This task fixes the
underlying constraint; Task 4's own `scripts/build.tcl` edit (already
implemented, sitting unstaged and correct) resumes once this is closed.

**The root cause, traced by Task 4 and confirmed by reading the file
directly.** `constrs/rgmii_timing.xdc`'s RX section (Task 1) copies
`reference/verilog-ethernet/syn/quartus/rgmii_io.sdc`'s false-path structure
verbatim:

```tcl
set_false_path -rise_from virt -fall_to real -setup
set_false_path -fall_from virt -rise_to real -setup
set_false_path -rise_from virt -rise_to real -hold
set_false_path -fall_from virt -fall_to real -hold
```

This pairing is correct **only when the real capturing clock is phase-shifted
relative to the virtual one** — the reference template's own real clock is
declared `-waveform {2 6}`, a 90° shift from its virtual clock's `{0 4}`,
specifically so "corresponding" edges land mid-eye. `constrs/clocks.xdc`
declares `rgmii_rx_clk` with **no waveform argument** (`create_clock -name
rgmii_rx_clk -period 8.000 [get_ports rgmii_rx_clk]`), and
`constrs/rgmii_timing.xdc`'s `rgmii_rx_clk_virt` also has no waveform
argument — both default to `{0.000 4.000}`, identical, zero relative phase.
The structure was transplanted from the reference; the phase relationship
that makes the structure valid was not. With zero phase between virtual and
real, the edge pair the RX section leaves un-false-pathed for hold
(`fall_from virt → rise_to real`) is not the fictitious pair the reference
template intended to exempt from checking — it is real, and it is violated:
data launched off the virtual clock's fall edge is captured almost
immediately (~1.4 ns, an IBUF delay) by the real clock's very next rise edge,
while the clock network's own route to the IDDR (~5.2 ns) dwarfs that margin.

**Why this was not caught earlier.** Task 1's own verification (Step 4 of its
brief) checked `report_timing -from [get_ports {rgmii_rxd[0]}]` — one port
only, and it happens to pass (Task 1's own report: hold slack `+1.794 ns` on
`rgmii_rxd[0]`). The TX chain (Tasks 2c/2d/2e) later established the
discipline of checking **all** RGMII ports, because Task 2c found up to 15 ps
of port-to-port variation — that discipline was never retroactively applied
to Task 1's RX work. This task closes that gap too: every RX port gets
checked, at both setup and hold, on the real build, not a sample of one.

**What this task is not.** It is not free to guess a plausible-looking fix
and declare victory if `report_timing` happens to show positive slack —
that is exactly how the original defect passed review: a structure that
looked right, matched a reference, and was never checked against whether the
reference's own embedded assumption held here. Any fix must be re-derived
from B.1b's actual physical numbers (the PHY's ~1.2 ns default `RX_CLK`
delay, the `TsetupR`/`TholdR` 1.0–2.0 ns window) and verified against the
real, wired-in build — not a throwaway script — before being trusted.

**Files:**
- Modify: `constrs/rgmii_timing.xdc` (RX section — the virtual clock's
  declaration and/or the false-path structure, whichever the re-derivation
  finds correct; do not touch the TX section, which is unrelated and
  already closed)
- Possibly modify: `constrs/clocks.xdc` (`rgmii_rx_clk`'s `create_clock`
  waveform) — only if the re-derivation concludes the real clock's declared
  phase, not the virtual one, is where the fix belongs; both are
  mathematically equivalent ways to encode a relative phase between two
  clocks where only one (the virtual one) is a pure modelling construct
  with no other consumer in the design, so the choice is about clarity for
  a future reader, not correctness — state which was chosen and why
- Modify: `Documents/RGMII I-O Timing Derivation.md` (record what was wrong,
  why, and the corrected derivation — this is exactly the kind of finding
  that belongs in this document's existing RX section, not a new one)

**Interfaces:**
- Consumes: `constrs/clocks.xdc`'s existing `rgmii_rx_clk` declaration (do
  not touch the RX FIFO's `set_clock_groups -asynchronous` relationship to
  the MMCM-derived clocks — that is unrelated to this virtual-clock/real-
  clock pairing entirely).
- Produces: a corrected `constrs/rgmii_timing.xdc` RX section with positive
  setup and hold slack on `rgmii_rxd[0..3]` and `rgmii_rx_ctl`, verified on
  the real, wired-in build — which is what unblocks Task 4's resumption.

- [ ] **Step 1: Re-derive the correct relationship from B.1b's numbers, not from the reference template's structure**

Read `spec/PROJECT_SPEC.md` B.1b's RX derivation again: the PHY delays
`RX_CLK` ~1.2 ns (typical) relative to `RXD`/`RX_DV`, by default, no MDIO
write needed — this is a physical fact about what arrives at the FPGA's
pins, not a choice this design makes. `RGMII v2.0`'s `TsetupR`/`TholdR`
window (1.0–2.0 ns) is the guaranteed margin a compliant receiver gets once
that delay is applied. Task 1's `set_input_delay -max 3.000 -min -1.000`
values (`period/2 - Tsetup_min` and `-(Thold_min)`) are not in question here
— what's missing is that those values were derived **relative to a virtual
clock representing an idealised, zero-delay launch reference**, and the
real clock (`rgmii_rx_clk`) is what the PHY delays by ~1.2 ns *relative to
that same idealised reference* — a fact never encoded anywhere in the XDC.
Work out, from first principles, what phase relationship between
`rgmii_rx_clk_virt` and `rgmii_rx_clk` correctly represents "the real clock
arrives ~1.2 ns after where an idealised launch reference's corresponding
edge would be" — and which of the two clocks should carry that phase in the
`create_clock` declaration, given that a `create_clock` phase on an
externally-driven, unconstrained-relationship clock pin is a modelling
choice for static analysis, not a claim about an externally observable
absolute phase (uniformly shifting `rgmii_rx_clk`'s declared phase does not
perturb any RX-domain-internal register-to-register check, since those are
all relative to `rgmii_rx_clk`'s own edges).

Write this derivation down — the arithmetic, the reasoning, the chosen
phase value and its sign — with the same rigor `rtl/gem_mmcm.v`'s header
already applies to its own numbers, before writing a single line of XDC.

- [ ] **Step 2: Write the corrected XDC**

Apply Step 1's derivation to `constrs/rgmii_timing.xdc`'s RX section (or
`constrs/clocks.xdc`, per Step 1's conclusion about which clock carries the
phase). Keep the `set_input_delay -max 3.000 -min -1.000` values as they
are — Task 1's own derivation of those specific numbers from the `1.0 ns`
guaranteed-minimum window bound was correct and independent of this bug; do
not re-derive them unless Step 1's reasoning genuinely implicates them too.

- [ ] **Step 3: Verify on the real, wired-in build — every RX port, both checks**

`scripts/build.tcl` already has Task 4's edit sitting in the working tree
(unstaged, uncommitted) with `constrs/rgmii_timing.xdc` in `XDC_SOURCES` for
`gem_top`. Do not revert it — build against it:

```bash
python scripts/build.py impl gem_top
```

(`synth` cannot reach gate 2/3 — `TARGET=="synth"` returns before
implementation runs, a fact Task 4's report already found and flagged; use
`impl` or `bitstream`, not `synth`, for every check in this task.)

Expected, if the fix is right: gate 2 passes (`WNS` and `WHS` both ≥ 0).
Then, against the resulting `build/post_route.dcp`, check every RX port
individually:

```tcl
report_timing -to [get_pins -hierarchical -filter {REF_NAME == IDDR}] -max_paths 10 -delay_type min_max
```

Confirm setup and hold are both positive on `rgmii_rxd[0]`,
`rgmii_rxd[1]` (the port that was violated), `rgmii_rxd[2]`, `rgmii_rxd[3]`,
and `rgmii_rx_ctl`. Record every number — this task does not get to
generalise from one port after what happened last time.

- [ ] **Step 4: Confirm the checked edge pairs are the physically real ones**

Read the full `report_timing` output (not just the slack summary) for the
worst setup and worst hold path, exactly as Task 2c and Task 4's own
diagnosis did — confirm which clock edges (`rise@`/`fall@` on both the
virtual and real clock) are actually being checked, and confirm by
independent reasoning (not just "the tool didn't flag it") that those are
the edges that physically correspond to a real capture event given the
PHY's ~1.2 ns delay. This is the same discipline Task 4's diagnosis already
applied when it found the *previous* pairing was checking a real relationship
the reference template assumed was fictitious — do not let a corrected
constraint pass this task's review on "no violation reported" alone.

- [ ] **Step 5: The sign-flip sanity check**

Same standard every timing constraint in this plan has been held to.
Deliberately change the chosen phase value by a clearly-wrong amount (e.g.
double it, or flip its sign) and confirm slack moves in the direction that
confirms the constraint is measuring the real relationship, not a
coincidentally-passing but disconnected one. Revert before committing.

- [ ] **Step 6: Update the derivation document**

Add to `Documents/RGMII I-O Timing Derivation.md`'s existing RX section
(not a new section — this corrects, not extends, the existing derivation):
what was wrong (the borrowed reference template's phase assumption), why it
passed Task 1's own review (single-port verification), the corrected
derivation from Step 1, and the Step 3 measured margins on all five RX
ports.

- [ ] **Step 7: Full verification, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28 (no RTL or simulation input touched).

```bash
python scripts/build.py bitstream gem_top
```

Expected: gate 2 passes, and gate 3 is now reached (it will still show
`no_input_delay`/`no_output_delay` counts from Task 3's already-closed
board pins and whatever remains — that is Task 4's concern, not this one's;
do not merge this task's commit with Task 4's `build.tcl` edit).

```bash
git add constrs/rgmii_timing.xdc "Documents/RGMII I-O Timing Derivation.md"
```

(Add `constrs/clocks.xdc` too if Step 1 concluded the phase belongs there.)

```bash
git commit -m "Fix the RX hold check the borrowed template's phase assumption never applied to this design"
```

The message must include: the wrong assumption and why it passed review,
Step 1's derivation, the Step 3 per-port measurements (all five), and the
Step 5 sign-flip result. Do **not** commit `scripts/build.tcl` — that
remains Task 4's uncommitted change, to be committed when Task 4 resumes.

**Task 4a's actual outcome:** BLOCKED. The re-derivation in Step 1 converged
correctly — `rgmii_rx_clk` needs `-waveform {1.200 5.200}`, and the RX input
delays become `max 0.200 / min -1.800` — and applying it makes Vivado check
the physically real edge pairs for the first time (confirmed by Step 4's
independent, pre-measurement arithmetic prediction, which matched the tool
to single-digit picoseconds). But doing so exposed a violation no constraint
can close: every RX port fails hold by very nearly the same amount
(`WHS` as bad as `-3.031 ns`), and Task 4a proved — algebraically and by a
sign-flip sweep — that `setup_slack + hold_slack` is invariant under every
choice of phase or input-delay value. The deficit is physical: the RX clock
network's own insertion-delay spread from pin to `IDDR` (measured **3.720 ns**,
fast corner 1.490 ns to slow corner 5.210 ns) is driven by a plain `BUFG`
with 142-way fanout, and it dwarfs the 2.000 ns eye RGMII v2.0 guarantees.
Full detail, including the falsifiable acceptance criterion this next task
uses (skew spread must drop below **1.761 ns**, from today's 2.746 ns
uncompensated), is in `task-4a-report.md`. The corrected XDC from Task 4a's
Step 2 is verified and ready — Task 4b applies it as-is; it does not need
re-deriving.

---

## Task 4b: Give the RX clock a BUFIO/BUFR path, closing the hold deficit at its source

**Why this task exists.** Task 4a proved the RX hold deficit cannot be closed
by any constraint — it is set by the RX clock network's own insertion-delay
spread, driven today by an inferred `BUFG` (fanout 142) with no dedicated
low-skew path to the six RX I/O sites. The project owner chose the standard
7-series fix: replace that `BUFG` with a `BUFIO`/`BUFR` pair — `BUFIO` for
the `IDDR` cells (the only thing it can drive; it has no fabric fan-out at
all), `BUFR` for everything else in the `rx_clk` domain, both derived from
the same clock-capable pin so their relative skew stays small and regional
rather than chip-wide. Task 4a confirmed the physical resources exist and
reach: `rgmii_rx_clk` lands on pin K18, `IO_L13P_T2_MRCC_15`
(`IS_CLK_CAPABLE = 1`), and **all six** RX I/O sites — `rgmii_rx_clk` itself
(`IOB_X0Y74`), `rgmii_rxd[0..3]` (`IOB_X0Y73/52/57/78`), `rgmii_rx_ctl`
(`IOB_X0Y80`) — sit in clock region **X0Y1**, where `BUFIO_X0Y4..7` and
`BUFR_X0Y4..7` are free.

**The reference pattern, already vendored in this repository.** This project
has already cited `reference/verilog-ethernet` twice (V-17's `IDDR` nibble
mapping, the Quartus SDC structure Tasks 1/2 built the XDC from). It has a
third citation here:
`reference/verilog-ethernet/rtl/ssio_ddr_in.v`'s `CLOCK_INPUT_STYLE ==
"BUFR"` branch is exactly this fix — `BUFIO` feeding the `IDDR`'s clock
(`clk_io`), `BUFR #(.BUFR_DIVIDE("BYPASS"))` feeding everything else
(`output_clk`), both driven from the same raw input net. Read that file
before writing anything; it is the concrete precedent, not a name to
recognise and reimplement from scratch.

**The scope decision that keeps this contained.** `rgmii_rx_clk` today
enters `rtl/gem_mac.v` as a single external port and is used *directly*,
unbuffered, by everything in the `rx_clk` domain: the `IDDR`s (inside
`gem_rgmii_rx`, via `gem_mac.v:221`), the deframer/CRC/classify logic
(`gem_mac.v:238,257`), the RX FIFO's write clock (`gem_mac.v:269`), and the
CDC pulse synchronisers' source clock (`gem_mac.v:301-317`). **Do not change
`gem_mac`'s external port list.** Every consumer of `gem_mac` —
`rtl/gem_top.v`, `tb/tb_gem_mac_rx.sv`, `tb/tb_gem_mac_tx.sv`,
`tb/tb_gem_mac_loopback.sv`, `tb/assertions/gem_internal_sva.sv` — connects
to the single `rgmii_rx_clk` port and none of them reach into `gem_mac`'s
internals (confirmed: every reference is a top-level port connection, not a
hierarchical path). The `BUFIO`/`BUFR` split happens **entirely inside
`gem_mac.v`**, at the point where `rgmii_rx_clk` currently fans out to its
internal consumers — zero external interface change, zero testbench
changes. `rtl/gem_top.v`'s separate wiring of the raw `rgmii_rx_clk` pin
into `gem_clk_rst`'s own `rx_clk` input (for the reset synchroniser only)
stays exactly as it is — that is a low-fanout, non-data-path use with no
static-timing requirement Task 4a's finding implicates.

**Files:**
- Create: `rtl/gem_rx_clkbuf.v` — the vendor-primitive module, following
  this project's own established pattern (`rtl/gem_mmcm.v`, `rtl/gem_iddr.v`,
  `rtl/gem_oddr.v`: vendor clocking primitives isolated in their own file,
  two branches gated on `GEM_BEHAVIORAL_IO` — the default branch
  instantiates `BUFIO`/`BUFR`, the behavioural branch is a plain
  pass-through for `XSim`/Verilator, since simulation cannot see clock-
  network skew at all and no testbench needs to change)
- Modify: `rtl/gem_mac.v` (instantiate the new module where `rgmii_rx_clk`
  enters; route its `BUFIO` output only to `gem_rgmii_rx`'s clock port;
  route its `BUFR` output to every other current consumer of the raw pin)
- Modify: `constrs/clocks.xdc`, `constrs/rgmii_timing.xdc` (Task 4a's
  already-derived, already-verified corrected text — apply as-is)
- Modify: `Documents/RGMII I-O Timing Derivation.md` (Task 4a deliberately
  left this unwritten, since the corrected derivation would have disagreed
  with the uncorrected tree — this task writes it, now that both the
  constraint and the clocking match)
- Modify: `rtl/gem_rgmii_rx.v` (the header's "no IDELAY … an IDDR clocked
  directly by the recovered clock is sufficient for v1" reasoning is now
  known incomplete — it accounted for the PHY's pin-level delay and never
  accounted for the FPGA's own internal clock-network insertion-delay
  spread; correct it, citing Task 4a's finding by report name)
- Modify: `verification_plan.md` (R14's row currently only carries the TX
  story; the RX hold finding and its fix belong there too, or in a new row
  if R14's scope doesn't naturally cover RX capture timing — check R9/R21's
  rows first, since RX latency/capture correctness might be the more
  natural home; use whichever the existing traceability table's own
  structure suggests, and say which you picked and why)

**Interfaces:**
- Consumes: Task 4a's corrected `constrs/clocks.xdc`/`constrs/rgmii_timing.xdc`
  text (reproduced in `task-4a-report.md`, Step 2) and its falsifiable
  acceptance criterion (skew spread < 1.761 ns).
- Produces: an RX clock path whose measured insertion-delay spread is inside
  that bound, verified per-port on the real build — which is what finally
  lets Task 4 resume and complete.

- [ ] **Step 1: Read the reference implementation and this project's own coding standard**

```bash
cat reference/verilog-ethernet/rtl/ssio_ddr_in.v
```

```bash
cat coding_standard.md
```

(check its section on vendor primitive isolation and the
`GEM_BEHAVIORAL_IO` two-branch convention against how `rtl/gem_mmcm.v` and
`rtl/gem_iddr.v` actually implement it — match the established style, not a
new one).

- [ ] **Step 2: Write `rtl/gem_rx_clkbuf.v`**

One input (the raw `rgmii_rx_clk` pin), two outputs: `rx_clk_io` (via
`BUFIO`, for the `IDDR`s only) and `rx_clk` (via `BUFR`, `BUFR_DIVIDE
("BYPASS")`, `CE` tied high, `CLR` tied low, for everything else). Default
branch: the two Xilinx primitives, following `ssio_ddr_in.v`'s exact
instantiation. `GEM_BEHAVIORAL_IO` branch: both outputs simply `assign`ed
from the input — a plain wire, since simulation's `GEM_BEHAVIORAL_IO`
`IDDR`/`ODDR` models already don't care about clock-network delay and
nothing should change about simulated behaviour.

- [ ] **Step 3: Wire it into `rtl/gem_mac.v`**

Instantiate `gem_rx_clkbuf` where `rgmii_rx_clk` currently enters the
module's RX-domain logic. Route its `rx_clk_io` output to `gem_rgmii_rx`'s
clock port only. Route its `rx_clk` output to every other current consumer
of the raw `rgmii_rx_clk` port (`gem_mac.v:238,257,269,301-317` — confirm
the exact list yourself by re-reading the file; do not trust this list as
exhaustive without checking). The external `rgmii_rx_clk` port itself does
not change name, width, or direction.

- [ ] **Step 4: Apply Task 4a's already-verified constraint corrections**

Apply the exact `constrs/clocks.xdc` and `constrs/rgmii_timing.xdc` text
from `task-4a-report.md`'s Step 2 — do not re-derive it, it is already
correct and already verified against the physically real edge pairs. If
this task's own measurement (Step 5) disagrees with Task 4a's, that is a
new finding to report, not a cue to adjust the constraint further without
understanding why first.

- [ ] **Step 5: Measure on the real build — every RX port, both checks, against the falsifiable criterion**

```bash
python scripts/build.py impl gem_top
```

Expected: gate 2 passes (`WNS` and `WHS` both ≥ 0). If it still refuses,
read the actual measured clock-network insertion delays off the routed
checkpoint (the same way Task 4a's Step 4/"root cause" section did — read
the segment-by-segment breakdown, not just the summary slack) and confirm
whether the spread is now under 1.761 ns; if it is not, this task has not
achieved what it set out to and should report the actual measured spread
rather than a generic "still fails."

Per RX port (`rgmii_rxd[0..3]`, `rgmii_rx_ctl`), record setup and hold slack
individually — the same discipline every task in this plan since Task 2c
has held to. Confirm `WNS` (TX) is unchanged from Task 2e's committed
`+0.058 ns` — this task should not perturb the TX side at all.

- [ ] **Step 6: Confirm the checked edge pairs are still the physically real ones**

Read the detailed `report_timing` output for the worst setup and worst hold
RX paths, exactly as Task 4a's Step 4 did, and confirm the launch/capture
edges named in the `Requirement:` line are one unit interval apart and
correspond to a real capture event — the constraint text is unchanged from
Task 4a, but the *measured* insertion delays feeding into it are not, and
this is the check that would catch a `BUFIO`/`BUFR` wiring mistake (e.g.,
a consumer accidentally left on the raw pin, or the two buffer outputs
swapped) that a bare "gate 2 passes" would not.

- [ ] **Step 7: Update the derivation document and the two stale reasoning comments**

`Documents/RGMII I-O Timing Derivation.md`: write the corrected RX
derivation Task 4a prepared but did not commit (its Step 1 reasoning, its
root-cause section, and this task's own Step 5 measurements replacing the
placeholder "not yet measured" state).

`rtl/gem_rgmii_rx.v`: correct the "no IDELAY … sufficient for v1" reasoning
to account for both halves — the PHY's pin-level delay (still correctly
reasoned about) and the FPGA's own clock-network insertion-delay spread
(the part that was missing, now closed by the `BUFIO`/`BUFR` path this task
adds). Cite `task-4a-report.md` for the finding and this task's report for
the fix, matching `rtl/gem_mmcm.v`'s own established habit of citing prior
task reports by name rather than restating their numbers.

- [ ] **Step 8: Full verification, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: 28 of 28. This task touches RTL (`gem_rx_clkbuf.v`,
`gem_mac.v`), so this is not a formality the way it was for XDC-only
tasks — confirm the `GEM_BEHAVIORAL_IO` branch genuinely compiles and
simulates identically (the new module is a pure pass-through in that
branch, so no scenario's behaviour should change; if anything does, that is
a real defect in the new module's behavioural branch, not something to
work around).

```bash
python scripts/build.py bitstream gem_top
```

Expected: DRC clean, bitgen succeeds, gates 0–2 all pass (gate 3 is Task
4's job, still pending — `scripts/build.tcl`'s edit remains uncommitted and
unmerged with this task's commit).

```bash
git add rtl/gem_rx_clkbuf.v rtl/gem_mac.v constrs/clocks.xdc \
    constrs/rgmii_timing.xdc "Documents/RGMII I-O Timing Derivation.md" \
    rtl/gem_rgmii_rx.v verification_plan.md
```

```bash
git commit -m "Give the RX clock a BUFIO/BUFR path, so the hold check has something real to measure against"
```

The message must include: the measured insertion-delay spread before and
after (from Task 4a's 3.720 ns to this task's measured value, against the
1.761 ns bound), the per-port setup/hold margins, confirmation TX is
unchanged, and an explicit statement that this closes the finding Task 4
exposed and Task 4a diagnosed. Do **not** commit `scripts/build.tcl` — it
remains Task 4's uncommitted change.

**Task 4b's actual outcome:** BLOCKED. `rtl/gem_rx_clkbuf.v` was written,
wired, placed and routed exactly as designed — `BUFIO`/`BUFR` verified on the
routed netlist to carry the intended fanout, nothing left on the raw pin. It
delivered a real, measured 1.47 ns hold improvement on every RX port and
technically met Task 4a's own falsifiable criterion (spread 1.759 ns against
a 1.761 ns bound) — and gate 2 still refuses, by `WHS = -1.559 ns`. The
criterion itself was incomplete: `spread < 1.761 ns` is exactly
`setup_slack + hold_slack > 0`, which constrains only the *width* of the
skew interval, not *where it sits*. Task 4b proved (algebraically, then
confirmed against the tool to single-digit picoseconds) that the real,
two-sided requirement is a **fixed window**, `skew_fast >= -0.977 ns` **and**
`skew_slow <= +0.784 ns` — and `BUFIO`/`BUFR` narrowed the measured interval
from `[1.069, 3.815]` to `[0.584, 2.343]`, which now fits the window's width
but still sits 1.559 ns too late. It also found the `BUFIO` primitive's own
corner-to-corner spread (1.049 ns on this `-1L` part) is now the largest
single remaining term — the estimate that `BUFIO`/`BUFR` would remove 2.4 ns
was optimistic; it delivered 0.99 ns. Full detail, including the segment-by-
segment insertion-delay tables and the derivation of the fixed window, is in
`task-4b-report.md`. The project owner reviewed this and chose the one
option Task 4b found with real headroom: an MMCM/PLL deskew on `rgmii_rx_clk`
itself, which cancels the clock network's delay by construction rather than
tolerating its spread (predicted interval `[-0.176, +0.082]`, ~0.7–0.8 ns of
real margin each side). Task 4b's `gem_rx_clkbuf.v`/`gem_mac.v` work sits
uncommitted, correct, and superseded by what follows — **Task 4d** decides
explicitly whether it is kept, replaced, or removed.

---

## Task 4c: Design the RX MMCM deskew and its reset/lock semantics — no RTL

**Why this is a design-only task, not an implementation task.** An MMCM fed
by a *recovered* clock is a different kind of problem than the crystal-fed
one `rtl/gem_mmcm.v` already builds, and `rtl/gem_clk_rst.v`'s own header
already states the exact hazard this reopens: *"rx_clk is recovered by the
PHY's CDR and simply does not exist until the PHY is out of reset with a
link. Gating [`rx_rst_n`] on LOCKED would work on the bench and be wrong in
principle."* That sentence was written about the *existing* MMCM (fed by
`clk50`, which the same header calls "free-running, never gated"). A new
MMCM whose `CLKIN` **is** `rgmii_rx_clk` does not get that guarantee — it
loses its own reference the instant the link drops, mid-operation, not only
at cold power-up, which the existing tx-side pattern has never had to
handle. Getting this wrong produces a design that silently stops receiving
frames after any link drop/re-establish cycle, which is a categorically
worse failure than the timing margin this whole chain has been chasing, and
far harder to catch — nothing in this project's regression would notice a
reset-sequencing defect that only bites when a physical link actually
flaps. This task produces a written, reviewed design before a single line of
RTL is written for it. Task 4d implements the design this task approves.

**What is already known and must be reused, not re-derived:**
- The `BUFIO`/`BUFR` topology's finding that the deskew, if it uses the same
  `BUFG`/feedback net for both the `IDDR` capture clock and the fabric
  logic clock, may make `rtl/gem_rx_clkbuf.v` **redundant rather than
  additional** — Task 4b's own concern 3 flags this. Determine which is
  true from Xilinx's actual documented MMCM feedback-deskew topology, not
  from the intuition that "more buffering is more").
- `rtl/gem_mmcm.v`'s existing header already cites the crystal MMCM's real
  lock time (**~100 µs**, from the datasheet) and deliberately does not
  model it in the `GEM_BEHAVIORAL_IO` branch. The new MMCM's lock time needs
  the same sourced number, not an assumption that it is similar.
- `rtl/gem_clk_rst.v`'s three-domain reset table (`clk50`: button alone;
  `tx_clk`: button AND lock, async-assert because losing lock stops the
  clock and "a synchronous path could not deliver the reset at all";
  `rx_clk`: button alone, deliberately not lock-gated) is the existing
  pattern to extend, not to redesign from scratch. The `tx_rst_n` pattern
  (`arst_n = ext_rst_n & mmcm_locked`, async-assert, sync-deassert on the
  MMCM's own output) is the template for how a *lock-gated* reset in this
  codebase is supposed to look; the open design question is whether the new
  RX domain should follow that template, and against which clock it should
  be synchronised if so.

**Files:**
- Create: `Documents/RX Clock Deskew Design.md` — the full derivation,
  written to the standard this repository's other derivation documents hold
  themselves to (see `Documents/RGMII I-O Timing Derivation.md`,
  `Documents/Why RX Recovery Gets 8 Cycles, Not 20.md` for the expected
  depth and citation style)
- No RTL, no XDC, no `scripts/` changes. If reaching a sound design turns
  out to require touching code to test an assumption (e.g. a throwaway
  Vivado session probing `report_clocks`/`report_property` behaviour on a
  minimal MMCM instantiation to confirm lock-time or `CLKINSTOPPED`
  behaviour empirically rather than trusting documentation alone — this
  project's established habit throughout Stage 6 part 2), that is
  encouraged and should be done the same disciplined way every prior task
  in this plan has: a throwaway, gitignored probe, never committed, with its
  findings written into the design document as measured evidence.

**Interfaces:**
- Consumes: Task 4b's finding (the fixed window and the `BUFIO`/`BUFR`
  interval), `rtl/gem_mmcm.v` and `rtl/gem_clk_rst.v`'s existing patterns.
- Produces: an approved design — the MMCM configuration (feedback topology,
  which net it taps, predicted lock time), the full reset/lock state
  machine covering cold power-up / link-establish / link-drop-mid-operation,
  and an explicit decision on `gem_rx_clkbuf.v`'s fate — that Task 4d
  implements without having to make any of these calls itself.

- [ ] **Step 1: Determine the correct MMCM feedback-deskew topology for this case**

Xilinx's network-deskew technique routes the MMCM's feedback input
(`CLKFBIN`) from a point in the clock's own distribution that represents
what the technique is meant to cancel. Work out, and write down with
citations: does the feedback tap need to be the same `BUFG` net that also
drives the `IDDR`s and the fabric logic (a single deskewed clock domain,
making a separate `BUFIO`/`BUFR` split unnecessary), or does correctly
deskewing the `IDDR`'s own capture point require a different topology (e.g.
tapping near the `IDDR` region specifically, keeping some form of the
`BUFIO` split alongside the new MMCM)? Consult `UG472` (7 Series FPGAs
Clocking Resources) rather than reasoning from first principles alone — this
is exactly the kind of primitive-behaviour claim Task 4b's brief insisted on
verifying against the tool or the vendor documentation, not assuming.

**State the decision plainly**, with the reasoning, and its consequence for
`rtl/gem_rx_clkbuf.v`: keep it (and say what still uses `BUFIO`/`BUFR` once
the MMCM is in place), replace it, or remove it.

- [ ] **Step 2: Derive the MMCM configuration**

`rgmii_rx_clk` is nominally 125 MHz (8 ns period) but is a **recovered**
clock — state what ppm/jitter tolerance a real RGMII link's recovered clock
carries (this project's own `spec/PROJECT_SPEC.md` B.3a already has a ppm
figure used elsewhere for the RX FIFO's drift budget — reuse it rather than
inventing a new one, and confirm it is the right number for this purpose
rather than assuming). Work out the VCO frequency, multiply/divide values,
and confirm the resulting VCO lands inside the Artix-7's 600–1200 MHz range,
the same discipline `rtl/gem_mmcm.v`'s own header applies to the existing
MMCM's arithmetic. State the predicted lock time, sourced from the
datasheet's lock-time formula or table (`UG472`), not assumed to match the
existing MMCM's ~100 µs figure just because it is a similar part.

- [ ] **Step 3: Derive the complete reset/lock semantics — this is the load-bearing part**

Write out, explicitly, what happens in each of these cases, and what RTL
behaviour (not yet written, but specified precisely enough that Task 4d does
not have to make a design choice while implementing) each one requires:

1. **Cold power-up, no link yet exists.** `rgmii_rx_clk` is not running. Does
   an un-clocked MMCM primitive sit in a stable, well-defined, non-erroring
   state indefinitely (confirm from `UG472`, do not assume)? What does
   `LOCKED` read in this state, and is that reliably readable by anything
   synchronous to a *different* clock without its own CDC hazard?
2. **Link establishes.** `rgmii_rx_clk` starts, plausibly with some CDR
   acquisition instability before it is a clean, stable, in-spec 125 MHz
   clock. Does the MMCM's own internal behaviour tolerate an unstable input
   during this window (i.e., does it just take longer to lock, or can an
   unstable input produce a *false* `LOCKED` assertion — check this, it is
   exactly the kind of primitive behaviour worth not assuming)? State the
   reset-release sequencing this implies for whatever domain the deskewed
   clock feeds.
3. **Link drops mid-operation.** `rgmii_rx_clk` stops. `rtl/gem_clk_rst.v`'s
   own header already states the general principle for this exact case on
   the tx side: *"a synchronous path could not deliver the reset at all"*
   once a clock stops, hence async-assert. Determine whether the new MMCM's
   `LOCKED` deasserts promptly enough, and by what mechanism, to serve as an
   async-assert reset source for whatever it feeds — and confirm this
   doesn't reintroduce exactly the deadlock class `gem_clk_rst.v`'s header
   warns about (**a domain's reset depending on another domain's clock
   running**) in a new guise, since the "another domain" here is the new
   MMCM's *own* lock state, sourced from a clock (`rgmii_rx_clk`) that is
   itself the thing disappearing.
4. **Link flaps rapidly** (up/down/up in quick succession — a real,
   expected condition, not a corner case to dismiss). Does repeated
   loss-and-reacquisition of lock ever leave the new MMCM, or whatever
   depends on it, in a state from which it cannot recover without a full
   board reset? This is the regression-risk question worth answering
   explicitly: does this design ever perform **worse** than today's
   BUFG-clocked (or Task 4b's BUFIO/BUFR-clocked) RX path under any
   condition, even though it has more margin when locked?

For each case, state whether the existing `u_rx_rst` reset synchroniser
(clocked by raw `rgmii_rx_clk`, deliberately *not* lock-gated per the
existing header) is still correct as-is, needs to move to the new deskewed
clock, or needs a second, lock-gated reset stage added — following the
`tx_rst_n` template (`arst_n = ext_rst_n & new_mmcm_locked`, async-assert,
sync-deassert on the new MMCM's own stable output) if Step 3.3's answer
calls for one, and explaining why if it does not.

- [ ] **Step 4: Write the design document**

`Documents/RX Clock Deskew Design.md`: Steps 1–3 in full, with every claim
about primitive behaviour cited (to `UG472`, to a throwaway empirical probe
this task ran and is showing the output of, or to this project's own
existing `spec/PROJECT_SPEC.md`/`rtl/gem_mmcm.v`/`rtl/gem_clk_rst.v` text) —
not asserted from general FPGA-design knowledge alone, the same standard
Task 4a and Task 4b held every numeric timing claim to. End with an explicit
implementation checklist Task 4d can execute against without having to
re-derive anything: the module(s) to write or modify, their port lists, the
reset topology, and the acceptance criteria (both the timing bound Task 4b
already established and any new lock-time/reset-sequencing behaviour this
task specifies that Task 4d's testbench work, if any, needs to demonstrate).

- [ ] **Step 5: Self-check against the project's own stated principle before finishing**

Re-read `rtl/gem_clk_rst.v`'s header one more time against the finished
design. B.1b's rule is "no domain's reset release depends on another
domain's clock running." If the design in Step 3 makes the RX-domain's
reset release depend on the new MMCM's lock — which is very likely the
right answer, since it is exactly the `tx_rst_n` pattern — write down
explicitly why that is *not* a violation of B.1b's rule (the new MMCM's
`CLKIN` and the domain being reset are the *same* clock source, `rgmii_rx_clk`,
not two independent domains, which is different in kind from the case the
header actually warns about) or, if it turns out to be a real violation,
say so and do not paper over it — that would be exactly the kind of "looks
right, matches a pattern" mistake this whole finding chain started from.

No commit in this task — it produces a document, and the plan's next task
(4d) is where implementation and its own commit happen.

**Files:**
- Modify: `scripts/build.tcl`

**Interfaces:**
- Consumes: zero unconstrained ports, from Task 3.
- Produces: a build that exits 1 if any RGMII or other pin loses its I/O delay
  or false-path exception in the future.

- [ ] **Step 1: Move the four I/O-delay checks from the reporting loop to the refusing one**

In `scripts/build.tcl`, the existing refusing `foreach` block (`no_clock`,
`constant_clock`, `unconstrained_internal_endpoints`, `multiple_clock`,
`loops`, `latch_loops`) and the reporting-only block just below it
(`no_input_delay`, `no_output_delay`, `partial_input_delay`,
`partial_output_delay`) merge into one refusing block:

```tcl
foreach {check description} {
    no_clock                          "register/latch pin(s) with no clock reaching them"
    constant_clock                    "register/latch pin(s) clocked by a constant"
    unconstrained_internal_endpoints  "internal endpoint(s) unconstrained for maximum delay"
    multiple_clock                    "register/latch pin(s) reached by multiple clocks"
    loops                             "combinational loop(s)"
    latch_loops                       "latch loop(s)"
    no_input_delay                    "input port(s) with no input delay"
    no_output_delay                   "output port(s) with no output delay"
    partial_input_delay               "input port(s) with only a partial input delay"
    partial_output_delay              "output port(s) with only a partial output delay"
} {
    set n [gem_check_count $ct_text $check]
    if {$n > 0} {
        puts "FATAL: check_timing reports $n $description ($check)."
        puts "See $ct_report."
        puts "Build refused: the design is not fully covered by timing analysis."
        exit 1
    }
}
```

Delete the old second `foreach` block and its preceding comment (the one
starting `# Reported, not refused. On this skeleton the LEDs genuinely have no
timing requirement`), since that reasoning now lives in Task 3's exceptions
comment instead.

- [ ] **Step 2: Confirm it passes clean**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: `==> Constraint coverage check: PASS`, no `FATAL` line, gates 0
through 3 all reporting PASS as in Stage 6 part 1, now with zero unconstrained
ports rather than 21.

- [ ] **Step 3: Prove it refuses — remove one line and watch**

```bash
sed -n '1,50p' constrs/rgmii_timing.xdc
```

Temporarily comment out the first `set_input_delay -clock rgmii_rx_clk_virt
-max 3.000 $rx_data_ports` line, then:

```bash
python scripts/build.py synth
```

Expected: gate 3 refuses with `FATAL: check_timing reports ... input port(s)
with only a partial input delay` (removing one of four edge/direction
combinations leaves a *partial* input delay, not a fully missing one — the
more precise failure mode, and worth seeing specifically). Revert:

```bash
git checkout -- constrs/rgmii_timing.xdc
```

- [ ] **Step 4: Also prove the skeleton build is unaffected**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream TOP=skeleton_top
```

Expected: still passes — `constrs/skeleton.xdc` already constrains its two
real ports and false-paths its LEDs, none of which changed.

- [ ] **Step 5: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

```bash
git add scripts/build.tcl
```

```bash
git commit -m "Make gate 3 refuse an unconstrained pin instead of reporting it"
```

Include the Step 3 refusal message and the Step 4 skeleton-build confirmation.

---

## Task 5: CDC and methodology gates

**Files:**
- Modify: `scripts/build.tcl`

**Interfaces:**
- Consumes: nothing new.
- Produces: `report_cdc` and `report_methodology` output in `build/`, and a
  gate that refuses on CDC criticals (R19's traceability table already
  promises this at Stage 6).

- [ ] **Step 1: Run both reports manually first, before wiring them into a gate**

```tcl
open_checkpoint build/post_synth.dcp
report_cdc -file build/gem_top_cdc.rpt
report_methodology -file build/gem_top_methodology.rpt
```

Read `build/gem_top_cdc.rpt`. Expect findings on: the RX FIFO's Gray-coded
pointers (`rtl/gem_rx_fifo.v`, the one true async-FIFO CDC in this design,
already covered by `constrs/clocks.xdc`'s `set_clock_groups -asynchronous`)
and the three reset synchronisers in `rtl/gem_clk_rst.v` (`gem_reset_sync`
instances). Both are *known-safe* crossings the design already handles
correctly — the goal here is confirming `report_cdc` recognises them as such,
not finding new bugs.

- [ ] **Step 2: Classify each finding**

For every CDC finding, determine: is it a crossing this design already
believes is safe (Gray-coded pointer, or a synchroniser chain with
`ASYNC_REG`-equivalent structure)? If Vivado's `report_cdc` flags a
synchroniser chain as a CDC risk because the two flops in
`rtl/gem_reset_sync.v` are not marked `ASYNC_REG`, that is the actual defect to
fix — not a report to override. Check:

```bash
grep -n "ASYNC_REG\|(\* \|attribute" rtl/gem_reset_sync.v rtl/gem_rx_fifo.v
```

If neither file has the attribute, add it via XDC (preferred over an inline
attribute, since it keeps synthesis-tool-specific properties out of portable
RTL — consistent with this repo's existing separation of concerns):

```tcl
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter \
    {NAME =~ "*u_reset_sync*/sync_reg*"}]
```

Adjust the hierarchy filter to match what `get_cells` on the actual checkpoint
returns — do not guess; run `get_cells -hierarchical -filter {NAME =~
"*sync*"}` interactively first and read the real names.

- [ ] **Step 3: Wire both reports into the build, refusing on CDC criticals only**

Add to `scripts/build.tcl`, after gate 3 (Task 4's merged block), before the
bitstream section:

```tcl
# Gate 4: CDC and methodology. report_cdc looks for crossings the design's own
# clock-domain declarations do not explain; report_methodology is Vivado's
# broader design-quality sweep (unclocked registers it missed, combinational
# feedback outside a proper latch, etc). R19's traceability table already
# promised this at Stage 6.
set cdc_report "$BUILD_DIR/${TOP}_cdc.rpt"
report_cdc -file $cdc_report

set cdc_text [read [open $cdc_report r]]
if {[regexp {Critical\s+:\s+(\d+)} $cdc_text -> cdc_crit] && $cdc_crit > 0} {
    puts "FATAL: report_cdc found $cdc_crit critical CDC issue(s)."
    puts "See $cdc_report."
    puts "Build refused: an unexplained clock-domain crossing is present."
    exit 1
}
puts "==> CDC check: PASS (see $cdc_report)"

set methodology_report "$BUILD_DIR/${TOP}_methodology.rpt"
report_methodology -file $methodology_report
puts "==> Methodology report written: $methodology_report (not gated -- read manually)"
```

`report_cdc`'s exact severity-summary text format needs confirming against
what Step 1 actually printed before trusting the `regexp` above — Vivado's
report format has changed between versions historically. Verify:

```bash
grep -n "Critical\|Warning\|Advisory" build/gem_top_cdc.rpt | head -10
```

and adjust the regex to match the real summary line syntax before wiring the
gate.

`report_methodology` is deliberately **not** gated — it is Vivado's general
design-quality sweep, not a Stage 6 pass/fail criterion this project has
scoped, and gating on it risks refusing builds over findings nobody has
triaged. It is written to `build/` for a human to read.

- [ ] **Step 4: Confirm gate 4 passes clean with the fixes from Step 2**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

Expected: `==> CDC check: PASS`.

- [ ] **Step 5: Prove it refuses**

Temporarily remove the `ASYNC_REG` property line added in Step 2 (or, if none
was needed, temporarily comment out `constrs/clocks.xdc`'s
`set_clock_groups -asynchronous` block, which is what makes the RX FIFO's
crossing look explained) and re-run Step 4's build. Expected: gate 4 refuses.
Revert whichever was changed:

```bash
git checkout -- constrs/clocks.xdc
```

(or the equivalent revert for the `ASYNC_REG` XDC line, whichever was used for
the demonstration).

- [ ] **Step 6: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

```bash
git add scripts/build.tcl
```

Include whichever RTL/XDC fix Step 2 required in the same commit if one was
needed:

```bash
git commit -m "Add a CDC gate, and give the reset synchronisers the property that makes them legible to it"
```

Message must state: what `report_cdc` found before the fix, what fixed it, and
the Step 5 refusal demonstration.

---

## Task 6: Read the first fully-constrained bitstream's reports

**Files:** none (verification only; numbers feed Task 7's documentation).

- [ ] **Step 1: Full bitstream build with every Stage 6 part 2 constraint in place**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

- [ ] **Step 2: Read the four Stage 6 checks, same discipline as Stage 6 part 1 Task 4 Step 8**

```bash
grep -n "WNS\|WHS" vivado.log | tail -10
```

```bash
sed -n '/^1. Slice Logic$/,/^2. Slice Logic Distribution$/p' build/post_route_utilization.rpt
```

```bash
sed -n '/^8. Primitives$/,/^9. Black Boxes$/p' build/post_route_utilization.rpt
```

Record: WNS/WHS post-route (now with real I/O timing constraining the RGMII
paths for the first time — expect it to move from Stage 6 part 1's +1.249 ns,
since those pins were previously unconstrained and therefore free), LUT/FF/
BRAM/MMCM counts (compare against Stage 6 part 1's 976/1422/1/1 and the B.2
row's 1123/1422/1/1 — this is the same divergence flagged then; if it has not
changed, that confirms the I/O constraints did not somehow alter synthesis
results, which they should not).

- [ ] **Step 3: Confirm gate 3 and gate 4 both report PASS in this run**

```bash
grep -n "Constraint coverage check\|CDC check" vivado.log | tail -5
```

- [ ] **Step 4: report_timing on the RGMII paths one more time, now end to end**

```tcl
open_checkpoint build/post_route.dcp
report_timing -from [get_ports {rgmii_rxd[0]}] -max_paths 1 -delay_type min_max
report_timing -to [get_ports {rgmii_txd[0]}] -max_paths 1 -delay_type min_max
```

Record both slack numbers — post-route, these are the real, placed-and-routed
margins, not the post-synthesis estimates Task 1/2 checked. This is the number
V-2's static half closes on.

---

## Task 7: Documentation closeout

**Files:**
- Modify: `spec/PROJECT_SPEC.md`
- Modify: `verification_plan.md`
- Modify: `README.md`
- Modify: `bringup_checklist.md`

- [ ] **Step 1: Spec version bump**

`spec/PROJECT_SPEC.md`'s status line reads `v0.13 — ... Stage 5 complete`. Add
a `v0.14` changelog entry following the existing pattern (see the v0.12→v0.13
entry for the shape): what Stage 6 part 2 added (`constrs/rgmii_timing.xdc`,
the CDC gate), and that the status line should now read `Stage 5 complete,
Stage 6 constraints and gates complete` (not "Stage 6 complete" — implementation
and bring-up, Stage 7 and B.5, are still ahead).

- [ ] **Step 2: `verification_plan.md`**

- **R14** row: change status from `open` to `green (static)`, citing Task 6
  Step 4's post-route slack numbers, and note explicitly that the bench half
  (ILA/scope on `GTX_CLK`/`TXD0`) remains bring-up step 5's job.
- **R20** row: change from `partial` to `green`, citing Task 4's refusing gate
  3 and the post-route WNS/WHS from Task 6.
- **V-2** row: close it — `~~R14's RGMII skew cannot be simulated~~ Closed —
  ...`, following the strikethrough-and-close pattern every other closed V-item
  in the table uses, with the static-timing evidence and the explicit statement
  that the bench half is what remains.

- [ ] **Step 3: `README.md`**

Replace the "**Stage 6 is under way**" paragraph (written at the close of
Stage 6 part 1) with the completed state: gate 0 through gate 4, RGMII I/O
delays written and load-bearing (cite the sign-flip evidence briefly), CDC
gate passing. State plainly what is NOT yet done: Stage 7 (implementation and
timing closure is already exercised by every `make bitstream` run, so this
mostly means the board itself — B.5 bring-up).

- [ ] **Step 4: `bringup_checklist.md`**

The `-2I` device pack box is unaffected by this plan (still open, still
correctly reasoned per Stage 6 part 1). No change expected here unless Task 6
Step 2's numbers reveal something bring-up-relevant — if they do, record it in
the relevant step's "If ... fails" note rather than adding a new box.

- [ ] **Step 5: Verify every quoted command, then full check**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe bitstream
```

- [ ] **Step 6: Commit**

```bash
git add spec/PROJECT_SPEC.md verification_plan.md README.md
```

```bash
git commit -m "Close V-2's static half, and say Stage 6's constraints and gates are done"
```

---

## Self-review

**Spec coverage.** `fpga_project_flow.md` Stage 6 asks for: clock definitions
(done, Stage 6 part 1) · physical pins (done, Stage 6 part 1) · exceptions
(Task 3) · the four synthesis-report checks (Task 6) · `report_methodology`
(Task 5) — all covered. R14 (Task 1/2/7), R19's `report_cdc` promise (Task 5),
R20 (Task 4/7), V-2 (Task 6/7) all have a task.

**Placeholder scan.** No TBD/TODO; every XDC and Tcl block is complete, real
code, not a description of code. Two steps (Task 2 Step 1's instance path, Task
5's regex) are explicitly flagged as needing empirical confirmation rather than
trusted as written — that is not a placeholder, it is the plan being honest
that a hierarchy path and a report's exact text format cannot be known without
running the tool, which is why each of those steps is immediately followed by
a verification step before anything depends on the guess.

**Type/name consistency.** `rgmii_rx_clk_virt` and `rgmii_gtx_clk_gen` are the
only two new clock names introduced; both are used identically in their
`report_timing` calls (Task 1 Step 4, Task 2 Step 4) and nowhere else renamed.
`constrs/rgmii_timing.xdc` is created once (Task 1) and only appended to (Task
2), never recreated.

## Exit criteria

1. `constrs/rgmii_timing.xdc` exists, both RX and TX sections, each verified
   against its own `report_timing` output and a sign-flip check.
2. `make bitstream` (both `gem_top` and `TOP=skeleton_top`) passes gates 0–4.
3. Gate 3 has been shown refusing on a removed constraint; gate 4 has been
   shown refusing on a removed CDC property.
4. `verification_plan.md`'s R14, R20 and V-2 all read closed/green, with
   evidence, not assertion.
5. `make check` is 28 of 28 at every commit in this plan — nothing here touches
   simulation inputs, so any change in that number is a signal something else
   broke.

**Not in scope:** anything requiring the physical board (V-2's bench half,
B.5 bring-up itself). Those stay exactly where `bringup_checklist.md` already
puts them.
