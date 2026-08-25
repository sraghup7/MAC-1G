# `gem_mac` — a 1000BASE-T Ethernet MAC on an Artix-7

A full-duplex 1 Gbps Ethernet MAC written from scratch in Verilog-2001, targeting
an ALINX AX7035B (Artix-7 XC7A35T) and talking RGMII to the board's Micrel
KSZ9031RNX PHY. No vendor MAC IP — the point is to build the thing, not to
configure someone else's.

**Status: Stages 1–7 complete; the board is not yet in hand.** The MAC is
written, constrained, placed, routed and gated: `make bitstream` produces
`build/gem_top.bit` behind nine refusing gates, and `make check` runs 29 of 29
scenarios green against a reference model that was finished before the first
line of the RTL existed — including 600-frame random sweeps in both directions
and a loopback that feeds the design's own transmit pins back to its receive
pins across an independent clock.

**One number on this page needs its caveat read, not skimmed.** Post-route
timing is **WNS −3.109 ns**, and that is a *deliberate, fenced* state rather
than a design that misses timing. The five RGMII receive input checks are
waived: task 4e measured the routed deskew feedback path against the arc
Vivado's ZHOLD model applies and proved those numbers are ~3.1 ns of tool
artifact, not silicon. Everything else — TX, fabric, every other path group —
closes positive, and gate 2 refuses on any violation outside those five named
endpoints. The full reasoning, the fences, and the real slow-corner hold miss
that was hiding *underneath* the artifact are below. **R20's receive half is
signed off by derivation and closes on the bench, not in the tool** — bring-up
step 5 is the authoritative check, and until it runs this is the honest state.

Stage 5 is integration, and two of its blocks are in. The **clock and reset
module** (`rtl/gem_clk_rst.v`), which the specification had described as
deliberately absent since v0.1: the MMCM and its phase-shifted second output, one
reset synchroniser per domain — asynchronous assert, synchronous deassert, the
first anywhere in this repository — and the PHY's 10 ms power-on reset hold. And
**R17's readout** (`rtl/gem_uart_tx.v`, `rtl/gem_stat_report.v`), which closes
V-20: the counters have been correct since Stage 4 and had no way out of the
chip. They now leave it as one named-field line a second —

```
gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 ... phyid=00221622 phyok=00000001 rxlock=00000001
```

— every field of which is captured in the same cycle, because a record takes 17 ms
to clock out at 115200 baud and a soak that reads fields from thirteen different
instants finds divergence it caused itself.

And now **the board itself** (`rtl/gem_top.v`): the MAC, the clocking, the
readout and an echo path, wired to real pins. A frame that arrives good goes
back out with its addresses exchanged, which is what makes the board testable
with nothing but a PC and Scapy — and what lets one observation prove the whole
chain, since a frame only completes the round trip if every stage from the IDDR
to the ODDR did its job. `tb_gem_top` drives the design at its pins and nowhere
else: a 50 MHz oscillator, a reset key, RGMII, and it reads back LEDs, a serial
line and frames on the wire.

Measured on the whole board, in context, against real constraints: **1123 LUTs,
1422 FFs, one BRAM18, one MMCM**, no latches, and **WNS +1.546 ns** at 125 MHz post-synthesis (Stage 5 snapshot -- post-route the board closes at +0.058 ns on TX, see the timing block below)
after synthesis.

And the PC side: [`sw/host/`](sw/host/README.md) drives B.5's steps from a
terminal — frames in, round trips, corruption, and a four-hour soak that writes a
file you can diff — while [`bringup_checklist.md`](bringup_checklist.md) is the
order to do it all in, with what each failure would mean.

**Stage 6 built the board.** `make synth`/`impl`/`bitstream` build `gem_top`
against `constrs/` by default (`TOP=skeleton_top` still builds the Stage 2
blinker, for B.5 step 1). A gate refuses the build outright on any
`CRITICAL WARNING`, which a constraint matching no port produces; it caught the
tree's own defect on the first run, 68 of them, from `constrs/` already
describing the board while the build still targeted the blinker. Post-route
slack is **WNS −3.109 ns / WHS +0.049 ns** — the negative figure being the
five waived RX input checks described above and nothing else.

