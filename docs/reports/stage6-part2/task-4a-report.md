# Task 4a report: the RX hold violation — BLOCKED

## Status: BLOCKED

The re-derivation converged cleanly, and its conclusion is not the one the brief
anticipated. The phase relationship Step 1 asks for is **+1.200 ns on the real
clock**, and encoding it does fix the *modelling* defect Task 4 found: with it,
Vivado checks the physically real edge pairs for the first time. But the design
does not meet the resulting check. It is short by **~0.99 ns of combined
setup+hold budget**, and that shortfall is **invariant under every choice of
clock phase and input-delay value** — it is set by the RX clock network's
min/max insertion-delay spread, not by the constraint.

Measured on the real, wired-in build with the corrected constraint:
`WNS = +0.058 ns` (TX, unchanged), `WHS = -3.031 ns` (RX). Gate 2 refuses.

Per this task's own stop condition ("if fixing the RX hold check reveals it also
perturbs the RX setup check … stop and report rather than forcing something that
merely silences the tool"), I stopped. **Nothing is committed. The working tree
is exactly as I found it** — `constrs/rgmii_timing.xdc` and `constrs/clocks.xdc`
are byte-identical to HEAD, and Task 4's uncommitted `scripts/build.tcl` edit is
untouched.

The full corrected XDC is below, verified and ready to apply the moment the
underlying clocking defect is fixed.

---

## Step 1: the re-derivation, from B.1b's numbers

### What the two clocks mean

`rgmii_rx_clk_virt` is a pure modelling construct: it drives nothing, nothing
else in the design references it, and its only job is to be the reference edge
that `set_input_delay` measures against. It stands for **the PHY's own
undelayed clock** — the internal reference that RGMII's un-delayed mode would
emit edge-aligned with `RXD`/`RX_DV`. Its edges are therefore, by definition,
the nominal *data transition* instants.

`rgmii_rx_clk` is the real, physically-arriving clock on pin K18. B.1b: the
KSZ9031RNX delays it by **1.2 ns typical relative to `RXD`/`RX_DV`, by default,
out of reset, no MDIO write**. So at the FPGA's pins the real clock's edges land
1.2 ns after the virtual clock's corresponding edges.

That single sentence is the phase relationship, and it was never written down
anywhere in the XDC. Both clocks defaulted to `{0.000 4.000}` — zero relative
phase — which is the bug Task 4 traced.

### Which clock carries the phase, and why

Mathematically it does not matter: only the relative phase enters any check.
Three considerations decide it in practice, and they all point the same way:

1. **Sign and readability.** The physical statement is "the real clock is
   *delayed* by 1.2 ns." Putting that on the real clock is `-waveform
   {1.200 5.200}` — positive, and it reads as the sentence it encodes. Putting
   the same relative phase on the virtual clock requires `-waveform
   {6.800 10.800}` (a −1.2 ns shift expressed modulo the period), which a future
   reader has to decode before they can check it.
2. **It matches the mechanism this project already documents.** B.1b describes a
   PHY that *adds delay to RX_CLK*. The constraint should say that, not its
   modular complement.
3. **It costs nothing.** `rgmii_rx_clk` has no defined phase relationship to
   anything else in the design: `constrs/clocks.xdc` already groups it
   `-asynchronous` against `clk50` and everything the MMCM derives, and every
   `rx_clk`-internal register-to-register check is expressed against this
   clock's *own* edges, so shifting all of them together by the same amount
   changes none of those checks. Verified empirically: the corrected build's
   `WNS` is `+0.058 ns`, byte-identical to Task 2e's committed TX number, and no
   new failing path appeared anywhere in the `rx_clk` domain.

The one real cost is that the phase then lives in a different file from the
input delays that depend on it — which is a smaller version of exactly the
failure mode this task exists to fix. Mitigated by a comment in each file
naming the other; see the XDC below.

**Conclusion: `rgmii_rx_clk` carries `-waveform {1.200 5.200}` in
`constrs/clocks.xdc`. `rgmii_rx_clk_virt` stays at the default `{0.000 4.000}`.**

### The input-delay values — and why Step 1 *does* implicate them

The brief asked me to keep `-max 3.000 / -min -1.000` unless the derivation
genuinely implicated them. It does, for two independent reasons.

**Reason 1: they are not independent of the phase.** Let Δ be the declared phase
of the real clock relative to the virtual one, UI = 4.000 ns (DDR at 125 MHz),
and let the RGMII v2.0 receive window's guaranteed bounds be
`TsetupR_min = TholdR_min = 1.0 ns` (B.1b's worst-case reading of the 1.0–2.0 ns
window, which Task 1 also used and which I keep).

Bit *k* is nominally launched at virtual edge `4k` and captured by the real edge
at `4k + Δ`. Its guaranteed data-valid window at the pin is
`[4k + Δ - 1.0, 4k + Δ + 1.0]`. Therefore:

```
max input delay = latest the bit becomes stable, measured from its own
                  launch edge
                = Δ - TsetupR_min
                = Δ - 1.000

