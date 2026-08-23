# RX Clock Deskew -- BUFH Variant

*The design for retrying the receive-clock deskew with regional (`BUFH`) clock
buffers instead of global (`BUFG`) ones, after the BUFG variant failed its
go/no-go measurement. Written before any RTL changes, because the failure it
responds to was itself caused by building on an untested assumption about a
clock network, and because its central claim -- that a shorter, more symmetric
feedback path fixes both the position and the width of the capture interval --
has to survive contact with the router before anything downstream is written.*

*Task 4d continuation, Stage 6 part 2. Companion to
[`RX Clock Deskew Design.md`](RX%20Clock%20Deskew%20Design.md) (revision 2,
the BUFG variant); reset semantics, supervisor, and the `rx_path_rst_n`
machinery carry over from that document unchanged.*

---

## Where this came from: the measured failure of the BUFG variant

The BUFG deskew was built, routed, and measured on 2026-08-23. It fixed what it
was built to fix and failed on what nobody had estimated:

| Quantity | Before (raw BUFG) | After (deskewed BUFG) | Required |
|---|---|---|---|
| Clock network corner-to-corner spread | 3.720 ns | **0.635 ns** | -- |
| WHS (whole design) | -3.031 ns | **+0.094 ns** | >= 0 |
| WNS (all five RX input ports) | +2.004 ns | **-2.067 .. -2.109 ns** | >= 0 |

The deskew collapsed the clock-network insertion-delay spread by 6x and hold
went clean everywhere. But the capture edge landed in the wrong place: the
feedback network through its BUFG measured **7.208 ns** at the slow corner
against the forward path's **3.187 ns**. Since the loop subtracts the feedback
path from the capture clock, the ~4 ns asymmetry landed directly on the RGMII
capture edge -- early, failing setup on all five pins while hold passed with
~1.86 ns spare.

Three consequences, each verified rather than assumed:

1. **The window cannot be escaped by shifting.** Setup needs +1.971 ns of
   capture-edge delay; hold can give up only +1.862 ns before *it* violates.
   Any static shift leaves >= ~0.107 ns violated on one side. Proven from the
   per-port slacks, whose setup+hold sums sit at a uniform -0.245 ns.
2. **The interval is also slightly too wide.** Width 1.868 ns against the
   1.761 ns window -- the same excess shows up as that -0.245 ns sum. Even a
   perfect recentering fails by ~0.05 ns per side. Both defects trace to the
   same root: the feedback path is long, and its corner spread does not cancel
   the forward path's.
3. **Placement cannot shorten the feedback path.** Constraining `u_bufg_fb`
   toward the CMT made the clock placer move the MMCM out of the RX pin's
   clock region to satisfy its own half-side rule, and placement failed
   outright (`Place 30-99`, IO Clock Placer). The BUFG feedback return is
   architecturally long regardless of where the buffer sits.

The spec escape was checked and closed: KSZ9031RNX DS00002117J Table 7-1
(p.58) gives `TRsetup = TRhold = 1.0 ns min` in integrated-delay mode -- the
2.000 ns eye the window was derived from is the real guarantee. There is no
wider eye to be had from the datasheet.

## What this document decides

| Question | Decision |
|---|---|
| Buffer type, forward and feedback | `BUFH` -- both paths, matched types |
| Region confinement | Every cell clocked by `rx_clk_deskew` constrained to clock region X0Y1 |
| MMCM configuration | Unchanged from revision 2 (M=9.000/D=1, VCO 1125 MHz, CLKOUT0 125 MHz @ 0 deg) |
| Static phase trim | An expected step, not a contingency: measure first, trim CLKOUT0_PHASE in 111.1 ps steps |
| Reset semantics, supervisor, `rx_path_rst_n` | Unchanged from revision 2 |
| Instance names | `u_bufg_rx` / `u_bufg_fb` retained even though they are BUFHs -- the XDC anchor and gate 1c key off these names |
| Go/no-go criterion | Unchanged: task-4b's two-sided test on all five ports, post-route, at REF_JITTER1 = 0.010 and 0.125 |

## Step 1: the BUFH topology, and its legality