**RGMII RX timing: signed off by derivation, bench check pending.** The RGMII
I/O delay constraints (V-2) are written, corrected, and wired into the real
build, and they check the physically real DDR capture events. The RX clock
deskew they demanded is built -- a second MMCM deskewing the recovered receive
clock -- and task 4e then resolved what task 4d had left open: the ~-2.1 ns
"structural" setup failure was **Vivado's ZHOLD compensation model**, which
freezes the deskewed capture-clock arrival at a routing-independent constant
(~2.3 ns of phantom spread on exactly those five checks). Underneath it sat a
real defect the model hid in both directions at once -- input-side IBUF spread
passes straight through a deskew loop, so slow-corner hold missed by ~0.33 ns
on silicon while STA showed hold passing -- fixed by a -45 degree (-1000 ps)
capture trim with predicted worst same-corner margin +0.669 ns. STA still shows
the five RX checks red by ~3.1 ns of artifact and always will; gate 2 waives
exactly those five endpoints under that documented basis (count asserted,
envelope bounded) and refuses everything else. R20's RX half gets its
authoritative check on the bench at bring-up. Evidence:
[`docs/reports/stage6-part2/task-4e-report.md`](docs/reports/stage6-part2/task-4e-report.md)
(and 4a/4b/4d/4d2 for the chain that got there); the reset architecture the
deskew forced (`rx_path_rst_n`, the clk50 supervisor, the B.1b exception) is in
[`Documents/RX Clock Deskew Design.md`](Documents/RX%20Clock%20Deskew%20Design.md).
Gate 3 (constraint coverage, refusing rather than reporting, anchored by gate
1c on the derived RX clock) passes; gate 2 passes with the five-path waiver.
Simulation is fully green: `make check` runs 29 of 29 scenarios against the new
reset architecture.

Writing it changed exactly one number in the reference. `tx_reject_oversize` had
frozen an expectation no cut-through MAC can meet — silence on the wire for a
request whose length the MAC is never told until it is already transmitting —
and the fix was to R6, not to the RTL: refuse the 1500th payload octet the
moment a 1501st is known to exist, before that octet is transmitted, so the wire
carries a 1517-octet frame marked bad rather than an oversize one. See [B.4d](spec/PROJECT_SPEC.md) and V-16. Its
`tx_expected.hex` is the only vector datum in the repository that changed; the
other 47 files regenerated byte-identically.

Measured, not estimated: **743 LUTs, 793 FFs, no BRAM, no DSP** (3.6% of the
device, against a B.2 budget of 2000 LUTs), **+1.897 ns** slack at 125 MHz out of
context (re-measured at the Stage 7 close), and an RX latency of **13
cycles** on every frame of every scenario — exactly what B.1b's bottom-up
pipeline sum predicted, stage for stage.

| | |
|---|---|
| Specification | [`spec/PROJECT_SPEC.md`](spec/PROJECT_SPEC.md) — requirements R1–R24, architecture, budgets |
| Block diagram | [`spec/block_diagram.md`](spec/block_diagram.md) |
| Verification plan | [`verification_plan.md`](verification_plan.md) — every requirement traced to a named test |
| Coding standard | [`coding_standard.md`](coding_standard.md) — the RTL conventions and what enforces each |
| Transmit datapath | [`Documents/Golden Model Transmit Path.html`](Documents/Golden%20Model%20Transmit%20Path.html) |

---

## Quick start

Everything runs through one command:

```bash
make check
```

That is model tests → committed-vector staleness → Verilator lint → the host
tooling's tests → the regression, in that order because it is the order that makes a failure
diagnosable: a broken reference explains a broken comparison, and a lint error
explains a lot of simulation nonsense. The regression itself runs cheapest-first
too — per-module testbenches, then the harness self-tests, then the scenarios,
then the loopback.

`make` is not on PATH by default on Windows, but **Vivado bundles it**:

```bash
D:/Vivado/2024.2/gnuwin/bin/make.exe check
```