min input delay = earliest the bit can start changing, measured from the same
                  launch edge; that is one UI after the previous bit's hold end
                = Δ - (UI - TholdR_min)
                = Δ - 3.000
```

Both track Δ. Fixing Δ = 1.200 gives **max = +0.200, min = −1.800**. Keeping
`-max 3.000` at Δ = 1.200 would declare data arriving 2.8 ns later than the PHY
can possibly deliver it, and setup would fail by that amount for no physical
reason.

**Reason 2: `-max 3.000 / -min -1.000` was wrong on its own terms, under any
phase.** The declared transition-uncertainty per unit interval is `max - min`,
and the declared eye is `UI - (max - min)`:

```
Task 1's values:  max - min = 3.000 - (-1.000) = 4.000 ns = the whole UI
                  declared eye = 4.000 - 4.000 = 0.000 ns
Corrected values: max - min = 0.200 - (-1.800) = 2.000 ns
                  declared eye = 4.000 - 2.000 = 2.000 ns
                              = TsetupR_min + TholdR_min          ✓
```

Task 1 declared a **zero-width data eye**. Under a correct edge pairing that is
unclosable by construction: no capture edge can meet setup and hold against a
window of zero width. It went unnoticed for the same reason the phase did — the
false-path structure, applied at zero phase, split setup and hold onto capture
edges 12 ns apart, so the two checks never had to be satisfied by one eye. The
arithmetic in the derivation document ("max = period/2 − Tsetup_min", "min =
−Thold_min") mixes two different reference points: it measures `max` from a
capture edge one UI *after* the launch edge, and `min` from the launch edge
itself. Each half is individually plausible, which is why it reads as correct.

### The false-path structure is correct, and is kept unchanged

Task 4's diagnosis suggested the reference template's pairing might itself be
wrong for a zero-phase design. Working it through, it is not — it is right in
general, and it was the missing phase alone that broke it. For DDR:

* **setup** is checked against the *corresponding* edge (the bit launched on a
  rise is captured by the real rise), so the non-corresponding pairs are
  false-pathed for setup;
* **hold** is checked against the *adjacent, opposite-polarity* edge one UI
  earlier, so the corresponding pairs are false-pathed for hold.

That is exactly the four lines already in the file. They are kept verbatim.
What makes them work is Δ > 0: at Δ = 0 the surviving setup pair has no capture
edge strictly after the launch edge within the same UI, so Vivado walks to the
next one 8 ns out and the check degenerates. Confirmed directly — see Step 5b.

---

## Step 2: the corrected XDC (applied, measured, then reverted)

`constrs/clocks.xdc` — the `rgmii_rx_clk` declaration becomes:

```tcl
#
# The 1.200 ns waveform shift is not cosmetic. It is the KSZ9031RNX's default
# RX_CLK delay (B.1b: 1.2 ns typical, out of reset, no MDIO write), declared
# relative to the idealised zero-delay launch reference that
# constrs/rgmii_timing.xdc calls rgmii_rx_clk_virt. It is a modelling phase,
# not a claim about an externally observable absolute: this clock has no
# defined phase relationship to anything else in the design -- it is grouped
# asynchronous to clk50's tree below, and every rx_clk-internal
# register-to-register check is expressed against this clock's own edges, so
# shifting all of them together changes none of those checks. The one place
# the number is load-bearing is the RX input-delay check in
# constrs/rgmii_timing.xdc, which reads it as "the real clock's edges arrive
# 1.200 ns after where the PHY's own undelayed edges would be". Do not drop
# the waveform without re-deriving that file's RX section with it.
create_clock -name rgmii_rx_clk -period 8.000 -waveform {1.200 5.200} \
    [get_ports rgmii_rx_clk]
