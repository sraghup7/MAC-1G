# `gem_mac` — Verification Plan

Document status: v1.4 — Stage 4 complete, **Stage 5 complete**: the clock/reset block,
R17's UART readout, the echo path, the board top level and the host tooling are all
built and tested, and V-20 and V-21 are closed. Versioned alongside the RTL.

This is how "are we done?" gets answered with evidence instead of opinion. Every
requirement in [`spec/PROJECT_SPEC.md`](spec/PROJECT_SPEC.md) B.2 appears below
with the named test that covers it and that test's current status. A requirement
with no test name is not a requirement that is passing — it is a requirement
nobody is checking.

**Status key:** `green` passing · `pending-rtl` test exists and runs, fails only
because there is no design yet · `open` no test yet, with a stated plan · `n/a`
out of scope for v1.

---

## How to run it

```bash
python scripts/run_sim.py
```

| Command | What it does | Gate |
|---|---|---|
| `make model` | the golden model's own test suite (70 tests) | must be green before any simulation result means anything |
| `make vectors` | regenerates every scenario from its seed | fails if the generator and the model disagree |
| `make vectors-check` | do the **committed** vectors still match the model? | fails if an edited model left them a fossil |
| `make sim S=<scenario>` | one scenario | — |
| `make regress` | per-module tests, harness self-tests, every frozen scenario, loopback | **the gate**: nonzero exit on any mismatch or assertion failure |
| `make regress-all` | plus the large random sweeps | — |
| `make lint` | Verilator `--lint-only -Wall --timing` on every design top — `gem_mac`, `skeleton_top`, `gem_clk_rst`, `gem_stat_report`, `gem_uart_tx` (R22) | **the gate**: nonzero exit on any warning; a missing Verilator is an error, not a skip. `--timing` disables no warning class: it tells Verilator how to read the delays `gem_mmcm`'s clock model cannot avoid, which it otherwise refuses to parse at all |
| `make hosttest` | the host tooling's own tests (`sw/host`), no board and no dependencies | **the gate** on the record format, which is a contract between `rtl/gem_stat_report.v` and `sw/host/gem_records.py` that nothing else in this build reads both halves of |
| `make check` | model, vectors-check, lint, hosttest, regress | the whole thing, in the order that makes a failure diagnosable |

Stage 2's build carries three more gates, inside `scripts/build.tcl`:

| Command | What it does | Gate |
|---|---|---|
| `make synth` | non-project synthesis | **gate 1**: any surviving inferred latch refuses the build · **gate 1b**: so does a `Synth 8-327` inference warning, which catches a latch optimised away before gate 1 could see it |
| `make oocsynth` | the whole MAC synthesised alone (Stage 4 step 6) | the latch gates, plus **gate 4**: a memory that dissolved into flip-flops (`Synth 8-4767`), plus area against B.2's budget and 125 MHz before placement |
| `make oocsynth` | `gem_mac` alone, out of context (Stage 4 step 6) | **gates**: both latch gates, negative post-synthesis slack at 125 MHz, and any B.2 resource line exceeded |
| `make impl` | place and route | **gate 2**: WNS or WHS below zero refuses · **gate 3**: `check_timing` refuses on unclocked registers, unconstrained internal endpoints, multiple clocks or loops |
| `make bitstream` | writes `build/skeleton_top.bit` | inherits every gate above |
| `make program` | loads the board | Stage 7; needs hardware |

All eight gates have been made to fail on purpose. See V-4, V-13, V-14 and V-18
for what each canary was and what it caught.

> `make` is not on PATH by default on Windows, but Vivado bundles GNU Make at
> `<Vivado>/gnuwin/bin/make.exe` — use that, or run the underlying commands
> directly (`python scripts/run_sim.py`, `python scripts/lint.py`,
> `matlab -batch "addpath('model'); runModelTests();"`). Every target has been
> executed from both Git Bash and PowerShell; the recipes deliberately avoid
> `echo` and `rm`, neither of which behaves portably in the shell make gets
> under Windows.

Layers, cheapest first, which is the same principle as the flow doc's four
debug loops:

1. **Model tests** (`model/tests/`, ~2 s) — is the reference itself right?
2. **Generator self-check** (inside `gem.genScenario`) — does the generator's
   stated intent match what the golden model reads back off the wire? The two
   are derived independently, so agreement is evidence rather than tautology.
   Runs on every frame whose class is predictable, including in scenarios that
   mix in `badsfd`: 525 of 600 frames in `random_rx_sweep`, 6 of 12 in
   `rx_bad_sfd`. Only `badsfd` frames are skipped, and the skip is counted
   separately from the checks so the report cannot overstate its coverage.
3. **Vector staleness** (`scripts/check_vectors.py`) — do the committed vectors
   still reflect the current model?
3a. **Host record parsing** (`sw/host/test_gem_records.py`, ~1 ms) — can the PC
   side still read what the design prints? Two of its fixtures are lines copied
   out of `tb_gem_stat_report` and `tb_gem_top`'s logs, so a change to the RTL's
   format fails here rather than at a bench four hours into a soak.
4. **Per-module testbenches** (`tb_gem_crc32`, `tb_gem_rx_fifo`, `tb_gem_mdio`,
   `tb_gem_clk_rst`, `tb_gem_uart_tx`, `tb_gem_stat_report`, `tb_gem_echo`,
   `tb_gem_top`) — Stage 4 step 4, each module checked before it is
   judged through everything else. `tb_gem_crc32` is the only layer whose
   reference does not come from this project: the published CRC-32 check value
   and the residue constant are properties of the standard, so a golden model
   that was wrong about the CRC could not hide behind an RTL that was wrong the
   same way. `tb_gem_rx_fifo` runs the async FIFO full, empty and against two
   unrelated clock rates — none of which the scenarios reach, because R18's
   contract keeps it nearly empty. `tb_gem_mdio` is V-3's PHY register-file BFM.
   `tb_gem_clk_rst` is Stage 5's, and it is here for a different reason than the
   other three: the clock/reset block has no data path, so there is nothing for
   the scenario regression to compare and no golden model to compare it against.
   If its four properties are not checked here they are not checked anywhere. The same
   is true of `tb_gem_uart_tx` and `tb_gem_stat_report`, R17's readout: nothing
   downstream of a serial pin exists in this project to notice that the wrong
   characters left it. `tb_gem_top` is the odd one out and the most important:
   it is not a unit test at all but the integration test Stage 5 exists to
   produce, driving the design only at the pins an ALINX AX7035B drives and
   reading only what a PC could read.
