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
| **R14 / R20 / V-2** | RGMII I/O timing margin is thin on both directions and neither can be confirmed by simulation. Re-derived for the real chip, a JLSemi JL2121(D) (A.2's B.5 correction, `docs/reports/stage9/rgmii-jl2121-retiming-report.md`): TX now closes at **+336 ps** worst case (was +58 ps under the wrong-chip derivation — the mechanism changed too, from an FPGA-generated phase shift to one cancelling an FPGA-internal clock-forwarding asymmetry), and the five RX input-delay checks **now close outright at +0.891 to +0.933 ns setup, with no waiver exercised** — see § B.5-RX-1 below, which found the capture edge was landing one whole unit interval late and corrected it; most of what task 4e attributed to a ZHOLD modeling artifact was a real misalignment. The RX half is confirmed on hardware (`rx_ok` advancing, zero error counters); what remains open on this row is the **TX** side. **There is no MDIO pad-skew fallback on this chip** — the JL2121(D) has no MMD register-access mechanism at all; its RX/TX clock delay is a hardware strap, fixed at board population. If the bench shows either margin insufficient, the fallback is a strap rework, not an MDIO write. | Bring-up step 5, a scope or the `make debug` ILA on `GTX_CLK`/`TXD0` and the RX side. | README's timing section · `Documents/RGMII I-O Timing Derivation.md` · `docs/reports/stage9/rgmii-jl2121-retiming-report.md` · `docs/reports/stage6-part2/task-4e-report.md` · `verification_plan.md` rows V-2, R14, R20 |
| **V-6** | The golden CRC has never been checked against a real capture — validation today is the published check value, `zlib` over 2000 vectors, and the residue property, none of which involve a wire. | Bring-up step 5: capture a frame the design transmitted and confirm Wireshark reports its FCS correct. | `verification_plan.md` row V-6 · `bringup_checklist.md` step 5 · `sw/host/gem_host.py echo` produces the frames to capture |
| **V-22** | Three of R10's four RX error classes cannot be provoked from a PC — a commodity NIC computes FCS in hardware and pads runts before transmitting, and RX_ER is the PHY's to assert, not a sender's to request. Only oversize reaches the wire malformed. | Not scoped to any bring-up step — needs a transmitter that owns its own MAC (a second FPGA, a traffic generator, or a NIC whose driver exposes CRC-offload control). Bring-up step 7 is deliberately scoped to oversize plus recovery and says so, rather than quietly sending frames the NIC already repaired. | `verification_plan.md` row V-22 |
| **V-3 / R16** | MDIO's sampling point has a margin simulation structurally cannot measure: the behavioural PHY BFM holds each bit a full period, so it cannot distinguish "sampled just after the MDC rising edge" from "sampled at the stable end of the bit period" — the safer point was chosen by analysis, not proven by test. | Bring-up step 3, alongside reading the PHY ID — no rebuild needed, sweep the request port. | `verification_plan.md` rows V-3, R16 |
| **PHY reset hold time (`tSR`)** | ~~`gem_clk_rst` holds `phy_rst_n` low for ≥10 ms, sourced to the KSZ9031RNX datasheet~~ — **closed 2026-08-27**: JL2121(D) DS009 §4.7.1 specifies t1 ≥ 10 ms (RSTn de-assert after powers ready), t2 ≥ 1 ms (RSTn assert), t3 ≥ 10 ms (RSTn hold after powers ready); the existing 10 ms / 500,000-cycle hold already satisfies all three (same 10 ms, citation corrected in `rtl/gem_clk_rst.v:53`, `rtl/gem_mac_params.vh:128`). No RTL change. | — (no bench step) | `rtl/gem_clk_rst.v` · `rtl/gem_mac_params.vh` · `Manuals/JL2121_datasheet.pdf` §4.7.1 |

## B.5-RX-1: the RX capture edge lands one unit interval late

**Root cause found, fixed, and CONFIRMED ON HARDWARE 2026-08-27.** This is not
a sixth entry in the table above — the table lists
questions no tool in this build can answer, and this one *was* answered, by
the `make debug` ILA. It is written here because the fix is a phase change
whose confirmation belongs to the same bench session as the R14/R20/V-2 row.

Bring-up step 4 received nothing: `rx_ok` stayed at zero for every frame sent,
and the ILA showed the SFD hunter never leaving `ST_HUNT` because the octet it
was fed was never `0xD5`. The corruption looked analogue — it clustered at
high-bit-transition bytes, it moved between captures, and a ±111 ps phase
sweep did not shift it — and the previous session's hypothesis was
signal-integrity or per-bit skew needing `IDELAYE2`.

It was neither. The captured octets are **systematically re-framed by exactly
one nibble**: the IDDR pair straddles an octet boundary, `Q1` holding one
octet's high nibble and `Q2` the *next* octet's low nibble. Six captures
across four protocols (`gem_host` 0x88B5, ARP, mDNS, IPv4/UDP) decode
byte-perfect under that one transformation — correct DA/SA, correct
EtherTypes, a clean `00 01 02 … 1e` payload run, `224.0.0.251` with
source and destination port 5353, and a multicast MAC matching its multicast
IP. Zero bit errors across ~500 octets: **the analogue capture is fine.**

The pattern hid itself. An octet whose two nibbles are equal (`0x55`
preamble) or whose high nibble repeats its predecessor's (a `0x00`–`0x0f`
payload run) still decodes clean when re-framed, so a systematic error
presents as sporadic damage at exactly the high-transition bytes. The
`dv=0, er=1` cycle at every frame start, read before as RGMII carrier sense,
is the same artefact: `0xD5` there is the in-band link-status nibble `0xD`
(link up / 1000 / full) paired with the first preamble nibble `0x5`.

