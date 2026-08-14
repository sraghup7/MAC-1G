# The FPGA Project Flow — Stage by Stage

A reference for how an FPGA engineer approaches a project end to end: what
happens at each stage, which tools are used, and which files are produced.

---

## The mental model

Before the stages, three ideas that explain most of the behaviour.

**1. You describe structure, not instructions.**
HDL looks like software and behaves nothing like it. Every line becomes physical
gates and wires that exist simultaneously and operate every clock cycle. A loop
does not iterate over time — it replicates hardware.

**2. There are four debug loops, and they differ in cost by orders of magnitude.**

| Loop | Turnaround | Catches |
|---|---|---|
| Lint | seconds | width mismatches, latches, unconnected signals |
| Simulation | seconds to minutes | functional bugs |
| Synthesis | minutes | inference failures, rough area |
| Implementation | 30 min to hours | timing, congestion, real utilisation |
| Hardware | rebuild per observation, and half-blind | everything you failed to model |

Almost every professional habit — golden models, self-checking testbenches,
assertions, linting, reading reports instead of exit codes — is the same
instinct: **catch each bug in the cheapest loop that can catch it.**

**3. The stages are loops, not steps.**
Timing closure sends you back to RTL. Integration sends you back to
architecture. Each stage exists partly to catch the previous stage's mistakes
while they are still cheap.

---

## Stage 1 — Specification and architecture

**What it is:** deciding *what to build*, before any thought of how to code it.
Almost entirely thinking and arithmetic — a whiteboard and a calculator, no EDA
tools running.

**The four questions, in order:**

1. **What are the requirements?** Not "make it fast" — numbers. Input rate,
   latency budget, precision, interfaces, resource ceiling.
2. **Does this belong in an FPGA at all?** A CPU is easier to program, debug,
   and change. An FPGA earns its place on throughput, latency determinism, tight
   I/O coupling, or power. If none apply, the correct answer is not to use one.
3. **What is the cycle budget?** The single most important calculation:

   ```
   clock frequency ÷ data rate = cycles available per data item
   ```

   This one number picks your architecture. Many cycles per item → build one
   processing unit and reuse it. One cycle per item → fully parallel array.
   Fractional → wider datapath, parallel engines, or a faster clock.
   Beginners skip this and build the parallel version by default, using 40× the
   resources needed to meet a spec they were already meeting.
4. **Where does the hardware/software boundary go?** What runs in the processor,
   what runs in the fabric, what crosses between them and at what rate.

**Numbers a Stage 1 spec pins down:**

- *Rate:* input rate per channel and aggregate, clock frequency, cycles per
  item, datapath utilisation
- *Size:* maximum item size, buffer depths, bit widths and fixed-point format
- *Timing:* worst-case processing time, worst-case queueing delay, total latency
  bound vs deadline, resulting margin
- *Resource:* estimated LUT / FF / BRAM / URAM / DSP against the device's actual
  counts, and which resource is the scarce one
- *Boundary:* the scale at which this architecture stops working

Each number feeds the next: rate → cycles per item → architecture → processing
time → service bound → buffer size → memory count → device fit. Change one input
and the chain re-derives. That is why they are *computed*, not chosen.

**Habits that mark experience:**

- **Derive numbers, don't choose them.** A size from "32 KB feels safe" cannot be
  defended or safely changed. A size from a formula can be re-derived.
- **Compute the worst case, then check the typical case separately.** The gap
  tells you how much of the design is insurance.
- **Write down where the design stops working.** The scale at which this
  architecture becomes the wrong one.
- **State weaknesses explicitly.** An unstated weakness is a weakness twice.
- **Evaluate the alternatives on paper.** Cheap now, expensive later.

**Tools:** whiteboard, Python or a spreadsheet for the arithmetic, vendor
datasheets, a text editor. Vivado opened only to confirm the device has the
resources you are assuming.