```

`constrs/rgmii_timing.xdc` — the RX section becomes:

```tcl
#
# rgmii_rx_clk_virt is the PHY's own *undelayed* reference: edge-aligned with
# RXD/RX_DV, phase 0, driving nothing. The real rgmii_rx_clk is that clock
# delayed 1.200 ns by the PHY, and constrs/clocks.xdc declares it
# -waveform {1.200 5.200} to say exactly that. The two numbers below are
# derived from that 1.200 ns and the RGMII v2.0 receive window, and they only
# mean what they say while that waveform is present:
#
#   max = phase - TsetupR_min       = 1.200 - 1.000 =  0.200 ns
#   min = phase - (UI - TholdR_min) = 1.200 - 3.000 = -1.800 ns
#
# max - min = 2.000 ns of transition uncertainty per 4.000 ns unit interval,
# i.e. a declared eye of exactly TsetupR_min + TholdR_min = 2.000 ns, which is
# the guarantee the datasheet actually gives.
create_clock -name rgmii_rx_clk_virt -period 8.000

set rx_data_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

set_input_delay -clock rgmii_rx_clk_virt -max 0.200 $rx_data_ports
set_input_delay -clock rgmii_rx_clk_virt -min -1.800 $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -max 0.200 -clock_fall $rx_data_ports -add_delay
set_input_delay -clock rgmii_rx_clk_virt -min -1.800 -clock_fall $rx_data_ports -add_delay

# (the four set_false_path lines are unchanged)
```

The TX section was not touched.

---

## Step 3: measurements on the real, wired-in build — all five RX ports

`python scripts/build.py impl gem_top`, with Task 4's `scripts/build.tcl` edit in
place (unmodified) and the corrected constraints above:

```
==> WNS (setup) = 0.058 ns, WHS (hold) = -3.031 ns
Build refused: negative hold slack (WHS = -3.031 ns).
impl FAILED (exit 1).
```

`WNS = +0.058 ns` is Task 2e's TX number, unchanged to the picosecond — the RX
phase shift perturbed nothing on the TX side or inside the `rx_clk` domain.

Per port, from the `build/post_route.dcp` that run wrote
(`get_timing_paths -from <port> -delay_type max|min`):

| Port | Setup | Hold | Sum |
|---|---|---|---|
| `rgmii_rxd[0]` | **+2.019 ns** | **−3.001 ns** | −0.982 |
| `rgmii_rxd[1]` | +2.042 ns | **−3.031 ns** (worst) | −0.989 |
| `rgmii_rxd[2]` | +2.021 ns | −3.011 ns | −0.990 |
| `rgmii_rxd[3]` | +2.014 ns | −2.996 ns | −0.982 |
| `rgmii_rx_ctl` | **+2.004 ns** (worst) | −2.987 ns | −0.983 |

Worst setup `+2.004 ns`, worst hold `−3.031 ns`. Every port is violated on hold,
by very nearly the same amount — this is structural, not a placement outlier.
Port-to-port spread is 38 ps on setup and 44 ps on hold, the same order as the
15 ps Task 2c found on TX.

`report_clocks` on that checkpoint, read off the tool rather than asserted:

```
rgmii_rx_clk       8.000  {1.200 5.200}  P  {rgmii_rx_clk}
rgmii_rx_clk_virt  8.000  {0.000 4.000}  V  {}
```

---

## Step 4: the checked edge pairs *are* the physically real ones

This is the part that matters, and it is why the result is trustworthy rather
than merely reported.

**Worst setup, `rgmii_rxd[1]`, slack +2.042 ns:**

```
Requirement:  1.200ns  (rgmii_rx_clk fall@5.200ns - rgmii_rx_clk_virt fall@4.000ns)
Input Delay:  0.200ns
```

Launch is the virtual clock's fall at 4.000 — a nominal data transition. Capture
is the real clock's fall at 5.200. The gap is **1.200 ns, which is the PHY's
delay**. That is the real capture event: the bit that changes when the PHY's
undelayed clock falls is sampled by the real clock's falling edge 1.2 ns later.
Arrival `4.000 + 0.200 + 0.421 = 4.621`; required `5.200 + 1.490 − 0.025 −
(−0.002) = 6.663`. Both are the fast-corner numbers, correct for a setup check.

**Worst hold, `rgmii_rxd[1]`, slack −3.031 ns:**

```
Requirement: -2.800ns  (rgmii_rx_clk fall@5.200ns - rgmii_rx_clk_virt rise@8.000ns)
Input Delay: -1.800ns
```

Same capture edge (real fall@5.200), launched from the virtual rise at 8.000 —
which is **exactly one unit interval (4.000 ns) after the setup launch at
4.000**. That is precisely the hold question: *the next bit must not arrive
before the capture of the current one has completed.* Setup and hold are testing
the same capture event, one UI apart. This is the pairing the original
constraint never produced.

Compare the pairing the committed constraint produces at zero phase, which Task 4
reported and I reproduced: setup `rgmii_rx_clk fall@12.000 - rgmii_rx_clk_virt
fall@4.000` (an 8.000 ns requirement — two whole unit intervals of slop, which is
why setup "passed" with +5 to +6 ns) and hold `rgmii_rx_clk rise@0.000 -
rgmii_rx_clk_virt fall@4.000`. Those two checks are 12 ns apart. Neither
describes a capture event that occurs.

I also checked the arithmetic independently rather than trusting the slack line.
Predicting from the derivation before running anything:

```
setup slack = (Δ + Dclk_fast - unc + tsu) - (M + Ddat_fast)
            = (1.200 + 1.490 - 0.025 + 0.002) - (0.200 + 0.421)  = +2.046