5. **Harness self-tests** (`tb_rgmii_bfm`, `tb_axis_tx_driver`) — are the bus
   functional model and the stimulus driver themselves right? Neither has a DUT
   in it, so they are the first thing to check when something downstream looks
   impossible. Both exist because the harness had real bugs that presented as
   design bugs.
6. **Bound assertions** (`tb/assertions/`) — invariants checked on every cycle
   of every scenario, including ones nobody designed. All three files are live as of
   Stage 4: `gem_axis_sva` (bound twice, to both ports), `gem_rgmii_sva`, and
   `gem_internal_sva`, whose properties were written in Stage 3 against modules
   that did not exist and were bound unchanged when they did. An SVA failure fails the scenario even when every data
   comparison passed, which `scripts/run_sim.py` enforces because a bound
   assertion's `$error` does not route through the testbench's failure count.

   **Vacuity is measured, not assumed.** Each `gem_axis_sva` bind reports at
   the end of every run how many beats and how many stalled beats it saw, so a
   property that never had an antecedent to evaluate says so instead of
   counting as coverage. A typical Stage 4 run now reports thousands of beats on
   both ports and zero stalled beats on `rx_axis` — the four stall properties
   there remain vacuous, which is R18's no-stall contract working as specified
   rather than a gap to fix by inventing stalls.
7. **Scenario regression** (`scripts/run_sim.py`) — the design against the
   model, bit for bit.
8. **Loopback** (`tb_gem_mac_loopback`) — the design against itself, which is
   the only layer where a TX and RX error that cancel each other out cannot
   hide.
8a. **Reset mid-operation** (`tb_gem_top`) — the one system-level case the flow
   doc names that nothing else here reaches. Every other testbench asserts reset
   at time zero and releases it; this one asserts it while both domains are busy.
9. **Build gates** (`scripts/build.tcl`, `scripts/synth_module.tcl`) — the checks a simulation cannot make:
   inferred latches, slack, and whether timing analysis actually covered the
   design rather than passing because nothing was constrained.

---

## Traceability — transmit

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R1 | Ethernet II encapsulation, preamble→FCS | `tFrame/fieldOrderAndLengths`, `tFrame/etherTypeIsBigEndian`, `tx_clean_sweep`, `gem_rgmii_sva/a_frame_starts_with_preamble` | model + sim + assertion | **green** |
| R2 | DA/SA/EtherType per frame, not compile-time | `tx_clean_sweep` (header on `tx_axis_tuser` at SOF) | sim | **green** |
| R3 | Pad payloads < 46 B to a 64 B frame | `tFrame/paddingReachesMinimumFrame`, `tFrame/padIsZeros`, `tx_padding` | model + sim | **green** |
| R4 | CRC-32, reflected, LSB-octet first | `tCrc32/*`, `tFrame/fcsIsLeastSignificantOctetFirst`, `tb_gem_crc32` (published check value + residue, against numbers from outside this project), `tx_clean_sweep` | model + unit + sim | **green** |
| R5 | IFG ≥ 96 bit times | `gem_rgmii_sva/a_ifg_respected`, plus a per-frame `gap >= GEM_IFG_BYTES` check in `tb_gem_mac_tx` — a **floor**, not an equality, per B.4c | assertion + sim | **green** |
| R6 | Reject payload > 1500 B, never emit oversize | `tFrame/oversizePayloadIsRejected`, `tx_reject_oversize` | model + sim | **green** — R6 reworded in Stage 4, see **V-16** and spec B.4d |
| R7 | Sustain back-to-back frames at line rate; abort on underrun (B.4b) | `tx_backpressure`, `tx_underrun` (stall mid-payload → TX_ER + inverted FCS, then clean recovery), `tAbort` ×10, `random_tx_sweep` (600 frames) | model + sim | **green** |

## Traceability — receive

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R8 | Detect SFD anywhere; tolerate absent preamble | `tDeframe/findsSfdWithNoPreambleAtAll`, `tDeframe/findsSfdAfterFullPreamble`, `rx_trimmed_preamble`, `rx_min_gap` | model + sim | **green** |
| R9 | Verify FCS, deliver with an EOF verdict | `tCrc32/residueIsConstant`, `tCrc32/residueRejectsCorruption`, `tb_gem_crc32` (residue and its rejection of a single flipped bit), `rx_clean_sweep`, `rx_bad_fcs` | model + unit + sim | **green** |
| R10 | Classify + count + recover from 4 error classes | `tFrame/classifies*`, `tFrame/classPrecedenceIsRuntOverBadFcs`, `rx_bad_fcs`, `rx_runt`, `rx_oversize`, `rx_rxer`, `rx_recovery_mix`, `gem_internal_sva/a_rx_recovers_in_budget` | model + sim + assertion | **green** — recovery assertion live and demonstrated to refuse a 10-cycle recovery |
| R11 | Ignore inter-frame garbage silently | `tDeframe/ignoresInterFrameGarbage`, `rx_garbage`, `rx_bad_sfd` | model + sim | **green** |
| R12 | *[stretch]* DA filter / promiscuous mode | — | — | **n/a for v1, closed** — promiscuous by decision, now an explicit B.7 non-goal · see **V-7** |