**Files:** the **specification document** (the sole real deliverable, versioned
alongside the RTL), a block diagram, a budget spreadsheet or script, a parameter
table with each number's derivation.

**A good spec contains:** requirements · rate and cycle budget · top-level
architecture · parameters with derivations · interfaces · resource budget ·
clocking and reset · verification strategy · bring-up order · scaling envelope ·
alternatives considered · open items.

*Verification strategy and bring-up order are the two beginners omit, and the two
that determine whether the project finishes.*

**Effort:** 15–20%. Feels unproductive because nothing is running. It is where
the resource savings, the timing headroom, and the schedule get decided.

---

## Stage 2 — Environment and build infrastructure

**What it is:** setting up the machinery that will build the project, and proving
it works while the design is still trivial.

**Why it comes before RTL:** the toolchain has ~10 failure modes unrelated to
your logic — wrong part number, missing constraints, IP version drift, licensing,
tool version differences, path handling. Meet them for the first time while also
debugging real logic and you cannot tell which layer is broken. Prove the
toolchain first, and every later failure is your design's fault by elimination.

**Project mode vs non-project mode — the defining decision:**

- *Project mode:* GUI creates a project file, tracks sources, remembers settings.
  Comfortable. But it is machine-specific, records absolute paths, and stores
  tool state you cannot review.
- *Non-project mode:* no project file. A TCL script reads sources into memory,
  runs each stage, writes outputs. **The entire build becomes one reviewable text
  file** that diffs in a pull request and reproduces on any machine.

Professionals use non-project mode. Same principle for block designs: the saved
block-design file is a **binary blob** that does not diff or merge. Build it once
in the GUI, export it as a script, commit the script, regenerate on every build.

**Authored vs generated — the organising rule:**

> If the build can regenerate it, it does not go in version control.

| Committed | Ignored |
|---|---|
| RTL, include files | checkpoints, bitstreams |
| Constraints | reports, logs |
| Build and simulation scripts | the block design file |
| Software source | compiled binaries |
| Golden model, testbenches | waveform databases |
| Specification | the Vivado project file |

**Make the build script enforce things.** The difference between a script and a
build *system* is that a good one gates on what a human is supposed to check and
eventually will not:

- fail on inferred latches
- fail on negative slack (the tool will otherwise write a broken bitstream and
  report success)
- print resource inference counts, so unexpected changes surface at synthesis

**The skeleton build, in two tiers:**

- **Tier A — pure RTL, no processor.** Near-empty top module, minimal
  constraints, run through to bitstream, program the board. Proves the part
  string, tool install, constraint reading, and board connection. Half a day.
- **Tier B — system skeleton.** Processor configured, interface IP instantiated,
  and a **pass-through** where your design will go: data in one side, straight
  out the other. Exercises the whole infrastructure with zero design logic to
  blame — and validates assumptions about vendor IP that Stage 1 could only read
  about in a datasheet.

**Tools:** Vivado in batch mode driven by TCL, Make, Git, Vitis, Hardware
Manager over JTAG.

**Files authored:** build script, parameter/include file (Stage 1's arithmetic
made executable, with compile-time assertions), minimal constraints, skeleton
top, `.gitignore`, Makefile, exported block-design script.

**Effort:** ~5%, two or three days. Feels like procrastination; it is the
opposite.

---

## Stage 3 — Reference model and verification strategy

**What it is:** building the thing that will tell you whether your hardware is
correct, before the hardware exists. Two artifacts: a **golden model** and a
**stimulus generator**.

**Why before the RTL — two reasons:**

1. **You cannot check what you have no reference for.** Without a model,
   verification means staring at a waveform and deciding it looks plausible.
   That is not a test.
2. **Writing the model finds spec bugs.** To implement the reference you must
   resolve every ambiguity the spec left open. You find those questions in an
   afternoon of Python instead of three weeks into RTL.