hold  slack = (m + Ddat_slow + UI) - (Δ + Dclk_slow + unc + thold)
            = (-1.800 + 1.395 + 4.000) - (1.200 + 5.210 + 0.025 + 0.191) = -3.031
```

Measured: `+2.042` and `−3.031`. Agreement to 4 ps and 0 ps respectively, on a
number I wrote down before the tool did. The model is the tool's model.

---

## Step 5: the sign-flip sanity check

**5a — phase deliberately doubled** (`-waveform {2.400 6.400}`, input delays left
at their correct values, so the phase error is a clean +1.200 ns):

| Port | Setup at Δ=1.200 | Setup at Δ=2.400 | Hold at Δ=1.200 | Hold at Δ=2.400 |
|---|---|---|---|---|
| `rgmii_rxd[0]` | +2.019 | +3.219 | −3.001 | −4.201 |
| `rgmii_rxd[1]` | +2.042 | +3.242 | −3.031 | −4.231 |
| `rgmii_rxd[2]` | +2.021 | +3.221 | −3.011 | −4.211 |
| `rgmii_rxd[3]` | +2.014 | +3.214 | −2.996 | −4.196 |
| `rgmii_rx_ctl` | +2.004 | +3.204 | −2.987 | −4.187 |

Every setup slack moved **+1.200 ns** and every hold slack moved **−1.200 ns**,
exactly, on every port. That is the signature of a constraint measuring the real
relationship: moving the declared capture edge later by 1.2 ns buys 1.2 ns of
setup and costs 1.2 ns of hold, one for one. The `Requirement:` line moved with
it (`2.400ns (rgmii_rx_clk rise@2.400ns - rgmii_rx_clk_virt rise@0.000ns)`), and
the pairing stayed one UI apart, so the check stayed meaningful while it moved.

**5b — phase set back to zero** (the committed state's phase, correct input
delays): setup jumps to `+8.842`, hold to `−1.831`, and the `Requirement:` line
reverts to `8.000ns (… fall@12.000 - … fall@4.000)`. The pairing decouples: the
setup and hold checks are no longer one UI apart, so their slacks stop trading
against each other and both become meaningless. This is the original bug,
reproduced deliberately and identified by the edge pairing rather than by the
slack.

**5c — a variant that "passes", and why it is rejected.** Declaring
`-waveform {5.200 9.200}` with delays tracked (`max 4.200 / min 2.200`) reports
worst setup `+2.004` and worst hold `+1.769` — both positive, a clean build. It
is wrong twice over and is exactly the trap this task was told not to fall into:

* It puts the real clock's *rising* edge where the physical *falling* edge is —
  a one-UI shift on a DDR clock is a polarity inversion, and the IDDR's
  rise/fall nibble mapping (`gm_byte = {d_fall, d_rise}`) depends on which
  physical edge is which. This is the V-17 defect class.
* Its hold check reads `Requirement: -6.800ns (rgmii_rx_clk fall@1.200ns -
  rgmii_rx_clk_virt rise@8.000ns)` — capture 6.8 ns *before* launch, 1.7 unit
  intervals away from the setup check's capture event. It passes because it is
  not checking anything, which is precisely how the committed constraint passed.

---

## Why no constraint fixes this: the invariant, and the root cause

Note the "Sum" column in Step 3: every port sits at **−0.98 to −0.99 ns**, and
Step 5a shows setup and hold trading one-for-one as the phase moves. That is not
a coincidence. As long as the setup and hold checks stay on the same capture
edge one UI apart — i.e. as long as the constraint is *meaningful* — the sum of
the two slacks is independent of Δ, of `max`, and of `min`:

```
setup_slack + hold_slack
  = (TsetupR_min + TholdR_min)              the declared eye
  - (skew_slow - skew_fast)                 clock-vs-data skew spread across corners
  - thold - tsu_term - 2 x uncertainty