Two changes, both in RTL:

1. **`rtl/gem_rgmii_rx.v` — reverted `da81e24`'s nibble swap.** RGMII v2.0
   fixes the low nibble to the rising edge on every compliant PHY; it is not
   a per-PHY choice, and `{d_fall, d_rise}` is correct. That commit also never
   re-ran the RX simulation, which fails on the swapped mapping — the golden
   model asserts the same thing directly in `tRgmii/lowNibbleOnRisingEdge`.
2. **`rtl/gem_rx_mmcm.v` — `CLKOUT0_PHASE` `-45.000` → `-225.000`**, one whole
   unit interval (180° = 4.000 ns at 125 MHz) earlier. No nibble order can
   repair a pair that straddles an octet boundary; the phase is the only lever.

**What let this through** is worth keeping, because the reasoning was careful
and still wrong. When A.2's correction moved the PHY's RX delay from the
KSZ9031RNX's assumed 1.200 ns to the JL2121(D)'s strapped 2.000 ns,
`rtl/gem_rx_mmcm.v` argued that every setup and hold margin was unchanged —
true, because margins are computed from a residual that does not depend on the
PHY's absolute delay. But *which nibble* the edge captures is absolute: it is
the capture position modulo one 4.000 ns unit interval, and the substitution
moved it by +0.800 ns. After the −1000 ps trim the slow corner sat at +3.636 ns
into a 4.000 ns nibble — 364 ps from rollover, where the KSZ-era numbers had
1.164 ns. Margin-invariance was read as safety, and it is not the same
property.

### Bench confirmation (2026-08-27, `make debug` + ILA on the real board)

Rebuilt, reprogrammed, re-captured. All of it held:

- **The ILA now triggers on a literal `0xD5` with `dv=1`** — something that
  never once happened before, when `state` sat in `ST_HUNT` for all 4096
  cycles of every capture. `state` leaves `ST_HUNT` for `ST_RECV`, `fifo_wr`
  asserts, and `wr_bin` advances.
- **The `gem_host` frame decodes natively and exactly**: `55`×7, `d5`, DA
  `02:00:00:00:00:01`, SA `02:00:00:00:00:02`, EtherType `88b5`, and a payload
  that is a clean +1 run across all 64 octets — `0x10` included, the value
  that used to vanish for 16 byte-times.
- **`rx_ok` advanced by 101** on `gem_host.py rx --count 100`, against +0
  before. `rx_bad`, `rx_runt`, `rx_over` and `rx_rxer` all stayed at **zero**;
  `rx_rxer` alone had gained +64 during the same test before the fix, and used
  to climb on a completely idle link. That idle-link RX_ER/runt noise was the
  same root cause, and it is gone.
- The 101st frame is ambient LAN traffic, confirmed by a control run: with
  nothing sent, `rx_ok` still climbs 1–2 per interval while every error
  counter stays at zero. `gem_host.py rx` asserted exact equality at the time,
  so it printed `FAIL rx_ok advanced by 101, expected 100` — **a property of
  the assertion on a live LAN, not of the receive path.** The assertion has
  since been changed to measure that ambient rate and allow for it; see the
  section below.