**What "golden" means:** the model must match the hardware **bit for bit**. Not
approximately. Floating-point in the model where the hardware uses fixed point
makes the comparison useless — every output differs slightly and you cannot tell
rounding noise from a real bug. The model reimplements the hardware's exact
arithmetic: same widths, truncation, rounding, saturation, overflow. Tedious, and
the entire point. **A model that "basically agrees" catches nothing.**

**The generator:** correct input is the easy part. You need the input that breaks
things — malformed data, truncation, boundary values, saturation and overflow
triggers, garbage between valid data, and timing pathology (bursts, gaps, long
backpressure, reset mid-operation).

Generate these **parametrically**, not as hand-written vectors: a function taking
corruption type and location gives thousands of cases from a loop. Two properties
to design in: **reproducibility** (seeded, and failures re-runnable from the seed
alone) and **self-description** (a failure names which corruption at which
offset, not "mismatch at cycle 41,203").

**The checker:** compares design output against model output and reports the
first divergence with enough context to act on. The goal is that the failure
message alone is actionable.

**Assertions:** statements about the design the simulator checks continuously. A
test checks a scenario you constructed; an assertion checks an invariant during
*every* scenario, including ones you never designed. They are also documentation
that cannot go stale. Written as a separate layer, bound to the RTL so the
property language never leaks into synthesisable code.

**Strategy decisions made here** (now, because they change the RTL you write):
what gets tested at which level; directed vs random; what "done" means as a
coverage criterion; which properties get assertions; how the slow full-scale
tests fit. That last one implies the RTL must be **parameterised from day one**
so it can be scaled down for fast iteration.

**Tools:** Python/MATLAB/C++ for the model and generator, SystemVerilog or
Verilator C++ for testbenches, SVA for assertions, XSim / Questa / VCS /
Verilator, GTKWave, Make or CI for regressions.

*Note that most of this stage happens in software languages, not HDL. A
substantial fraction of FPGA work is writing software to test hardware.*

**Files authored:** golden model, stimulus generator, reference vectors,
testbench skeletons, assertion files, regression runner, and the **verification
plan** — a table of test name, what it covers, which requirement it traces to,
and status. It is how you answer "are we done?" with evidence.

**Effort:** 10–15% for this stage; verification *overall* is 40–50%, because
every later stage keeps feeding it.

---

## Stage 4 — RTL design

**What it is:** writing the hardware description. The stage everyone thinks *is*
FPGA engineering, and typically ~10% of the effort.

**The mental shift:** you are not writing instructions that execute; you are
describing structure that exists. Everything that confuses newcomers follows from
this — two blocks cannot assign the same signal because that is a short circuit;
a missing `else` creates a latch because holding a value requires memory.

**What you are building — three things:**

- **Datapath** — where data flows and is transformed. Wide, regular, where the
  resources go.
- **Control** — the state machines deciding what the datapath does each cycle.
  Narrow, irregular, where the bugs live.
- **Interfaces** — almost always a handshake: sender says *valid*, receiver says
  *ready*, transfer happens when both agree. Gives flow control for free, and
  composes without glue.

**The per-module loop, bottom-up, each verified before the next is written:**

1. Define the interface precisely — signals, widths, handshake, latency
2. Write the RTL
3. **Lint it** — seconds, catches latches and width mismatches pre-simulation
4. Write its self-checking testbench
5. Simulate against the golden model
6. **Synthesise this module alone** — check area and rough timing against the
   Stage 1 estimate

*Step 6 is the one beginners skip and seniors never do.* Two minutes tells you
whether your area estimate was right. Discovering a block is 3× your estimate is
manageable now; discovering it after instantiating it thirty-two times is not.

**Habits:**

- **Pipeline for your target frequency from the start.** Deciding pipeline depth
  after timing fails means restructuring verified code and re-verifying it.