No tool needs to be on PATH. Every target goes through a script in `scripts/`
that locates Vivado, Verilator or MATLAB itself.

Run `make help` for the full target list.

---

## What is here

```
spec/         the specification, versioned alongside the RTL
model/        MATLAB golden model, stimulus generator, 70 tests, committed vectors
rtl/          the design: 13 MAC modules, one per file, plus the shared
              parameters — and, from Stage 5, 3 that clock and reset it, 2
              that read its counters out over a serial pin, an echo path and
              the board top level
tb/           testbenches, bus functional models, bound assertions
constrs/      clocks / pins / exceptions, split so each is reviewable alone
scripts/      build, simulation, lint, vector-staleness and clean drivers
Documents/    derivations too long to inline in the spec
sw/host/      the PC side of bring-up: Scapy, a serial reader, and its own tests
```

`bringup_checklist.md` is the order to bring the board up in, derived from B.5,
written before the board is in hand — including what each failure would mean and
the three questions only a bench can answer.

The design is nine blocks the specification named before any of them existed:
an AXI-Stream ingress register and a frame assembler on the transmit side, an
SFD hunter, deframer, classifier and async FIFO on the receive side, a CRC-32
accumulator shared by both, RGMII DDR cells at the pins, an MDIO master, and a
counter block. `rtl/gem_mac.v`'s header maps each one to its module.

---

## The three ideas this project is organised around

**The reference model comes before the RTL.** You cannot check what you have no
reference for, and writing the model is what finds the specification's holes. It
found three here that would otherwise have surfaced weeks into design: what
`rx_axis_tdata` actually carries, which error class wins when a frame is in
several at once, and what the transmit path does when user logic starves it
mid-frame. All three are now written down as binding contracts (B.4a, B.4b,
B.4c) rather than discovered during debug.

The RTL then found a fourth that the model could not have: a MAC cannot reject a
frame for being too long if it is never told the length until after it has
committed to transmitting (B.4d). Some questions only exist once something has
to drive a pin.

**No constant is written twice.** `gem.params` parses `rtl/gem_mac_params.vh`
rather than restating its numbers, so the model and the design cannot disagree
about something like the minimum frame length — a disagreement that looks
exactly like an RTL bug and costs a day to find.

**A gate that cannot fail is not a gate.** Every check in this repository has
been made to fail on purpose, by planting the defect it exists to catch:

| Gate | Proven by |
|---|---|
| Verilator lint | an injected width mismatch |
| Vector staleness | one corrupted octet |
| Scenario regression | a planted assertion failure |
| Inferred latches | a deliberate incomplete `always @(*)` — twice, once for a latch that synthesis optimised away and the first gate missed |
| Timing / slack | commenting out `create_clock` |
| Constraint coverage | the same |
| Critical-warning cleanliness (gate 0) | the 68 real ones a mismatched build emitted while exiting 0 — constraints describing `gem_top` read against `skeleton_top` — plus a renamed port planted in `constrs/pins.xdc` |
| RX capture-clock anchor (gate 1c) | asserted by construction: it refuses on any count ≠ 1, and the failure mode it guards (a stale instance path silently voiding four false-path lines) is exactly what renaming an instance would cause |
| RX I/O waiver fences | a stale endpoint name (`g_rxd[9]` → "resolved to 4 pin(s)"), TX output delays planted past closure (five paths named and refused), clk50 over-constrained to 8 ns (enumeration-cap refusal) |
| FIFO integrity across a link drop (D6) | the receive path's *two independent* reset protections removed together — `gem_mac`'s `rx_path_rst_n` wiring and `gem_rx_fifo`'s internal `rd_rst_eff_n` cross-coupling. 491 octets of FIFO memory were then handed to the AXI-S port as a well-formed frame. Removing either one alone changes nothing, which is the point: the defect needs both gone, so a canary that defeats only one proves nothing |
| Phantom statistics across a link drop (D7) | the five `gem_pulse_sync` destinations reverted to `tx_rst_n`, with the event toggles left at **odd** parity — `rx_ok` counted 25 → 26 with nothing on the wire. At even parity the same broken RTL passes, so the test drives one extra frame first to make the parity odd |
| FIFO overflow, FSM legality, CRC re-seed, R10 recovery | a CRC re-seeded one cycle late, and a receive path made to take 10 cycles to recover instead of 8 |
| MDIO Clause 22 framing | a write sent with the read opcode, which leaves both ends driving the bus |
| MDIO preamble length | a frame started mid-MDC-period, which drives 31 preamble ones instead of 32 |
| Clock/reset properties | three defects planted one at a time: an rx reset gated on MMCM lock (then forbidden — the deskew architecture has since reversed this, with the testbench rewritten around the new semantics), a tx reset that is *not* gated on it, and a synchroniser chain made synchronous-only — which cannot assert at all once the MMCM's reset has stopped the clock |
| UART framing and baud | a divisor 3.2% off, and a transmitter reversed to send MSB first. The first of those **passed** until the test was fixed: it had been measuring its own receiver's delay loop rather than the design's edges, and framing alone cannot catch a wrong baud because a receiver resynchronises on every start bit |
| Status record | the snapshot removed, so the fields come from thirteen different instants, and the value nibbles reversed |
| Recovery from a mid-operation reset | a `pending` flag moved out of the echo path's reset, so it survives a reset that clears the length and header underneath it. It powers up correct, so a cold start works and every other test stays green — the same defect passes the previous testbench at 31 checks and fails this one |
| Echo path | the header taken from the live capture register instead of the one latched at commit — the defect this module actually had, which corrupts a reply's destination only when a second frame arrives mid-transmission — and a bad frame echoed as though it were good |
| Memory inference | the defect that motivated it: a FIFO array that dissolved into 648 flip-flops |