## Traceability — interfaces

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R13 | RGMII v2.0, 4-bit DDR at 125 MHz | `tRgmii/*`, `rgmii_bfm` (drives real DDR), every sim scenario | model + sim | **green** (simulation) — the pins' electrical timing is V-2 |
| R14 | Documented clock/data skew mechanism | `gem_mmcm` asks the MMCM for the −72° (1.6 ns) second output B.1b derives; `tb_gem_clk_rst` confirms both outputs exist and start together | bench + static timing | **open** · see **V-2** — the mechanism is now implemented rather than only specified, but a phase shift is an I/O timing property and simulation passes at any phase. Note the achievable step: 45°/8 = 5.625°, so the request rounds to −73.125° (1.625 ns), still 0.375 ns inside the datasheet window |
| R15 | Registered AXI-Stream, no combinational handshake paths | `gem_axis_sva` ×8 properties, bound to both ports | assertion | **green** |
| R16 | MDIO/MDC master, ≤ 2.5 MHz, register-level requests | `tb_gem_mdio`: an on-demand read and a write confirmed by reading it back, the sequencer's poll order (PHY ID, BMSR ×2, vendor status), Clause 22 framing and turnaround on both opcodes, and a measured MDC period — against a PHY register-file BFM | unit | **green** — PHY address and the vendor speed encoding remain bring-up step 3 · see **V-3** |
| R17 | Status/counter block, per error class, readable over UART | `counters_expected.txt` checked in all 16 frozen scenarios, including `tx_underrun`; `tb_gem_uart_tx` (framing and baud against an independently timed receiver); `tb_gem_stat_report` (the whole record compared against the line it should have printed, with every input changed mid-transmission so the snapshot has to hold) | sim + unit | **green** — counters in Stage 4, readout in Stage 5 (**V-20** closed). The one thing left is a pin to drive it out of: **V-21** |

## Traceability — performance and quality

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R18 | Line rate both directions, zero drops | `rx_min_gap`, `random_rx_sweep`, `random_tx_sweep`, `tb_gem_mac_loopback` (both directions at once) | sim | **green** |
| R19 | Three clock domains, zero undeclared CDC | one async FIFO and five toggle synchronisers, and nothing else crossing; `tb_gem_rx_fifo` runs the FIFO across two unrelated clock rates; `tb_gem_mac_loopback` re-emits on an independent `rx_clk`; `gem_reset_sync` ×3 in `gem_clk_rst`, one per domain, checked by `tb_gem_clk_rst`; `report_cdc` at Stage 6 | sim + unit + tool | **green** (structural + sim) — `report_cdc` is Stage 6, and it now has the reset synchronisers to look at as well |
| R20 | WNS ≥ 0 at 125 MHz, RGMII I/O constrained | `scripts/synth_module.tcl` (WNS +2.262 ns post-synthesis, out of context, refuses on negative), `scripts/build.tcl` gates 2 and 3 | tool | **partial** — the I/O-delay half lands with the RGMII constraints in Stage 6 |
| R21 | RX MAC-added latency ≤ 32 cycles | `tb_gem_mac_rx` measures SFD→first beat on **every frame of every RX scenario** | sim | **green** — **13 cycles**, on every frame of every scenario, exactly B.1b's bottom-up prediction |
| R22 | Verilator lint clean, zero warnings | `make lint` (`scripts/lint.py`), Verilator 5.032 | tool | **green** — 2 tops, zero warnings, three justified suppressions |
| R23 | Zero inferred latches | `scripts/build.tcl` gates 1 and 1b, and the same two in `scripts/synth_module.tcl` | tool | **green** |
| R24 | Bit-exact vs the golden model; no negative slack | `make regress` + the slack gates | sim + tool | **green** — 28 of 28 runs pass; WNS +2.262 ns out of context at 125 MHz |

---

## Scenario catalogue

Defined in [`model/+gem/scenarios.m`](model/+gem/scenarios.m), which is the
single source of truth — `scripts/run_sim.py` parses it rather than keeping a
second list that would drift.

| Scenario | Dir | Covers | What makes it worth running |
|---|---|---|---|
| `rx_clean_sweep` | rx | R8 R9 R13 | boundary lengths, nominal gap — the control |
| `rx_trimmed_preamble` | rx | R8 | preamble 0–7 octets, including SFD-only |
| `rx_min_gap` | rx | R8 R10 R18 | **8-byte gap floor** with minimum frames |
| `rx_bad_fcs` | rx | R9 R10 R17 | single-bit corruption alternating with good frames |
| `rx_runt` | rx | R10 R17 | truncation — also exercises class precedence |
| `rx_oversize` | rx | R10 R17 | detectable mid-reception, not at EOF |
| `rx_rxer` | rx | R10 R13 R17 | PHY error flag with the FCS left intact |
| `rx_garbage` | rx | R11 | DV-low octets seeded with `0xD5` |
| `rx_bad_sfd` | rx | R8 R11 | damaged delimiter; the model defines the outcome |
| `rx_recovery_mix` | rx | R10 R17 R21 | every class interleaved with good frames at the min gap |
| `rx_length_edges` | rx | R9 R10 R17 | **63 / 64 / 1518 / 1519** — the exact lengths where classification changes over, constructed rather than stumbled on |
| `tx_underrun` | tx | R7 R15 R17 | **user starves the MAC mid-payload** — B.4b abort, then clean recovery |
| `tx_clean_sweep` | tx | R1 R2 R4 R5 R13 | frame assembly, compared at cycle granularity |
| `tx_padding` | tx | R3 | payloads either side of 46 octets |
| `tx_reject_oversize` | tx | R6 | 1501 B in, **1517 B out marked bad** — the only vector Stage 4 amended (B.4d) |
| `tx_backpressure` | tx | R7 R15 | tready deasserted between frames |
| `random_rx_sweep` | rx | R8–R11 R17 | 600 frames, every corruption × the length set |
| `random_tx_sweep` | tx | R1 R3 R5 R7 | 600 frames across the full length range |

