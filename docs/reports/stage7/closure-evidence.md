# Stage 7 closure evidence pack

Design: `gem_top` on `xc7a35tifgg484-1L` · Vivado 2024.2 · routed checkpoint
`build/post_route.dcp` at the Stage 7 tree. Every number below was read off
the tool at this checkpoint or printed by `scripts/build.tcl` during the run.

## 1. Per-path-group worst slacks (post-route)

| Path group | Setup WNS | Hold WHS | Notes |
|---|---|---|---|
| `clk50` (crystal tree, internal) | **+15.809 ns** | +0.122 ns | clk50-domain registers; enormous margin, as expected at 50 MHz |
| `clk0_raw` (tx_clk = sys_clk domain) | **+1.326 ns** | +0.049 ns | all fabric MAC logic |
| `clkout0_raw` (rx_clk deskewed domain) | **−3.109 ns** | +0.077 ns | the negative figure is *entirely* the five RX input-delay checks -- the documented ZHOLD artifact (task-4e), fenced in gate 2; RX-domain register-to-register paths are inside this group's positive population |
| `rgmii_gtx_clk_gen` (TX I/O) | **+0.058 ns** | +1.645 ns | matches task-2e's committed number exactly |
| `async_default` (unconstrained-domain I/O) | +1.808 ns | +0.621 ns | false-pathed LEDs etc.; sanity only |

Gate 5 additionally confirms: DRC 0 Critical rule hits (22 warnings, triaged),
0 routing errors, power/QoR written as artifacts.

## 2. Corner statement

Vivado's default flow analyses **setup at the slow process corner** and
**hold at the fast process corner** natively (single-corner min/max); no
multi-corner configuration exists to review on a 7-series part in this flow.
The two numbers per group above are therefore already cross-corner by
construction. What the flow does *not* cover, and what the sign-off split
exists for: recovered-clock jitter (bench, criterion A physical half) and
cross-die variation against the PHY (datasheet window).

## 3. Physical reports (new in gate 5)

* **DRC** (`build/gem_top_drc.rpt`): 0 Critical. 22 warnings across four
  rules, all triaged: CFGBVS-1 fixed at source (`constrs/pins.xdc` now sets
  `CFGBVS VCCO` / `CONFIG_VOLTAGE 3.3`); CHECK-3 is REQP-1840 hitting its own
  report cap; PDRC-138 is a cosmetic LUT-pairing note; REQP-1840 ×20 is the
  echo buffer's write index carrying an async reset that feeds RAM address
  pins -- echo is bring-up diagnostics, a reset mid-frame corrupts one echoed
  frame by design (B.4a amendment), documented rather than restructured.
* **Route status**: 2168 of 2168 routable nets fully routed, 0 errors.
* **Power** (`build/gem_top_power.rpt`): 0.388 W total on-chip (0.326 dynamic,
  0.062 static) at **default switching activity -- confidence LOW**; no real
  workload data exists until the bench runs a soak.
* **QoR assessment** (`build/gem_top_qor.rpt`): score **2** ("timing will not
  meet") -- expected by construction: the scorer counts the five waived RX
  input-delay paths, whose negative slack is the documented ZHOLD artifact,
  not a physical failing path.

## 4. Criterion A status

Re-based form (Deskew Design acceptance criteria §A): both REF_JITTER1 runs
recorded -- and the rerun produced a measured finding: the parameter does not
propagate into STA clock uncertainty on this tool/configuration at all
(`task-report-refjitter.md`). The modeled margins cannot be pessimised through
it; jitter exposure is owned entirely by the bench half.

## 5. Methodology

All findings fixed-or-justified in `methodology-triage.md`: LUTAR-1 ×5
(deliberate reset gating, glitch-direction argument per site), TIMING-9 ×1
(superseded by gate 4's stricter asserted inventory). TIMING-10 eliminated by
the gate-4 ASYNC_REG work.
