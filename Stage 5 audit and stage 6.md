# Stage 5 & Stage 6 Audit

*Independent audit performed 2026-08-24, after task 4e / spec v0.15
(commits `3be89aa`, `d036451`). Three parallel reviewers with disjoint
scopes: (1) the Stage 6 part 2 RGMII timing document chain, (2) Stage 5
deliverables against B.5/B.6/B.1a, (3) Stage 6 build infrastructure and
gates. Research-only; no builds were run by the auditors except the host
unit tests.*

## Verdict

| Area | State |
|---|---|
| Stage 5 deliverables | **All exist and match their claims** (`gem_top`, `gem_echo` store-and-forward w/ DA-SA swap, clock-reset block, UART readout snapshot semantics, `sw/host` — 15 unit tests pass hardware-free). Prose counts drifted behind the v0.14 `rxlock` field addition. |
| Stage 6 gates | **Every spec-claimed gate exists with claimed behavior**, including the new fenced waiver (fresh-eyes code review found no defects). Two claims about *reports* are false: `report_cdc`/gate 4 never implemented; README still says the build refuses. |
| Stage 6 part 2 doc chain | Coherent at the sign-off level (WNS −2.109 → −3.109 trajectory, waiver described identically five ways), but the derivation's own printed equation is broken in two of its three copies, and one live derivation document was never rewritten. |

## Critical