The first sixteen are frozen: their vectors are committed, so they are readable
in review and runnable without MATLAB. The two `random_*` sweeps regenerate
bit-identically from the seed in their manifest and are git-ignored. `--all`
has been run end to end: 304,236 RX cycles and 460,992 TX cycles load and are
compared, so the large-scale path is exercised rather than merely available.

### Coverage criterion for "done"

From B.4, checked mechanically rather than by reading the table and hoping:

- every requirement R1–R24 has ≥ 1 named test — the tables above — **except R12**,
  which has none because it has no logic: it is a stated v1 non-goal (B.7, V-7),
  and an exemption that is written down is not the same thing as a gap;
- every error class appears in at least one frozen scenario —
  `tGenerator/everyErrorClassIsExercisedSomewhere` fails if one does not;
- every corruption type crossed with {min, typical, max} length —
  `random_rx_sweep`;
- the whole regression is green from one command.

---

## Current status

| Layer | Result |
|---|---|
| Golden model test suite | **70 / 70 passing** |
| Scenario generation | 18 / 18, every generator self-check agrees with the model |
| Committed vectors vs the model | **48 / 48 files current** |
| Per-module testbenches | **8 / 8** — `tb_gem_crc32`, `tb_gem_rx_fifo`, `tb_gem_mdio` (Stage 4 step 4), `tb_gem_clk_rst`, `tb_gem_uart_tx`, `tb_gem_stat_report`, `tb_gem_echo`, `tb_gem_top` (Stage 5) |
| Host record parser (`make hosttest`) | **15 / 15 passing** — including counter wrap modulo 2³², a truncated line, and an unknown field being an error rather than a skip |
| **Board-level round trip** (`tb_gem_top`) | **passing**, 60 checks — 12 good frames in on RGMII, 6 echoed back with addresses exchanged and a valid FCS the testbench computed itself, 6 dropped by the echo buffer's stated policy. `rx_ok` in the UART record agrees with the frames sent, and the readout reports no link with no PHY on the bus |
| **Reset asserted mid-operation** (`tb_gem_top`) | **passing** — the board's reset is asserted with a frame arriving *and* a frame leaving, while the link partner keeps sending, then released. The design must relock, restart its counters from zero and count a full replay exactly. This is the case the reset architecture creates: `tx_rst_n` waits for MMCM lock and `rx_rst_n` deliberately does not, so the two domains always release at different moments, and `gem_rx_fifo` straddles that boundary with a reset from each side |
| BFM self-test | **passing** — 3572 checks, including burst segmentation |
| TX driver self-test | **passing** — 35 checks, 3 of 3 stalls landed where the stimulus asked |
| Verilator lint (R22) | **passing** — 7 tops, zero warnings, 4 justified suppressions |
| Build gates (R20, R23) | **passing** — latch, slack and constraint-coverage gates green |
| **Frozen regression vs `gem_mac`** | **16 / 16 passing** (28 / 28 runs in total, per-module, board-level and loopback included) |
| Random sweeps | **2 / 2** — 600 frames each |
| Loopback, across an independent rx_clk | **2 / 2** |
| `gem_mac` out of context (Stage 4 step 6) | 745 LUT · 788 FF · 0 BRAM · 0 DSP · WNS **+2.262 ns** at 125 MHz (cell counts; 669 slice LUTs) |
| `gem_clk_rst` out of context (Stage 5) | 10 LUT · 27 FF · **1 MMCME2_ADV · 2 BUFG** · zero latches · zero critical warnings. Every one of the 27 registers synthesised with an *asynchronous* reset, which is the structure B.1b asks for read back out of the netlist rather than assumed from the source, and the 6 synchroniser flops kept their `ASYNC_REG`. This is the branch simulation never exercises — XSim and Verilator both run the behavioural model — so it is the only check that the real MMCM instantiation is legal at all. Repeatable as `make oocsynth M=gem_clk_rst` |
| `gem_top` synthesised in context (Stage 5) | **1123 LUT · 1422 FF · 1 RAMB18 · 1 MMCM · 0 latches · 0 critical warnings**, against B.2 budgets of 2000 LUT, 3000 FF, 4 BRAM36 and 1 MMCM. **WNS +1.546 ns · WHS +0.045 ns** at 125 MHz post-synthesis with `constrs/` applied, and the MMCM's two output clocks derived automatically from `create_clock` on `clk50` rather than declared by hand. The echo buffer inferred the BRAM18 its header predicted rather than dissolving into flip-flops — the gate V-18 left behind, doing its job on a new memory |
| R17's readout out of context (Stage 5) | `gem_stat_report` 209 LUT · 343 FF, `gem_uart_tx` 40 LUT · 30 FF — **249 LUT · 373 FF** together, zero latches, no inferred RAM. Against B.7 item 5's estimate of 150-250 LUTs, and against B.2's budget: the design now stands at roughly 1004 LUTs of 2000 and 1188 FFs of 3000, with the top level still to come |
| R21 measured worst-case RX latency | **13 cycles** against a 32-cycle ceiling — exactly B.1b's predicted 13 |

Three things are worth pulling out of that table.

**The design was compared against a reference nobody had tuned to it.** Every
number the scenarios check was frozen before the RTL existed, and the one
vector that changed (`tx_reject_oversize`, V-16) changed because the
specification was wrong, not because the design was — the counters it checks
were right both before and after.