- **Write code the tool can recognise.** Synthesis infers dedicated blocks from
  recognised patterns. An unusual multiplier style becomes hundreds of slow LUTs
  instead of one dedicated block. Vendor coding guides are not optional.
- **Reset only what needs resetting.** Control state needs a defined start;
  pipeline registers usually do not. Blanket reset wastes resources and hurts
  timing.
- **Parameterise everything sized.** From the parameter file, never literals.
- **Never cross clock domains casually.** Multi-bit data needs an asynchronous
  FIFO, not per-bit synchronisers. This is the number-one cause of "worked in
  simulation, fails on hardware".

**Synthesisable vs not:** delays, file I/O, unbounded loops, dynamic memory, and
most of the verification language never become a circuit. RTL files and testbench
files are different populations; only RTL goes to the synthesis tool.

**Tools:** editor with an HDL extension, **Verilator `--lint-only`** or a
commercial linter, a simulator, GTKWave, Vivado out-of-context mode for the
per-module synthesis check, the vendor coding style guide.

**Files authored:** RTL (one module per file), the parameter include file now
actually used everywhere, per-module testbenches, assertion files, a coding
standard.

**Effort:** ~10%. The most visible stage and the least of the effort — which is
why judging progress by "how much RTL is written" misleads badly.

---

### Sidebar: what linting is

Static analysis — checking code for suspicious patterns without running it. It
fills the gap between "compiles" and "simulates correctly", where things are
legal but almost certainly wrong.

**What an HDL linter catches:** width mismatches (assigning 12 bits to an 8-bit
signal silently drops 4 — one of the most common real Verilog bugs) · inferred
latches · incomplete sensitivity lists · blocking/non-blocking misuse ·
unconnected or undriven signals · combinational loops · multiple drivers ·
unreachable states.

**Why it earns its place:** it runs in **seconds** on a design that takes minutes
to synthesise and hours to implement. It is the cheapest loop in the flow.

**In practice:** editor integration flags problems as you type; a pre-commit hook
or CI job blocks code that does not lint clean. Most teams enforce **zero
warnings** — a hundred tolerated warnings mean the one that matters is invisible.
Suppress a rule only with a comment explaining why.

**Tools:** Verilator `--lint-only` (free, fast, the default choice) · Icarus ·
Synopsys SpyGlass, Cadence HAL, Siemens Questa Lint (commercial; these add
automated clock-domain-crossing analysis a plain linter cannot do).

---

## Stage 5 — Integration

**What it is:** assembling verified modules into a working system, then
connecting it to the processor. Nothing new is designed — but the connections are
where a surprising share of bugs live.

**Why it is harder than it sounds:** each module passed its testbench because you
tested it against *your* understanding of its interface. The module beside it was
tested against its author's understanding of the same interface. The mismatches
are subtle: one asserts a signal for a cycle, the other expects it held until
acknowledged; one counts a length inclusive, the other exclusive; one deasserts
*ready* when busy, the other assumed *ready* was always high. None break a unit
test. All break the system.

**The discipline: integrate incrementally.** Connect two modules, verify. Add a
third, verify. A failure in a two-module system has a small suspect list; a
failure after connecting nine has a combinatorial one.

Useful pattern — the **vertical slice**: get a single path working end to end
before adding breadth. A working narrow system tells you far more than a broad
one that does not run.

**Interface contracts:** for every internal interface write down the signal list,
widths, handshake, latency, ordering guarantees, reset behaviour, and
backpressure behaviour. Then encode it as **assertions bound to both sides**, so
a protocol violation fails at the exact cycle it occurs rather than as corrupted
output forty thousand cycles later. Standard interfaces pay off here: the
contract is already documented and vendor IP already speaks it.

**The processor boundary — three distinct paths:**

- **Control** — processor reads/writes your registers. Low bandwidth.
- **Data** — bulk movement via DMA, so the processor is not copying by hand.
- **Events** — interrupts, so software need not poll.

