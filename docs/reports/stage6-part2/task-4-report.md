# Task 4 Report: Turn gate 3's report into a refusal — BLOCKED

## Status: BLOCKED

Step 1 (the `scripts/build.tcl` edit the brief describes) is implemented and is correct
in isolation. But verifying it — the whole point of the task — surfaced a real,
previously-unmeasured timing violation: **gate 2 (WNS/WHS) now refuses the build with a
hold violation, WHS = -1.031 ns**, the first time `constrs/rgmii_timing.xdc` is ever read
by the real build (`read_xdc`) instead of a throwaway `read_xdc`-against-checkpoint
script. Per the task's own "Before You Begin" instruction, I stopped rather than trying
to work around it. `scripts/build.tcl` is left edited but **not committed**, and Steps 2-7
(clean-pass confirmation via `bitstream`, the refusal demo, the skeleton build, `make
check`, the final `make bitstream`, and the commit) were not run, because the design does
not currently pass gate 2 with the real RGMII constraints wired in.

## What was implemented (Step 1)

`scripts/build.tcl`:

1. Added `constrs/rgmii_timing.xdc` to `XDC_SOURCES` for `gem_top`:
   ```tcl
   set XDC_SOURCES [list constrs/clocks.xdc constrs/pins.xdc \
                         constrs/exceptions.xdc constrs/rgmii_timing.xdc]
   ```
2. Merged the two gate-3 `foreach` blocks into one refusing block covering
   `no_clock`, `constant_clock`, `unconstrained_internal_endpoints`, `multiple_clock`,
   `loops`, `latch_loops`, `no_input_delay`, `no_output_delay`, `partial_input_delay`,
   `partial_output_delay` — exactly as the brief's Step 1 specifies. Deleted the old
   reporting-only block and its preceding comment.
3. Also updated the larger "Gate 3: nothing important may be unconstrained" comment
   above (not explicitly named in the brief, but it was left describing stale behavior —
   "the two conditions... refuse" and "When Stage 6 adds the RGMII I/O constraints, this
   becomes a refusal too" — now that Stage 6 *is* this task, I updated it to state
   current reality rather than leave an inaccurate comment next to the code it describes).

The brief's described `foreach` block structure matched what was actually in the file
exactly — no discrepancy there.

Diff (`git diff scripts/build.tcl`): 14 insertions, 27 deletions, net -13 lines (one
`foreach` block removed, ten checks now live in one).

## Discrepancy #1 (non-blocking): `python scripts/build.py synth` cannot reach gate 3

The brief's Step 3 (refusal demo) says to test with `python scripts/build.py synth`.
That command maps to `TARGET=="synth"` in `build.tcl`, which does `return` at line
161-164 — **before** gate 2 (timing) and gate 3 (`check_timing`) ever run. I confirmed
this empirically: running `python scripts/build.py synth` with the real
`rgmii_timing.xdc` unmodified stopped cleanly at "Target 'synth' reached. Stopping."
right after the latch/utilization report, never reaching `check_timing`. Only `impl` and
`bitstream` targets reach gate 2/3 (confirmed against `Makefile`'s target definitions and
Task 3's report, which used `make bitstream` — not `synth` — to inspect
`check_timing.rpt`). I planned to substitute `impl`/`bitstream` for the brief's literal
`synth` command wherever gate 2/3 needed to run, and say so plainly rather than silently
pretend the literal command was exercised — but I never got that far because of finding
#2 below.

## Discrepancy #2 (blocking): gate 2 refuses with a hold violation, not the WNS<0 case anticipated

Ran `python scripts/build.py impl` (gem_top, `rgmii_timing.xdc` wired in, otherwise
unmodified) to reach gate 2/3. Output:

```
==> WNS (setup) = 0.058 ns, WHS (hold) = -1.031 ns
Build refused: negative hold slack (WHS = -1.031 ns).

impl FAILED (exit 1).
```

**WNS is fine** — `+0.058 ns`, matching exactly what the task context said Task 2e's MMCM
restructuring measured for TX setup margin. Task 2e's fix holds. But **WHS is
`-1.031 ns`**, a hold violation gate 2 has never been able to see before, because
`rgmii_timing.xdc` was never read by the real build until this task's Step 1. This is a
"NEW, unexpected timing violation that [no prior task] actually resolved," per the
task's own stop-condition — it just shows up as `WHS < 0` rather than the literally-named
`WNS < 0` case, on the RX side rather than TX, which Task 2e never touched.

