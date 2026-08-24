# Stage 7 Implementation Plan — Timing Closure & Sign-off

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** turn "the build passes its gates" into a signed-off timing story: every path in the design accounted for (met outright, fenced-waived under a documented derivation, or documented-deliberate), every flow-doc Stage 7 report generated **and read**, and the two long-outstanding timing items (criterion A at REF_JITTER1 = 0.125, methodology findings) closed.

**Architecture:** Stage 7's traditional opt/place/route loop already runs inside every `make impl`, so what remains is closure *evidence*: re-basing acceptance criterion A onto the task-4e regime (its current text demands STA numbers that are provably artifact), running the deferred jitter rerun, triaging the six methodology warnings, and generating the three reports the flow doc lists that do not exist yet (DRC, power, congestion/route-status).

**Tech stack:** Vivado 2024.2 non-project mode (Tcl), Python 3 drivers under `scripts/`, GNU Make from Vivado's `gnuwin` bundle, PowerShell 5.1.

**Spec:** `fpga_project_flow.md` Stage 7 · `spec/PROJECT_SPEC.md` B.2 R19/R20/R24 · `Documents/RX Clock Deskew Design.md` acceptance criteria · `verification_plan.md` R14/R20/R24, V-24. ILA deferred to Stage 8; staying on −1L (owner decisions, recorded 2026-08-24).

## Global constraints

- Branch `charan/dev`; never commit or push `main` without being asked (`CLAUDE.md`).
- PowerShell 5.1 is the primary shell: one command per line, no `&&` chaining.
- Every new refusal demonstrated failing before trusted.
- No constant written twice: part string in `scripts/part.tcl`, RTL constants in `rtl/gem_mac_params.vh`.
- Error messages name only files that exist (`CLAUDE.md`, "Error messages").
- Verified means run: report what was executed and what it printed.
- Full check after each task: `D:/Vivado/2024.2/gnuwin/bin/make.exe check`
- Do **not** restructure the reset topology to silence LUTAR-1 — async assertion into CLR is load-bearing (`Documents/RX Clock Deskew Design.md` Step 3b).

---

### Task 0: Commit this plan

- [ ] Save this document as
      `docs/superpowers/plans/2026-08-24-stage7-timing-closure.md` and commit.

### Task 1: Re-base acceptance criterion A onto the task-4e regime

**Files:** Modify `Documents/RX Clock Deskew Design.md` (acceptance criteria §A),
`verification_plan.md` (V-24 outstanding column).

Criterion A still says "post-route, skew_fast ≥ −0.977 ns and skew_slow ≤ +0.784 ns"
-- measured how? Under the proven ZHOLD artifact those STA skews can never satisfy
it. The honest form:

- physical margins from the loop equation per corner (the task-4e method):
  setup/hold margins ≥ 0 at fast and slow, computed from measured segments;
- STA side: the five endpoints stay inside gate 2's −5.000 ns envelope;
- the `Requirement:`-line pairing check kept (task-4a Step 5c's discipline);
- bench measurement named as the authoritative half.

- [ ] Rewrite §A accordingly, cross-referencing task-4e
- [ ] Update V-24's outstanding items to point at the re-based criterion
- [ ] Doc-only; verified by review against task-4e numbers

### Task 2: Criterion A second pass — REF_JITTER1 = 0.125

**Files:** Modify `rtl/gem_rx_mmcm.v` (`REF_JITTER1 0.010 → 0.125`, then revert);
create `docs/reports/stage7/task-report-refjitter.md`.

- [ ] Temp-edit the parameter, run `python scripts/build.py impl gem_top`
- [ ] Record gate-2 waived slack values (modeled −3.109 baseline vs this run),
      WHS, TX WNS movement (investigate ≠ +0.058, do not assume failure)
- [ ] State plainly: the physical derivation is jitter-independent; what moves is
      only modeled clock uncertainty on the derived clock
- [ ] Revert the parameter; confirm clean rebuild returns −3.109
- [ ] Write the report; tick criterion A's second pass off in V-24

### Task 3: Methodology triage — every finding fixed or justified

**Files:** Create `docs/reports/stage7/methodology-triage.md`.

Inventory (from `build/gem_top_methodology.rpt`):

- **LUTAR-1 ×5** — LUTs driving async CLR/PRE:
  `#1` `u_mmcm/sync → u_tx_rst.CLR`, `#2` `u_rx_mmcm/sync → u_rx_rst.CLR`,
  `#4` `u_tx_rst → u_rx_path_rst.CLR`: reset gating ANDs (`tx_rst_n & locked`
  etc.), deliberate per Step 3b; `#3`, `#5`: the FIFO's
  `rst_eff_n = rst_n && other-domain-rst_n` terms -- same class, and they are
  what makes both pointer sets always assert together (Step 3b property 1).
- **TIMING-9 ×1** — unknown CDC without double-registers: identify the exact
  crossing (candidates: FIFO mem→egress, already inside gate 4's set).

- [ ] For each LUTAR-1: argue safety in writing (which registered outputs drive
      the LUT inputs and why they are edge-aligned) or restructure.
      Default: document, do not restructure.
- [ ] Trace TIMING-9 to its crossing; fold into gate 4's asserted inventory
      explicitly or fix.
- [ ] Commit the triage doc; methodology stays ungated (by design).

### Task 4: Generate the missing Stage-7 reports, gate what deserves it

**Files:** Modify `scripts/build.tcl` (after gate 4), `README.md` gate table,
`spec/PROJECT_SPEC.md` B.4 enumeration.

- [ ] Add `report_drc` → `build/${TOP}_drc.rpt`; refuse on any CRITICAL;
      demonstrate refusing before trusted
- [ ] Add `report_route_status` → `build/${TOP}_route_status.rpt`;
      unrouted nets refuse
- [ ] Add `report_power` → `build/${TOP}_power.rpt`, informational; state the
      switching-activity assumption
- [ ] Add QoR/congestion assessment report, informational
- [ ] Update README "Proven by" + B.4 enumeration for the DRC refusal
- [ ] Verify: clean build PASS; planted-DRC demo refuses; `make check`

### Task 5: Closure evidence pack + documentation truth sweep

**Files:** Modify `verification_plan.md` (R20/R24 rows), `README.md` numbers
block, `spec/PROJECT_SPEC.md`; review `build/post_route_timing.rpt`.

- [ ] Per-clock-pair setup/hold table from the routed checkpoint, recorded in
      the task report
- [ ] Corner statement written down (setup@slow / hold@fast native analysis)
- [ ] R20 row → post-route final numbers; R24 → refreshed; README matches
- [ ] Audit-style spot check for stale claims ("refuses", old WNS values)

### Task 6: Exit-criteria sweep and the closing commit

Exit criteria (all demonstrated, output recorded):

1. `make bitstream` builds `gem_top.bit` with gates 0–4 all PASS
2. Criterion A re-based; both REF_JITTER1 runs recorded
3. Every methodology finding fixed or justified in a committed triage doc
4. DRC/route-status/power/QoR reports generated per build; DRC refusal demonstrated
5. No stale timing claim in any current-truth document
6. `make check` exit 0 at close