```

Substituting the numbers Vivado printed for this build:

```
skew_slow = Dclk_slow - Ddat_slow = 5.210 - 1.395 = 3.815 ns
skew_fast = Dclk_fast - Ddat_fast = 1.490 - 0.421 = 1.069 ns
spread                                          = 2.746 ns

budget needed = 2.746 + 0.191 (thold) - 0.002 (negative tsu) + 0.050 (2 x unc)
              = 2.985 ns
budget available = TsetupR_min + TholdR_min      = 2.000 ns
deficit                                          = 0.985 ns
```

Measured sums: −0.982 to −0.990. The arithmetic and the tool agree.

**The root cause is the RX clock network, not the constraint.** The clock from
pin K18 to the IDDR `C` pins takes:

| Segment | Fast corner | Slow corner | Spread |
|---|---|---|---|
| IBUF (K18) | 0.245 | 1.477 | 1.232 |
| net IBUF→BUFG | 0.634 | 1.972 | 1.338 |
| BUFG cell | 0.026 | 0.096 | 0.070 |
| net BUFG→IDDR (fo=142) | 0.585 | 1.665 | 1.080 |
| **total to IDDR C** | **1.490** | **5.210** | **3.720** |
| data IBUF→IDDR D, for comparison | 0.421 | 1.395 | 0.974 |

The data path has no counterpart to the BUFG and its two nets, so 2.746 ns of
that spread is uncompensated. Geometrically: the capture edge lands
**1.069 ns** into the unit interval at the fast corner and **3.815 ns** into it
at the slow corner. The guaranteed eye is the 2.000 ns arc `[3.000, 4.000] ∪
[0.000, 1.000]` (mod the 4.000 ns UI, centred on the nominal capture point). The
sweep from 1.069 to 3.815 crosses the entire 2.000 ns *dead* zone between those
arcs. At neither corner is the capture comfortably in the eye, and at mid-corner
it sits in the middle of the data transition.

This contradicts B.1b's conclusion, and it is worth stating plainly:
`rtl/gem_rgmii_rx.v`'s header says *"No IDELAY, and that is a decision rather
than an omission … an IDDR clocked directly by the recovered clock is sufficient
for v1."* That reasoning accounts for the PHY's 1.2 ns delay at the **pins** and
omits the FPGA's own clock-network insertion delay **inside** the chip. Task 1's
throwaway `read_xdc`-against-checkpoint verification could not catch it, because
with the zero-phase constraint the tool was never checking a real capture event.
Wiring the constraint into the real build (Task 4) and giving it the right phase
(this task) is the first time anything in this project has measured it.

### What would fix it, with a falsifiable acceptance criterion

The constraint closes iff the clock-vs-data skew **spread** drops below

```
TsetupR_min + TholdR_min - thold + tsu_term - 2 x unc
  = 2.000 - 0.191 + 0.002 - 0.050 = 1.761 ns