**The assertions written in Stage 3 were bound unchanged and caught something
immediately.** `gem_internal_sva` refers to signals inside modules that did not
exist when it was written; the RTL was made to expose them rather than the
properties rewritten to suit the RTL. `a_crc_reseeded` then failed on a design
whose every data comparison passed, because the CRC accumulator was re-seeded
when the hunt began instead of one cycle earlier at end of frame. At the 8-byte
gap floor that poisons the next frame. No data check in this repository would
have found it.

**Both new assertion properties were made to fail on purpose**, like the seven
gates before them: re-seeding the CRC one cycle late trips `a_crc_reseeded` (12
failures on `rx_clean_sweep`, data comparison still green), and lengthening RX
recovery from 1 cycle to 10 trips `a_rx_recovers_in_budget` on `rx_min_gap`.

---

### What Stage 3 left behind, and what Stage 4 found in it

The Stage 3 result — the regression failing against a port-only stub — was not a
problem to fix. What was being checked is that the plumbing ran end to end and
that failures were legible, and running it found real defects in the harness
that would otherwise have surfaced mid-debug:

- `trim_nl` compared against the string literal `"\r"`, which is **not** a
  SystemVerilog escape sequence — XSim resolved it to a bare `r`, so any
  scenario name ending in "r" lost its last character. `rx_rxer` silently
  became `rx_rxe` and the testbench went looking for a directory that did not
  exist. It would have looked like a missing vector file, and only for some
  scenarios.
- the TX driver waited on `tready` unbounded, so a MAC that never asserts it
  reported "TIMED OUT after 20 ms" — six seconds of wall clock per scenario and
  no indication of the cause. It now names the stall.
- **the RGMII monitor sampled both nibbles on the wrong clock phases.** Captured
  words paired the rising nibble of cycle N with the falling nibble of cycle
  N+1 — every octet's high half taken from the next octet. Every TX scenario
  would have reported the design as broken, and the design would have been
  fine. Found only once `tb_rgmii_bfm` diffed the BFM against itself, which is
  why that testbench now exists and runs first.

Stage 4 found three more of the same kind, and the pattern is worth naming: **a
harness written against a stub encodes assumptions the stub could never
violate.** All three presented as design bugs and none of them was one.

- **the loopback scoreboard assumed a frame cannot come back before it has
  finished being sent.** It compared `rx_frame >= u_drv.frames_sent` and failed
  on the first beat of the first frame of every loopback run. That inequality is
  correct for a store-and-forward MAC and correct against a stub that transmits
  nothing; against this design it is wrong, because cut-through means the header
  is on the wire and looping back while the driver is still handing over the
  payload. B.4b's 22-octet head start, observed from the far end.
- **the FIFO unit test counted reads the FIFO never made.** It qualified its
  data check on `rd_en` alone, while the FIFO advances on `rd_en && !empty`; on
  the cycle after the last entry is taken those disagree, and every later entry
  read back as shifted by one. The design was right to refuse the pop.
- **the same test's writer held `wr_en` up one cycle too long**, offering an
  extra entry the burst had not counted, which then read back as a duplicate.
  Both of these were written to catch a CDC bug and would have reported one.

None of the three could have been found before there was a design, which is the
argument for writing them anyway and the argument for not trusting them until
something real has run through them.

---

## Open items

