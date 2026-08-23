# Task 4d report: the RX MMCM deskew -- built, measured, BLOCKED

## Status: BLOCKED

The deskew was implemented exactly as `Documents/RX Clock Deskew Design.md`
revision 2 specifies, routed, and measured against criterion A's two-sided
test. **It fixed what it was built to fix and failed on what nobody had
estimated.** Hold is clean everywhere; setup now fails on all five RX ports by
~2.1 ns, and the deficit is structural rather than constraint-related.

Nothing downstream was written assuming success: this report is the stop the
design document's Step 0 calls for.

## What was built

* `rtl/gem_rx_mmcm.v` -- MMCME2_BASE, D=1 / M=9.000, VCO 1125 MHz, CLKOUT0 =
  125 MHz @ 0 deg, `CLKFBOUT -> BUFG u_bufg_fb -> CLKFBIN`, one forward BUFG
  (`u_bufg_rx`) carrying IDDR capture and fabric together. Behavioural model
  included (see "Behavioural model defects found by its own testbench").
* `rtl/gem_clk_rst.v` -- `u_rx_mmcm`, the clk50 reset supervisor (registered,
  async-preset output, 80 ns pulse / retry period parameterised, default
  327.68 us), `u_rx_rst` retargeted onto the deskewed clock and lock-gated
  (`tx_rst_n & rx_mmcm_locked`), new `u_rx_path_rst` producing
  `rx_path_rst_n`.
* `rtl/gem_mac.v` -- port renamed `rgmii_rx_clk` -> `rx_clk` (it no longer
  carries the pin); Step 3b rewiring: FIFO read side, egress, and all five
  counter-event synchronisers moved to `rx_path_rst_n`; stats deliberately
  left on `tx_rst_n`.
* `rtl/gem_top.v` -- wiring including the seventh crossing the design document
  missed (`u_ev_fifo_drop`, destination half moved to `rx_path_rst_n`); LED[0]
  becomes `mmcm_locked & rx_mmcm_locked`; `rxlock` field added to the UART
  record (parser and fixtures updated).
* `scripts/build.tcl` -- gate 1c: the RX capture-clock anchor must resolve to
  exactly one clock or the build refuses (the XDC cannot assert this itself;
  an `if` in XDC is a CRITICAL WARNING -- measured).

## Go/no-go measurement (Step 0)

`python scripts/build.py impl gem_top`, post-route, corrected RGMII
constraints wired:

```
==> RX capture-clock anchor check: PASS (clkout0_raw)
==> Constraint coverage check: PASS
==> WNS (setup) = -2.109 ns, WHS (hold) = 0.094 ns
Build refused: negative setup slack (WNS = -2.109 ns).
```

Per port (`get_timing_paths -from <port> -delay_type max|min`):

| Port | Setup | Hold | Sum |
|---|---|---|---|
| `rgmii_rxd[0]` | -2.096 | +1.849 | -0.247 |
| `rgmii_rxd[1]` | -2.067 | +1.824 | -0.243 |
| `rgmii_rxd[2]` | -2.087 | +1.844 | -0.243 |
| `rgmii_rxd[3]` | -2.100 | +1.854 | -0.246 |
| `rgmii_rx_ctl` | -2.109 | +1.862 | -0.247 |

TNS -10.459 across exactly 5 endpoints (the five RX pins); THS 0.000. TX
unaffected.

## What worked

The deskew mechanism itself. Clock-network corner-to-corner spread to the
IDDR collapsed from 3.720 ns (raw BUFG, task-4a) to **0.635 ns**, and hold --
the check that failed -3.031 ns before -- is met everywhere with +0.094 ns
worst slack.

## What failed, and why

Segment-by-segment clock path to the IDDR C pin, slow corner, from the routed
checkpoint:

| Segment | Fast | Slow |
|---|---|---|
| IBUF (K18) + net to MMCM clk_in | ~1.05 | 2.569 |
| MMCME2_ADV internal (loop alignment = minus fb path) | -6.062* | -7.208 |
| forward: net + cell + distribution net | 2.041* | 3.187 |
| **capture edge vs waveform origin** | **-0.817** | **-1.452** |

