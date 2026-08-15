# `gem_mac` — Verification Plan

Document status: v1.0 — Stage 3 complete. Versioned alongside the RTL.

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
| `make model` | the golden model's own test suite (55 tests) | must be green before any simulation result means anything |
| `make vectors` | regenerates every scenario from its seed | fails if the generator and the model disagree |
| `make vectors-check` | do the **committed** vectors still match the model? | fails if an edited model left them a fossil |
| `make sim S=<scenario>` | one scenario | — |
| `make regress` | every frozen scenario | **the gate**: nonzero exit on any mismatch or assertion failure |
| `make regress-all` | plus the large random sweeps | — |
| `make lint` | Verilator `--lint-only -Wall` on every design top (R22) | **the gate**: nonzero exit on any warning; a missing Verilator is an error, not a skip |
| `make check` | model, vectors-check, lint, regress | the whole thing, in the order that makes a failure diagnosable |

> `make` is not currently on PATH on this machine. Until it is, run the
> underlying commands directly — `python scripts/run_sim.py`,
> `matlab -batch "addpath('model'); runModelTests();"`,
> `matlab -batch "addpath('model'); genVectors();"`.

Layers, cheapest first, which is the same principle as the flow doc's four
debug loops:

1. **Model tests** (`model/tests/`, ~2 s) — is the reference itself right?
2. **Generator self-check** (inside `gem.genScenario`) — does the generator's
   stated intent match what the golden model reads back off the wire? The two
   are derived independently, so agreement is evidence rather than tautology.
3. **Vector staleness** (`scripts/check_vectors.py`) — do the committed vectors
   still reflect the current model?
4. **BFM self-test** (`tb_rgmii_bfm`) — is the bus functional model itself
   right? It has no DUT in it, so it is the only run that passes today, and the
   first thing to check when something downstream looks impossible.
5. **Bound assertions** (`tb/assertions/`) — invariants checked on every cycle
   of every scenario, including ones nobody designed.
6. **Scenario regression** (`scripts/run_sim.py`) — the design against the
   model, bit for bit.
7. **Loopback** (`tb_gem_mac_loopback`) — the design against itself, which is
   the only layer where a TX and RX error that cancel each other out cannot
   hide.

---

## Traceability — transmit

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R1 | Ethernet II encapsulation, preamble→FCS | `tFrame/fieldOrderAndLengths`, `tFrame/etherTypeIsBigEndian`, `tx_clean_sweep`, `gem_rgmii_sva/a_frame_starts_with_preamble` | model + sim + assertion | pending-rtl |
| R2 | DA/SA/EtherType per frame, not compile-time | `tx_clean_sweep` (header on `tx_axis_tuser` at SOF) | sim | pending-rtl |
| R3 | Pad payloads < 46 B to a 64 B frame | `tFrame/paddingReachesMinimumFrame`, `tFrame/padIsZeros`, `tx_padding` | model + sim | pending-rtl |
| R4 | CRC-32, reflected, LSB-octet first | `tCrc32/checkValue`, `tCrc32/agreesWithZlib`, `tCrc32/residueIsConstant`, `tFrame/fcsIsLeastSignificantOctetFirst`, `tFrame/fcsCoversHeaderAndPadOnly`, `tx_clean_sweep` | model + sim | **green** (model) / pending-rtl (design) |
| R5 | IFG ≥ 96 bit times | `gem_rgmii_sva/a_ifg_respected`, `tx_clean_sweep` | assertion + sim | pending-rtl |
| R6 | Reject payload > 1500 B, never emit oversize | `tFrame/oversizePayloadIsRejected`, `tx_reject_oversize` | model + sim | pending-rtl |
| R7 | Sustain back-to-back frames at line rate | `tx_backpressure`, `random_tx_sweep` | sim | pending-rtl · see open item **V-1** |