The **register map** is a contract shared between two teams and two languages.
Change a layout in RTL without re-exporting the hardware description and the
software addresses registers that moved — silently. Generating both the RTL
register block and the software header from one source file is the standard
defence.

**Block design tools:** useful for stitching vendor IP. Two cautions — the saved
file is a binary blob (export it as a script and version that), and automatic
connection is convenient but opaque (know what clock crossings and width
converters the tool silently inserted into your data path).

**System-level tests that unit testing structurally cannot reach:** end-to-end
against the golden model · concurrency and contention (individually correct
modules can deadlock or starve each other) · backpressure held for a long time ·
reset asserted mid-operation · sustained load long enough for buffers to reach
steady state and slow leaks to appear.

**Tools:** Vivado IP Integrator or hand-written top-level HDL, vendor IP
catalogs, simulators, SVA and vendor protocol-checker IP, TCL, often a custom
register-map generator.

**Files authored:** top-level HDL or block-design script, IP configuration files
(generated but capture decisions, so versioned), interface contract documents,
protocol assertions, system testbenches, register map definition.

**Effort:** 10–15%. Rarely smooth. Where the schedule risk concentrates, because
a genuine interface mismatch sends you back to Stage 4.

---

## Stage 6 — Constraints and synthesis

**What it is:** two things that belong together because one is meaningless
without the other. **Constraints** tell the tool what your HDL cannot express.
**Synthesis** translates HDL into a gate-level netlist of real device primitives.

**Constraints — the missing half of your design.** Your HDL describes what the
circuit does and says nothing about how fast it must run. Three kinds:

- **Clock definitions** — "this input is a clock with a 10 ns period". This one
  line does two jobs: it is the tool's **optimisation target** *and* its
  **pass/fail criterion**.
- **Physical** — which package pin, at what voltage standard and drive strength.
- **Exceptions** — paths that genuinely need not be checked normally, e.g. a
  register written once at startup, or a path between unrelated clocks already
  handled by a synchroniser.

**The failure mode that defines this stage:**

> If you do not declare a clock, the tool does not check it, and reports success.

Not a warning. The report says timing met — because it verified zero paths. The
design then fails on hardware for reasons every report insisted did not exist.
This produces the two classic errors: **under-constraining** (silent, and the
worst outcome) and **over-constraining** (hours spent chasing slack you do not
need, and possibly failing to route a design that would otherwise close).

*Rule: constrain exactly what is real, and never write an exception you cannot
justify out loud.* A false-path declaration is a promise that a path does not
matter; if you are wrong, no report will ever mention it again.

**Synthesis — what actually happens:** the tool **infers** dedicated hardware
from recognised coding patterns, **optimises** (removes unused logic, folds
constants, shares subexpressions, restructures to shorten paths), **maps** the
rest into LUTs and flip-flops, and **estimates** timing without knowing
placement. The optimisation is aggressive, which means **the netlist is not a
direct translation of your code** — logic you wrote may vanish, logic you did not
write may appear.

**Reading the reports — the actual skill.** "Synthesis completed successfully"
tells you almost nothing. Four checks every build:

1. **Inference** — did the dedicated blocks you expected appear, at the expected
   counts? Forty budgeted and three present means thirty-seven multipliers became
   LUT logic.
2. **Latches** — any inferred latch is a bug, no exceptions.
3. **Utilisation vs estimate** — per block, against Stage 1's budget. Wildly
   different means your mental model is wrong.
4. **Things that disappeared** — a module optimised entirely away usually means
   an unconnected output or a constant that propagated.

Encode these as automated build-script checks rather than eyeballing them.

**The relationship between the two:** constraints affect synthesis *before*
implementation starts. The same HDL constrained at 100 MHz and at 300 MHz
produces measurably different netlists. Which is why constraints are written
before the first meaningful synthesis run, not bolted on when timing fails.