```

against **2.746 ns** today. So roughly 1.0 ns of clock-network delay spread has
to go. Two standard ways, both RTL changes and both outside a constraints task:

1. **BUFIO + BUFR instead of BUFG for the RX clock.** This is the textbook
   7-series RGMII RX answer: a BUFIO drives the ILOGIC/IDDRs in its own clock
   region with a short, low-spread regional path, and a BUFR (`BYPASS`) drives
   the fabric. I confirmed the resources exist and reach: K18 is
   `IO_L13P_T2_MRCC_15` (`IS_CLK_CAPABLE = 1`), and **all six** RX I/O sites are
   in clock region **X0Y1** — `rgmii_rx_clk` `IOB_X0Y74`, `rgmii_rxd[0..3]`
   `IOB_X0Y73/52/57/78`, `rgmii_rx_ctl` `IOB_X0Y80` — where `BUFIO_X0Y4..7` and
   `BUFR_X0Y4..7` are available. This removes the BUFG cell and both long nets
   (2.418 ns of the 2.746 ns spread) and replaces them with a regional path.
2. **An MMCM/PLL on `rgmii_rx_clk` with the BUFG inside its feedback path**,
   which deskews the clock network by construction (the network delay is
   cancelled rather than tolerated). B.2 has MMCM headroom (1 of 5 used). This
   costs a second MMCM on a recovered clock, with the jitter and lock-time
   questions that implies.

What does **not** help, and I checked each rather than assuming:

* **Any phase or input-delay value.** Proven above and demonstrated in Step 5a —
  it moves setup and hold one-for-one and the sum never changes.
* **A fixed IDELAYE2 on the data.** It shifts the mean capture point, exactly
  like a phase change, and buys setup at hold's expense one-for-one. It does not
  reduce the clock network's spread, which is the binding term.
* **Referencing `set_input_delay` to the real clock instead of a virtual one.**
  For an input port Vivado uses the clock's latency at its *definition point*
  (the pin, i.e. zero) on the launch side and the full propagated network on the
  capture side, whether or not the two clocks are the same object. The asymmetry
  is identical.
* **Declaring a wider eye.** It would take `TsetupR = TholdR ≈ 1.49 ns` to
  close, which is more than the datasheet guarantees. That is manufacturing
  margin, not measuring it.

---

## Step 6: the derivation document

**Not updated**, deliberately. `Documents/RGMII I-O Timing Derivation.md`'s RX
section describes a constraint that is not in the tree in corrected form, and
writing a corrected derivation into it while the tree still carries the old one
would make the document disagree with the file it documents — the same class of
problem as the bug itself. Everything the update needs is in Step 1 and the
root-cause section above; it should land in the same commit as the fix, once the
clocking question is settled, since the numbers it records depend on which
option is chosen.

## Step 7: verification

* `D:/Vivado/2024.2/gnuwin/bin/make.exe check` → **28 of 28 scenario(s)
  passed**, run on the reverted tree. No RTL or simulation input was touched at
  any point in this task.
* `python scripts/build.py impl gem_top` with the corrected constraints → gate 0
  (critical warnings) PASS, gate 1 (latches) PASS, **gate 2 refuses**:
  `WNS = 0.058 ns, WHS = -3.031 ns`. Gate 3 not reached.
* `python scripts/build.py bitstream gem_top` → **not run.** It cannot reach
  gate 3 while gate 2 refuses, and running it would only reproduce the same
  refusal more slowly.
* **No commit was made.**

I used `impl`, never `synth`, for every gate-2 check, per Task 4's finding that
`TARGET=="synth"` returns before implementation.

## Files changed

**None.** The working tree is byte-identical to how I found it:

```
$ git status --short
 M scripts/build.tcl