That habit is not decoration. Reviewing Stage 3 found a skewed comparison, a
self-check disabled by a single input, assertions that were structurally
vacuous, a vacuity detector that was itself broken, and a build target that had
never once executed. None of them were wrong answers — they were checks quietly
not checking, and every one would have surfaced in Stage 4 as a phantom RTL bug.

The last two rows of that table were added in Stage 4, and the second one earned
its place immediately: the obvious way to re-seed the receive CRC — when the
hunt for the next frame begins — leaves one cycle in which the accumulator still
holds the previous frame's remainder. Every data comparison still passed. Only
the assertion caught it, which is the entire argument for writing assertions
before the RTL they watch.

---

## Running less than everything

```bash
python scripts/run_sim.py --scenario rx_min_gap
```

Other useful entry points:

- `make model` — the golden model's own suite, ~5 s, the fastest signal there is
- `make vectors` — regenerate every scenario from its seed
- `make regress-all` — includes the two large random sweeps (~760k cycles)
- `make synth` / `impl` / `bitstream` — `gem_top` against real constraints,
  nine gates (critical-warning cleanliness before and after implementation,
  the RX capture-clock anchor, two latch checks, constraint coverage, slack
  — where the five RGMII RX input checks are waived under the fenced task-4e
  derivation and everything else must pass outright — CDC via `report_cdc`,
  and physical verification via `report_drc` and route status).
  `TOP=skeleton_top` builds the Stage 2 blinker instead.
- `make oocsynth` — the whole MAC synthesised alone: area, slack, and the B.2
  budget checked rather than assumed (Stage 4 step 6). `M=gem_crc32` does one
  module.

Every scenario is reproducible from the seed recorded in its `manifest.json`,
and each scenario now has its own seed, so the random sweeps explore somewhere
the directed tests have not already been.

---

## Where the numbers come from

Nothing in the specification is asserted without a derivation. The inter-frame
gap floor is 8 byte times rather than 12 because that is what a *receiver* must
tolerate (Table 4-2 Note 3), and a regression that only ever emits 12 passes
even when RX recovery silently needs 15. The RX FIFO is 64 entries against a
derived requirement of ~4.3. The RX latency budget is 13 cycles against R21's
ceiling of 32, and that 13 includes a four-octet FCS holdback that the first
draft of the arithmetic missed.

The reasoning for the ones that needed more room than a spec paragraph lives in
[`Documents/`](Documents/).
