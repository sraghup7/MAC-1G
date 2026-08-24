# Stage 6 implementation plan — part 1: preconditions and the build retarget

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development`
> (recommended) or `superpowers:executing-plans` to implement this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make `make synth` / `impl` / `bitstream` build `rtl/gem_top.v` against
`constrs/`, on a part string somebody has justified, from a clone that starts
green — and make the build refuse when a constraint matches nothing.

**Architecture:** three changes that have to land in one order. A gate that
refuses on `CRITICAL WARNING` is written first and observed failing against
today's build; the retarget then makes it pass; the part string is settled
before either, because area and slack measured against the wrong speed file
have to be measured again. Nothing here writes an RGMII I/O delay constraint —
that is Stage 6 part 2, and it depends on all of this working.

**Tech stack:** Vivado 2024.2 non-project mode (Tcl), Python 3 drivers under
`scripts/`, GNU Make from Vivado's `gnuwin` bundle, Git for Windows.

**Spec:** `fpga_project_flow.md` Stage 6 · `spec/PROJECT_SPEC.md` B.2 (R20, R23),
B.6 · `verification_plan.md` V-2, V-14 · `bringup_checklist.md` "Before power".

---

## Global constraints

- **Branch: `charan/dev`.** Never commit to `main`, never push `main` without
  being asked. `CLAUDE.md` is binding on this and on everything below.
- **PowerShell 5.1 is the primary shell.** No `&&` chaining. One command per
  line.
- **Every gate must be proven to fail.** A gate is added only together with the
  planted defect that makes it refuse, and the demonstration is recorded in the
  commit message. This is the repository's existing habit — see the table in
  `README.md` — not a new rule invented here.
- **No constant is written twice.** The part string lives in `scripts/part.tcl`;
  RTL constants live in `rtl/gem_mac_params.vh`.
- **Error messages may not name a file, script or command without confirming it
  exists** (`CLAUDE.md`, "Error messages").
- **Verified means run.** Report what was executed and what it printed. A check
  that could not be run is reported as not run, never assumed.
- `$SCRATCH` below means any scratch directory outside the repository — set it
  once per session, e.g. `export SCRATCH=/c/Users/$USER/AppData/Local/Temp/mac1g`.
  Nothing in this plan writes a throwaway inside the working tree except under
  `build/`, which is gitignored.
- Full check command, used at the end of every task below:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

---

## File structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `.gitattributes` | Modify | Line-ending policy; the catch-all must sit **above** the vector pin |
| `scripts/run_sim.py` | Modify | Vivado locator, both install layouts; error text names only files that exist |
| `scripts/part.tcl` | Modify | The one part string, with the speed-grade argument written down |
| `scripts/build.tcl` | Modify | Builds a **selectable** top; sources and constraints follow that top; gate 0 refuses on critical warnings |
| `constrs/skeleton.xdc` | Create | The Stage 2 blinker's own two-port constraint set |
| `scripts/build.py` | Modify | Usage text and `program` argument follow the top actually built |
| `Makefile` | Modify | `synth`/`impl`/`bitstream`/`program` take `TOP=`; `program` no longer hardcodes a `.bit` path |
| `verification_plan.md` | Modify | V-14's deferred half restated; R20/R24's stale numbers corrected |
| `README.md`, `bringup_checklist.md` | Modify | "What Stage 6 inherits" and the two "Before power" boxes |

---

## Task 1: A fresh clone's vector gate passes

`make vectors-check` fails on any clone made on a machine with
`core.autocrlf=true` — the Git for Windows default. `.gitattributes` pins
`model/vectors/** -text`, but the catch-all `* text=auto` is written *below* it,
and in gitattributes the **last** matching pattern wins. The pin has never been
in effect. `fix/windows-clone-portability` already fixes it and is unmerged.

**Files:**
- Modify: `.gitattributes`
- Modify: `scripts/run_sim.py` (arrives with the merge; one line needs fixing)

**Interfaces:**
- Produces: a clone whose `make check` passes without regenerating vectors.
  Every later task's verification depends on this.

- [ ] **Step 1: Observe the failure before touching anything**

```bash
git check-attr text -- model/vectors/rx_clean_sweep/rx_rgmii.hex
```

Expected: `text: auto` — i.e. the `-text` pin is not applied. Then confirm the
consequence on a throwaway clone:

```bash
git clone -q --no-hardlinks --branch charan/dev . "$SCRATCH/attrtest"
```

```bash
od -c "$SCRATCH/attrtest"/model/vectors/rx_clean_sweep/rx_rgmii.hex | head -3
```

Expected: `\r \n` line endings, while the model emits `\n`. Record both outputs;
they are the evidence this task exists.

- [ ] **Step 2: Merge the branch that fixes it**

```bash
git checkout charan/dev
```

```bash
git merge fix/windows-clone-portability
```

That branch reorders `.gitattributes` so the catch-all comes first, and widens
`run_sim.py`'s Vivado locator to the unified-installer layout
(`<root>/<version>/Vivado/bin`). Both are wanted.

- [ ] **Step 3: Fix the one defect the merge brings in**

`run_sim.py`'s new "could not find vivado" message ends with a line pointing at
`python scripts/setup_env.py`. That file does not exist on either branch.
`CLAUDE.md` forbids exactly this. Delete the line:

```python
    sys.exit(
        f"error: could not find {name}. Put Vivado's bin/ on PATH or set "
        f"VIVADO_BIN to it."
    )
```

- [ ] **Step 4: Verify the attribute now applies**

```bash
git check-attr text -- model/vectors/rx_clean_sweep/rx_rgmii.hex
```

Expected: `text: unspecified` (the `-text` pin wins; `auto` is gone).

- [ ] **Step 5: Verify the clone is green, which is the thing that actually matters**

```bash
rm -rf "$SCRATCH/attrtest"
```

```bash
git clone -q --no-hardlinks --branch charan/dev . "$SCRATCH/attrtest"
```

```bash
od -c "$SCRATCH/attrtest"/model/vectors/rx_clean_sweep/rx_rgmii.hex | head -3
```

Expected: `\n` only, no `\r`. Then run the gate itself in that clone:

```bash
cd "$SCRATCH/attrtest"
D:/Vivado/2024.2/gnuwin/bin/make.exe vectors-check
```

Expected: PASS. If it fails here, stop — nothing further in this plan is
trustworthy, because every later verification runs the same gate.

- [ ] **Step 6: Check the working tree did not get rewritten**

```bash
git status --porcelain
```

Expected: empty. If `model/vectors/` shows as modified, the working-tree copies
were CRLF and are now being normalised; `git checkout -- model/vectors` and
re-run. Then:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: exit 0, 28 of 28.

- [ ] **Step 7: Commit**

```bash
git add .gitattributes scripts/run_sim.py
```

```bash
git commit -m "Stop the vector gate accusing the model on every Windows clone"
```

The message should record the `git check-attr` before-and-after and the clone
test, because the fix is invisible in the diff's effect: the file content barely
changes and the behaviour change is entirely in Git's pattern precedence.

---

## Task 2: A part string somebody has justified

`scripts/part.tcl` targets `xc7a35tifgg484-1L`. The board is
`XC7A35T-2FGG484I`. This Vivado install offers `-1L` as the *only* speed grade
for `xc7a35ti`/`fgg484` — I confirmed this in
`D:/Vivado/2024.2/data/parts/installed_devices.txt`. The commercial `xc7a35t`
does offer `-1 -2 -2L -3`, and reaching for it would be a mistake worth naming
in advance: a commercial `-2` part is **faster** than the board, so timing closed
against it is optimistic, and optimism is the one direction a sign-off must not
lean. `-1L` is *slower* than the board's `-2I`, so the current numbers are
pessimistic — conservative, not wrong.

That reframes this task. It is not "unblock the build"; the build is not
blocked. It is "write down which way the error leans, and re-measure once".

**Files:**
- Modify: `scripts/part.tcl`
- Modify: `verification_plan.md` (R20 and R24 rows)

**Interfaces:**
- Consumes: nothing.
- Produces: `$PART` in `scripts/part.tcl`, sourced by `build.tcl` and
  `synth_module.tcl`. No other file may name a part string.

- [ ] **Step 1: Ask Vivado what it actually has, rather than guessing the string**

Write a throwaway query script — a heredoc into `vivado -source` is not reliable
under the shells this repo runs in, so use a file:

```bash
printf 'puts "PARTS: [lsort [get_parts -filter {DEVICE =~ \"xc7a35t*\" && PACKAGE == \"fgg484\"}]]"\nexit\n' > build/query_parts.tcl
```

```bash
D:/Vivado/2024.2/bin/vivado.bat -mode batch -nolog -nojournal -source build/query_parts.tcl
```

Record the exact `PARTS:` line. Do not write a part string into `part.tcl` that
has not appeared in that output. (`build/` is gitignored, so the throwaway needs
no cleanup commit.)

- [ ] **Step 2: Install the `-2I` device pack, if the user wants it now**

This is a GUI action and needs an AMD login: Vivado → *Help* → *Add Design Tools
or Devices* → Artix-7 full device support. It cannot be scripted from here, and
it is **not a blocker** for the rest of this plan — see the reasoning above. Ask
the user before spending the download; if they decline, go to step 3 and stay on
`-1L`.

After any install, re-run step 1 and use the string it prints.

- [ ] **Step 3: Write down the argument, whichever part is chosen**

Replace the comment block in `scripts/part.tcl` with one that states the
direction of the error rather than only the mismatch:

```tcl
#############################################################################
# The part string, in one place.
#
# The board is an XC7A35T-2FGG484I. This install offers xc7a35ti/fgg484 in
# -1L only (data/parts/installed_devices.txt), so that is what is targeted
# until the -2I device pack is added via Vivado's "Add Design Tools or
# Devices".
#
# The mismatch is deliberate and its direction is the point: -1L is SLOWER
# than the board's -2I, so every slack number measured here is pessimistic.
# Timing that closes on -1L closes on the real part. The opposite substitution
# -- the commercial xc7a35tfgg484-2, which this install does have -- would be
# faster than the board and would let a design that cannot make 125 MHz sign
# off as though it could. Speed grade may be wrong in the safe direction only.
#
# It lives in its own file because it was written twice: build.tcl called
# itself the single point of truth for it while synth_module.tcl carried a
# second copy. The same rule the RTL follows for sized constants
# (rtl/gem_mac_params.vh) applies to the build scripts.
#############################################################################

set PART "xc7a35tifgg484-1L"
```

- [ ] **Step 4: Re-baseline, and fix the numbers that are already stale**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe oocsynth
```

Record `LUTs`, `FFs`, `BRAMs` and `WNS` from the script's summary. Then correct
`verification_plan.md`, which currently disagrees with itself — the R20 and R24
rows carry `+2.135 ns` and "23 of 23 runs", while line 242 of the same file has
the post-V-18 figures. The true values as of this plan are **+2.262 ns** and
**28 of 28**; if step 4's run prints something different, use what it printed.

In the R20 row, replace `WNS +2.135 ns post-synthesis` with the measured value.
In the R24 row, replace `23 of 23 runs pass; WNS +2.135 ns out of context` with
the measured count and value.

- [ ] **Step 5: Verify nothing else moved**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: exit 0, 28 of 28.

- [ ] **Step 6: Commit**

```bash
git add scripts/part.tcl verification_plan.md
```

```bash
git commit -m "Say which way the speed-grade error leans, and re-measure once"
```

---

## Task 3: Refuse the build when a constraint matches nothing

Write this gate **before** the retarget, and watch it fail against today's
build. That ordering is the whole value: the gate has to be seen catching a real
defect that is present right now, not a planted one.

Today `make synth` emits **68 `CRITICAL WARNING`s and exits 0**. Sixty of them
are `[Common 17-55] 'set_property' expects at least one object`; two are
`create_clock ... No valid object(s) found for '-objects [get_ports
rgmii_rx_clk]'`. `constrs/` describes `gem_top` and `build.tcl` builds
`skeleton_top`, so nearly every constraint in the repository matches nothing —
and gates 1, 1b and 2 pass exactly as they would on a correct build. This is the
Stage 6 failure the flow doc opens by naming: *if you do not declare a clock, the
tool does not check it, and reports success.*

**Files:**
- Modify: `scripts/build.tcl` (new gate 0, before gate 1)

**Interfaces:**
- Consumes: `$BUILD_DIR` from the config block.
- Produces: a build that exits 1 whenever synthesis or constraint reading
  raised a critical warning. Task 4 relies on this to prove the retarget worked.

- [ ] **Step 1: Add gate 0, immediately after `synth_design`**

Insert into `scripts/build.tcl` between `write_checkpoint -force
"$BUILD_DIR/post_synth.dcp"` and the `# Gate 1:` comment:

```tcl
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
```

- [ ] **Step 2: Run it against the current build and watch it refuse**

```bash
python scripts/build.py synth
```

Expected: `FATAL: 68 CRITICAL WARNING(s) during read and synthesis.` and a
non-zero exit. Record the count — it is the before-number for Task 4.

If it prints PASS, the gate is not working: `get_msg_config -severity` may be
counting only messages since the last `reset_msg_count`. Check by adding
`reset_msg_count` before `read_verilog` and re-running.

- [ ] **Step 3: Commit the gate, red**

```bash
git add scripts/build.tcl
```

```bash
git commit -m "Refuse a build whose constraints matched nothing"
```

Commit it failing, and say so in the message. The next task is what makes it
pass, and the two commits together are the record that the gate caught something
real rather than being written to fit a build that already worked.

---

## Task 4: Build `gem_top`, and keep the blinker buildable

**Files:**
- Modify: `scripts/build.tcl` (config block)
- Create: `constrs/skeleton.xdc`

**Interfaces:**
- Consumes: `$PART` from `scripts/part.tcl`; gate 0 from Task 3.
- Produces: `build/gem_top.dcp`, `build/gem_top.bit`, and the tclarg contract
  `vivado -source scripts/build.tcl -tclargs <target> [<top>]` that Task 5's
  `build.py` and the Makefile depend on. Valid tops: `gem_top` (default),
  `skeleton_top`.

**One decision worth stating.** Constraints have to follow the top, because
reading `gem_top`'s pin file against a two-port blinker is what produced the 68
critical warnings. That means the blinker needs a constraint file of its own,
which restates `clk50` and the four LED pins — a duplication, in a repository
whose second organising principle is that no constant is written twice. It is
accepted here, and the alternative was considered and rejected: deleting the
skeleton target would remove the bitstream B.5 step 1 depends on, and a bring-up
step whose artefact cannot be rebuilt is worse than five duplicated pin numbers.
The new file says this, and names `constrs/pins.xdc` as the copy to keep it in
step with.

- [ ] **Step 1: Create the skeleton's own constraints**

Create `constrs/skeleton.xdc`:

```tcl
# Constraints for rtl/skeleton_top.v only -- the Stage 2 blinker, which B.5
# step 1 loads to prove power, JTAG and a clock reaching the fabric before any
# of the real design is trusted.
#
# It has its own file because constraints follow the top. Reading the board's
# full pin set against a module with two ports leaves every get_ports empty,
# and Vivado's response is a CRITICAL WARNING per line and a clean exit 0 --
# which is how this repository spent Stage 5 with a build that constrained
# nothing and said it had succeeded. Gate 0 in scripts/build.tcl now refuses
# that, so the skeleton needs constraints that match the skeleton.
#
# The five pin numbers below are duplicated from constrs/pins.xdc, which is
# the copy to change first if a board revision moves them. That is a knowing
# exception to "no constant is written twice": the alternative was dropping
# the skeleton build entirely, and a bring-up step whose bitstream cannot be
# rebuilt is a worse trade than five repeated numbers.

# 50 MHz Sitime active oscillator -- bank 14, 3.3V, MRCC-capable.
create_clock -name clk50 -period 20.000 [get_ports clk50]
set_property PACKAGE_PIN Y18      [get_ports clk50]
set_property IOSTANDARD  LVCMOS33 [get_ports clk50]

# User LEDs LED1-LED4 -- bank 16, active low. Deliberately unconstrained for
# timing and said out loud, exactly as constrs/exceptions.xdc says it for the
# real design: these drive human eyes at ~0.4 Hz and there is no external
# device sampling them.
set_property PACKAGE_PIN F19      [get_ports {led[0]}]
set_property PACKAGE_PIN E21      [get_ports {led[1]}]
set_property PACKAGE_PIN D20      [get_ports {led[2]}]
set_property PACKAGE_PIN C20      [get_ports {led[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]
```

- [ ] **Step 2: Make the top selectable in `build.tcl`**

Replace the config block — from `set TOP         skeleton_top` through
`if {[llength $argv] > 0} { set TARGET [lindex $argv 0] }` — with:

```tcl
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
                              constrs/exceptions.xdc]
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
```

Note there is deliberately **no** `GEM_BEHAVIORAL_IO` define: synthesis must get
the real Xilinx `ODDR`/`IDDR` primitives. `scripts/synth_module.tcl` makes the
same choice and says why.

- [ ] **Step 3: Update the file header, which still describes the skeleton**

`build.tcl` line 2 reads `Non-project-mode build script - gem_mac Stage-2
skeleton (skeleton_top).` Replace with:

```tcl
# Non-project-mode build script. Builds rtl/gem_top.v -- the board -- by
# default, or rtl/skeleton_top.v for B.5 step 1.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/build.tcl -tclargs <target> [<top>]
#   target: synth | impl | bitstream   (default: bitstream)
#   top:    gem_top | skeleton_top     (default: gem_top)
```

- [ ] **Step 4: Run synthesis and watch gate 0 turn green**

```bash
python scripts/build.py synth
```

Expected: `==> Critical-warning check: PASS (0 critical warnings)`, then
`==> Latch check: PASS`, then a utilisation report for `gem_top`.

If gate 0 still refuses, read the count and the log — a nonzero count here is a
genuine constraint that matches nothing in `gem_top`, and it should be fixed in
`constrs/`, never by relaxing the gate.

If elaboration fails on `` `include "gem_mac_params.vh" ``, add
`-include_dirs rtl` to the `synth_design` call. (`synth_module.tcl` resolves it
without, so this is a contingency, not an expected step.)

- [ ] **Step 5: Check the blinker still builds**

```bash
python scripts/build.py synth skeleton_top
```

Expected: gate 0 PASS, gate 1 PASS, a two-port utilisation report. This is the
step that proves `constrs/skeleton.xdc` matches its top.

- [ ] **Step 6: Prove gate 0 refuses on a planted defect too**

The gate has already caught a real defect, but the repository's standard is that
every gate is demonstrated against a deliberate one. Temporarily rename a port
in `constrs/pins.xdc` — `rgmii_txd` to `rgmii_txdd` on one line — then:

```bash
python scripts/build.py synth
```

Expected: refusal, with a count of at least 1. Restore the file:

```bash
git checkout -- constrs/pins.xdc
```

- [ ] **Step 7: Run implementation and the bitstream end to end**

```bash
python scripts/build.py bitstream
```

Expected: gates 0, 1, 1b, 2 and 3 all run. **Gate 3 will report unconstrained
I/O ports** — every RGMII pin, because no `set_input_delay`/`set_output_delay`
exists yet. That is correct and expected: it reports rather than refuses today,
and turning it into a refusal is Stage 6 part 2, step 6.3, once the delays are
written. Record the port list it prints; it is the input to that step.

- [ ] **Step 8: Read the reports rather than glancing at them**

The four Stage 6 checks, against `build/post_synth_utilization.rpt`:

1. **Inference** — expect 1 MMCM, 1 BRAM18 (the echo buffer), and the IOB DDR
   cells: 4 ODDR for `rgmii_txd`, 1 for `rgmii_tx_ctl`, 1 for `rgmii_gtx_clk`,
   and 5 IDDR on the receive side.
2. **Latches** — 0. Gates 1 and 1b already refuse otherwise.
3. **Utilisation vs B.2** — against the whole-board row: 1123 LUT, 1422 FF,
   1 BRAM18, 1 MMCM. Any large divergence means the Stage 5 numbers were
   measured under different conditions and B.2's measured column needs
   replacing, not explaining away.
4. **What disappeared** — if a module is absent, suspect an unconnected output
   or a constant that propagated.

Write the four answers into the commit message.

- [ ] **Step 9: Full check, then commit**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

Expected: exit 0, 28 of 28. (Nothing here touches RTL, so a change in this
number means something is badly wrong.)

```bash
git add scripts/build.tcl constrs/skeleton.xdc
```

```bash
git commit -m "Point the build at the board, and give the blinker its own pins"
```

---

## Task 5: `make program` stops naming a file that may not exist

`Makefile`'s `program` target and `scripts/build.py`'s usage text both hardcode
`build/skeleton_top.bit`. After Task 4 the default build produces
`build/gem_top.bit`, so the documented command points at a file that will not be
there — the failure mode `CLAUDE.md`'s "Error messages" section exists to
prevent.

**Files:**
- Modify: `Makefile` (`synth`, `impl`, `bitstream`, `program`)
- Modify: `scripts/build.py` (docstring, and a `program` pre-check)

**Interfaces:**
- Consumes: the `<target> [<top>]` tclarg contract from Task 4.
- Produces: `make synth|impl|bitstream|program TOP=<top>`, default `gem_top`.

- [ ] **Step 1: Add a `TOP` variable to the Makefile build targets**

Replace the Stage 2 build block:

```make
# ---- Stage 2/6: build ------------------------------------------------------

# Which top the build targets. gem_top is the board; skeleton_top is the Stage
# 2 blinker B.5 step 1 loads. Constraints follow the top -- see
# constrs/skeleton.xdc.
TOP ?= gem_top

synth:
	$(PYTHON) scripts/build.py synth $(TOP)

impl:
	$(PYTHON) scripts/build.py impl $(TOP)

bitstream:
	$(PYTHON) scripts/build.py bitstream $(TOP)

program: bitstream
	$(PYTHON) scripts/build.py program $(BUILD_DIR)/$(TOP).bit
```

And in `HELP_TEXT`, replace the `make synth impl bitstream program` line with:

```
Build (Stage 2 / Stage 6):
  make synth impl bitstream program      the board (gem_top)
  make bitstream TOP=skeleton_top        the Stage 2 blinker, for B.5 step 1
```

- [ ] **Step 2: Pass the top through `build.py`**

`TARGETS` maps `synth`/`impl`/`bitstream` to `build.tcl` and currently sends
only the target name as a tclarg. Change the argument assembly:

```python
    target = sys.argv[1]
    script = TARGETS[target]
    if target in ("program", "oocsynth"):
        tclargs = sys.argv[2:]
    else:
        # <target> [<top>] -- build.tcl defaults the top to gem_top.
        tclargs = [target, *sys.argv[2:]]
```

- [ ] **Step 3: Make `program` refuse a bitstream that is not there**

Add, before the `vivado = vivado_bin("vivado")` line:

```python
    # CLAUDE.md: do not point the reader at a file without confirming it
    # exists. `make program` used to hand program.tcl a hardcoded
    # build/skeleton_top.bit; after Stage 6 the default build writes
    # build/gem_top.bit, and the JTAG failure that follows a missing file is a
    # long way from its cause.
    if target == "program":
        if not tclargs:
            sys.exit("usage: build.py program <path/to/bitstream.bit>")
        bit = Path(tclargs[0])
        if not bit.is_absolute():
            bit = REPO / bit
        if not bit.exists():
            available = sorted(p.name for p in (REPO / "build").glob("*.bit"))
            found = ", ".join(available) if available else "none"
            sys.exit(
                f"error: {tclargs[0]} does not exist.\n"
                f"  bitstreams in build/: {found}\n"
                f"  build one with: make bitstream TOP=<top>"
            )
```

- [ ] **Step 4: Update the module docstring**

In `scripts/build.py`, replace the usage lines:

```python
Usage:
    python scripts/build.py synth              # gem_top, the board
    python scripts/build.py bitstream skeleton_top
    python scripts/build.py program build/gem_top.bit
    python scripts/build.py oocsynth            # whole MAC, out of context
    python scripts/build.py oocsynth gem_crc32  # one module
```

- [ ] **Step 5: Prove the new refusal fires**

```bash
python scripts/build.py program build/nonexistent.bit
```

Expected: the error above, listing the `.bit` files that do exist, and a
non-zero exit. No Vivado launch.

- [ ] **Step 6: Prove the Makefile plumbing works both ways**

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe synth
```

Expected: builds `gem_top`.

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe synth TOP=skeleton_top
```

Expected: builds `skeleton_top`.

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe help
```

Expected: the new two-line build section, with no literal quote characters
(`$(info)` is used precisely because `@echo` prints them under cmd.exe — V-10).

- [ ] **Step 7: Commit**

```bash
git add Makefile scripts/build.py
```

```bash
git commit -m "Let the build targets name the top, and refuse a bitstream that is not there"
```

---

## Task 6: Say what changed, where the project says things

**Files:**
- Modify: `README.md`
- Modify: `bringup_checklist.md`
- Modify: `verification_plan.md` (V-14 row)

- [ ] **Step 1: `README.md`**

Replace the paragraph beginning *"What Stage 6 inherits: the build flow still
targets the Stage 2 blinker"* — that sentence is no longer true. Write what is
now true: the build targets `gem_top` against `constrs/`, a gate refuses on
critical warnings, and what remains for Stage 6 is the RGMII I/O delay
constraints (V-2) and the refusal on unconstrained I/O they enable.

Also update the `make synth / impl / bitstream` bullet under "Running less than
everything", which still says "the Stage 2 build and its three gates" — it is
five gates now (0, 1, 1b, 2, 3), on the real design.

- [ ] **Step 2: `bringup_checklist.md`**

Two boxes under "Before power" are now answerable:

- *"Point the build at the board"* — done; delete the box and say `make
  bitstream` builds `gem_top`, `make bitstream TOP=skeleton_top` the blinker.
- *"Add the -2I device pack"* — keep the box, but replace the body with Task 2's
  argument: the direction of the error, not merely the mismatch. Whoever reads
  this at a bench should learn that `-1L` is the safe way to be wrong.

Step 1's instruction "Load the Stage 2 blinker (`make bitstream && make program`
as it stands today)" needs both the new command and PowerShell-safe formatting —
`&&` is not a statement separator in PowerShell 5.1 (`CLAUDE.md`).

- [ ] **Step 3: `verification_plan.md`, V-14's plan column**

It reads `I/O-delay refusal deferred to Stage 6`. That is still true, but the
adjacent half is now done. Extend it to say that gate 0 refuses on critical
warnings as of this change, that the refusal on unconstrained I/O still waits on
the delay constraints, and that the defect gate 0 was written against was the
one this repository actually had — 68 critical warnings on a build that exited 0.

- [ ] **Step 4: Verify the documentation does not lie**

For each command quoted in the three files above, run it. This is the same
discipline that closed V-10 and V-13, and both of those found targets that had
never once executed.

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe help
```

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

- [ ] **Step 5: Commit**

```bash
git add README.md bringup_checklist.md verification_plan.md
```

```bash
git commit -m "Make the documentation agree with a build that targets the board"
```

---

## Exit criteria for 6.0 and 6.1

All five must be demonstrated, with the output recorded:

1. A fresh clone on a `core.autocrlf=true` machine passes `make vectors-check`.
2. `make check` exits 0 at 28 of 28.
3. `make bitstream` produces `build/gem_top.bit` with gates 0, 1, 1b, 2 and 3
   all reporting PASS, and gate 3 listing the RGMII ports that still lack I/O
   delays.
   *(Superseded by Stage 6 part 2: gate 3 now REFUSES on unconstrained I/O
   rather than listing it — the RGMII delays exist and the refusal is the
   point — and gate 2 passes with the five RX input-delay endpoints waived
   under the fenced task-4e derivation. See `docs/reports/stage6-part2/`.)*
4. `make bitstream TOP=skeleton_top` still produces the B.5 step 1 blinker.
5. Gate 0 has been shown refusing, both against the defect that motivated it and
   against a planted one.
   *(First half evidenced at commit time — the 68 real criticals; the planted-
   defect half was demonstrated later: a renamed port in `constrs/pins.xdc`
   refuses. Gates 1c, 2's waiver fences and gate 4 have since been demonstrated
   refusing in their own commits.)*

**Not in scope, and deliberately:** any `set_input_delay` or `set_output_delay`,
the `create_generated_clock` on `rgmii_gtx_clk`, `report_cdc`,
`report_methodology`, and turning gate 3's I/O reporting into a refusal. Those
are Stage 6 part 2 (steps 6.2–6.4), and each depends on this build existing
first.

**Do not merge to `main`.** Everything above lands on `charan/dev`. `main` moves
only when the user says so, after the checks have been run and reported.