**Gate 2 needed no waiver at all.** The five RX input-delay setup checks came
back **+0.891 to +0.933 ns**, hold **+6.82 to +6.86 ns**, with zero violating
paths design-wide (WNS +0.336 ns on the TX path; WHS +0.019 ns on a `dbg_hub`
path that exists only in the debug build). The worst RX endpoint moved from the
predicted −3.109 ns to **+0.891 ns — exactly +4.000 ns, one unit interval.**

That number is worth sitting with: most of what task-4e attributed to a ZHOLD
*modeling artifact* was Vivado correctly reporting a real one-UI misalignment,
and the fenced waiver was masking it. `scripts/build.tcl`'s fences are kept
(they cost nothing while nothing violates), but a future violation on those
five endpoints should now be read as a real defect, not re-waived.

### The step 4 assertion, closed separately

`sw/host/gem_host.py rx` could not report PASS on a machine whose NIC sees
ambient traffic, because the board accepts frames regardless of destination
address and the check was `==`. That was left alone while the RX path was being
fixed — loosening a pass criterion to make a test go green is not a call to make
in passing — and settled on its own afterwards. Of the three options recorded
here, **the control read won**:

- *Filter by destination address in the check.* Not implementable host-side.
  The number being checked is the board's own counter, and the board has no
  address filter to consult (R12 is a stated non-goal, B.7 is promiscuous by
  design). Reconstructing the board's view from a host-side sniff means
  assuming the host NIC and the board see the same wire, and aligning a
  libpcap capture with a counter window whose edges are two UART records —
  more machinery for a worse guarantee.
- *Accept `>=`.* Worse than it sounds. `rx_ok` at the end is
  `(count − drops) + ambient`, so `>=` passes whenever `ambient >= drops` — it
  does not merely lose duplicate detection, it loses **drop** detection, which
  is the one thing step 4 exists to establish. And nothing bounds the top, so
  any amount of duplicate counting passes too.
- *Bracket with a control read.* `rx` now watches a `--control` window (4 status
  records, nothing sent) before sending and a `--window` one (3 records) after,
  both counted in records rather than seconds slept so each is a known number of
  board-seconds. The measured ambient rate scales onto the test window, three
  Poisson sigma are added, and `rx_ok` must land in
  `[count, count + allowance]`.

What that buys and what it costs, both stated in `evaluate_rx` and printed by
the command: a control window that measures zero yields an allowance of zero, so
**on an isolated link the check is exactly as strict as the `==` it replaces**;
the low edge stays exact on any link, because ambient traffic only ever adds;
and what is given up is resolution at the top — a shortfall smaller than the
allowance (9 to 14 frames at the 1–2 per second this bench measured, over
the default 3 s window) cannot be told from ambient. Sending more frames
shrinks that as a fraction of the run without narrowing the allowance itself.

`sw/host/gem_host.py`, `sw/host/README.md` and `bringup_checklist.md` step 4
carry it; `sw/host/test_gem_host.py` and `test_gem_host_commands.py` cover it,
including that a drop still fails on a busy segment and that a quiet control
window still rejects an over-count.

## B.5-TX-1: V-2 closes badly — the TX falling-edge nibble is sampled late

**Found 2026-08-27, the first time step 6 was ever runnable.** Step 4 had never
passed before B.5-RX-1, so nothing had ever round-tripped through this board.
With receive working, `gem_host.py echo --count 100` returns frames whose
payloads are wrong:

    sent 100, returned 83, payload mismatches 20, address swap wrong 0
    FAIL step 6

**Receive is not implicated.** Across the same runs the board reports
`rx_ok +141`, `rx_bad 0`, `rx_runt 0`, `rx_over 0`, `rx_rxer 0` — every frame
the board took in passed its own FCS check. The damage is downstream of that.

**The signature is exact.** Every corrupted bit is the falling-edge (high)
nibble taking the value of the **following** rising-edge (low) nibble in that
bit position, and the low nibble is never touched. Checked against every
corrupted byte the run reported: **13 of 13**, no exceptions.

| sent | got | high nibble | following low nibble | bits flipped |
|---|---|---|---|---|
| `17` | `97` | `0001` → `1001` | `1000` | `1000` |
| `2b` | `ab` | `0010` → `1010` | `1100` | `1000` |
| `ad` | `ed` | `1010` → `1110` | `1110` | `0100` |
| `a4` | `f4` | `1010` → `1111` | `0101` | `0101` |
| `e4` | `f4` | `1110` → `1111` | `0101` | `0001` |