## Traceability — receive

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R8 | Detect SFD anywhere; tolerate absent preamble | `tDeframe/findsSfdWithNoPreambleAtAll`, `tDeframe/findsSfdAfterFullPreamble`, `rx_trimmed_preamble`, `rx_min_gap` | model + sim | pending-rtl |
| R9 | Verify FCS, deliver with an EOF verdict | `tCrc32/residueIsConstant`, `tCrc32/residueRejectsCorruption`, `tFrame/goodFrameParsesClean`, `rx_clean_sweep`, `rx_bad_fcs` | model + sim | pending-rtl |
| R10 | Classify + count + recover from 4 error classes | `tFrame/classifiesBadFcs`, `tFrame/classifiesRunt`, `tFrame/classifiesOversize`, `tFrame/classifiesRxError`, `tFrame/classPrecedenceIsRuntOverBadFcs`, `tDeframe/goodFrameSurvivesAfterABadOne`, `rx_bad_fcs`, `rx_runt`, `rx_oversize`, `rx_rxer`, `rx_recovery_mix`, `gem_internal_sva/a_rx_recovers_in_budget` | model + sim + assertion | pending-rtl |
| R11 | Ignore inter-frame garbage silently | `tDeframe/ignoresInterFrameGarbage`, `tDeframe/dvBurstWithoutSfdIsReportedNotSilentlyDropped`, `rx_garbage`, `rx_bad_sfd` | model + sim | pending-rtl |
| R12 | *[stretch]* DA filter / promiscuous mode | — | — | n/a for v1 (B.7 non-goal until R12 is promoted) |

## Traceability — interfaces

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R13 | RGMII v2.0, 4-bit DDR at 125 MHz | `tRgmii/lowNibbleOnRisingEdge`, `tRgmii/controlEncodingTable`, `tRgmii/encodeDecodeRoundTrip`, `rgmii_bfm` (drives real DDR), every sim scenario | model + sim | **green** (model) / pending-rtl |
| R14 | Documented clock/data skew mechanism | — | bench + static timing | **open** · see **V-2** |
| R15 | Registered AXI-Stream, no combinational handshake paths | `gem_axis_sva` ×5 properties, bound to both ports | assertion | pending-rtl |
| R16 | MDIO/MDC master, ≤ 2.5 MHz | — | — | **open** · see **V-3** |
| R17 | Status/counter block, per error class | `counters_expected.txt` checked in all 14 scenarios | sim | pending-rtl |

## Traceability — performance and quality

| Req | What it requires | Test(s) | Level | Status |
|---|---|---|---|---|
| R18 | Line rate both directions, zero drops | `rx_min_gap`, `random_rx_sweep`, `random_tx_sweep` | sim | pending-rtl |
| R19 | Three clock domains, zero undeclared CDC | `tb_gem_mac_rx` drives `rx_clk` deliberately offset from `tx_clk`; `tb_gem_mac_loopback` re-emits on an independent `rx_clk` so the async FIFO is genuinely crossed; `report_cdc` at Stage 6 | sim + tool | pending-rtl |
| R20 | WNS ≥ 0 at 125 MHz, RGMII I/O constrained | Stage 6/7, `scripts/build.tcl` slack gate | tool | **open** (Stage 6) |
| R21 | RX MAC-added latency ≤ 32 cycles | `tb_gem_mac_rx` measures SFD→first beat on **every frame of every RX scenario** against `GEM_RX_LATENCY_MAX_CYCLES`; `tb_rgmii_bfm` verifies the timebase the measurement rests on | sim | pending-rtl |
| R22 | Verilator lint clean, zero warnings | `make lint` (`scripts/lint.py`), Verilator 5.032 | tool | **green** — 2 tops, zero warnings; gate verified to fail on an injected width mismatch |
| R23 | Zero inferred latches | `scripts/build.tcl` latch gate (Stage 2) | tool | **green** (gate in place since Stage 2) |
| R24 | Bit-exact vs the golden model; no negative slack | `make regress` + `scripts/build.tcl` slack gate | sim + tool | pending-rtl |

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
| `tx_clean_sweep` | tx | R1 R2 R4 R5 R13 | frame assembly, compared at cycle granularity |
| `tx_padding` | tx | R3 | payloads either side of 46 octets |
| `tx_reject_oversize` | tx | R6 | 1501 B in, **nothing** on the wire |
| `tx_backpressure` | tx | R7 R15 | tready deasserted between frames |
| `random_rx_sweep` | rx | R8–R11 R17 | 600 frames, every corruption × the length set |
| `random_tx_sweep` | tx | R1 R3 R5 R7 | 600 frames across the full length range |

The first fourteen are frozen: their vectors are committed, so they are readable
in review and runnable without MATLAB. The two `random_*` sweeps regenerate
bit-identically from the seed in their manifest and are git-ignored.

### Coverage criterion for "done"

From B.4, checked mechanically rather than by reading the table and hoping:

- every requirement R1–R21 has ≥ 1 named test — the tables above;
- every error class appears in at least one frozen scenario —
  `tGenerator/everyErrorClassIsExercisedSomewhere` fails if one does not;
- every corruption type crossed with {min, typical, max} length —
  `random_rx_sweep`;
- the whole regression is green from one command.

---

## Current status

| Layer | Result |
|---|---|
| Golden model test suite | **55 / 55 passing** |
| Scenario generation | 16 / 16, every generator self-check agrees with the model |
| Committed vectors vs the model | **42 / 42 files current** |
| BFM self-test | **passing** — 3522 checks, the only run with no DUT in it |
| Frozen regression vs `gem_mac_stub` | 0 / 16 passing — **expected**, there is no design yet |

The regression failing against a port-only stub is the Stage 3 result, not a
problem to fix. What was being checked is that the plumbing runs end to end and
that failures are legible, and running it found two real defects in the harness
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

---

## Open items

| # | Item | Why it is open | Plan |
|---|---|---|---|
| **V-1** | TX behaviour when the user stalls mid-frame is unspecified | At 1 byte/cycle with no slack (B.3), a MAC that has started a frame cannot pause. It must either buffer whole frames before starting — latency plus a BRAM the resource budget does not carry — or underrun and abort with TX_ER. R7 only promises line rate "when user logic supplies data every cycle" and is silent on the alternative. | Decide **before** the TX datapath is written in Stage 4, then add a `tx_underrun` scenario. The generator deliberately does not guess: `gem.genTxScenario` stalls only between frames. |
| **V-2** | R14's RGMII skew cannot be simulated | The 1.6 ns `GTX_CLK` phase shift is an I/O timing property. Simulation will pass with any phase; only static timing analysis and a scope on the bench can confirm it. | Stage 6 `report_timing` on the constrained I/O paths, then bring-up step 5 with an ILA or scope on `GTX_CLK`/`TXD0`. |
| **V-3** | R16 MDIO has no test | The MDIO master is an independent block on a different interface; there is no golden-model work it shares. | Add `tb_mdio.sv` with a PHY register-file BFM when the module is written (Stage 4), checking the 64-cycle Clause 22 transaction and the ≤ 2.5 MHz MDC bound. |
| **V-4** | ~~R22's lint gate cannot run~~ | **Closed.** Verilator 5.032 installed under WSL; `scripts/lint.py` bridges to it from Windows and falls back to a native binary elsewhere. Both design tops lint clean under `-Wall`, and the gate was verified to fail by injecting a width mismatch — it caught that plus the unused signal and exited nonzero. `make check` now runs it. | — |
| **V-5** | ~~R21's latency is specified but not measured~~ | **Closed.** `gem.expectedBeats` now emits each frame's `sfdCycle`, the driver exposes when cycle 0 was launched, and `tb_gem_mac_rx` converts the two into a per-frame cycle count checked against `GEM_RX_LATENCY_MAX_CYCLES`. The worst measured latency is printed on every run even when it passes, so erosion against B.1b's predicted 13 is visible before it becomes a violation. | — |
| **V-6** | The golden CRC is not yet checked against a real capture | B.4 asks for validation against a Wireshark capture; the board is not in hand. Validation is currently the published check value, Python's `zlib` over 2000 vectors, and the residue property. | Close at bring-up step 5 by capturing a frame the design transmitted and confirming Wireshark reports its FCS correct. |
| **V-7** | R12 (DA filter) has no test | Stretch requirement, not implemented. | Promote out of B.7's non-goals or leave explicitly unimplemented at release. |
| **V-8** | The latency *measurement* has never measured a real number | The arithmetic is exercised only when a design delivers beats, and the stub delivers none. `tb_rgmii_bfm` verifies the `t0` timebase it rests on (1764 cycles checked), so the input is sound — but the subtraction itself is unproven. | It will be exercised by the first RTL that delivers a frame, in Stage 4. Sanity-check the first number reported against B.1b's predicted 13 rather than only against the 32-cycle ceiling. |
| **V-9** | Two lint suppressions live in `rtl/gem_mac_stub.v` | `UNUSED` (every input is deliberately unconnected — that is what makes it a stub) and `DECLFILENAME` (the module must be named `gem_mac` for the testbenches while the file is named for what it is). Both are justified in the source, which is what R22 permits. | Both are deleted, not carried forward, when Stage 4 replaces the stub with `rtl/gem_mac.v`. If either survives into real RTL, that is a finding. |

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