(*BUFG-build numbers shown; see task-4d2-report.md for why the BUFH rebuild
produced the same residues shifted by a common mode.)

With skew defined as in task-4b (clock-minus-data insertion):

```
skew_setup-side = DCD_slow  - Ddat_slow  = -1.452 - 1.496 = -2.948   (need >= -0.977)
skew_hold-side  = DCD_fast  - Ddat_fast  = -0.817 - 0.263 = -1.080   (need <= +0.784)
interval width  = 1.868 ns against the 1.761 ns window
```

Three verified consequences:

1. **No static shift closes this build.** Centering needs +1.971 ns of
   capture-edge delay; hold can give up only +1.862 ns. The per-port sums sit
   at a uniform -0.245 ns, which is shift-invariant.
2. **The interval is too wide even for perfect centering** (~0.05 ns per side
   over). Root causes: data-side IBUF corner spread (0.263 <-> 1.496 ns =
   1.233 ns, placement-varying) plus residual clock spread (0.635 ns).
3. **The asymmetry is not placement-recoverable.** Constraining `u_bufg_fb`
   toward the CMT moves the MMCM out of K18's clock region instead
   (`Place 30-99`, IO Clock Placer failure -- measured).

The spec escape was checked and closed: KSZ9031RNX DS00002117J Table 7-1
(p.58) gives TRsetup = TRhold = 1.0 ns minimum in integrated-delay mode, so
the 2.000 ns eye behind every bound here is the real guarantee.

The design document's Step 2d IDELAYE2 fallback is **wrong-signed** for this
failure mode: the interval sits early, and adding data delay pushes it
further down.

## Behavioural model defects found by its own testbench

Two real bugs in the simulation-only branch, both caught the moment the
rewritten `tb_gem_clk_rst` exercised lock/recovery:

1. **Watchdog aliasing.** The state-comparison watchdog (sample a toggle every
   CLKIN_WATCH_NS, flag stop when unchanged) aliases whenever the window is an
   integer number of half-periods: at exactly 40 ns = 5 x 8 ns the sampled
   toggle never changed and the model never locked; at 37 ns it re-asserted
   "stopped" intermittently, clearing the lock counter mid-acquisition.
   Replaced with elapsed-time-since-last-edge detection, which has no parity
   to alias.
2. **Phantom first edge.** Gating `clk_out` on `locked` makes the wire jump
   from 0 to clk_in's current level when lock rises -- an edge unrelated to
   the clock grid, which desynchronised the synchronous-deassert check by half
   a period. `clk_out` now tracks clk_in whenever rst is out and the clock
   runs; safety before lock belongs to the lock-gated resets upstream, which
   is where UG472 p.83's warning is actually honoured.


## Open question recorded, not resolved: the half-cycle residue

The capture edge lands -1.452 ns relative to the declared waveform origin --
and the fb/fwd difference that produces it (4.021 ns slow) is suspiciously
close to half a unit interval. Two readings are open:

* The tool's compensation model for this configuration genuinely delivers the
  output edge anti-phase to the declared assumption, in which case the
  constraint's declared phase and input delays need re-deriving against the
  real edge positions before any margin number is meaningful.
* The residues are real routing and the near-half-period value is coincidence.

This matters for correctness of the model before it matters for margin, and
it is recorded here so the next session starts from the question rather than
rediscovering it.

## Verification state at close

* `make check`: 29 of 29 scenarios, lint clean 8/8 tops, host tests green.
* `impl`/`bitstream`: refuse at gate 2 (WNS -2.109), by design and honestly.
* `tb_gem_clk_rst` rewritten for the new reset architecture (cold start,
  late-start ordering, async assert on link drop, stop-restart recovery via
  the supervisor with overridden retry period, rapid flap, plus the carried
  tx/PHY properties).
* Deferred to a later task: criterion D6/D7/D8 (FIFO integrity across link
  drop, phantom statistics, AXI-S abort demonstration) in `tb_gem_mac_rx`;
  the REF_JITTER1 = 0.125 second run of criterion A.