?? docs/
?? stage6_plan.md

$ git diff --stat
 scripts/build.tcl | 41 ++++++++++++++---------------------------
 1 file changed, 14 insertions(+), 27 deletions(-)
```

`git diff --stat` names `scripts/build.tcl` and nothing else. **I never edited
`scripts/build.tcl`** — that diff is Task 4's, unchanged (14 insertions, 27
deletions, the same shape Task 4's report recorded), and I confirmed it before
starting and again after finishing. `constrs/clocks.xdc` and
`constrs/rgmii_timing.xdc` were edited to run Step 3's real build and then
restored from copies taken before the edit; neither appears in `git diff`.
`docs/` and `stage6_plan.md` are pre-existing untracked files, untouched.

Scratch Tcl probes were written to the session scratchpad, and their report files
to `build/` (gitignored); the latter were deleted after use.

## Self-review

* **Did I confirm the edge pairs rather than trust the slack?** Yes — Step 4
  reads the `Requirement:` lines for both checks and shows they name the same
  capture edge with launches one UI apart. I also rejected a *passing*
  configuration (5c) on exactly that evidence, which is the test of whether the
  discipline is real.
* **Did I predict before measuring?** Yes — the derivation predicted +2.046 /
  −3.031 before the build ran; measured +2.042 / −3.031.
* **All five ports, both checks?** Yes, individually, on the real build. Not
  generalised from one.
* **One Vivado batch at a time?** Yes, every invocation was sequential.
* **Contamination caught.** An early exploratory sweep re-issued
  `set_input_delay` on an already-constrained checkpoint; I found that
  `set_input_delay` without `-add_delay` cleared the `-max` entries but *not* the
  `-min` ones, so several trials silently kept a stale `-min` and Vivado used the
  worse of the two. I discovered this by reading the `Input Delay:` line in the
  detailed reports and noticing it disagreed with what I had set. Every number
  reported above is from either a freshly-opened checkpoint or the real build,
  and I re-verified the binding `Input Delay:` value in each detailed report.
  Worth flagging for anyone else iterating constraints against a checkpoint.
* **Did I touch the TX section?** No.

## Concerns

1. **This is a design defect, not a constraint defect, and it is bigger than
   this task.** RGMII RX capture is not reliable across PVT with a BUFG-clocked
   IDDR on this board. It blocks Task 4 and it invalidates B.1b's "no IDELAY
   needed for v1" conclusion and `rtl/gem_rgmii_rx.v`'s header comment, both of
   which reason correctly about the PHY's 1.2 ns delay at the pins and omit the
   FPGA's internal clock insertion delay. Both should be corrected alongside
   whatever fix is chosen.
2. **Somebody should sanity-check my reading of the RGMII window before the RTL
   changes.** Everything above rests on `TsetupR_min = TholdR_min = 1.0 ns`
   giving a 2.000 ns guaranteed eye — Task 1's reading of B.1b, which I kept. If
   the real datasheet number is more generous the deficit shrinks, though it
   would take an eye of ~2.99 ns (a 1.49 ns window each side) to vanish, which
   I do not believe RGMII v2.0 guarantees. A.2 already flags the KSZ9031RNX
   datasheet as read online and unverified against the physical part.
3. **The corrected constraint is worth landing even before the clocking fix, if
   somebody decides gate 2 refusing is the honest state.** It is verified, it is
   in Step 2 ready to apply, and it makes the tool check the real relationship.
   I did not land it because it would leave `impl`/`bitstream` failing, which is
   a call for the user rather than for me. Say the word and it is a two-file
   edit.
4. **The estimate for option 1 (BUFIO/BUFR) is an estimate.** I confirmed the
   resources exist and are reachable, and I derived the ≤1.761 ns spread the fix
   must achieve, but I did not build it — that needs RTL. The criterion is
   falsifiable: re-run this task's Step 3/4 against the new clocking and the
   sums in the per-port table should come out positive.