**Tools:** Vivado (Quartus, Yosys), a text editor for the TCL-based constraint
language, the tool's **report methodology** command — which specifically audits
for missing clock definitions and unconstrained paths.

**Files authored:** constraint files, often split by purpose (clocks/timing,
physical pins, exceptions) so each is reviewable on its own.
**Generated:** post-synthesis checkpoint, utilisation report, estimated timing
summary, methodology and DRC reports, synthesis log.

**Effort:** ~5% in effort, but it is a gate. Bad constraints do not slow you down
here — they mislead you all the way to hardware.

---

## Stage 7 — Implementation and timing closure

**What it is:** turning the netlist into a physical layout on real silicon, then
proving it runs at the required clock speed. **The stage where projects slip.**

**The physical reality:** a signal leaving a flip-flop travels through LUTs and
along metal wires to the next flip-flop, and that takes time. On modern devices
**most of the delay is wire, not logic** — often 60–80% of a critical path is
routing. Two blocks placed far apart are slow because the wire is long. This is
why implementation can fail on a design synthesis said was fine: synthesis
estimated delay without knowing placement.

**The four sub-steps:** optimisation (netlist cleanup with device knowledge) ·
**placement** (assigning every cell a physical site — the dominant factor in
final timing) · physical optimisation (register duplication, cell relocation) ·
**routing** (choosing actual metal paths; congestion forces detours, and detours
are delay).

**Timing concepts:**

- **Setup** — data must arrive a certain time *before* the clock edge. A
  violation means the path is too slow. Yours to fix architecturally.
- **Hold** — data must stay stable *after* the edge. A violation means a path is
  too *fast* and the new value overwrites data before capture. Usually the tool
  fixes this automatically; a hold violation it cannot fix often indicates an
  unhandled clock domain crossing.
- **Slack** = required time − actual time. Positive made it; negative failed.
- **Worst Negative Slack (WNS)** — the single worst path. The number that decides
  whether you ship.

**Reading a failing path** — the report shows the full journey with delay
attributed. What you are looking for:

| Symptom | Cause | Fix |
|---|---|---|
| Many LUT levels | too much logic in one cycle | pipeline it (back to Stage 4) |
| Routing delay dominant | endpoints physically far apart | placement guidance, or restructure |
| High fan-out | one signal driving thousands of loads | register duplication |
| Detoured routing | congestion | often architectural |
| Path shouldn't be checked | bad or missing constraint | fix the constraint, not the design |

*Read the path, identify the cause, fix the cause.* Beginners re-run with
different strategies hoping for luck. Sometimes it works, which is worse than if
it never did.

**The closure loop, cheapest first:**

1. Fix the constraints — free, if the path should not have been checked
2. Change tool strategy — minutes to hours, no design change
3. Add placement guidance — effective, adds maintenance
4. Restructure the RTL — back to Stage 4, invalidates verification
5. Change the architecture — back to Stage 1

Rough guide: a few hundred picoseconds negative is a tool-settings problem.
Several nanoseconds negative is an architecture problem, and no amount of
re-running fixes it.

**The trap:** the tool will produce a bitstream that misses timing and report
success. It is broken; it just has not failed yet. It may work on your bench and
fail on a colleague's board, or at a different temperature — timing margin is
what protects against process, voltage, and temperature variation.
**Never program a bitstream with negative slack.** The build script should refuse
to write one.

**Tools:** Vivado (Quartus, nextpnr), the built-in static timing analyser, and
the GUI's device view, path visualisation, and congestion heat maps — timing
problems invisible in a text report are often obvious as a picture.

**Files generated:** **post-route checkpoint** (the most important artifact —
reopen it to analyse anything), timing summary, detailed failing-path report,
final utilisation, DRC, power, **the bitstream**, **the hardware handoff file**,
and the debug probes file if on-chip debug is instrumented.

**Effort:** 15–20%, and the most variable. A comfortable design closes on the
first run; a tight one can consume weeks. Which is why Stage 1's cycle budget
matters — a design at 20% datapath utilisation has enormous headroom, and one at
95% will fight for every picosecond.