### Citations (UG472 v1.13, March 1, 2017)

* **p.19 (Ch. 1, Figure 1-4 discussion):** "Any of the four clock-capable
  input pins can drive the PLL/MMCM in the CMT and the BUFH. [...] BUFG and
  BUFH share 12 routing tracks in the HROW and **can drive all clocking points
  in the region**."
  This is the fact the BUFIO variant lacked: a regional buffer that reaches
  not just the ILOGIC ring but every fabric flop in the region, so ONE buffer
  type carries the whole domain and the capture clock is not split from the
  fabric clock.
* **p.14:** "The horizontal clock buffer (BUFH/BUFHCE) allows access to the
  global clock lines in a single clock region through the horizontal clock
  row." One region per BUFH -- which is why Step 3 confines the domain to one.
* **p.80 (CLKFBIN):** "Must be connected either directly to the CLKFBOUT for
  internal feedback or IBUFG [...], BUFG, **BUFH**, or interconnect." BUFH is
  a legal feedback driver.
* **p.80:** "...the feedback path clock buffer type should match the forward
  clock buffer type with the exception of BUFR." Forward and feedback are
  both BUFH -- matched.
* **p.93:** "When an MMCM is driving both BUFGs and BUFH, only one of the
  clock buffers that is also used in the feedback path is deskewed." The RX
  MMCM therefore drives ONLY BUFHs -- no mixing. (The crystal MMCM's BUFGs
  belong to a different tile and different clock; the restriction is per-CMT.)
* **p.19:** "Clock sources from one region can drive clock buffer resources
  in its own region as well as in a horizontally adjacent region." The MMCM
  in X0Y1 drives BUFHs in X0Y1 -- its own region, no backbone crossing.

### Why this fixes the measured failure

The deskew loop cancels exactly the feedback path: capture edge =
`pin_arrival_at_MMCM - fb + fwd`. The BUFG variant failed because `fb` was a
~7.2 ns trip up to the device-half spine and back into the CMT, while `fwd`
was a ~3.2 ns local distribution -- a structural ~4 ns asymmetry no placement
could remove. Both BUFH paths live in the same clock region's horizontal row:
short, structurally similar, routed by the same resources. The expectation is
not that `fb == fwd` exactly -- it is that their difference lands within
tens-to-hundreds of picoseconds, where the 111.1 ps static-phase grid can
absorb it, and that their *corner spreads* track each other closely enough
that the interval width drops below the 1.761 ns window with margin.

What is NOT being claimed: that BUFH insertion delay is specified anywhere it
can be cited from. DS181 has no BUFH delay table. The magnitude claim is
structural (same-row routes, matched buffer types); the number comes from the
go/no-go measurement, as it should have the first time.

### What happens to `rtl/gem_rx_mmcm.v`

