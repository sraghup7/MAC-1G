# RX Clock Deskew Design

*The design for an MMCM-based deskew of `rgmii_rx_clk`, and the reset/lock
semantics it forces. Written before any RTL, because the reset question an MMCM
on a **recovered** clock reopens is harder than the one `rtl/gem_clk_rst.v`
already answered, and getting it wrong produces a MAC that stops receiving
frames after a link flap — a failure nothing in this repository's regression
would notice.*

*Task 4c of Stage 6 part 2. Task 4d implements what this document decides.*

*Revision 2, after design review. The review confirmed Step 1's topology, Step
2's arithmetic, the "MMCM does not self-recover" finding and the supervisor's
own arithmetic, and found three Critical defects in the safety analysis. The
largest — that this design is the first thing in the project able to reset the
two halves of `gem_rx_fifo` asymmetrically — is now **Step 3b**, and it is the
most important section in this document. Revision 1 asserted the opposite
without checking, and that assertion was false.*

---

## What this document decides

| Question | Decision |
|---|---|
| Feedback topology | `CLKFBOUT → BUFG → CLKFBIN`; **one** forward `BUFG` off `CLKOUT0` carries both the IDDR capture clock and the whole fabric side of the `rx_clk` domain |
| `rtl/gem_rx_clkbuf.v` (Task 4b's BUFIO/BUFR module) | **Replaced outright.** Not kept, not coexisting. A `BUFIO`/`BUFR` cannot be deskewed |
| MMCM configuration | `D = 1`, `M = 9.000`, VCO = **1125 MHz**, `CLKOUT0_DIVIDE_F = 9.000` → 125 MHz, `CLKOUT0_PHASE = 0.000` |
| Predicted lock time | **≤ 100 µs** (`MMCM_TLOCKMAX`, DS181 Table 37) — a datasheet **bound**, not a typical |
| Worst-case RX recovery after a link returns | **≈ 428 µs** — retry period (327.68 µs) + lock time (100 µs). *Not* 100 µs |
| MMCM reset supervisor | A state machine **clocked by `clk50`**, with a **registered** reset output |
| `rx_rst_n` | Moves to the **deskewed** clock and becomes lock-gated: `arst_n = tx_rst_n & rx_mmcm_locked` |
| **`rx_path_rst_n` (new)** | **A second reset, in the `tx_clk` domain, covering the destination half of every crossing out of the RX domain.** Without it a link drop delivers stale FIFO contents as fabricated frame data. See Step 3b |
| Gap 1 (residual insertion delay) | **Architecture-deciding, not margin-affecting.** Task 4d's *first* action is a go/no-go measurement. Fallback worked out in Step 2c |
| B.1b self-check | **Violated, justified, spec amended.** The safety argument (no deadlock) holds; the framing in revision 1 did not |

---

## Where this came from

Three findings, in order, each the foundation of the next. Task 4a's and
Task 4b's reports are committed at
[`docs/reports/stage6-part2/`](../docs/reports/stage6-part2/); other task
reports cited below (2d, 2e) live in the session working papers under
`.superpowers/sdd/2026-08-19-stage6-part2-rgmii-timing/` and are not part of
the repository.

1. **[`docs/reports/stage6-part2/task-4a-report.md`](../docs/reports/stage6-part2/task-4a-report.md)** — the RX hold check had never been measuring a real
   capture event. Giving it the right phase made it real, and it failed by
   ~0.99 ns of combined setup+hold budget. That deficit is **invariant** under
   every choice of clock phase and input-delay value: it is set by the RX clock
   network's min/max insertion-delay spread, not by the constraint.
2. **[`docs/reports/stage6-part2/task-4b-report.md`](../docs/reports/stage6-part2/task-4b-report.md)** — the textbook `BUFIO`/`BUFR` fix was built and
   measured. It recovered 1.47 ns of hold on every port and still refused, and
   in the process corrected 4a's acceptance criterion. The requirement is
   **two-sided**, on the design's own pin-to-IDDR clock-minus-data insertion
   difference `skew`:

   ```
   setup passes  iff  skew_fast >= -(TsetupR - unc + tsu)   = -0.977 ns
   hold  passes  iff  skew_slow <=  (TholdR  - unc - thold) = +0.784 ns
   ```

   The declared phase and both input delays cancel out of both. The measured
   intervals: `BUFG [1.069, 3.815]`, `BUFIO/BUFR [0.584, 2.343]`. The second
   *fits* inside the 1.761 ns-wide window and still *sits* 1.559 ns too late.
3. **The binding term is now the `BUFIO` cell itself** — 1.049 ns of
   corner-to-corner spread on this `xc7a35tifgg484-1L` part. No placement or
   wiring change touches it. Buffering without deskew has run out.

The remaining lever is the one 4a named as option 2 and 4b quantified: cancel
the clock network delay instead of tolerating it.

---

## Step 1: the feedback-deskew topology

### What UG472 actually says

Citations are to **UG472 v1.13 (March 1, 2017)**, by section title and page.

**"Clock Network Deskew", Ch. 3 *General Usage Description*, p.72:**

> In many cases, designers do not want to incur the delay on a clock network in
> their I/O timing budget therefore they use a MMCM/PLL to compensate for the
> clock network delay. 7 series FPGAs support this feature. A clock output
> matching the reference clock CLKIN frequency (always CLKFBOUT) is connected to
> a BUFG in the same half of the device and fed back to the CLKFBIN feedback pin
> of the MMCM/PLL.

**"CLKFBIN – Feedback Clock Input", p.80:**

> Must be connected either directly to the CLKFBOUT for internal feedback or
> IBUFG (through a clock-capable pin for external deskew), BUFG, BUFH, or
> interconnect (not recommended). For external clock alignment, the feedback
> path clock buffer type should match the forward clock buffer type **with the
> exception of BUFR. BUFR cannot be compensated for.**

**"Clock Network Deskew", Ch. 3 *MMCM and PLL Use Models*, p.93:**

> There are certain restrictions on implementing the feedback. The CLKFBOUT
> output can be used to provide the feedback clock signal. **When an MMCM is
> driving both BUFGs and BUFH, only one of the clock buffers that is also used
> in the feedback path is deskewed.**

Read together:

* The legal drivers of `CLKFBIN` are `CLKFBOUT` direct, `IBUFG`, `BUFG`, `BUFH`,
  or interconnect. **`BUFIO` is not on that list at all**, and `BUFR` is on it
  only to be excluded by name.
* Compensation is defined against the *buffer type in the feedback path*. A
  clock leaving the MMCM through a buffer of a different type is not deskewed —
  UG472 states this as a restriction, not as a caveat.

### The decision

**One forward `BUFG` off `CLKOUT0`, driving the IDDR `C` pins and the fabric
side of the domain together; a second `BUFG` in the feedback path from
`CLKFBOUT` to `CLKFBIN`.** This is UG472 Figure 3-11 verbatim, which the text
calls "the most flexible" configuration at the cost of two global clock
networks.

The IDDR needs no special treatment, and could not be given any that helped: the
only buffer that can reach `ILOGIC`'s clock without going through the global
network is a `BUFIO`, and a `BUFIO` is exactly what cannot be deskewed. There is
no topology in which the capture clock is both regionally-buffered and
compensated. The two goals are mutually exclusive on this silicon.

That the IDDR `C` pin can be driven from a `BUFG` is not an assumption: it is
what this design did before Stage 6 part 2, and `task-4a-report.md` measured the
routed path segment by segment (`net BUFG→IDDR (fo=142)`, 0.585 ns fast /
1.665 ns slow) to the IDDR `C` pins.

### What happens to `rtl/gem_rx_clkbuf.v`

**Replaced. It does not survive in any form, and it must not coexist with the
MMCM.**

Task 4b's own concern 3 flagged "redundant rather than additional" as a
possibility. It is stronger than redundant: keeping a `BUFIO` on the capture
clock alongside the MMCM would give the IDDRs an *un-deskewed* clock while the
fabric got a deskewed one, which is the current failing design plus a large,
deliberate intra-domain skew — strictly worse than either option alone.

The module is not in the working tree (it was uncommitted and reverted along
with a stalled attempt), so nothing needs deleting. Its full text is preserved
in `task-4b-report.md` Step 2. Task 4d should not re-create it.

One consequence worth naming, because Task 4b spent a paragraph checking it and
the answer flips: 4b left `gem_clk_rst`'s reset synchroniser on its own inferred
`BUFG` while the MAC ran on `BUFR`, then measured that crossing safe (`+2.518`
setup, `+1.185` hold). **That measurement does not carry over.** Under the
deskew the raw and deskewed nets are several nanoseconds apart *by
construction* — removing that offset is the entire point — so `u_rx_rst` must
move onto the deskewed clock rather than stay on the raw pin.

---

## Step 2: the MMCM configuration

### 2a. The device's own limits, from DS181

`scripts/part.tcl` sets `PART = xc7a35tifgg484-1L`, which is DS181's **-1LI**
column (0.95V). DS181's introduction: *"The -1LI devices operate only at
V<sub>CCINT</sub> = V<sub>CCBRAM</sub> = 0.95V and have the same speed
specifications as the -1 speed grade."*

DS181 (v1.27, February 10, 2022) Table 37, "MMCM Specification", -1LI column:

| Symbol | Description | Value | Our value | |
|---|---|---|---|---|
| `MMCM_FINMIN` | Minimum input clock frequency | 10.00 MHz | 125 MHz | ✓ |
| `MMCM_FINMAX` | Maximum input clock frequency | 800.00 MHz | 125 MHz | ✓ |
| `MMCM_FINJITTER` | Maximum input clock period jitter | *< 20% of clock input period or 1 ns Max* | see 2b | flagged |
| `MMCM_FINDUTY` | Allowable input duty cycle, 50–199 MHz | 30 % | see 2b | flagged |
| `MMCM_FVCOMIN` | Minimum VCO frequency | 600.00 MHz | 1125 MHz | ✓ |
| `MMCM_FVCOMAX` | Maximum VCO frequency | **1200.00 MHz** | 1125 MHz | ✓ |
| `MMCM_FPFDMIN` | Minimum frequency at the PFD | 10.00 MHz | 125 MHz | ✓ |
| `MMCM_FPFDMAX` | Maximum frequency at the PFD | 450.00 MHz | 125 MHz | ✓ |
| `MMCM_TLOCKMAX` | **MMCM maximum lock time** | **100.00 µs** | — | a bound, see below |
| `MMCM_RSTMINPULSE` | Minimum reset pulse width | **5.00 ns** | 80 ns | ✓ |
| `MMCM_TFBDELAY` | Maximum delay in the feedback path | *3 ns Max or one CLKIN cycle* | must check | 4d |
| `MMCM_TSTATPHAOFFSET` | Static phase offset of the MMCM outputs | 0.12 ns | counted in 2c | ✓ |
| `MMCM_TOUTDUTY` | Output duty-cycle precision (incl. global buffer) | 0.20 ns | tool models it | — |

`MMCM_FVCOMAX = 1200 MHz` for -1/-1LI independently confirms the 600–1200 MHz
range `rtl/gem_mmcm.v`'s header already asserts. It is **not** a family-wide
number: -3 is 1600 MHz and -2 is 1440 MHz.

**`MMCM_TLOCKMAX` is a datasheet maximum, not a typical.** It is a flat number,
identical in every speed-grade column and independent of M, D and the input
frequency, which is what a guaranteed bound looks like. Vivado's Clocking Wizard
reports a *computed* lock time for a specific configuration that is usually far
below it. Every latency figure in this document uses the 100 µs bound, because a
design must be built against the guarantee; do not be surprised when the bench
shows something much faster, and do not re-tune the supervisor to the faster
number.

### 2b. The arithmetic, the ppm figure, and the jitter figure

```
  F_IN      = 125 MHz (8.000 ns), the recovered RGMII receive clock
  PFD       = F_IN / DIVCLK_DIVIDE(1)          = 125 MHz
              inside [MMCM_FPFDMIN 10, MMCM_FPFDMAX 450]      ✓
  VCO       = F_IN x CLKFBOUT_MULT_F(9.000) / DIVCLK_DIVIDE(1)
            = 1125 MHz
              inside [MMCM_FVCOMIN 600, MMCM_FVCOMAX 1200]    ✓
  CLKOUT0   = 1125 MHz / CLKOUT0_DIVIDE_F(9.000) = 125 MHz    ✓
  CLKFBOUT  = 1125 MHz / 9                       = 125 MHz
              = PFD, which is UG472 Equation 3-11's requirement
              that both PFD inputs be identical                ✓
```

**Why `M = 9` and not `M = 8`.** Both are legal (`M = 8` gives a 1000 MHz VCO).
A higher VCO gives lower output jitter and a finer static phase-shift grid
(`SPS = 1/(8 F_VCO)` = **111.1 ps** at 1125 MHz against 125.0 ps at 1000 MHz,
UG472 Equation 3-3), and 1125 MHz is the VCO `rtl/gem_mmcm.v` already runs and
already documents the arithmetic for, so a reviewer checking one is checking the
grid of both. The 75 MHz of headroom to the 1200 MHz ceiling is 600 000 ppm
against an input specified to ±100 ppm — the frequency-offset question is not
close. (Note for Step 2c: `M = 8` / VCO 1000 MHz is *also* the only VCO that
could serve an integer-divided 200 MHz IDELAYCTRL reference. It cannot serve
both that and this MMCM's job, because this MMCM has no spare output to give.)

**`CLKOUT0_PHASE = 0.000` is a derivation, not a default.** The deskew puts the
capture edge back at the clock's arrival time at the pin. The KSZ9031RNX already
delays `RX_CLK` by 1.2 ns relative to `RXD`/`RX_DV` (B.1b, default, out of
reset, no MDIO write), so the capture edge lands 1.2 ns into a guaranteed eye
running from 0.2 ns to 2.2 ns after the nominal data transition — its geometric
centre. Task 4b's window `[-0.977, +0.784]` is centred at −0.097 ns, so zero is
within 0.1 ns of optimal. **No phase shift is wanted.** If Task 4d's measurement
shows the interval off-centre, trim is available in 111.1 ps steps, subject
unchanged to `gem_mmcm.v`'s header warnings: the grid is `k × VCO_period/8`,
`CLKOUT0_PHASE` must be an exact multiple of `45°/CLKOUT0_DIVIDE = 5°`, and
`CLKOUT0_USE_FINE_PS` is not a way past it.

**The ±100 ppm figure is right for one question and wrong for the other.**
`spec/PROJECT_SPEC.md` B.3a carries **±100 ppm each side**, sourced to *IEEE
802.3-2022 Clause 40 (1000BASE-T transmit clock tolerance)*, already used for
the RX FIFO's drift budget.

* **Frequency offset — yes, B.3a's number, and it is harmless.** ±100 ppm on a
  125 MHz input moves the PFD by ±12.5 kHz and the VCO by ±112.5 kHz. Both stay
  inside DS181's ranges by five orders of magnitude. And because `CLKIN` and
  `CLKFBIN` both derive from the same physical clock, UG472 p.83's lock
  criterion — *"frequency matching within a predefined PPM range"* — compares
  the clock against itself and is satisfied identically at any input frequency
  in range. A static frequency offset is simply tracked; that is what a PLL is.
  B.3a's figure is confirmed sufficient and is not re-derived.
* **Jitter — no. ppm is frequency accuracy, not cycle-to-cycle variation, and
  B.3a's number cannot serve as `REF_JITTER1`.** The sourced *limit* is
  `MMCM_FINJITTER` = *"< 20% of clock input period or 1 ns Max"*. At an 8 ns
  period, 20% is 1.6 ns, so the binding cap is the **1 ns** absolute — expressed
  as a fraction of the input period that is **0.125 UI**, the largest
  `REF_JITTER1` the part is specified for. What the KSZ9031RNX's recovered
  `RX_CLK` actually carries is not a number this project has. `REF_JITTER1`
  is therefore **0.010** — the primitive default `rtl/gem_mmcm.v` already uses —
  explicitly recorded as unverified. Acceptance criterion A requires the design
  to be measured at **both** 0.010 and the 0.125 ceiling, because `REF_JITTER1`
  feeds Vivado's clock-uncertainty modelling on the derived clock and an
  understatement makes the reported margin optimistic. See criterion A.
* **Duty cycle — flagged, not confirmed.** `MMCM_FINDUTY` for the 50–199 MHz
  band is 30%, i.e. the input must stay inside 30–70%. That is a wide window and
  a recovered RGMII clock would have to be badly distorted to leave it, but this
  project has no measured or datasheet duty-cycle figure for the KSZ9031RNX's
  `RX_CLK`, and A.2 already flags that datasheet as read online and unverified
  against the physical part. Recorded as satisfied-by-expectation, not checked.

**`BANDWIDTH`** is `"OPTIMIZED"`, matching `rtl/gem_mmcm.v`. `"LOW"` filters more
input jitter — attractive for a recovered clock — at the cost of increased
static offset (UG472 "Jitter Filter", p.73), and static offset comes straight out
of the skew budget derived below. The two settings therefore trade against each
other in *the same* budget and must be measured together, never one at a time.
If criterion A passes at `REF_JITTER1 = 0.010` but fails at 0.125,
`BANDWIDTH = "LOW"` is the lever to try, and the whole of criterion A must be
re-run with it.

### 2c. Gap 1: the residual, three readings, and why this is a go/no-go

**Revision 1 said "the design closes under either reading". That was wrong**: it
considered only two readings, both favourable. There is a third, it is the
physically-motivated one, and under it the design fails.

The MMCM's phase-frequency detector drives the loop until the `CLKFBIN` edge
coincides with the `CLKIN1` edge **at the MMCM's own pins**. That is the whole
mechanism, and everything follows from it:

```
  t(CLKFBIN) = t(CLKIN1)                                    the loop's fixed point

  t(fb BUFG out) + fb_net          = t(CLKIN1)
  t(fwd BUFG out) = t(fb BUFG out)                          same MMCM phase,
                                                            matched buffer type
  => t(IDDR C) = t(CLKIN1) - fb_net + fwd_net
```

The two `BUFG` **cell** delays cancel. The forward **net** does not cancel
against the feedback net unless the two are comparable — and structurally they
are not. `task-4a-report.md` measured the forward net (`BUFG → IDDR C`,
fanout 142) at **0.585 ns fast / 1.665 ns slow**. The feedback net is a fanout-1
route from a `BUFG` output back to one CMT.

Three readings, and what each predicts for the skew interval
`[skew_fast, skew_slow]` against the required `[-0.977, +0.784]`:

| Reading | Mechanism | Interval | Verdict |
|---|---|---|---|
| **Optimistic** (UG472 p.89 "MMCM Clock Input Signals": of `IBUFG`, *"the MMCM will compensate the delay of this path"*) | input `IBUF` cancelled too | narrower than below | passes easily |
| **Task 4b's** | insertion collapses to the input `IBUF` alone | `[-0.176, +0.082]`, 0.258 ns wide | passes, ~0.7–0.8 ns margin |
| **Pessimistic — the loop's actual fixed point** | residual = `IBUF + ccio_route + fwd_net − fb_net` | **roughly `[+0.3, +1.5]`** for a feedback net of 0.1–0.3 ns | **width fits, sits too high — hold fails by ~0.7 ns** |

The pessimistic case reproduces Task 4b's exact failure mode: an interval that
*fits* the 1.761 ns window and *sits* outside it. That is not a small-margin
question; it is the same wall this chain has already hit twice, and the numbers
in the third row are an order-of-magnitude estimate, not a measurement — the
feedback net's delay is unknown and I could not source it.

**Therefore: this is Task 4d's first action, before any other work, and it is a
go/no-go.** Build the MMCM, route it, read the segment-by-segment clock path to
the IDDR `C` pins, and compute the interval. Everything else in the checklist is
downstream of the answer. Do not proceed to the reset work on the assumption
that the timing closes.

Add `MMCM_TSTATPHAOFFSET` = 0.12 ns (DS181 note 2: *"The static offset is
measured between any MMCM outputs with identical phase"* — `CLKOUT0` and
`CLKFBOUT` are exactly that, so the deskew's own accuracy is bounded by it) to
whichever reading turns out to hold, as a ±0.12 ns widening.

### 2d. The fallback, worked out now rather than left for 4d to discover

If the measurement lands in the pessimistic region, the fix is **MMCM deskew
*plus* a fixed `IDELAYE2` on the five RX data pins**. This works where Task 4b
showed a bare `IDELAY` does not, and the reason is precise: 4b's objection was
that an `IDELAY` moves the interval without narrowing it, and the
`BUFIO`/`BUFR` interval was 1.759 ns wide against a 1.761 ns window, so there
was nowhere to move it *to*. The MMCM narrows the interval (the forward net's
1.080 ns spread partly cancels against the feedback net's), and a narrow
interval that sits wrong is exactly what an `IDELAY` fixes.

**The `IDELAYCTRL` reference clock is the hard part, and it has a clean answer.**
`IDELAYE2` requires an `IDELAYCTRL` with a continuously running, in-spec
reference. DS181 v1.27 Table 25, "Input/Output Delay Switching
Characteristics", -1LI column:

| Symbol | Value |
|---|---|
| `FIDELAYCTRL_REF` | **200.00 MHz** or **300.00 MHz** (400 MHz is *N/A* on -1/-1LI) |
| `IDELAYCTRL_REF_PRECISION` | **±10 MHz** |
| `TDLYCCO_RDY` | 3.67 µs reset-to-ready |
| `TIDELAYCTRL_RPW` | 59.28 ns minimum reset pulse width |
| `TIDELAYRESOLUTION` | `1/(32 × 2 × F_REF)`; note 1: **average tap delay at 200 MHz = 78 ps** |

32 taps at 78 ps gives ~2.4 ns of range — several times the ~1.5 ns of
re-centring the pessimistic case needs.

**Where the reference cannot come from, and why:**

* **Not the new RX MMCM.** `IDELAYCTRL`'s reference must run continuously; if it
  stops, `RDY` deasserts and every `IDELAY` sharing that controller loses its
  calibration. Sourcing it from the recovered clock would make the *data* path's
  delay depend on the link — the exact coupling this whole design exists to
  avoid, moved from the clock to the data.
* **Not the existing crystal MMCM, by integer division.** Its VCO is 1125 MHz.
  `1125/5 = 225`, `1125/6 = 187.5` — neither is inside 200 ± 10, and
  `1125/4 = 281.25`, `1125/3 = 375` miss 300 ± 10. More strongly: a VCO that
  yields **both** 125 MHz and 200 MHz by integer division must be a common
  multiple of the two, i.e. a multiple of 1000 MHz, and the only one inside the
  600–1200 MHz range is **1000 MHz** — precisely the configuration
   `task-2d-report.md` / `task-2e-report.md` (working papers, not committed)
   rejected, because its 5.625° phase
  grid could not place the TX `GTX_CLK` shift inside the PHY window with
  adequate margin (`rtl/gem_mmcm.v`'s header records the whole history). For a
  300 MHz reference the common multiple is 1500 MHz, outside the range
  entirely. **So no single MMCM on this device can serve both the TX phase
  requirement and an integer-divided `IDELAYCTRL` reference.** That is a
  complete result, not an estimate.
* **Fractional divide would work but is not worth the risk.** `CLKOUT0` supports
  fractional divide in eighths (UG472 "Frequency Synthesis Using Fractional
  Divide in the MMCM", p.73), and `1125/5.625 = 200.000 MHz` exactly, with
  `5.625 = 5 + 5/8` a legal eighth. But `CLKOUT0` is already `tx_clk`, so this
  means moving `tx_clk` to another output counter — perturbing the TX clocking
  that an entire sub-chain of tasks tuned to a **+0.058 ns** worst-case setup
  margin. Any perturbation there is dangerous. Rejected unless the option below
  is somehow unavailable.

**The answer: a dedicated `PLLE2_BASE` on `clk50`.** Checked against DS181 v1.27
Table 38, "PLL Specification", -1LI column:

```
  CLKIN   = clk50 = 50 MHz      inside [PLL_FINMIN 19, PLL_FINMAX 800]     ✓
  PFD     = 50 / 1  = 50 MHz    inside [PLL_FPFDMIN 19, PLL_FPFDMAX 450]   ✓
  VCO     = 50 x 20 = 1000 MHz  inside [PLL_FVCOMIN 800, PLL_FVCOMAX 1600] ✓
  CLKOUT0 = 1000 / 5 = 200 MHz  -> IDELAYCTRL REFCLK, inside 200 +/- 10    ✓
```

A `PLLE2` rather than an MMCM because the PLL is the less scarce of the two
resources in a CMT and none of the MMCM's extra capability is needed here. It is
fed from `clk50`, which never stops, so `IDELAYCTRL.RDY` is stable from ~104 µs
after power-up (`PLL_TLOCKMAX` 100 µs + `TDLYCCO_RDY` 3.67 µs) — long before any
link exists. `IDELAYCTRL` and the `IDELAYE2`s must share an `IODELAY_GROUP`
property, and the RX pins are all in bank 15.

**This fallback is designed but not built.** It is here so that a bad
measurement in 2c has a worked-out next step with sourced numbers rather than an
open question. Building it is a separate task from 4d if it is needed.

### 2e. Primitive choice, and two parameter traps

**`MMCME2_BASE`**, matching `rtl/gem_mmcm.v`, with `STARTUP_WAIT = "FALSE"`.

`CLKINSTOPPED` — which would let logic distinguish "the input clock is gone"
from "present but unlockable" — exists only on `MMCME2_ADV`. It is not needed:
UG472 "Missing Input Clock or Feedback Clock" (p.91) says `LOCKED` deasserts in
both cases, and the supervisor in Step 3 keys off `LOCKED` alone. It also could
not be used to *trigger* the recovery reset even if present, because UG472
p.83 says `CLKINSTOPPED` *"is deasserted after the clock has restarted and
LOCKED is achieved"* — it clears only after the thing the reset is needed to
produce. The `MMCME2_ADV` upgrade remains available at no behavioural cost:
`D:/Vivado/2024.2/data/verilog/src/unisims/MMCME2_BASE.v` is literally an
`MMCME2_ADV` instantiation with `CLKINSTOPPED`/`CLKFBSTOPPED` on unused nets and
the DRP/phase-shift ports tied off, so the silicon behaviour of the two is
identical and only the visibility differs.

**`STARTUP_WAIT` must be `"FALSE"`, and this is load-bearing rather than a
copied default.** `TRUE` makes the FPGA's startup sequence wait for this MMCM to
lock. On a recovered clock that does not exist until a cable is plugged in,
`TRUE` would hold the entire device out of startup until a link came up — a
bricked board with no link and no way to diagnose it.

**Do not set `CLOCK_DEDICATED_ROUTE FALSE`** on any net in this design. It is
the standard first answer to the placer error a clock-capable-pin-to-MMCM path
can raise ("Poor placement for routing between an IO pin and BUFG/MMCM"), it
makes the error go away, and it does so by permitting the tool to route the
clock on general interconnect — degrading precisely the insertion delay this
entire design exists to control, silently and invisibly in the slack numbers.
If that error appears, fix the placement or the pin choice. Never the property.

---

## Step 3: reset and lock semantics

### 3a. The sentence the design turns on

**UG472 "LOCKED", p.83:**

> An output from the MMCM/PLL used to indicate when the MMCM/PLL have achieved
> phase and frequency alignment of the reference clock and the feedback clock at
> the input pins. […] The MMCM automatically locks after power on, no extra
> reset is required. **LOCKED will be deasserted within one PFD clock cycle if
> the input clock stops, the phase alignment is violated (for example, input
> clock phase shift) or the frequency has changed. The MMCM/PLL must be reset
> when LOCKED is deasserted.** The clock outputs should not be used prior to the
> assertion of LOCKED.

**UG472 "Missing Input Clock or Feedback Clock", p.91:**

> When the input clock or feedback clock is lost, the CLKINSTOPPED or
> CLKFBSTOPPED status signal is asserted. The MMCM deasserts the LOCKED signal.
> **After the clock returns, the CLKINSTOPPED signal is deasserted and a RESET
> must be applied.**

Corroborated *structurally* in Xilinx's shipped simulation model,
`D:/Vivado/2024.2/data/verilog/src/unisims/MMCME2_ADV.v`. The relevant block
(lines 2972–2982) is:

```verilog
  always @(posedge clkinstopped_out1 or posedge rst_int)
    if (rst_int)
      clkinstopped_out_dly <= 0;          // the ONLY unconditional clear
    else begin
       clkinstopped_out_dly <= 1;
       if (clkin_hold_f == 1) begin       // never true -- see below
         @(negedge rst_clkinstopped_rc or posedge rst_int)
           clkinstopped_out_dly <= 0;
       end
    end
```

`clkin_hold_f` is declared `reg clkin_hold_f = 0;` (line 1229) and is **never
assigned anywhere in the 4506-line file**, so the guarded branch is unreachable
and `rst_int` is the only thing that can clear `clkinstopped_out_dly`. Line 3765
makes `pll_unlock` include that signal, and the `LOCKED_out` block (line 2707)
drives `LOCKED` low whenever `pll_unlock` is set. So in the vendor's own model,
**`LOCKED` is provably stuck low until `RST` is applied** — a structural proof,
not merely the accompanying `$display` warning ("Input CLKIN1 is stopped […]
Reset is required when input clock returns", line 2938).

**Scope of the claim, stated precisely.** The MMCM does not self-recover **from
a stopped input clock or a stopped feedback clock**. That is narrower than "an
MMCM never self-recovers", which would be false: `pll_unlock` also includes
`clkpll_jitter_unlock` and `unlock_recover`, and the model's `unlock_recover`
path (lines 2586–2621) does clear itself, so a *jitter-only* unlock recovers
without external help. The supervisor below is a safe superset — it resets on
any unlock — but the claim it is justified by is the narrow one, and the narrow
one is the case this design actually faces.

**The consequence, and it is this task's headline.** An MMCM on a clock that can
disappear needs something to reset it, and that something cannot be clocked by
`rgmii_rx_clk` (gone), by the MMCM's own output (gone with it), or by anything
gated on `rx_rst_n` (asserted). It must run on `clk50` — which
`rtl/gem_clk_rst.v` already calls, about the PHY reset counter, *"the only clock
guaranteed to be running at that point"*, and declares as *"free-running, never
gated"*. **The supervisor reuses the file's existing principle rather than
introducing a new one.**

### 3b. THE RX RESET DOMAIN IS LARGER THAN THE `rx_clk` DOMAIN

**This section is the most important one in this document, and revision 1 got it
wrong.** Revision 1's Scenario 4 asserted that `gem_rx_fifo`'s "Gray pointers
re-synchronise through the same path they use at cold start". That claim is
false, and the reason it *reads* as true is the trap:

> **Today, `rx_rst_n` and `tx_rst_n` can only ever assert together.** Both derive
> from `ext_rst_n` alone (`rtl/gem_clk_rst.v`: `u_rx_rst` takes `ext_rst_n`,
> `u_tx_rst` takes `ext_rst_n & mmcm_locked`, and the crystal MMCM's lock cannot
> drop while `clk50` runs). Every reset this design has ever taken has been a
> *whole-chip* reset. **This design is the first thing in the project that can
> reset one side of a clock-domain crossing without the other.**

There are exactly six such crossings out of the RX domain, and I enumerated them
from `rtl/gem_mac.v` rather than from R19's claim that they are the only ones:

| Crossing | Source half (`rx_clk`) | Destination half (`tx_clk`) |
|---|---|---|
| `u_rx_fifo` (`gem_rx_fifo`) | `.wr_rst_n(rx_rst_n)` (l.270) | `.rd_rst_n(tx_rst_n)` (l.275) |
| `u_ev_rx_ok` … `u_ev_rx_rxer` (5 × `gem_pulse_sync`) | `.src_rst_n(rx_rst_n)` (ll.300–318) | `.dst_rst_n(tx_rst_n)` |

#### What actually happens to the FIFO — traced through `rtl/gem_rx_fifo.v`

On an RX-only reset (`rx_rst_n` low, `tx_rst_n` high):

* `wr_bin`, `wr_gray` → 0 (ll.122–130), and the write side's view of the read
  pointer `rd_gray_s1/s2` → 0 (ll.132–140).
* `rd_bin`, `rd_gray` are **untouched** and hold their prior value *N*
  (ll.147–155). So does the read side's `wr_gray_s1/s2`, until it samples the
  new `wr_gray`.
* `empty = (rd_gray == wr_gray_s2)` (l.90). Two `rd_clk` edges later
  `wr_gray_s2 = 0` while `rd_gray = bin2gray(N) ≠ 0` for any `N ≠ 0`, so
  **`empty` goes false**.
* The read side therefore drains. `mem` **has no reset** — deliberately, so it
  infers as RAM (ll.97–115) — so what it drains is whatever the last frames
  left behind, with arbitrary `last` and `user` bits, straight into
  `gem_rx_egress` and out of the AXI-S port **as if it were a received frame**.
  The pointer is `AW+1 = 7` bits, so this runs until `rd_bin` wraps to 0: up to
  **127 octets of fabricated frame data per link drop.**
* `full` misbehaves too. `level = wr_bin − gray2bin(rd_gray_s2)` (l.87) becomes
  `0 − N` in 7-bit arithmetic = `128 − N`, and `full = (level == 64)` (l.89)
  asserts spuriously for `N = 64`, blocking writes on recovery.

This is silent corruption delivered as valid data — the worst failure class in
the document, and strictly worse than the timing margin the whole chain has been
chasing.

#### What happens to the pulse synchronisers

Same root cause, smaller blast radius. In `rtl/gem_pulse_sync.v`, `toggle`
resets on `src_rst_n` (l.40) while `sync1/2/3` reset on `dst_rst_n` (l.50). If
`toggle` was 1 when `rx_rst_n` asserted, it goes to 0 while the destination
chain keeps its old value; the edge detector `dst_pulse = sync3 ^ sync2` (l.62)
fires. Result: a **phantom statistics event** — `rx_ok`, `rx_badfcs`,
`rx_runt`, `rx_oversize` or `rx_rxer` — on every link flap, on up to five
counters. Statistics corruption, not data corruption, but it makes R17's
counters lie about a link that never delivered a frame.

#### The fix: a second reset, in the `tx_clk` domain

```verilog
// The rx_clk (deskewed) domain itself.
gem_reset_sync u_rx_rst (
    .clk    (rx_clk_deskew),
    .arst_n (tx_rst_n & rx_mmcm_locked),
    .rst_n  (rx_rst_n)
);

// The tx_clk-side half of every crossing OUT of the RX domain.
gem_reset_sync u_rx_path_rst (
    .clk    (tx_clk),
    .arst_n (tx_rst_n & rx_rst_n),
    .rst_n  (rx_path_rst_n)
);
```

Two instances of the module the design already uses, no new primitive and no new
mechanism. Rewiring in `rtl/gem_mac.v`:

| Instance | Port | Was | Becomes |
|---|---|---|---|
| `u_rx_fifo` | `.rd_rst_n` | `tx_rst_n` | **`rx_path_rst_n`** |
| `u_ev_rx_*` (all five) | `.dst_rst_n` | `tx_rst_n` | **`rx_path_rst_n`** |
| `u_rx_egress` | `.rst_n` | `tx_rst_n` | **`rx_path_rst_n`** (see below) |
| `u_stats` | `.rst_n` | `tx_rst_n` | **`tx_rst_n` — unchanged, deliberately** |

**Why the two directions are both covered.** `u_rx_rst`'s `arst_n` takes
`tx_rst_n` rather than `ext_rst_n & mmcm_locked`, which subsumes both and adds
the case revision 1 missed: if `tx_rst_n` ever asserts on its own (crystal MMCM
unlock without a board reset), the RX write side now resets too, so the
asymmetry cannot occur in *either* direction. `u_rx_path_rst`'s `arst_n` keeps
`tx_rst_n &` even though `rx_rst_n` already implies it — the term is redundant
by construction today and is written out anyway, so that the symmetry invariant
survives someone later editing `u_rx_rst`'s expression.

**Why it is correct — the four properties, each checked against the RTL above:**

1. **Both halves always assert together.** Any cause drives `rx_rst_n` low
   asynchronously, which drives `rx_path_rst_n` low asynchronously. Neither
   needs a clock edge, which matters because the RX clock is exactly what is
   missing.
2. **Release order is deterministic and falls out rather than being enforced.**
   `rx_rst_n` rises two `rx_clk_deskew` edges after its `arst_n`;
   `rx_path_rst_n` rises two `tx_clk` edges after *that*. **The write side
   always releases strictly before the read side.**
3. **The release window is safe.** With the write side out and the read side
   still in reset: `rd_gray = 0` and `wr_gray_s1/s2 = 0`, so `empty` is true and
   no read occurs; on the write side `rd_gray_s1/s2 = 0` gives
   `level = wr_bin − 0`, the correct occupancy. When the read side releases it
   begins at entry 0, which is where the write side began. No stale octet is
   readable at any point.
4. **No new deadlock.** `rx_path_rst_n` depends on `rx_rst_n` as a *level*, not
   on `rx_clk` running — and `rx_rst_n` low is precisely the state that persists
   with no RX clock at all, because `gem_reset_sync`'s assert half is
   asynchronous. `tx_clk` always runs. The dependency graph stays the acyclic
   one traced in Scenario 3.

And the pulse synchronisers: with `src_rst_n` and `dst_rst_n` asserting
together, `toggle` and `sync1/2/3` all reach 0 in the same reset event, so
`dst_pulse = 0 ^ 0 = 0`. No phantom event.

**Why `gem_stats` deliberately does *not* take the new reset.** Its counters
must survive a link flap — a statistics block that zeroed itself whenever the
cable moved would destroy the evidence at exactly the moment it is wanted. It
stays on `tx_rst_n`. This is safe only *because* of the pulse-sync fix above:
with no phantom events reaching it, the counters stay truthful across a flap
without being reset. The two changes are one change.

#### The consequence that is not fully solved, and is an owner decision

`gem_rx_egress` must take `rx_path_rst_n` — leaving it on `tx_rst_n` is worse
than resetting it. Traced: if the FIFO read side resets while egress does not,
egress stalls mid-frame on `fifo_empty`, then **resumes the old frame with the
new frame's octets** when data returns, and emits `tlast` at the new frame's
end. That is a well-formed AXI-S frame containing spliced data from two
different frames — silent corruption dressed as valid output. Resetting egress
instead makes the failure loud: `tvalid` drops mid-frame.

**But dropping `tvalid` mid-frame is itself a change to the RX user contract.**
Any consumer holding per-frame state sees a frame that starts and never ends. In
this design that consumer is `gem_echo` (`rtl/gem_top.v`), which stays on
`tx_rst_n`; the visible effect is one corrupted or never-completed echo frame
after a link flap, in a block B.5 step 6 describes as bring-up diagnostics.

The clean answer is an **in-band abort**: `gem_rx_egress` emits one final beat
with `m_tlast = 1` and `m_tuser = 1` (the error flag it already carries), so a
downstream consumer sees a properly terminated bad frame and discards it. That
is the right thing for B.4a's delivery contract and it is **not in this
design** — it changes a module and a published interface contract, both outside
this task's scope.

**Decision required from the project owner, not silently taken here:** either
(a) accept the mid-frame `tvalid` drop and add a line to B.4a saying the RX
stream may abort without `tlast` on a link event, or (b) schedule the in-band
abort as its own task. Task 4d's testbench must **demonstrate whichever
behaviour is chosen**, so it is documented rather than latent. Recommendation:
(a) now, (b) before anything real consumes the RX port, since R18 already puts
frame-drop responsibility on user logic.

### 3c. The supervisor, specified

```
inputs   clk50            free-running, never gated
         ref_rst_n        the existing clk50-domain reset, already in the file
         rx_mmcm_locked   asynchronous, from the MMCM's LOCKED pin
output   rx_mmcm_rst      active high, REGISTERED, to gem_rx_mmcm's RST

  locked_s : 2-flop ASYNC_REG synchroniser of rx_mmcm_locked, on clk50.
             A plain data synchroniser, NOT gem_reset_sync -- this is a level
             being sampled, not a reset being distributed.

  retry_cnt : 15 bits, on clk50

    if (!ref_rst_n)                                retry_cnt <- 0
    else if (locked_s)                             retry_cnt <- 0
    else if (retry_cnt == RX_MMCM_RETRY_CYCLES-1)  retry_cnt <- 0
    else                                           retry_cnt <- retry_cnt + 1

  rx_mmcm_rst : registered, asynchronously PRESET (not cleared) by ref_rst_n

    always @(posedge clk50 or negedge ref_rst_n)
      if (!ref_rst_n) rx_mmcm_rst <= 1'b1;
      else            rx_mmcm_rst <= (!locked_s) && (retry_cnt < RST_PULSE_CYCLES);

  RST_PULSE_CYCLES     = 4       4 x 20 ns = 80 ns >= MMCM_RSTMINPULSE (5 ns)
  RX_MMCM_RETRY_CYCLES = 16384   16384 x 20 ns = 327.68 us > 3 x MMCM_TLOCKMAX
```

**Registered, not combinational.** Revision 1 specified `rx_mmcm_rst` as a
combinational multi-bit magnitude comparison feeding a hard primitive's
asynchronous `RST` pin. That shape is wrong regardless of whether a particular
encoding happens to be glitch-free, and the safety of the previous encoding was
incidental to its exact coding rather than designed in. Registering costs one
`clk50` cycle (20 ns) of latency on a path where latency is irrelevant — the
MMCM is already unlocked — and buys a guaranteed glitch-free level. The reset
value is **1**, via an asynchronous *preset*, so the MMCM is held in reset from
configuration until `ref_rst_n` releases; the FPGA's GSR clears the flop to 0 at
configuration, and the async preset immediately overrides it because
`ref_rst_n` is low at that moment.

**An emergent property worth naming so nobody optimises it away.** Because
`retry_cnt` is held at 0 for as long as `locked_s` is high, the *instant*
`locked_s` falls the comparison `retry_cnt < 4` is already true, so `RST`
asserts on the very next `clk50` edge rather than after a wait. An implementer
who "simplifies" the counter's clear condition — for instance clearing it only
on `ref_rst_n` — would silently lose this and turn every unlock into a wait of
up to a full retry period. The `else if (locked_s) retry_cnt <- 0` line is
load-bearing.

**`RX_MMCM_RETRY_CYCLES` is a parameter** with the same justification
`PHY_RST_CYCLES` already carries in this file: a testbench overrides it to check
the sequencing without simulating 327 µs of it, and nothing else should. Follow
`PHY_RST_TERMINAL`'s precedent for the typing — Verilog-2001 has no `$clog2`, so
the terminal value is an explicitly-sized `localparam [14:0]` and **15 bits is
the ceiling on any override** (32767 × 20 ns = 655.34 µs). The constraint on the
value is stated rather than left implicit: it must exceed `MMCM_TLOCKMAX`
(100 µs) by a comfortable margin, or a retry pulse will interrupt a lock
acquisition that was about to succeed.

**Three properties, each doing a specific job:**

* **Unconditional.** While unlocked, it re-pulses `RST` forever. UG472 p.91
  requires the reset to be applied *after the clock returns*, and nothing on the
  FPGA knows when that is; a periodic retry guarantees one lands there without
  needing to know.
* **Cannot interrupt a legitimate acquisition.** 327.68 µs is 3.3 ×
  `MMCM_TLOCKMAX`.
* **Cannot wedge.** Its clock never stops, its only input is a level, and it has
  no terminal state. Every path through it returns to "pulse RST, wait".

**Worst-case recovery latency is ≈ 428 µs, not 100 µs.** The supervisor does not
know when the clock returned. If the clock comes back just after a retry pulse
has ended, the next `RST` arrives up to 327.68 µs later, and the MMCM then takes
up to `MMCM_TLOCKMAX` = 100 µs to lock: **327.68 + 100 ≈ 428 µs**, plus two
`rx_clk_deskew` edges (16 ns) for `rx_rst_n` and two `tx_clk` edges for
`rx_path_rst_n`. This is the number that belongs in the spec.

A clock-activity detector on `clk50` would cut this to roughly the lock time
alone by triggering `RST` on the clock's return rather than on a timer. It is
**deliberately not taken**: it adds a second clock-crossing on a stopped clock,
inside the one mechanism in this design that must never fail, to save ~330 µs on
an event that is already three orders of magnitude shorter than link
establishment. If a future requirement makes RX recovery latency matter, this is
the knob and this is its cost.

### 3d. `rx_rst_n` — the verdict, and it is the same for all four scenarios

```verilog
gem_reset_sync u_rx_rst (
    .clk    (rx_clk_deskew),                 // was: raw rgmii_rx_clk
    .arst_n (tx_rst_n & rx_mmcm_locked),     // was: ext_rst_n alone
    .rst_n  (rx_rst_n)
);
```

It is **not** correct as-is; it **does** move to the deskewed clock; it **does**
gain the lock gate; and it does **not** need a second lock-gated stage *within
the RX domain*. What it does need is the companion `rx_path_rst_n` of Step 3b,
which is a different thing in a different domain.

* Clock moves because B.1b requires synchronisation on *that domain's own
  clock*, and because leaving it on the raw pin creates a
  same-clock/different-buffer crossing whose skew is large by construction.
* The gate is added because UG472 p.83 says *"The clock outputs should not be
  used prior to the assertion of LOCKED"*, and `rtl/gem_clk_rst.v`'s own TX-side
  header transfers unchanged: *"the output clock during acquisition is not a
  125 MHz clock, it is whatever the VCO is doing on the way there, and a state
  machine clocked by that comes out of reset in a state nobody designed."*
* Async-assert is required, not stylistic — same header: *"when the MMCM
  unlocks, tx_clk stops, and a synchronous path could not deliver the reset at
  all."*

### 3e. The four scenarios

#### 1 — Cold power-up, no link

**Does an unclocked MMCM sit in a stable, well-defined state?** With no `CLKIN1`
edges the PFD never runs and `LOCKED` is never asserted. **Stated plainly:
UG472 contains no sentence about an MMCM whose input clock never starts.** What
it does say is that a *stopped* input leaves `LOCKED` low and needs a reset when
the clock returns, and electrically the two are the same condition. The unisim
model behaves accordingly — `clkin_lock_cnt` advances only on `CLKIN` edges, so
it never reaches `locked_en_time` and `LOCKED_out` stays 0. That is as far as I
can honestly take it; the claim "the primitive is guaranteed not to enter an
erroring state" is **not** being made.

**Is `LOCKED` safely readable from a different clock?** Yes. It is a **static
level**, not a pulse — there is no event to miss — so a 2-flop `ASYNC_REG`
synchroniser on `clk50` is textbook-safe, and the supervisor's behaviour while
unlocked does not depend on how long it takes to notice.

**Required behaviour:** `rx_rst_n` and `rx_path_rst_n` both asserted, with no
clock present (`gem_reset_sync`'s header already names *"an rx_clk the PHY has
not started driving yet"* as one of the two cases it exists to survive).
Everything else — `phy_rst_n`'s 10 ms count, `tx_rst_n`, MDIO, the register
block, statistics, the UART — runs normally. The board comes up fully and
reports no link, which is the truth.

#### 2 — Link establishes, CDR possibly ragged

**Can an unstable input produce a *false* `LOCKED`?** Two-part answer. **UG472
makes no statement that it cannot**, and none is being invented. What it states
is the mechanism, and the mechanism makes any false lock **self-correcting
rather than sticky**: `LOCKED` is a continuous comparison (*"phase and frequency
alignment […] within a predefined window […] within a predefined PPM range"*)
that *"will be deasserted within one PFD clock cycle"* on violation. A lock
asserted during a transiently-stable stretch and dropped when the input moves
again is a **deassertion event** — exactly what the design already treats as
"reset and try again".

**Required RTL behaviour: lock is a level, never a one-shot.** No edge-latched
"we locked once, we're done" bit; no state entered on `LOCKED` rising and never
left. The supervisor satisfies this because it is written as a level condition
on `locked_s`. *An implementation that latched first-lock would pass every
simulation this project could reasonably write and fail on silicon at exactly
this scenario.*

#### 3 — Link drops mid-operation

**Does `LOCKED` deassert promptly enough, and by what mechanism?** Yes —
UG472 p.83: *"within one PFD clock cycle if the input clock stops."* The PFD
runs at 125 MHz, so the bound is **8 ns**, one `rgmii_rx_clk` period, faster
than a byte time. The mechanism is internal to the MMCM and needs no RX-domain
clock to deliver it, which is precisely what an async-assert reset source must
be. `LOCKED` falling pulls `arst_n` low combinationally; `gem_reset_sync`'s
async clear takes `rx_rst_n` down with no edge, and `rx_path_rst_n` with it.

**Does it reintroduce the deadlock class?** No. Dependency graph after the drop:

```
clk50 (free-running, never gated)
  |-> ref_rst_n -> phy_rst_n counter               still running
  |-> crystal MMCM -> tx_clk -> tx_rst_n           still running
  |    '-> rx_path_rst_n (async-asserted, held)    reset, by design
  |-> RX MMCM reset supervisor                     still running  <-- recovery
  '-> MDIO, register block, statistics, UART       still running

rgmii_rx_clk (gone)
  '-> RX MMCM -> rx_clk_deskew -> rx_rst_n         parked in reset
```

Strict DAG rooted at `clk50`; the recovery mechanism sits on the root, not on
the branch that died. A deadlock requires a cycle and there is none.

#### 4 — Rapid link flapping

**Can repeated loss and reacquisition wedge anything?** No state in this design
requires a board reset to leave.

* The **MMCM** is reset by the supervisor on every unlock, unconditionally, for
  as long as it stays unlocked. `RST` is asynchronous and returns it to the same
  place every time; there is no accumulating state.
* The **supervisor** is clocked by `clk50`, has no terminal state, and its worst
  case is cycling through "pulse RST / wait", which is what it should be doing.
* The **`rx_clk` domain** is held in reset throughout, so no logic in it
  observes a partial state.
* **`gem_rx_fifo`** now resets *both* pointer sets together, every time, via
  Step 3b — this is the claim revision 1 made without checking and got wrong.
  With `rx_path_rst_n` in place it is true, and it is true for the traced reason
  in Step 3b, not by analogy with cold start.
* **The five pulse synchronisers** reset both halves together, so no phantom
  statistics event is emitted.
* **`rx_rst_n` cannot glitch high**: release requires `LOCKED` high *and* two
  edges of a running deskewed clock.
* **`ext_rst_n` asserted mid-acquisition or mid-retry** is benign: it forces
  `rx_mmcm_rst` high through the async preset and clears `retry_cnt`, so the
  supervisor restarts from its power-up state, which is the state it is designed
  to start from.

**Does this design ever perform worse than today's path?** Four honest yeses.

1. **Up to ≈ 428 µs of RX dead time per link event** (Step 3c) that the `BUFG`
   and `BUFIO`/`BUFR` paths did not charge. The lock happens while the link is
   coming up and a partner that has just finished negotiating is not sending
   data 428 µs later — not material, but real, and it belongs in the spec rather
   than being discovered.
2. **Sub-gigabit links stop working entirely — and this is arguably an
   improvement.** RGMII runs `RX_CLK` at 125 MHz only at 1 Gb/s; at 100 Mb/s and
   10 Mb/s it is 25 MHz and 2.5 MHz respectively (RGMII v2.0 — this project
   holds no copy of that spec, so treat the two lower figures as the
   widely-stated ones rather than as verified here; the 1 Gb/s figure is
   B.1b's). **2.5 MHz is below `MMCM_FINMIN` (10 MHz)**, and neither speed can
   make a ≥600 MHz VCO with fixed `M = 9, D = 1`. So on a non-gigabit link the
   MMCM never locks and RX is silent. It was never *correct* at those speeds —
   this is a 1000BASE-T MAC whose datapath assumes one byte per 125 MHz cycle —
   so it goes from "captures garbage" to "captures nothing, with
   `rx_mmcm_locked` low saying why". This needs a line in B.1b.
3. **A frame in flight on the AXI-S RX port is aborted without `tlast`** on
   every link event (Step 3b). New, and an owner decision is pending on whether
   to close it in-band.
4. **RX availability now depends on a lock that did not previously exist.** If
   the supervisor is wrong, or the recovered clock is outside `MMCM_FINJITTER`
   or `MMCM_FINDUTY`, RX is dead rather than degraded. Mitigations: the three
   above, plus visibility — see immediately below, which is a **requirement**.

### 3f. Making the new failure mode visible — resolved, not left implicit

Revision 1 named LED visibility as *the* mitigation for the worst failure mode
and then specified something unbuildable: `rtl/gem_top.v:308` is
`assign led = ~{err_seen, heartbeat_cnt[24], link_up, mmcm_locked};` and all four
LEDs are already assigned and pinned (`constrs/pins.xdc:101-104`, F19/E21/D20/C20).
There is no fifth LED to add, and the board is not in hand to discover one.

**Two changes, both executable, neither needing a new pin:**

1. **Status readout (primary, mandatory).** `gem_stat_report` already takes
   `link_up`, `link_speed`, `phy_id`, `phy_id_valid` and prints them over the
   UART (`rtl/gem_top.v:190`, `:234`). Add `rx_mmcm_locked` as one more input
   and one more printed field. This is the real diagnostic surface, it is
   readable without looking at the board, and it costs one wire.
2. **LED (secondary).** The existing `mmcm_locked` bit becomes
   `mmcm_locked & rx_mmcm_locked` — an "all clocks locked" indicator. Almost
   nothing is lost: `mmcm_locked` alone is high within ~100 µs of power-up and
   stays high, because `clk50` never stops. And the combination that the four
   LEDs now show is exactly the new failure's signature:

   | `link_up` | clocks LED | Meaning |
   |---|---|---|
   | 0 | 1 | No link. Expected with no cable. |
   | 1 | 1 | Normal operation. |
   | **1** | **0** | **The new failure: a link exists but the RX MMCM is not locked.** |
   | 0 | 0 | Crystal MMCM unlocked — a supply problem, not this design's. |

   The third row is unambiguous *because* the crystal MMCM's lock does not
   depend on the link, so a link-up board with the clocks LED dark can only be
   the RX MMCM. Diagnosable from the existing four LEDs, with the UART report
   distinguishing the two MMCMs for certainty.

---

## Step 5: the self-check against B.1b

`spec/PROJECT_SPEC.md` B.1b: *"Per-domain: asynchronous assert, synchronous
deassert (2-flop synchronizer) on that domain's own clock — **no domain's reset
release depends on another domain's clock running**."*

### Verdict: **violated, justified, and the spec must be amended.**

Revision 1 said "not a violation". That verdict was wrong, and it contradicted
this document's own implementation checklist, which separately told Task 4d that
B.1b's `rx_clk` bullet "now has an exception and must say so". Both cannot be
true. The honest one is the checklist.

**Where the violation is, precisely.** Revision 1's Argument 1 observed that the
new MMCM's `CLKIN1` is `rgmii_rx_clk` — the same physical clock the domain was
always derived from — and concluded there was no *other* domain involved. That
observation is correct and it is not the whole dependency. `rx_rst_n`'s release
requires `rx_mmcm_locked`, and `rx_mmcm_locked` can only ever rise after the
**`clk50`-clocked supervisor** has pulsed `RST` following the clock's return.
Its `arst_n` now also carries `tx_rst_n` (Step 3b), which requires the **crystal
MMCM** locked and `tx_clk` running. So `rx_rst_n`'s release depends on two other
domains' clocks running. That is B.1b's rule, violated, twice, by name.

Revision 1 never addressed the supervisor at all — it analysed the MMCM's input
and stopped. That is the same shape of error as the one this whole finding chain
started from: a reading that is locally correct and does not cover the case that
matters.

### Why it is justified anyway

The rule guards against a **circular** wait, which `rtl/gem_clk_rst.v`'s header
names outright: *"gating the MMCM's domain on rx_clk would deadlock the whole
design whenever the cable is unplugged."* A deadlock needs a cycle, and there is
none — the graph in Scenario 3 is a strict DAG rooted at `clk50`:

* Nothing outside the RX domain consumes `rx_rst_n`, `rx_path_rst_n` or
  `rx_mmcm_locked`. `tx_rst_n` does not depend on anything RX.
* `phy_rst_n` — the one thing that must happen before a link can exist at all —
  is counted on `clk50` and is already documented as such for this exact reason.
* **The recovery mechanism itself runs on `clk50`.** This is what makes the
  argument hold rather than merely sound plausible. UG472 p.91 requires a reset
  after the clock returns; *if that reset were generated anywhere in the RX
  domain, the design would have exactly the cycle B.1b forbids* — the RX domain
  needing its own clock in order to recover its own clock — **and this document
  would have reported BLOCKED.** It is on `clk50` precisely so it does not.

The clocks `rx_rst_n` now depends on are `clk50` and `tx_clk`, and `tx_clk` is
itself derived from `clk50`. So the dependency is, at root, on the board
oscillator alone — which every other reset in this design already depends on,
including `phy_rst_n`, explicitly and by design.

### The amendment B.1b needs

Task 4d must make this edit; the rule as written cannot stand alongside the
design:

> Per-domain: asynchronous assert, synchronous deassert (2-flop synchronizer) on
> that domain's own clock. No domain's reset release depends on another domain's
> clock running, **with one exception: a domain whose own clock is not
> free-running may have its reset release depend on `clk50` and on clocks
> derived from it, because `clk50` is the board oscillator — free-running, never
> gated, and already the root that every other reset in this design depends on
> (the PHY reset hold is counted on it for exactly this reason). Any use of this
> exception must be acyclic and must be written down.** `rx_clk`'s reset takes
> this exception; the reasoning is in `Documents/RX Clock Deskew Design.md`.

### What is being given up, stated rather than papered over

For `rx_rst_n`, B.1b's rule was doing a second job beyond deadlock avoidance: it
made RX readiness depend on *nothing at all* except its own clock existing. That
simplicity is being traded for ~1.5 ns of capture margin the design provably
cannot get any other way (4a: invariant under every phase and input delay; 4b:
the `BUFIO`'s own spread is the binding term). The trade is worth making, but it
*is* a trade, and it is now a larger one than revision 1 admitted: the RX path
gained a dependency on two other clocks, a second reset domain, and an
AXI-S abort case. Mitigated by making the dependency acyclic, the failure
observable (Step 3f), and the recovery self-clearing (Step 3c).

---

## What is not confirmed

1. **The actual residual insertion delay after compensation — Gap 1.** Now
   promoted to a **go/no-go measurement at the start of Task 4d** (Step 2c),
   with a fallback worked out in Step 2d. The three readings disagree about
   whether the design closes at all.
2. **Whether a marginal input clock can transiently assert `LOCKED`.** UG472
   describes the mechanism but makes no such statement. The design survives it
   either way; "it cannot happen" is not claimed.
3. **The KSZ9031RNX's actual `RX_CLK` period jitter and duty cycle.** DS181's
   limits are sourced (1 ns period jitter → 0.125 UI; 30–70% duty at this
   frequency); the PHY's actual figures are not in this project, and A.2 already
   flags that datasheet as read online and unverified against the physical part.
   `REF_JITTER1 = 0.010` is the primitive default, not a measurement — hence
   criterion A's two-value requirement.
4. **Placement.** `task-4a-report.md` established that `rgmii_rx_clk` is on K18,
   `IO_L13P_T2_MRCC_15`, in clock region **X0Y1**. UG472 p.16 says a clock
   region contains, if applicable, one CMT; p.80 says `CLKIN1` can be driven by
   an SRCC/MRCC I/O directly within the same clock region or through the CMT
   backbone in a vertically adjacent one. I did **not** verify empirically that
   X0Y1's CMT is free. The PLL in the same CMT is a genuine fallback, and unlike
   revision 1 this is now checked rather than asserted from a topology sentence:
   DS181 Table 38 gives the -1LI PLL `FVCOMIN`/`FVCOMAX` as **800 / 1600 MHz**
   and `FPFDMIN`/`FPFDMAX` as **19 / 450 MHz**, so the Step 2b configuration
   (VCO 1125 MHz, PFD 125 MHz, input 125 MHz against `PLL_FINMIN` 19 MHz) is
   legal on a `PLLE2_BASE` unchanged. UG472 p.91 confirms the deskew use models
   *"can equally be applied to the PLL."*
5. **`MMCM_TFBDELAY`.** DS181 caps the feedback path at *"3 ns Max or one CLKIN
   cycle"*; at 125 MHz the 3 ns binds. The `CLKFBOUT → BUFG → CLKFBIN` route
   should be well under it, but I have not measured it — and note this is the
   *same* quantity Gap 1 turns on, from the other side: a feedback net long
   enough to threaten `TFBDELAY` would be one long enough to cancel more of the
   forward net. Task 4d gets both numbers from one report.

---

## Implementation checklist for Task 4d

### Step 0 — the go/no-go, before anything else

Build only `gem_rx_mmcm` and its wiring, route it, and measure the skew interval
(Step 2c). If `skew_fast ≥ −0.977` and `skew_slow ≤ +0.784` on all five RX
ports, continue. If not, **stop and report** — do not reach for the phase trim,
which moves setup and hold one-for-one and does not change `skew` (proved in
`task-4a-report.md`). The next step is then Step 2d's `IDELAYE2` fallback, which
is a different task.

> **Amended by the Revision 3 addendum (task 4e).** This step's reasoning was
> written against the tool's model, which turned out to carry ~2.3 ns of
> phantom spread. Under the corrected physics a static shift *does* close:
> the feasible window is s ∈ [−1.676, −0.331] ns, and the shipped fix is
> exactly that — `CLKOUT0_PHASE = −45°`. The "phase trim cannot help" claim
> above is true of the artifact-widened interval and false of the physical
> one; see the addendum's §2 for the arithmetic.

### Modules

**New: `rtl/gem_rx_mmcm.v`** — same two-branch shape as `rtl/gem_mmcm.v`, same
`GEM_BEHAVIORAL_IO` define, same direction of default.

```verilog
module gem_rx_mmcm (
    input  wire clk_in,     // the raw rgmii_rx_clk pin -- NO buffer between the
                            // port and here (UG472 p.89: a BUFG-driven CLKIN is
                            // not compensated; an IBUFG one is)
    input  wire rst,        // active high, asynchronous, from the clk50 supervisor
    output wire clk_out,    // 125 MHz, deskewed: the whole rx_clk domain
    output wire locked
);
```

Instance name **`u_rx_mmcm`**, instantiated in `gem_clk_rst` as
`u_clk_rst/u_rx_mmcm`, with the forward buffer named `u_bufg_rx` and the
feedback buffer `u_bufg_fb`. These names are load-bearing: the XDC below
addresses the clock through them.

Synthesisable branch: `MMCME2_BASE` with

```
BANDWIDTH          "OPTIMIZED"     see Step 2b before changing
CLKIN1_PERIOD      8.000
DIVCLK_DIVIDE      1
CLKFBOUT_MULT_F    9.000           VCO = 1125 MHz
CLKFBOUT_PHASE     0.000
CLKOUT0_DIVIDE_F   9.000           125 MHz
CLKOUT0_PHASE      0.000
CLKOUT0_DUTY_CYCLE 0.500
REF_JITTER1        0.010           default, UNVERIFIED -- criterion A tests 0.125 too
STARTUP_WAIT       "FALSE"         load-bearing: TRUE bricks a board with no link
```

plus `BUFG u_bufg_rx (.I(clkout0_raw), .O(clk_out));` and
`BUFG u_bufg_fb (.I(clkfbout_raw), .O(clkfbin));`. **Both buffers must be `BUFG`
and there must be exactly one forward buffer.**

**Behavioural branch — specified concretely, because three of criterion D's
scenarios are vacuous without it.** A model whose `locked` never deasserts makes
D3, D4 and D5 pass while checking nothing.

```verilog
// clk_out is clk_in gated by locked. There is no insertion delay in simulation
// for a deskew to cancel, so modelling one would model nothing.
//
// Clock-stop detection: an independent time-based process samples a toggle that
// flips on every clk_in edge. No zero-delay loop, because the process has a
// non-zero delay of its own.
localparam real CLKIN_WATCH_NS = 40.0;      // 5 x the 8 ns nominal period
reg clkin_toggle = 1'b0;
reg clkin_prev   = 1'b0;
reg clk_stopped  = 1'b1;

always @(clk_in) clkin_toggle <= ~clkin_toggle;   // both edges

always begin
    #CLKIN_WATCH_NS;
    clk_stopped <= (clkin_toggle === clkin_prev);
    clkin_prev   = clkin_toggle;
end

// LOCK_CYCLES of clk_in after rst releases and the clock is running, exactly as
// gem_mmcm's model counts input clocks. locked clears immediately on rst or on
// clk_stopped.
localparam [7:0] LOCK_CYCLES = 8'd128;      // 1.024 us at 125 MHz
```

The header must carry `gem_mmcm.v`'s warning in the same words it uses: this
reproduces the *sequencing* and not the numbers. Detection latency here is up to
80 ns against the silicon's 8 ns (one PFD cycle, UG472 p.83); `LOCK_CYCLES`
gives ~1 µs against `MMCM_TLOCKMAX`'s 100 µs; jitter, the static phase offset
and the real deskew are absent entirely.

**Modified: `rtl/gem_clk_rst.v`**

* instantiate `gem_rx_mmcm` as `u_rx_mmcm` — `.clk_in(rx_clk)` (the raw port),
  `.rst(rx_mmcm_rst)`, `.clk_out(rx_clk_deskew)`, `.locked(rx_mmcm_locked)`
* add the `clk50` supervisor of Step 3c, inline, beside the PHY reset counter —
  parameter `RX_MMCM_RETRY_CYCLES = 16384` (15-bit ceiling), localparam
  `RST_PULSE_CYCLES = 4`, `rx_mmcm_rst` **registered with an async preset**
* retarget `u_rx_rst`: `.clk(rx_clk_deskew)`, `.arst_n(tx_rst_n & rx_mmcm_locked)`
* **add `u_rx_path_rst`** (Step 3b): `gem_reset_sync`, `.clk(tx_clk)`,
  `.arst_n(tx_rst_n & rx_rst_n)`, `.rst_n(rx_path_rst_n)`
* new ports: `output wire rx_clk_deskew`, `output wire rx_mmcm_locked`,
  `output wire rx_path_rst_n`
* update the header's three-domain table — it is now four resets, and the header
  currently states the opposite of the new `rx_clk` policy in two places. The
  paragraph explaining why `rx_rst_n` was the button alone must be **replaced by
  a pointer to this document, not deleted**: the reasoning it records is still
  correct about the case it was written for.

**Modified: `rtl/gem_mac.v`** — the Step 3b rewiring table: `u_rx_fifo.rd_rst_n`,
all five `u_ev_rx_*.dst_rst_n`, and `u_rx_egress.rst_n` all move from `tx_rst_n`
to a new `rx_path_rst_n` input port. `u_stats.rst_n` stays on `tx_rst_n`
**deliberately** — put the reason in a comment, or someone will "fix" it. Also
rename the `rgmii_rx_clk` port to `rx_clk` (it no longer carries the pin) and say
so in the header.

**Modified: `rtl/gem_top.v`** — `u_clk_rst.rx_clk` keeps the raw `rgmii_rx_clk`
port; `u_mac`'s clock input takes `rx_clk_deskew`; `u_mac.rx_path_rst_n` takes
the new signal; `gem_stat_report` gains `rx_mmcm_locked`; the LED expression at
line 308 becomes `~{err_seen, heartbeat_cnt[24], link_up, mmcm_locked &
rx_mmcm_locked}` (Step 3f).

**Modified: `rtl/gem_stat_report.v`** — one input, one printed field.

**Not created:** `rtl/gem_rx_clkbuf.v`.

**Testbenches that must be edited for the `gem_mac` port rename** — `make check`
will catch these, but they belong on the list rather than being discovered:
every bench instantiating `gem_mac` or `gem_top`, which per `scripts/run_sim.py`
includes at least `tb_gem_mac_rx`, `tb_gem_mac`, `tb_gem_top` and
`tb_gem_clk_rst`. Confirm the list from the file rather than from this sentence.

**Also:** `scripts/run_sim.py`'s `RTL_SOURCES` needs `"rtl/gem_rx_mmcm.v"` added
by hand — three of the four source lists in this repo discover files
automatically and the simulation one does not (Task 4b found this).

### Constraints

The working tree is at `32403cf`, so **Task 4a's corrected XDC is not in it**.
Apply in this order, confirming `report_clocks` between steps:

1. **Task 4a's corrections, verbatim from `task-4a-report.md` Step 2** —
   `-waveform {1.200 5.200}` on `rgmii_rx_clk`, and `-max 0.200 / -min -1.800`
   on all four `set_input_delay` lines, with both comment blocks. Do not
   re-derive them.
2. **Retarget the four `set_false_path` lines.** They currently name
   `[get_clocks rgmii_rx_clk]` as the capture clock. Capture now happens on the
   MMCM's derived clock, so as written they would **silently stop applying** —
   the same "the tool reports success and is checking nothing" class this whole
   chain started from. Address the clock by object, and **assert the match**,
   because a hierarchical path string that goes stale is exactly the fragility
   this chain keeps hitting:

   ```tcl
   set rx_cap_clk [get_clocks -quiet -of_objects \
       [get_pins -quiet u_clk_rst/u_rx_mmcm/u_bufg_rx/O]]
   if {[llength $rx_cap_clk] != 1} {
       error "RX capture clock not found at u_clk_rst/u_rx_mmcm/u_bufg_rx/O\
              (got '[llength $rx_cap_clk]' clocks). The RX input-delay\
              exceptions would silently apply to nothing. Fix the path or the\
              instance names before continuing."
   }
   set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -fall_to $rx_cap_clk -setup
   set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -rise_to $rx_cap_clk -setup
   set_false_path -rise_from [get_clocks rgmii_rx_clk_virt] -rise_to $rx_cap_clk -hold
   set_false_path -fall_from [get_clocks rgmii_rx_clk_virt] -fall_to $rx_cap_clk -hold
   ```
3. **Fix `set_clock_groups`.** `constrs/clocks.xdc` currently reads
   `-group [get_clocks rgmii_rx_clk]`. The MMCM-derived RX clock is a *new*
   clock object and is not in that group, so every `clk50`↔RX CDC path — the RX
   FIFO's Gray pointers and the five pulse synchronisers — would be timed as if
   synchronous and would fail on paths that are correct by construction:

   ```tcl
   -group [get_clocks -include_generated_clocks rgmii_rx_clk]
   ```

   matching the form the `clk50` group already uses.
4. **Do not hand-write a `create_generated_clock` for the MMCM output** —
   `constrs/clocks.xdc`'s own comment gives the reason and it applies unchanged.
5. **Do not add `CLOCK_DEDICATED_ROUTE FALSE`** anywhere (Step 2e).

### Acceptance criteria

**A — timing, the one that decides it.** Post-route, all five RX ports
individually, both corners:

* `skew_fast ≥ −0.977 ns` **and** `skew_slow ≤ +0.784 ns` — Task 4b's two-sided
  form. Do not use the one-sided `spread < 1.761 ns` criterion; 4b's whole
  finding is that it is necessary and not sufficient.
* the `Requirement:` lines confirmed to name real DDR capture events one unit
  interval apart, per `task-4a-report.md` Step 4's method. **A passing gate 2 is
  not evidence on its own** — 4a rejected a *passing* configuration (Step 5c) on
  exactly this check.
* **Run the whole of A twice: at `REF_JITTER1 = 0.010` and at 0.125** (DS181's
  `MMCM_FINJITTER` ceiling expressed in UI). Passing at 0.010 is required;
  the margin at 0.125 is recorded either way, and a failure there is a known gap
  requiring bench jitter measurement before sign-off, not a build blocker. If
  `BANDWIDTH` is changed to `"LOW"`, re-run both.
* TX `WNS ≥ 0`, and **investigate** any movement from `+0.058 ns` rather than
  treating movement as failure: a second MMCM and two more `BUFG`s can
  legitimately perturb the placement of unrelated logic.
* a segment-by-segment insertion-delay table for the new clock path, in the
  format `task-4a-report.md` and `task-4b-report.md` both used, so the three are
  comparable.

**B — constraints.** `report_clocks` shows the derived RX clock; the Step 2
`error` guard did not fire; `report_clock_interaction` shows no timed paths
between the `clk50` tree and the RX tree; `check_timing` clean.

**C — placement and the MMCM's own limits.** From the routed checkpoint: the RX
MMCM's site and clock region (X0Y1 or a vertically adjacent one reachable via
the CMT backbone); the `CLKFBOUT → BUFG → CLKFBIN` path delay against
`MMCM_TFBDELAY` = 3 ns; `report_drc` clean of anything naming the new MMCM, its
`BUFG`s, or clock region X0Y1; and **no `CLOCK_DEDICATED_ROUTE` override
present**.

**D — simulation.** `make check` still 28/28, plus new `tb_gem_clk_rst` and
`tb_gem_mac_rx` scenarios (with `RX_MMCM_RETRY_CYCLES` overridden small):

1. cold start, `rx_clk` never runs → `rx_rst_n` and `rx_path_rst_n` both
   asserted, no X propagates out of the RX domain, `phy_rst_n` / `tx_rst_n`
   sequence normally
2. `rx_clk` starts late → MMCM locks; `rx_rst_n` releases two deskewed clocks
   after lock and `rx_path_rst_n` two `tx_clk` **after that** — assert the
   ordering, it is Step 3b property 2
3. `rx_clk` stops mid-operation → `rx_rst_n` asserts **with no further `rx_clk`
   edge**, the async-assert property a synchronous implementation would pass
   every other test without having
4. `rx_clk` stops then restarts → the supervisor pulses `RST`, the MMCM
   re-locks, and a frame received afterwards is delivered intact. **This is the
   scenario the whole task exists for.**
5. rapid flap, several times, faster than one retry period → still recovers, and
   recovery never requires `ext_rst_n`
6. **`gem_rx_fifo` integrity across a link drop (Step 3b).** Write *N* octets,
   drop the link mid-frame, restore it, and assert that **zero** octets are
   delivered on the AXI-S port between the drop and the next genuine frame, and
   that the next genuine frame is delivered intact. Without this test the
   Critical-1 defect is invisible: it produces well-formed AXI-S output.
7. **No phantom statistics events (Step 3b).** Drop and restore the link with no
   frame in flight; assert all five RX counters are unchanged.
8. **The AXI-S abort behaviour**, whichever of Step 3b's options (a) or (b) the
   owner chooses — demonstrated, so it is documented rather than latent.

**E — lint.** `python scripts/lint.py` clean, 7 tops (8 with `gem_rx_mmcm`),
zero warnings (R22). `gem_mmcm.v`'s header warning applies: a comment line whose
text begins with the word "verilator" is read as a metacomment and fails lint.

### Documentation to update in the same commit

* **`spec/PROJECT_SPEC.md`** — B.1b's reset-strategy bullet takes the **Step 5
  amendment, quoted above**; B.1b's clock table gains the deskewed RX clock;
  B.1b's RX skew paragraph ("no IDELAY for v1 — an IDDR clocked directly by
  `RX_CLK` is sufficient") is the claim `task-4a` disproved and must be
  corrected; B.2's MMCM row goes 1 → 2 of 5; the ≈ 428 µs recovery latency and
  the sub-gigabit consequence each need a line; and B.4a needs the AXI-S abort
  line if the owner chooses option (a).
* **`Documents/RGMII I-O Timing Derivation.md`** — the RX section. Task 4b's
  rewrite is in `task-4b-report.md` Step 7 and still applies, plus this design's
  measured result. It must not record the fix as complete until gate 2 passes.
  *(Done in the task-4e close-out, with the derivation updated past both this
  document's Step 2c readings and the Rev 3 addendum.)*
* **`rtl/gem_rgmii_rx.v`** — its "No IDELAY" header paragraph, per
  `task-4b-report.md` Step 7.
* **`verification_plan.md`** — V-23 gets its resolution or updated status;
  R13/R14 point at it. Add a new open item for the AXI-S abort decision.
  *(Done: V-23 marked superseded by V-24, which carries the task-4e
  resolution; V-25 records the abort decision and the D6/D7/JITTER
  deferrals.)*

---

## Revision 3 addendum (task 4e): the capture edge, measured and corrected

*Written after task 4d's go/no-go measurement came back BLOCKED. Task 4e
resolved the open question that report recorded -- the "half-cycle residue"
-- and its result amends Step 2c's readings and the CLKOUT0_PHASE = 0
derivation above. The full evidence is
[`docs/reports/stage6-part2/task-4e-report.md`](../docs/reports/stage6-part2/task-4e-report.md);
the essentials:*

### 1. The pessimistic reading of Step 2c was still too optimistic

Step 2c's three readings all assumed the tool's STA reflects the loop's fixed
point. It does not. Measuring the routed feedback path directly on the
task-4d checkpoint:

| Quantity | Fast | Slow |
|---|---|---|
| Routed fb path (CLKFBOUT -> BUFH -> CLKFBIN) | 0.936 | 1.974 |
| Vivado's compensation arc `Prop_mmcme2_adv_CLKIN1_CLKOUT0` | -2.703 | -6.062 |

The physical transfer is exactly `-fb_path` (that is what the PFD enforces).
Vivado's ZHOLD model applies a constant instead: comparing the BUFG and BUFH
builds shows `IBUF+ccio + arc + fwd` is invariant at -1.452/-0.817 ns -- the
arc anti-correlates perfectly with the forward route, i.e. it is constructed,
not measured. The task-4d2 "property of the tool's model" conclusion was
right; this is the mechanism.

Escapes tested and closed: manual generated-clock re-declaration leaves the
arc intact (measured); `COMPENSATION=EXTERNAL` is rejected for any on-chip
feedback loop ([Timing 38-290], measured); PHASESHIFT_MODE does not bear on
the ZHOLD insertion arc (UG906 Table 18).

### 2. The physical margins, and why 0 degrees was wrong

Replacing the arc with the measured `-fb` gives the true capture-edge
position -- **+2.150 fast / +3.836 slow after the data transition**, i.e.
a residual of +0.950/+2.636 after the pin's own nominal edge:

```
after transition : pin_edge(1.200) + IBUF+ccio + fwd - fb
fast : 1.200 + 0.913 + 0.973 - 0.936 = +2.150 ns   residual +0.950
slow : 1.200 + 2.569 + 2.041 - 1.974 = +3.836 ns   residual +2.636
```

The input-side IBUF+route spread (~1.66 ns corner-to-corner) passes straight
through a deskew loop -- only the fb-vs-fwd mismatch cancels -- which is the
term every reading in Step 2c missed. Same-corner pairing (one die sits at
one corner at a time), TsetupR = TholdR = 1.0 ns about the PHY's nominal
1.2 ns delayed edge, IDDR tsu = -0.011 / thold = 0.191:

```
setup margin = 1.0 + skew + tsu      hold margin = 1.0 - skew - thold
skew_fast = 0.687   skew_slow = 1.140
```

Hold fails at slow corner by ~0.33 ns with the output at 0 degrees: the
capture edge lands after the next bit can arrive. The feasible shift window
is s in [-1.676, -0.331]; centred at **s = -1.000 ns**, which on this VCO is
exactly **CLKOUT0_PHASE = -45.000** -- one grid step of 5 degrees, legal.

Predicted margins after trim: setup +0.676/+1.129, hold +1.122/+0.669 ns;
worst ~+0.5 ns after clock uncertainty. Bench fine-trim remains available in
111.1 ps steps or via the KSZ9031RNX MMD pad-skew registers.

### 3. What this means for STA sign-off

Vivado will still fail the five RX input-delay checks after the trim --
about 1 ns worse than task-4d's numbers, since WAVEFORM-mode phase moves the
modeled edge too. R20's RX half is signed off by this derivation plus bench
measurement. `scripts/build.tcl` gate 2 now fences exactly those five IDDR
endpoints (count asserted, envelope bounded at -5.000 ns, any other
violation refusing as before) instead of letting them fail the whole build.
