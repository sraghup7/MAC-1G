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
| **R14 / R20 / V-2** | RGMII I/O timing margin is thin on both directions and neither can be confirmed by simulation: TX closes at **+58 ps** worst case, and the five RX input-delay checks are signed off by derivation under a fenced waiver (Vivado's ZHOLD modeling artifact, task 4e) rather than by a passing STA number. | Bring-up step 5, a scope or the `make debug` ILA on `GTX_CLK`/`TXD0` and the RX side. If 58 ps proves insufficient, the fallback (KSZ9031RNX `GTX_CLK` pad-skew register, over MDIO) is already written down, deliberately not implemented. | README's timing section · `Documents/RGMII I-O Timing Derivation.md` · `docs/reports/stage6-part2/task-4e-report.md` · `verification_plan.md` rows V-2, R14, R20 |
| **V-6** | The golden CRC has never been checked against a real capture — validation today is the published check value, `zlib` over 2000 vectors, and the residue property, none of which involve a wire. | Bring-up step 5: capture a frame the design transmitted and confirm Wireshark reports its FCS correct. | `verification_plan.md` row V-6 · `bringup_checklist.md` step 5 · `sw/host/gem_host.py echo` produces the frames to capture |
| **V-22** | Three of R10's four RX error classes cannot be provoked from a PC — a commodity NIC computes FCS in hardware and pads runts before transmitting, and RX_ER is the PHY's to assert, not a sender's to request. Only oversize reaches the wire malformed. | Not scoped to any bring-up step — needs a transmitter that owns its own MAC (a second FPGA, a traffic generator, or a NIC whose driver exposes CRC-offload control). Bring-up step 7 is deliberately scoped to oversize plus recovery and says so, rather than quietly sending frames the NIC already repaired. | `verification_plan.md` row V-22 |
| **V-3 / R16** | MDIO's sampling point has a margin simulation structurally cannot measure: the behavioural PHY BFM holds each bit a full period, so it cannot distinguish "sampled just after the MDC rising edge" from "sampled at the stable end of the bit period" — the safer point was chosen by analysis, not proven by test. | Bring-up step 3, alongside reading the PHY ID — no rebuild needed, sweep the request port. | `verification_plan.md` rows V-3, R16 |
| **Bank 16 VCCIO** | Assumed 3.3 V from the ALINX manual's general rule; the schematic labels the bank's pins `LVCMOS33` but does not state the bank's supply voltage directly. `constrs/pins.xdc` still flags this as an assumption. | Bring-up step 1, if the LEDs behave. | `constrs/pins.xdc` · `bringup_checklist.md` step 1 · `verification_plan.md` row V-21's closure note |

## What already closed, so this page isn't mistaken for the whole list

Closing V-25 does not shrink this table — it closed a *different* kind of
question, the board-level-reset half of what a link event does, which
simulation could fully answer on its own (`gem_rx_abort`, `tb_gem_top`
criteria D8/D9). The five items above are a different kind of question —
not more RTL, more test infrastructure, or more careful review, but specific
physical numbers no tool in this build can produce. That is what makes them
a Stage 9 list rather than a Stage 3–7 one.