---

## Stage 8 — Software and hardware bring-up

**What it is:** writing the processor code and getting real hardware working for
the first time. Combined because on a system-on-chip neither can be meaningfully
tested without the other.

**The handoff:** implementation produced a hardware description file carrying the
memory map. The software toolchain reads it and generates address definitions and
driver skeletons. **When the register layout changes, re-export** — otherwise
software addresses registers that moved and reads garbage, silently. Automate the
re-export; it will otherwise be forgotten exactly once, at the worst time.

**Bare metal or Linux:** bare metal means C running directly on the processor —
no OS, physical addresses, deterministic, easy to debug. Linux gives networking,
filesystems, and libraries, but costs virtual memory mapping, driver-mediated
hardware access, non-deterministic timing, and complex boot. Bring up on bare
metal first even for a project destined for Linux.

**What the software does** in a well-partitioned system: configure (write
registers), move data (set up DMA), handle events (interrupts), monitor (status
and error counters). *If your software is copying data word by word in a loop, the
partitioning is wrong.*

**Bring-up — the incremental principle:**

> Change one thing at a time, and always be able to answer
> "what was the last thing that worked?"

1. Board alive — power, JTAG, device recognised
2. Bitstream loads
3. Clocks running at the frequency you think — a wrong clock makes every later
   symptom nonsensical
4. Processor runs — a trivial program prints over serial
5. **Registers respond** — write a value, read it back. Proves the entire address
   path for one line of code
6. Data path, smallest case — one item in, one out, checked
7. Data path, realistic — full rate, sustained
8. Real inputs — actual sensors or interfaces
9. Soak — hours. Watch for counters that never reset, pointers that drift,
   buffers creeping toward full

Steps 1–5 take a day and feel like nothing is happening. They are what makes step
6's failure diagnosable.

**The debugging problem:** on hardware you are nearly blind. In simulation every
signal is visible every cycle; on hardware you see only what you decided in
advance to instrument.

The **on-chip logic analyser** is the primary tool — a logic analyser instantiated
inside your own design, capturing to on-chip memory on a trigger and streaming
out over JTAG. Its limits shape how you use it: it **consumes resources**, it
**affects timing** (a design at marginal slack may stop closing once
instrumented), probes are **chosen at build time** (needing a different signal
means a full rebuild), and capture depth is thousands of cycles, not millions.
*Think carefully about what to probe before rebuilding.*

Two supporting tools: a **register interface** for status and error counters —
often more useful than waveforms, because a good counter set tells you *which*
check failed and *where*, which is a diagnosis rather than a clue. And a **serial
console**, humble and indispensable.

**When simulation and hardware disagree** — the short list, in rough order of
likelihood:

1. Clock domain crossing handled incorrectly (simulation may not model
   metastability at all)
2. Reset not synchronised, not held long enough, or released unevenly
3. Missing or wrong constraints — a path never checked, so its failure never
   appeared in any report
4. Interface protocol violation by a component your testbench modelled
   optimistically
5. Real-world I/O timing differing from your model
6. Initialisation — memories or registers simulation initialised and hardware did
   not

*Almost every item is something simulation could not see.* Knowing this list
turns "it does not work and I do not know why" into a checklist.

**Tools:** Vitis or standard cross-compilers, PetaLinux/Yocto if needed, Vivado
Hardware Manager over JTAG, ILA and VIO, GDB over JTAG, serial console, XSCT for
scripting, and an oscilloscope for signals leaving the chip.

**Files authored:** C source and headers, linker scripts, board init, Linux
config, bring-up scripts, and a **bring-up checklist** — written *before* touching
hardware, listing each step, its expected result, and what to check if it fails.
Bring-up is stressful, and improvisation under stress produces the classic
failure: changing three things at once, something works, and nobody knows which
change did it.