That is the PHY sampling the falling-edge nibble late enough that some bits
have already advanced to the next nibble. It is per-bit and intermittent,
which is what differing trace/pin delays across TXD[3:0] would produce.

**What it is not.** Reproduced identically on the debug bitstream and on the
shipped one, so it is not ILA routing pressure. `tx_urun` stays 0, so it is not
the egress FIFO. A pure phase error would hit both edges; **only the falling
edge is ever wrong**, which points at the falling-edge launch specifically —
duty cycle rather than phase. Worth noting `rtl/gem_mmcm.v`'s `CLKOUT1_DIVIDE`
is **9**, an odd divide, where 50% duty needs the MMCM's edge control rather
than falling out of the divider.

**Unresolved, and it matters.** These frames reach the host at all, which means
either the corruption happens *before* CRC generation (so the FCS is valid over
corrupted data) or the NIC is passing frames whose FCS is bad. The nibble-level
signature says the former is implausible — fabric logic does not produce
"falling nibble takes the following rising nibble" — but that has not been
proven, and **it cannot be proven on this host at all.** Wireshark was installed
to try (`tshark 4.6.8`, 2026-08-27) and two independent things block it:

1. Wireshark 4.6.8 refuses to run on WinPcap — it requires Npcap and instructs
   the user to uninstall WinPcap. WinPcap (`npf`, running) is what Scapy and
   therefore `gem_host.py` currently use, which also finally explains the
   "Scapy worked without Npcap, unclear why" note from an earlier session.
   Swapping the driver risks the one path that currently passes step 4.
2. More fundamentally, **the NIC strips the FCS in hardware.** It is a Realtek
   PCIe GbE Family Controller and its advanced properties carry no CRC/FCS
   retention option, so no capture stack — Npcap included — can ever see the
   FCS. This is a property of the adapter, not of the software.

So step 5's "Wireshark reports the FCS as correct" criterion is **not
achievable on this bench** and should not be left looking merely un-attempted.
Closing it needs a different adapter (one exposing a keep-CRC option), a second
FPGA, or a traffic generator. Its other two criteria — frames from the board
appear, and a frame compares byte for byte — are already met by
`gem_host.py echo`, which is how B.5-TX-1 was found in the first place.

Note this leaves a genuine contradiction on the record rather than resolving
it: the nibble signature says the corruption is at the pins, *after* CRC
generation, so the FCS should be wrong and a NIC should drop those frames —
yet they arrive. Either the adapter passes bad-FCS frames while WinPcap has it
in promiscuous mode, or the corruption precedes CRC generation and the
signature is misleading. **The `CLKOUT1_PHASE` sweep below settles this without
needing to see an FCS at all:** if the mismatch rate moves with TX clock phase,
the corruption is at the pins and the first horn is right.

**The discriminating experiment, before any fix:** sweep
`rtl/gem_mmcm.v`'s `CLKOUT1_PHASE` (currently `+70.000`, a derived value — see
that file's header and `docs/reports/stage9/rgmii-jl2121-retiming-report.md`)
and watch the mismatch rate. If it moves, this is phase and the derivation
needs redoing. If it does not move — as the RX ±111 ps sweep did not move
B.5-RX-1 — then phase is the wrong knob and the falling-edge launch itself is,
which is the more likely reading given only one edge is affected. **Do not
retune the phase before that sweep says it is the right lever**; B.5-RX-1's
whole history is a careful derivation adjusted in the wrong dimension.

## Bring-up status after B.5-RX-1 (2026-08-27)

| step | state |
|---|---|
| 1–3 | PASS (unchanged) |
| **4 — receive** | **PASS** on the shipped bitstream. See § B.5-RX-1. |
| 5 — transmit / FCS | **Blocked on tooling.** Wireshark is not installed on this machine and a Windows NIC does not expose the FCS to a capture. Closes with B.5-TX-1. |
| **6 — round trip** | **FAIL.** See § B.5-TX-1. |
| 7 — corruption | **Blocked on host config, board behaviour correct.** The oversize half never reached the wire: the `Ethernet` adapter is MTU 1500 with Jumbo Frame *Disabled*, so the NIC dropped the 1600-octet frames and `rx_over 0` is right. The good-frame half worked — `rx_ok` advanced by exactly the 20 sent plus 2 ambient. Enabling jumbo frames is an adapter setting, not a repo change. |
| 8 — soak | Not started; it is the acceptance test for a working round trip and step 6 does not pass yet. |

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