The two `BUFG` instantiations become `BUFH`. Nothing else in the module
changes: same MMCME2_BASE configuration, same ports, same behavioral model.
The instance names stay `u_bufg_rx` and `u_bufg_fb` -- they are load-bearing
(`constrs/rgmii_timing.xdc` anchors the derived-clock lookup and
`scripts/build.tcl`'s gate 1c keys off exactly this path), and renaming them
buys nothing.

## Step 2: configuration, and why phase trim is now part of the plan

MMCM arithmetic is unchanged and remains as documented in revision 2, Step 2b:
PFD 125 MHz, VCO 1125 MHz (M=9.000, D=1), CLKOUT0 = 125 MHz, CLKFBIN = PFD.
All DS181 Table 37 checks pass identically. `STARTUP_WAIT` stays `"FALSE"`
(bricks a linkless board otherwise); `CLOCK_DEDICATED_ROUTE FALSE` stays
forbidden everywhere.

Revision 2 argued `CLKOUT0_PHASE = 0.000` from the assumption that the deskew
lands the capture edge at the pin arrival and the PHY's 1.2 ns default delay
centers the eye. That argument survives in form but not in precision: the
loop's actual fixed point leaves a residual `(fwd - fb)` whose value is a
measurement, not a derivation. The honest sequence is:

1. Build with `CLKOUT0_PHASE = 0.000`, route, measure `skew_fast` / `skew_slow`
   per task-4b's definitions.
2. Compute the centering trim: the midpoint of the window is -0.097 ns of
   skew; if the measured interval sits off-center by more than half the
   remaining margin, shift `CLKOUT0_PHASE` by the difference rounded to the
   nearest whole step of the grid (45 deg / CLKOUT0_DIVIDE = 5 deg = 111.1 ps;
   positive phase delays the output and moves both skews UP).
3. Rebuild once, re-measure, and only then apply the acceptance criteria.

A trim that has to exceed ~0.9 ns (eight steps) to center the interval is not
a trim, it is a symptom -- stop and report rather than tuning past it.


## Step 3: region confinement

A BUFH reaches only its own clock region, so every cell clocked by
`rx_clk_deskew` must live in X0Y1 -- the region that already holds the RX I/O
bank (K18 and the five data pins, IOB sites in X0Y1) and the CMT. The design
is ~5% utilized; one region holds it many times over.

Constrained instances (hierarchical `CLOCK_REGION` property, which applies to
every leaf cell beneath):

* `u_mac/u_rgmii_rx` -- the IDDR capture cells (already there by pin placement)
* `u_mac/u_rx_ctrl` (deframer), `u_mac/u_rx_crc` -- rx_clk fabric
* `u_mac/u_rx_fifo` -- BOTH halves land in X0Y1. The write half must; the read
  half is tx-domain but confining it too is harmless at this utilization and
  avoids splitting a hierarchy across a constraint boundary by flop-level
  bookkeeping.
* `u_mac/u_ev_rx_ok` ... `u_ev_rx_rxer` -- each pulse synchroniser's source
  toggle must be in-region; its destination chain comes along for free.
* `gem_top/u_ev_fifo_drop` -- same reasoning.

Everything else (TX path, MDIO, stats, echo, UART, resets, supervisors) stays
unconstrained. The CDC crossings out of the RX domain are timed async and
false-pathed via clock groups exactly as before; moving the destination flops'
neighbors changes nothing about their correctness.

## Step 4: go/no-go acceptance criteria

Unchanged from revision 2 criterion A, applied to this build:

1. Post-route, all five RX ports individually: `skew_fast >= -0.977 ns` AND
   `skew_slow <= +0.784 ns`. The one-sided spread test remains forbidden.
2. The failing-path reports' `Requirement:` lines name real DDR capture events
   one unit interval apart (task-4a-report.md Step 4's method). A passing
   gate 2 alone is not evidence.
3. Run at `REF_JITTER1 = 0.010` (must pass) and `0.125` (margin recorded).
4. TX WNS >= 0; investigate any movement from +0.058 ns rather than treating
   movement as failure.
5. Segment-by-segment insertion-delay table for both BUFH paths, comparable
   with task-4a/4b format.
6. `report_clock_interaction`: no timed paths between the clk50 tree and the
   RX tree; `check_timing` clean through gate 3; gate 1c anchor resolves.

## Step 5: fallback ladder if the measurement fails again

1. **Interval fits but sits off-center** -> phase trim per Step 2, ONE rebuild.
2. **Width still exceeds 1.761 ns** -> compare which side grew. If the clock
   spread did not shrink below ~0.5 ns, the symmetry hypothesis is dead:
   record, revert to BUFG variant or stop, and take stock with the board in
   hand. No third topology gets invented inside this task.
3. **Placer/DRC refuses BUFH -> IDDR or the MMCM/BUFH arrangement** -> record
   the exact DRC text, stop, report. That would falsify the p.19 reading and
   matters beyond this project.

## What is not confirmed

* The actual fb/fwd residual and its corner tracking under BUFH -- the whole
  point of the go/no-go.
* Whether the tools accept an MMCME2_ADV driving two BUFHCE/BUFHs with one in
  feedback without demanding extra properties. Expected yes from p.19/p.93;
  proven only by building it.
* Whether the HROW distribution to fabric flops vs to the ILOGIC ring carries
  meaningfully different corner spreads. If it does, the width may not shrink
  as hoped (Step 5 item 2).