**Effort:** 10–15%, high variance. A well-verified design comes up in days. A
design that skimped on Stages 3 and 5 can spend months here — this is where the
cost of skipping earlier verification gets paid, at the worst exchange rate in the
project.

---

## Stage 9 — Release and handoff

**What it is:** not glamorous, and what separates a design that survives from one
that dies the moment its author leaves.

- **Reproducibility check** — clone the repo fresh, run one command, get a
  bit-identical bitstream. If that fails, the design is captured in your machine's
  state and your memory, not in version control.
- **Tagging** — version the release *and* record the tool version that built it.
  Tool versions change behaviour; a design that closed timing in one may not in
  the next.
- **Documentation for the next person** — how to build, how to run, what the
  registers mean, the interface contract, known limitations.
- **Test collateral handover** — whoever inherits this needs your testbenches and
  golden model, not just the RTL.
- **Known issues and open items** — written down. An undocumented limitation
  becomes a surprise bug later.

**Effort:** ~5%. Its value shows up six months later, when a change either takes a
day or requires reverse-engineering everything.

---

## Effort summary

| | Stage | Effort |
|---|---|---|
| 1 | Specification and architecture | 15–20% |
| 2 | Environment and build infrastructure | 5% |
| 3 | Reference model and verification strategy | 10–15% |
| 4 | RTL design | 10% |
| 5 | Integration | 10–15% |
| 6 | Constraints and synthesis | 5% |
| 7 | Implementation and timing closure | 15–20% |
| 8 | Software and hardware bring-up | 10–15% |
| 9 | Release and handoff | 5% |

---

## Tools by stage

| Stage | Primary tools | Language |
|---|---|---|
| 1 Spec | whiteboard, Python, spreadsheet, datasheets | — |
| 2 Environment | Vivado batch, Make, Git | TCL |
| 3 Verification | Python/MATLAB, Questa/XSim/Verilator | Python, SystemVerilog |
| 4 RTL | editor, Verilator lint, simulator | Verilog / VHDL |
| 5 Integration | IP Integrator, protocol checkers | HDL + TCL |
| 6 Constraints & synth | Vivado synthesis, report methodology | XDC (TCL) |
| 7 Implementation | Vivado impl, static timing analyser | TCL |
| 8 Software & bring-up | Vitis, Hardware Manager, ILA, GDB | C |
| 9 Release | Git, documentation | Markdown |

## Files by category

**Authored (versioned):** `.v` / `.sv` RTL · `.vh` / `.svh` includes · `.xdc`
constraints · `.tcl` build and block-design scripts · `.c` / `.h` software ·
`.py` / `.m` golden model and generators · `.md` specification · `Makefile` ·
`.gitignore`

**Generated (ignored):** `.dcp` checkpoints · `.bit` bitstream · `.xsa` hardware
handoff · `.ltx` debug probes · `.rpt` reports · `.elf` binary · `BOOT.BIN` boot
image · `.wdb` / `.vcd` waveforms · `.log` / `.jou` tool logs · `.bd` block design

**The awkward middle:** `.xci` IP configuration — generated, but captures
decisions, so it is versioned.

---

## Three things worth carrying away

**1. Writing HDL is the smallest technical stage.** Around 10%. Courses and
interviews over-index on it because it is the most teachable part, but the
leverage is in the architecture decisions before it and the verification rigour
around it.

**2. The stages are loops, not steps.** Stage 7 sends you back to 4. Stage 5
sends you back to 1. Each stage exists partly to catch the previous stage's
mistakes — and the cost of a bug rises by roughly an order of magnitude each time
it survives to a later stage.

**3. The whole flow is one long argument for front-loading.** Golden models,
self-checking testbenches, linting, assertions, scripted builds, reading reports
instead of exit codes — every one is the same instinct: catch it in the cheapest
loop that can catch it. **That instinct is the expertise.**