**C1. The capture-edge equation prints results inconsistent with its own
inputs — and differently across documents.** The deskew loop equation
`1.200 + IBUF+ccio + fwd − fb` yields **+2.150 fast / +3.836 slow** after
the data transition (= **+0.950/+2.636** after the pin's nominal edge).
`rtl/gem_rx_mmcm.v` states it correctly; `task-4e-report.md` §2 and the
Deskew Design Rev 3 addendum print the same inputs with the pin-relative
results and a label matching neither frame. Downstream numbers (skews,
margins, trim window) are internally consistent with the pin-relative
frame, so this is presentation — but as written the R20 sign-off
derivation contains an equation false on its face and disagreeing between
copies. Fix: pick one reference frame everywhere (drop the `1.200 +`
term, or keep it and print 2.150/3.836).

**C2. `Documents/RGMII I-O Timing Derivation.md`'s RX section is still the
retracted pre-task-4a derivation** (`max = 3.000 / min = −1.000` at zero
phase — what task 4a proved wrong and v0.14 retracted), while
`constrs/rgmii_timing.xdc` cites it as its derivation while carrying
0.200/−1.800. Task-4b Step 7's promised rewrite never landed. Fix: rewrite
the RX section to the current constraint set plus the deskew MMCM and −45°
trim state.

**C3. Spec B.1b still declares the TX phase ≈ −72° / 1.6 ns in six places;
the committed design is −55° / 1.222 ns** (`rtl/gem_mmcm.v`; R14 row in
verification_plan even records "−72° was never achievable"). Also
`spec/block_diagram.md`. Fix: sweep to −55°/1.222 ns.

**C4. Stage 5: spec B.1a asserts a testbench property the RTL and TB both
now contradict.** B.1a says `tb_gem_clk_rst` checks "`rx_rst_n` not
depending on the MMCM at all"; since Stage 6 part 2 `rx_rst_n` releases
gated on `tx_rst_n & rx_mmcm_locked` and the testbench explicitly retires
that property and checks its opposite. B.1b was amended for the reset
architecture; the B.1a bullet was not.

**C5. `report_cdc`/`report_methodology` ("gate 4") does not exist anywhere,
but R19 claims CDC is "(checked by report_cdc)"** and verification_plan
says it "now has the reset synchronisers to look at". Part 2's plan defined
gate 4 and its exit criteria require it passing with a planted-defect
demonstration; no task-5 report exists. Either implement gate 4 or correct
R19/the plan honestly.

## Important

**I1. README's "Known issue" block is now false** — says impl/bitstream
refuse at gate 2 (~−2.1 ns structural); since 3be89aa/d036451 the build
passes via the fenced waiver. Anyone reading README will distrust a green
build.

**I2. Record-format counts frozen pre-`rxlock`.** Spec B.7 example shows 13
fields but says "192 characters" (it measures 208) and "12 × 32-bit"
(`N_FIELDS = 13`); `sw/host/README.md` documents a record **without**
`rxlock` that its own parser rejects as missing-field; module docstring and
README sample records likewise pre-date `rxlock`.

**I3. V-23 is dangling** — created by task-4b, silently absorbed by V-24;
no supersession recorded, and Deskew Design still instructs updating it.

**I4. Deskew Design Step 0 still forbids the fix that shipped** ("do not
reach for the phase trim…"); under the corrected physics a static shift
*does* close, and −45° is exactly that. The Rev 3 addendum amends Step 2c
and the phase-0 derivation but not Step 0.

**I5. Spec B.4's gate enumeration is stale**: "six conditions" vs today's
seven-plus refusals, and "negative setup or hold slack" is no longer an
unconditional refusal post-waiver. Also "every one has been observed to
fail": gate 0b and gate 1c have no recorded refusal demonstrations.

**I6. stage6_plan exit criteria partially unsatisfiable/stale**: criterion
3 describes gate 3 *listing* unconstrained ports — part 2 deliberately made
it refuse; criterion 5's planted-defect half of gate 0 has no committed
evidence (only the natural defect).

**I7. RTL header hold margins mis-stated**: `gem_rx_mmcm.v` says "hold
+0.68/+1.12"; correct fast/slow order is **+1.12/+0.67** (as printed it
duplicates setup's fast value and understates worst-hold).

**I8. verification_plan: V-24/V-25 rows sit outside the open-items table
and literal tabs corrupt V-25's cells** (`tlast`→`last`, `rx_path_rst_n`
split across lines).

**I9. README's gate accounting omits gate 1c and gate 0b**, and the
"Proven by" table lacks rows for the critical-warning gate and the waiver
fences whose demonstrations are recorded in d036451.

## Minor

- task-4e hold-slow margin −0.327 should read −0.331 (one-number fix; the
  window/trim-centre already use −0.331).
- task-4e §2 has a spliced half-sentence editing remnant.
- Stale "1.6 ns" comments adjacent to scope: `gem_mac.v`, `gem_rgmii_tx.v`,
  `gem_iddr.v`, `gem_oddr.v` headers.
- D6/D7 deferral tracked only inside history reports; no live tracker (D8
  has V-25).
- `pins.xdc` header says "pin locations only" but carries the RX pblock.
- `synth_module.tcl` hardcodes "125 MHz" in its WNS message regardless of
  the module's actual clock; prints WNS before validating it (cosmetic).
- `build.tcl` `gem_check_unconstrained` regex requires a following section
  heading; latent fragility if section order ever changes (fails safe).
- Skeleton builds refusing quote the RX-waiver explanation verbatim —
  correct direction, confusing wording on a blinker.
- README M3: gate-table parenthetical "(B.1b forbids it)" — B.1b now
  explicitly permits lock-gated resets via the clk50 exception.
- Spec R20 row could cross-reference the waiver instead of standing bare.

## Verified clean (highlights)

- All Stage 5 deliverables exist and behave as specified; echo is genuinely
  store-and-forward good-only with DA/SA swap; stat_report snapshots all 13
  fields in one cycle; uart_tx divisor derived from parameters; host tests
  run stdlib-only and pass (15/15).
- Every gate the spec enumerates exists with claimed behavior; gate order
  (coverage before slack) preserved; synth_module budget checks match B.2.
- Waiver code survived fresh-eyes review: quoting, `lassign`, `+inf`
  sentinel, NAME-fallback, skeleton fail-safe all sound.
- Constraint↔RTL consistency: anchor path, five waiver endpoints, TX
  gen-clock wildcard, pblock cells, async group with generated clocks.
- `.gitattributes` catch-all correctly precedes the vector pin; part string
  single-sourced; Makefile↔build.py↔build.tcl contract coherent.
- WNS trajectory −2.109 → −3.109 and the waiver description are consistent
  across every current-truth document.

## Not statically verifiable (needs a run)

stage6_plan exit criteria 1 (autocrlf clone), 2 (`make check` count),
3/4 (both bitstreams build), and part-2's report-vs-truth comparisons.
`make check` was last run green (29/29) at commit time.

## Suggested fix order

1. C1 + I7 (sign-off arithmetic presentation — same commit).
2. C2 (derivation doc rewrite — the one live document contradicting the XDC).
3. C3 + minors around 1.6 ns remnants.
4. C4 + I2/I3/I8 (prose counts, V-23/V-25 hygiene).
5. C5 (implement gate 4 or correct R19/plan — owner call).
6. I1/I6/I9 + minors (README/plan staleness sweep).