### The specific violating path

Opened `build/post_route.dcp` (written by the `impl` run before it exited) and re-ran the
exact query gate 2 itself uses (`get_timing_paths -max_paths 1 -nworst 1 -hold`):

```
Slack (VIOLATED) :        -1.031ns  (arrival time - required time)
  Source:                 rgmii_rxd[1]
                            (input port clocked by rgmii_rx_clk_virt {rise@0.000ns fall@4.000ns period=8.000ns})
  Destination:            u_mac/u_rgmii_rx/g_rxd[1].u_iddr/u_iddr/D
                            (rising edge-triggered cell IDDR clocked by rgmii_rx_clk {rise@0.000ns fall@4.000ns period=8.000ns})
  Path Group:             rgmii_rx_clk
  Path Type:              Hold (Min at Slow Process Corner)
  Requirement:            -4.000ns  (rgmii_rx_clk rise@0.000ns - rgmii_rx_clk_virt fall@4.000ns)
  Data Path Delay:        1.395ns  (logic 1.395ns (100.000%) route 0.000ns (0.000%))
```

This is a **fall-from-virtual → rise-to-real** hold check on `rgmii_rxd[1]`'s capture at
the IDDR. It is not false-pathed.

### Root cause (as far as I traced it, without touching anything)

`constrs/rgmii_timing.xdc`'s header says its structure "follows
`reference/verilog-ethernet/syn/quartus/rgmii_io.sdc`". I read that reference file. Its
RX false-path scheme is:

```tcl
# setup: false-path the non-corresponding edge pairs
set_false_path -rise_from virt -fall_to real -setup
set_false_path -fall_from virt -rise_to real -setup
# hold: false-path the corresponding edge pairs
set_false_path -rise_from virt -rise_to real -hold
set_false_path -fall_from virt -fall_to real -hold
```