| # | Item | Why it is open | Plan |
|---|---|---|---|
| **V-1** | ~~TX behaviour when the user stalls mid-frame is unspecified~~ | **Closed — resolved in spec B.4b as cut-through with abort on underrun.** Store-and-forward was rejected: buffering a max frame before starting costs 12.14 µs of transmit latency and a BRAM the B.2 table does not carry, in a design whose premise is latency. On a mid-payload stall the MAC emits the FCS over what it has sent, bitwise inverted, with TX_ER across those four cycles, counts `stat_tx_underrun`, and discards the rest rather than resuming. Modelled by `gem.abortedFrame`, exercised by the `tx_underrun` scenario, and pinned down by `tAbort`'s 10 tests. | — |
| **V-17** | ~~The IDDR nibble mapping was inverted for the real PHY~~ | **Closed — mapping corrected, and the comment that excused it deleted.** `gem_iddr`'s primitive branch mapped `q_rise = Q2`, carried over from the behavioural model, whose phase convention is right for the testbench's clock-aligned launch and wrong for a PHY that delays its clock. The KSZ9031RNX adds 1.2 ns to RX_CLK relative to RXD (B.1b's own citation), which walks the rising edge into the middle of the rise-launched nibble — so Q1 is the low nibble. On hardware every octet would have arrived nibble-swapped: an SFD of 0xD5 reading as 0x5D, the hunter never finding a frame, and `gm_dv` actually carrying DV ^ RX_ER. Simulation cannot see any of it, because simulation runs the behavioural branch. | — Closed. The file's comment previously said the mapping "cannot be settled from a datasheet alone", which was an abdication where analysis was available; it now carries the derivation and cites `reference/verilog-ethernet`'s `rgmii_phy_if.v`, which maps Q1 → `rxd[3:0]` and `rx_dv = ctl_1` in the field. What is genuinely left for the bench is confirming the PHY's delay is present (V-2), not deciding which wire goes where. |
| **V-18** | ~~The RX FIFO's memory dissolved into 648 flip-flops~~ | **Closed — memory moved out of the reset block, and a gate added.** The array was written inside `always @(posedge wr_clk or negedge wr_rst_n)`. RAM contents cannot be reset, so Vivado could not build a RAM and said so — `[Synth 8-4767] … RAM "mem_reg" dissolved into registers` — then built 64×10 bits from flip-flops and a MUXF7/MUXF8 tree. That was nearly half the design's registers, and B.2 meanwhile claimed distributed RAM. Every gate passed: nothing was functionally wrong, only the shape of the result, and the warning sat unread in a log the build prints. | — Closed. Pointers keep their resets, the memory write is its own reset-free block, and the FIFO now occupies 14 LUTs of distributed RAM. 993 → 745 LUTs, 1403 → 788 FFs, WNS +2.135 → +2.262 ns; B.2 corrected. `scripts/synth_module.tcl` refuses the build on `Synth 8-4767`, which is the eighth gate and the only one whose canary is the defect that motivated it. |
| **V-19** | ~~MDIO could drive only 31 preamble ones~~ | **Closed — frames start on an MDC falling edge.** A transaction began on whatever `tx_clk` cycle it was requested, unaligned to MDC. `bit_cnt` advances on `fall_en`, so a frame begun while MDC was high spent its first bit period with no rising edge in it — and the PHY samples on rising edges, so it would count 31 preamble ones before the start bit. Clause 22 asks for 32. Many PHYs tolerate short preamble and none of them promises to. | — Closed. Requests are now accepted immediately and started at the next falling edge, so acceptance stays decoupled from framing and costs at most half an MDC period. `tb_gem_mdio` counts driven preamble ones, which it did not before — a BFM that hunts for the first zero cannot notice a missing edge. Demonstrated: forcing a high-phase start makes it report exactly 31. |
| **V-20** | ~~R17's counters have no way out of the chip~~ | **Closed — the readout is built.** `gem_uart_tx` (8N1 framing, 115200 at 125 MHz) and `gem_stat_report` (the formatter) print every R17 counter plus `link_up`, `link_speed`, `phy_id` and `phy_id_valid` as one named-field record per second, 192 characters and a newline. The counters were already proven against the golden model in all sixteen frozen scenarios, so the obligation was narrow — that the framing is right and that what is printed is what the ports held — and it is met by a testbench that decodes its own transmitter's output, exactly as spec B.7 item 5 proposed. | — Closed. Two properties are worth naming because neither was in the original plan. **The baud check needed an independent clock**: the first version computed the bit period from the receiver's own sampling delays, which is a tautology, and a planted 3.2% divisor error passed it — framing alone cannot catch that, because a receiver resynchronises on every start bit. It now measures the low run the design's own two edges make. **And every field of a line is snapshotted in one cycle**: a record takes ~17 ms to clock out, so live fields would each be true at a different instant and a soak looking for divergence would find some it caused. Measured cost 249 LUTs, 373 FFs, against B.7 item 5's estimate of 150-250 LUTs. |
| **V-21** | ~~The board pins for the reset key and the UART are documented only in schematic figures~~ | **Closed — found, then confirmed against the schematic.** The ALINX manual's text genuinely does not carry them: Part 20 (keys) and Part 13 (USB to serial port) describe the hardware in prose and leave the numbers in figures. ALINX's own demo projects have them, and the board schematic — 18 sheets, Rev 1.0, in the same mirror — agrees: reset key **F20** (net `RESET`, pin function `IO_L18N_T2_16`, which is what Vivado independently reports for that pin), **G16** for the FPGA's UART transmit and **G15** for its receive, keys M13/K14/K13/L13. The direction question is settled rather than flagged: `04_uart_test` declares `output uart_tx` on G16. | — Closed. The more valuable half is incidental: the schematic **also confirms all fifteen RGMII and MDIO pins**, which had come from a text extraction of a manual and had never been checked against a second source — and they are the pins the entire design talks through. Nothing disagreed anywhere. What remains an assumption is bank 16's VCCIO, corroborated by ALINX constraining those pins `LVCMOS33` but not stated beside the bank; `constrs/pins.xdc` still flags it, and the LEDs settle it on the bench. Provenance and the full reasoning in `Manuals/AX7035B_pinout_notes.md`. |
| **V-16** | ~~R6 as written and B.4b as written cannot both be satisfied~~ | **Closed — R6 reworded, one vector regenerated (spec B.4d).** Found by writing the Stage 4 transmit path, and unfindable before it: R6 said reject payloads over 1500 octets and never emit an oversize frame, and `tx_reject_oversize` froze that as *nothing at all on the wire* for a 1501-octet request. But the transmit interface carries no length — a frame's length is known only when `tlast` arrives, and B.4b's cut-through decision means TX_EN went up long before that. Knowing the length before committing means holding the whole frame first: store-and-forward, which B.4b rejected for costing 12.14 µs and a BRAM the B.2 table does not carry, and which a threshold buffer does not rescue, because a buffer deep enough to decide *is* a whole-frame buffer. The two requirements were jointly unsatisfiable and the vector encoded the impossible half. Resolved the way B.4b would have resolved it: refuse the octet that would be the 1501st **before** transmitting it, leaving 14 + 1499 + 4 = 1517 octets on the wire — inside maxBasicFrameSize, so R6's "never emit an oversize frame" holds literally — marked bad with `TX_ER` and an inverted FCS, counted in `stat_tx_rejected`, remainder drained and discarded. `gem.abortedFrame` already modelled the object; only `gem.genTxScenario` needed to emit it. | — Closed. `tx_reject_oversize/tx_expected.hex` is the only vector datum that changed; all 47 other committed files regenerated byte-identically, which is the evidence that this was a contained specification error rather than a design that had drifted. The counters never moved: they were right before the amendment and after it. |
| **V-22** | Three of R10's four error classes cannot be provoked from a PC | A commodity NIC computes the FCS in hardware and pads anything under 60 octets before transmitting, so bad-FCS and runt frames never reach the wire, and RX_ER is the PHY's to assert rather than a sender's to request. Found while writing `sw/host/`, not at a bench — which is the point of writing the harness before the board arrives. Oversize is the one class a PC can send, because a long frame is well-formed rather than malformed. | Bring-up step 7 is scoped to oversize plus recovery, and says so rather than quietly sending frames the NIC repaired. All four classes stay covered bit-exactly in simulation against the golden model (`rx_bad_fcs`, `rx_runt`, `rx_rxer`, `rx_oversize`, and `rx_recovery_mix` for the interleaving); what hardware adds is the PHY, the pins and the skew, which one class exercises as well as four. Closing it properly needs a transmitter that owns its own MAC — a second FPGA, a traffic generator, or a NIC whose driver exposes CRC offload controls. |
| **V-2** | R14's RGMII skew cannot be simulated | The 1.6 ns `GTX_CLK` phase shift is an I/O timing property. Simulation will pass with any phase; only static timing analysis and a scope on the bench can confirm it. | Stage 6 `report_timing` on the constrained I/O paths, then bring-up step 5 with an ILA or scope on `GTX_CLK`/`TXD0`. |
| **V-3** | ~~R16 MDIO has no test~~ | **Closed, and R16 completed along the way.** `tb/tb_gem_mdio.sv` runs the master against a PHY register-file BFM that decodes Clause 22 the way the standard specifies rather than the way this MAC happens to emit it, so a wrongly ordered field is answered by silence instead of accommodated. Writing it exposed that the module was only half of R16: there was a sequencer but no "register-level request interface", because the frozen port list had no channel for one — and with no way to read an arbitrary register, B.5 step 3 (read the PHY ID, prove MDIO and the PHY are alive) could not be performed at all. Ports were added rather than the requirement trimmed. The test now covers an on-demand read, a write confirmed by reading it back through the same port, the sequencer's poll order, framing and turnaround on **both** opcodes, and a measured MDC period against R16's ceiling. It was made to fail on purpose: sending a write with the read opcode trips the turnaround check on the first affected bit. What it cannot check is what the board straps `PHY_ADDR` to, and whether register 0x1F carries the speed bits where the KSZ9031RNX datasheet says — both stated in the module header, both bring-up step 3, and both now answerable from the bench without a rebuild by sweeping the address over the request port. | the remaining half is bring-up |
| **V-4** | ~~R22's lint gate cannot run~~ | **Closed.** Verilator 5.032 installed under WSL; `scripts/lint.py` bridges to it from Windows and falls back to a native binary elsewhere. Both design tops lint clean under `-Wall`, and the gate was verified to fail by injecting a width mismatch — it caught that plus the unused signal and exited nonzero. `make check` now runs it. | — |
| **V-5** | ~~R21's latency is specified but not measured~~ | **Closed.** `gem.expectedBeats` now emits each frame's `sfdCycle`, the driver exposes when cycle 0 was launched, and `tb_gem_mac_rx` converts the two into a per-frame cycle count checked against `GEM_RX_LATENCY_MAX_CYCLES`. The worst measured latency is printed on every run even when it passes, so erosion against B.1b's predicted 13 is visible before it becomes a violation. | — |
| **V-6** | The golden CRC is not yet checked against a real capture | B.4 asks for validation against a Wireshark capture; the board is not in hand. Validation is currently the published check value, Python's `zlib` over 2000 vectors, and the residue property. | Close at bring-up step 5 by capturing a frame the design transmitted and confirming Wireshark reports its FCS correct. `bringup_checklist.md` step 5 is written to do exactly that, and `sw/host/gem_host.py echo` produces the frames to capture. |
| **V-7** | ~~R12 (DA filter) has no test~~ | **Closed — R12 is not implemented in v1, and that is now written down rather than pending.** This item offered two ways to close: promote R12 out of B.7's non-goals, or leave it explicitly unimplemented. The second is taken. The receive path is promiscuous — every frame is delivered with its verdict and user logic filters — which is also the mode bring-up step 4 needs, since address filtering in the MAC would hide the frames a bring-up session is trying to see. A stretch requirement with no test is only a problem while nobody has said which way it went; the failure mode being avoided here is a release that cannot state what it does. | — Closed. R12 is listed in B.7's non-goals and B.2's R12 says why. It stays untested because there is nothing to test: no filtering logic exists. If it is ever promoted, it needs a comparator on the first six delivered octets, a mode bit in R17's block, and a scenario pairing matching and non-matching DAs against both modes — additive, with no other contract touched. |
| **V-8** | ~~The latency measurement has never measured a real number~~ | **Closed.** It measures **13 cycles**, on every frame of every RX scenario including the 600-frame random sweep. The sanity check this item asked for — compare against B.1b's predicted 13, not merely against the 32-cycle ceiling — passes exactly, which is worth more than clearing the ceiling would have been: the pipeline has the depth the specification says it has, stage for stage. | — |
| **V-9** | ~~Two lint suppressions live in `rtl/gem_mac_stub.v`~~ | **Closed.** The stub is deleted and both suppressions went with it; neither was carried forward. The design carries three of its own, each justified in the source as R22 requires, and each for a signal that exists to be *observed* rather than used: `frame_active` (which `gem_internal_sva` binds to), the three deliberately unread outputs gathered at the bottom of `gem_mac` (`fifo_full`, and the CRC value and residue each path does not use), and one `COMBDLY` in the behavioural DDR output model, where the nonblocking assignment is precisely what keeps the captured wire stream independent of simulator scheduling order. | — |
| **V-10** | ~~The Makefile has never been executed~~ | **Closed.** GNU Make 4.2.1 ships with Vivado (`$(VIVADO_ROOT)/gnuwin/bin/make.exe`), so no install was needed and it is guaranteed present wherever Vivado is. Running it found two defects that only appear on execution: `@echo "..."` printed its quotes literally under cmd.exe, and `clean`/`clean-sim` used `rm -rf`, which is not a cmd builtin — they worked only when make happened to be launched from Git Bash and failed from PowerShell or cmd. Help now uses `$(info)` (never reaches a shell) and the clean targets go through `scripts/clean.py`. `make check` runs end to end and exits nonzero on the failing regression, as a gate should. | — |
| **V-15** | ~~Vector coverage was partly accidental~~ | **Closed.** Reviewing the committed vectors rather than the catalogue that claims to produce them found three gaps. All 17 scenarios shared one hard-coded seed, so two scenarios differing only in corruption kind drew **identical** offsets, and the random sweeps retraced the directed set's RNG trajectory — `gem.seedFor` now derives a distinct seed per scenario from its name (name-derived, so inserting a scenario does not churn every other vector file). `rx_trimmed_preamble` claims to sweep preamble lengths 0..7 and actually produced {0,1,2,3,5,6}, missing 4 and — in the one scenario whose entire purpose is preamble length — 7, the standard full preamble; `PreambleMode='random'` now covers all eight before repeating. The four classification boundaries were present but 63 and 1519 occurred once each, purely because seeded offsets happened to land there, so a seed change would have removed them silently; `rx_length_edges` now constructs all four and `tGenerator` asserts they survive. | — |
| **V-14** | ~~A passing WNS was hiding an unconstrained design~~ | **Closed.** Vivado said it plainly and nobody was reading it: *"[Place 30-2953] Timing driven mode will be turned off because no critical terminals were found"* — the build reported WNS 17.2 ns while the placer had timing analysis switched off, because nothing in the design was constrained. WNS ≥ 0 is nearly free when no path is constrained enough to have negative slack. Added gate 3, a `check_timing` coverage gate that refuses on unclocked registers, unconstrained internal endpoints, multiple clocks and loops, and lists ports lacking I/O delay. Also declared the LEDs as false paths in `constrs/exceptions.xdc` so "unconstrained because it does not matter" is written down and distinguishable from "unconstrained because somebody forgot" — check_timing now reports them as *"no output delay but user has a false path constraint"*. Gate 2's diagnosis was wrong too: with no clock, `get_property SLACK` returns `""` and Tcl compares `"" < 0` as strings, so the build was refused with "negative setup slack (WNS =  ns)" — right outcome, misleading cause. | I/O-delay refusal deferred to Stage 6 |
| **V-13** | ~~The build gates had never been demonstrated, and one had a hole~~ | **Closed.** `make synth` could not run at all — the Makefile invoked a bare `vivado`, which is not on PATH here, so all four Stage 2 targets had been unexercised while the Python-driven ones worked. Now routed through `scripts/build.py`, which reuses `run_sim.py`'s locator. With that fixed, planting a latch showed gate 1 refuses correctly — **but a latch that synthesis infers and then optimises away passed silently**, netlist clean and `PASS` printed, while the log said `inferring latch for variable`. Gate 1b now refuses on the inference warning itself; verified against the exact case that previously passed. The timing gate runs and reports (WNS 17.2 ns on the skeleton) but has not been made to refuse — that needs a design that fails timing, which the blinker cannot supply. | timing-gate refusal still unproven |
| **V-12** | ~~The SystemVerilog layer had four review findings~~ | **Closed.** A step-by-step review of `tb/` found: the AXI-S assertions were largely decorative (all six properties on the `tx_axis` bind watch the stimulus driver, since the user drives everything but `tready`; four more are permanently vacuous on `rx_axis` because R18's no-stall contract ties `tready` high) — now measured and reported per run, with `tready`/`tvalid` X-checks added, which were the one gap that would have presented as a dead design rather than as an X. `gem_rgmii_sva` sampled DDR pins on one edge, so `wire tx_en = tx_ctl` was reading TX_EN^TX_ER and `a_frame_starts_with_preamble` passed only because both nibbles of `0x55` are `5`; it now reconstructs the full cycle from both edges and asserts on real TX_EN, TX_ER and whole octets. The loopback scoreboard misattributed every frame after a dropped one; it now stops at the first frame-level divergence and says why. | — |
| **V-11** | ~~TX comparison was misaligned and over-constrained~~ | **Closed.** An independent review of the Stage 3 vectors found three defects that were invisible against the stub and would all have presented as RTL bugs in Stage 4. (a) `tb_gem_mac_tx` diffed cycle streams index-for-index while `rgmii_monitor` skips leading idle and the model emits a full IFG first — a skew of exactly 12, so *every* cycle would have mismatched. (b) The frozen gap of exactly 12 over-constrained R5's floor and was unreproducible after a B.4b abort, where the MAC drains up to 1440 discarded octets. (c) `tx_padding` contained two zero-length payloads, which an AXI-Stream port cannot express — no beat to carry `tlast`. Fixed by segmenting both streams into frames and gaps (content compared exactly, gaps against the floor), and by rejecting length 0 in the generator. Spec B.4c records both interface limits. | — |

---

## Decisions this stage forced

Writing the model resolved three things the spec left ambiguous. All three are
now binding on Stage 4, and each is recorded where the code that depends on it
lives.

1. **RX delivers the frame, not the payload.** `rx_axis_tdata` carries DA
   through pad — everything except preamble, SFD and FCS — so `rx_axis_tuser`
   stays the single good/bad bit R15 specifies. B.1a's "extracts DA/SA/
   EtherType, streams payload onward" and R15's one-bit `tuser` could not both
   be true. *(`gem.expectedBeats`)*
2. **One `tlast` timing for all five classes.** Errors detectable mid-frame
   (oversize, RX_ER) do not cut the stream short; every frame ends at the
   natural end of its DV burst carrying its verdict. `Documents/Bad bitstream
   handle.md` said early termination "can also be" done, which is not a
   decision. *(`gem.expectedBeats`)*
3. **Error class precedence: `rxer > oversize > runt > badfcs`.** R10 requires
   one counter per class and a frame can be in several at once. Without a
   stated order the model and the RTL would pick differently and every counter
   comparison would mismatch. *(`gem.parseFrame`, with the reasoning)*

And one arithmetic correction to the spec: cut-through delivery cannot know
which four octets are the FCS until DV drops, so the RX path needs a four-octet
holdback register to keep the FCS off the user port. That is four cycles B.1b's
latency sum does not list — 13 rather than 9, against R21's ceiling of 32.
