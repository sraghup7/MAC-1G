# Stage 9 — known issues and open items

Stage 9's fourth item, verbatim from `fpga_project_flow.md`:

> **Known issues and open items** — written down. An undocumented limitation
> becomes a surprise bug later.

This page is that write-up. It exists because the honest answer is scattered
across three files that each state it for a different reason — `verification_
plan.md` for the requirement it traces to, `bringup_checklist.md` for the step
that closes it, the README for the headline number — and nobody reading only
one of them gets the whole picture. This page links rather than restates: the
reasoning and the numbers live in one place each, and stay there.

**Every item below is blocked on hardware, not on coverage.** `verification_
plan.md`'s own status table is the authority on that (29 of 29 runs, lint
clean, every requirement traced except the stated R12 non-goal — B.4's
coverage criterion, met mechanically). What follows is not "untested"; it is
"cannot be settled by anything short of the board," which is a different,
narrower claim.

## The five items

| # | What's unresolved | Closes at | Full reasoning |
|---|---|---|---|
| **R14 / R20 / V-2** | RGMII I/O timing margin is thin on both directions and neither can be confirmed by simulation. Re-derived for the real chip, a JLSemi JL2121(D) (A.2's B.5 correction, `docs/reports/stage9/rgmii-jl2121-retiming-report.md`): TX now closes at **+336 ps** worst case (was +58 ps under the wrong-chip derivation — the mechanism changed too, from an FPGA-generated phase shift to one cancelling an FPGA-internal clock-forwarding asymmetry), and the five RX input-delay checks are still signed off by derivation under the same fenced waiver (Vivado's ZHOLD modeling artifact, task 4e) — confirmed by a post-route build reporting the identical WNS task 4e originally measured. **There is no MDIO pad-skew fallback on this chip** — the JL2121(D) has no MMD register-access mechanism at all; its RX/TX clock delay is a hardware strap, fixed at board population. If the bench shows either margin insufficient, the fallback is a strap rework, not an MDIO write. | Bring-up step 5, a scope or the `make debug` ILA on `GTX_CLK`/`TXD0` and the RX side. | README's timing section · `Documents/RGMII I-O Timing Derivation.md` · `docs/reports/stage9/rgmii-jl2121-retiming-report.md` · `docs/reports/stage6-part2/task-4e-report.md` · `verification_plan.md` rows V-2, R14, R20 |
| **V-6** | The golden CRC has never been checked against a real capture — validation today is the published check value, `zlib` over 2000 vectors, and the residue property, none of which involve a wire. | Bring-up step 5: capture a frame the design transmitted and confirm Wireshark reports its FCS correct. | `verification_plan.md` row V-6 · `bringup_checklist.md` step 5 · `sw/host/gem_host.py echo` produces the frames to capture |
| **V-22** | Three of R10's four RX error classes cannot be provoked from a PC — a commodity NIC computes FCS in hardware and pads runts before transmitting, and RX_ER is the PHY's to assert, not a sender's to request. Only oversize reaches the wire malformed. | Not scoped to any bring-up step — needs a transmitter that owns its own MAC (a second FPGA, a traffic generator, or a NIC whose driver exposes CRC-offload control). Bring-up step 7 is deliberately scoped to oversize plus recovery and says so, rather than quietly sending frames the NIC already repaired. | `verification_plan.md` row V-22 |
| **V-3 / R16** | MDIO's sampling point has a margin simulation structurally cannot measure: the behavioural PHY BFM holds each bit a full period, so it cannot distinguish "sampled just after the MDC rising edge" from "sampled at the stable end of the bit period" — the safer point was chosen by analysis, not proven by test. | Bring-up step 3, alongside reading the PHY ID — no rebuild needed, sweep the request port. | `verification_plan.md` rows V-3, R16 |
| **PHY reset hold time (`tSR`)** | ~~`gem_clk_rst` holds `phy_rst_n` low for ≥10 ms, sourced to the KSZ9031RNX datasheet~~ — **closed 2026-08-27**: JL2121(D) DS009 §4.7.1 specifies t1 ≥ 10 ms (RSTn de-assert after powers ready), t2 ≥ 1 ms (RSTn assert), t3 ≥ 10 ms (RSTn hold after powers ready); the existing 10 ms / 500,000-cycle hold already satisfies all three (same 10 ms, citation corrected in `rtl/gem_clk_rst.v:53`, `rtl/gem_mac_params.vh:128`). No RTL change. | — (no bench step) | `rtl/gem_clk_rst.v` · `rtl/gem_mac_params.vh` · `Manuals/JL2121_datasheet.pdf` §4.7.1 |

## What already closed, so this page isn't mistaken for the whole list

Closing V-25 does not shrink this table — it closed a *different* kind of
question, the board-level-reset half of what a link event does, which
simulation could fully answer on its own (`gem_rx_abort`, `tb_gem_top`
criteria D8/D9). The five items above are a different kind of question —
not more RTL, more test infrastructure, or more careful review, but specific
physical numbers no tool in this build can produce. That is what makes them
a Stage 9 list rather than a Stage 3–7 one.

**Bank 16 VCCIO closed** the same way, and used to be a sixth row here: it
was "assumed 3.3 V from the ALINX manual's general rule," flagged unverified
in `constrs/pins.xdc`. The real manual (`Manuals/AX7035B_UG.pdf`, obtained
after this page's previous revision) states it directly for BANK16 by name —
a dedicated LDO, part number SPX3819M5-3.3 (fixed 3.3V output) — rather than
leaving it to the general rule. `constrs/pins.xdc` and
`Manuals/AX7035B_pinout_notes.md` carry the citation; no bench check needed
first, unlike the five items above.

**A.2 (B.5)'s PHY-identity fallout closed too**, and used to be its own row
here under "RGMII timing budget unconfirmed against the real chip." B.5 found
the board's PHY is a JLSemi JL2121(D), not the KSZ9031RNX A.2 previously
stated; every consequence that followed is now resolved: `rtl/gem_mdio.v`'s
register-0x1F speed/duplex read (was decoding the wrong register on this
chip) and `PHY_ADDR` (was a guessed 0, confirmed strapped to 1) are both
fixed in RTL, and the RGMII AC timing budget the row's "still open" half
referred to is re-derived and confirmed by a real post-route build in
`docs/reports/stage9/rgmii-jl2121-retiming-report.md` — folded into the R14 /
R20 / V-2 row above rather than kept separate, since what's left (the bench
measurement itself) is exactly that row's own open question.