`constrs/rgmii_timing.xdc` (RX section, lines 25-28) copies this exactly, pairing setup
with non-corresponding edges and hold with corresponding edges — **and that pairing is
correct only when the real capturing clock is phase-shifted relative to the virtual
clock**. The reference template creates its real clock with `-waveform {2 6}` (a 90°
shift from the virtual clock's `{0 4}`) specifically so that "corresponding" edges land
mid-eye. `constrs/clocks.xdc` creates `rgmii_rx_clk` with **no phase shift**:

```tcl
create_clock -name rgmii_rx_clk -period 8.000 [get_ports rgmii_rx_clk]
```

Both `rgmii_rx_clk_virt` and `rgmii_rx_clk` land on the same `{0, 4}` ns edges. With zero
phase offset between them, the edge pairing that is physically real for hold is not the
same one the reference template (built for a 90°-shifted real clock) assumes — and the
pairing the XDC leaves un-false-pathed for hold (`fall_from virt → rise_to real`) turns
out to be a real, tight, currently-violated relationship rather than a fictitious one:
data launched off the virtual clock's fall edge is captured almost immediately (only an
IBUF delay, ~1.4 ns) by the real clock's very next rise edge, and the clock network's own
route/skew (~5.2 ns to the IDDR's C pin) dwarfs that margin.

I did not attempt to fix this. Getting RGMII RX false-path edge selection wrong in either
direction is exactly the kind of thing that can silently mask a real violation instead of
exempting a fictitious one, and it is `constrs/rgmii_timing.xdc` (Task 1's file) and/or
`constrs/clocks.xdc`'s clock declaration that would need to change, not
`scripts/build.tcl`. That is out of Task 4's scope (wiring an existing, assumed-correct
file into the build) and needs someone to actually work out whether `rgmii_rx_clk` should
be declared with a phase-shifted waveform (matching the reference template's assumption
and whatever internal RX delay the board's PHY is strapped for) or whether the false-path
pairing itself should be swapped for a zero-phase-shift board. I don't have enough context
on the KSZ9031RNX's RX delay strapping on this board to make that call safely.

## What was NOT done (and why)

- Step 2 (brief) / Step 3 (task): "confirm `python scripts/build.py synth` passes clean"
  — not meaningfully testable per Discrepancy #1, and moot per Discrepancy #2: `impl`
  (which does reach gate 2/3) does **not** pass clean.
- Step 3 (brief) / Step 4 (task): refusal demo (comment out one `set_input_delay` line,
  confirm `partial_input_delay` refusal) — not run. The build already refuses at gate 2,
  before gate 3 is reached, so this specific refusal mode could not be demonstrated
  without first fixing or masking the hold violation, which would be a workaround.
- Step 4 (brief) / Step 5 (task): skeleton build (`TOP=skeleton_top`) — not run. Not
  expected to be affected (it uses `constrs/skeleton.xdc`, untouched), but I stopped
  before reaching this step in the brief's sequence rather than cherry-pick verification
  out of order.
- Step 5 (brief) / Step 6 (task): `make check` — **was** run, before discovering the
  timing issue, and passed 28/28 (see below). `make bitstream` for `gem_top` — not run to
  completion in bitstream-writing form (the `impl` run covers the same gates 0-3 and
  refused at gate 2).
- Step 7 (task): commit — not done. `scripts/build.tcl` is left modified but unstaged.

## Test results

### `make check` (run before any timing investigation, no RTL/testbench changes)

```
28 of 28 scenario(s) passed.
```
Full pass: 8 per-module testbenches, 2 harness self-tests, 16 scenarios, 2 loopback
scenarios, all PASS. (Full output captured during the run; not re-run after, since
`scripts/build.tcl` changes cannot affect `model`/`vectors-check`/`lint`/`hosttest`/`regress`.)

### `python scripts/build.py synth` (gem_top, `rgmii_timing.xdc` wired in)

Reached gate 0 (critical warnings: PASS, 0) and gate 1 (latch check: PASS, 0 inferred
latches), then stopped cleanly at `TARGET=="synth"` before gate 2/3 — as expected once
Discrepancy #1 was understood. `read_xdc` output confirms `constrs/rgmii_timing.xdc` is
now actually read:
```
==> Reading constraints: constrs/clocks.xdc constrs/pins.xdc constrs/exceptions.xdc constrs/rgmii_timing.xdc
```

### `python scripts/build.py impl` (gem_top, `rgmii_timing.xdc` wired in, unmodified)

```
==> WNS (setup) = 0.058 ns, WHS (hold) = -1.031 ns
Build refused: negative hold slack (WHS = -1.031 ns).

impl FAILED (exit 1).
```

Gate 2 refuses. Gate 3 (the actual subject of this task) was never reached.

## Files changed

- `scripts/build.tcl` — modified, unstaged. `XDC_SOURCES` for `gem_top` now includes
  `constrs/rgmii_timing.xdc`; the two gate-3 `foreach` blocks are merged into one
  refusing block; the preceding comment block is updated to match.
- No other files touched. `constrs/rgmii_timing.xdc` was never edited (the Step 3/4
  refusal demo, which would have temporarily commented out a line, was never reached).

## Self-review

- The `build.tcl` edit itself is correct against the brief and against what the file
  actually contained — verified by reading the merged block back and by `git diff`.
- I did not commit, since `make check`/`make bitstream` full verification (the stated
  bar for a merge-worthy state, and this task's own Step 6/7) did not pass.
- I did not attempt any fix to `constrs/rgmii_timing.xdc` or `constrs/clocks.xdc`,
  per the task's explicit instruction to stop and report rather than work around a
  real timing violation revealed by wiring the constraints into the real build.
- `docs/` and `stage6_plan.md` remain untracked and untouched — pre-existing, unrelated
  to this task.

## Concerns / what needs to happen next

1. **The RX hold violation is real and needs a timing-literate fix to
   `constrs/rgmii_timing.xdc` (and possibly `constrs/clocks.xdc`'s `rgmii_rx_clk`
   declaration)**, not a `build.tcl` change. Candidates, for whoever picks this up:
   phase-shift `rgmii_rx_clk`'s `create_clock` waveform to match what the reference
   template assumes (if the KSZ9031RNX's RX internal delay is strapped/expected that
   way), or rework the RX false-path edge pairing for a zero-phase-shift relationship.
   Either requires understanding the board's actual RGMII RX delay mode, which is outside
   what I verified.
2. Once that's fixed, Task 4's Step 1 change (already implemented, sitting in the working
   tree) should still be correct as-is — re-run Steps 2-7 from the brief against the
   corrected constraints.
3. **Separately** (does not block anything, but is worth fixing when someone next touches
   `scripts/build.tcl`): the brief's Step 3 refusal-demo command, `python scripts/build.py
   synth`, cannot reach gate 2 or gate 3 given the current `TARGET=="synth"` early return
   at line 161-164. Any future refusal/timing verification for this file should use
   `impl` or `bitstream`, not `synth`.
