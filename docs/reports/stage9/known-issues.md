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

### The `CLKOUT1_PHASE` sweep, run 2026-08-27 — phase is NOT the fix

Swept the real board, rebuilding and reprogramming at each point. `CLKOUT1_PHASE`
is on a 5° grid (45/`CLKOUT1_DIVIDE`(9)), and TX ODDR setup slack tracks it
exactly 1:1 in ns (1° = 8 ns/360 = 22.2 ps), which is itself a useful check that
the constraint is doing what it claims.

| phase | TX ODDR setup slack | build | `echo --count 100` |
|---|---|---|---|
| 25° | −0.664 ns | **refused** | — |
| 50° | −0.109 ns | **refused** | — |
| 60° | +0.114 ns | pass | returned 100, **mismatches 24 / 21 / 27** |
| **70°** (committed) | +0.336 ns | pass | returned 83, **mismatches 20** |
| 115° | > +0.891 ns | pass | **returned 0** — nothing recognisable comes back |

Three things fall out, and the third is the important one.

1. **The corruption is at the pins, not in the fabric.** A phase change destroyed
   it completely at 115°. Fabric logic does not care about TX clock phase. This
   settles the contradiction recorded above in favour of the nibble signature:
   the FCS on those frames is wrong and the adapter is passing bad-FCS frames
   under WinPcap promiscuous mode.
2. **STA setup and the hardware want opposite directions.** Setup slack improves
   as phase rises; the hardware gets worse. That is the signature of a **hold**
   failure at the PHY, which is what "the falling nibble already advanced to the
   next one" means. The gate refuses below ~55°, so the setup constraint is
   actively fencing off the direction the hardware wants.
3. **But phase is not the lever anyway.** 60° and 70° give the *same* ~24%
   mismatch rate (24/100, 21/100, 27/100 against 20/83). 0.22 ns of movement
   changes nothing; 1 ns destroys everything. **Phase moves both clock edges
   together, and only ONE edge is ever wrong** — so no phase value can fix it,
   exactly as B.5-RX-1's ±111 ps sweep could not fix a whole-UI framing error.

`CLKOUT1_PHASE` was returned to the committed `70.000` and the board reprogrammed
there (`gem_mmcm.v` byte-identical to baseline, WNS back to the documented
+336 ps, step 4 re-confirmed PASS). **No speculative value was left in the tree.**

**Where to look next, in order.** The remaining explanation consistent with every
observation is a **fixed displacement of the falling edge** — duty-cycle
distortion. `CLKOUT1_DIVIDE` is **9**, an odd divide, where an MMCM reaches 50%
only through its edge control at half-VCO-period (0.444 ns) resolution; the same
is true of `CLKOUT0_DIVIDE` for `tx_clk`, which launches TXD. Worth checking the
*achieved* duty on both outputs before anything else, then whether an even divide
(a different VCO multiplier reaching 125 MHz on an even divisor) removes it. That
is a real design change, not a parameter tweak, and it should not start until the
duty numbers are actually read off the implemented MMCM.

**Superseded — the original recommendation, kept because it was run:** sweep
`rtl/gem_mmcm.v`'s `CLKOUT1_PHASE` (currently `+70.000`, a derived value — see
that file's header and `docs/reports/stage9/rgmii-jl2121-retiming-report.md`)
and watch the mismatch rate. If it moves, this is phase and the derivation
needs redoing. If it does not move — as the RX ±111 ps sweep did not move
B.5-RX-1 — then phase is the wrong knob and the falling-edge launch itself is,
which is the more likely reading given only one edge is affected. **Do not
retune the phase before that sweep says it is the right lever**; B.5-RX-1's
whole history is a careful derivation adjusted in the wrong dimension.

### `SLEW FAST` + `DRIVE`, run 2026-08-27 — mechanism confirmed, not yet a fix

Following the phase sweep's conclusion above (duty-cycle/edge-rate, not phase),
checked `constrs/pins.xdc`: the six RGMII TX ports (`rgmii_gtx_clk`,
`rgmii_txd[3:0]`, `rgmii_tx_ctl`) set only `PACKAGE_PIN` and `IOSTANDARD`, never
`SLEW` or `DRIVE`, so all six took Vivado's default `SLEW SLOW DRIVE 12`. On a
125 MHz DDR interface with a 4 ns nibble, `SLOW`'s edge rate is a significant
fraction of the unit interval, and rise/fall times are asymmetric under `SLOW`
— that asymmetry displaces one clock edge relative to the other, fitting every
observation the phase sweep could not: one edge only, per-bit and intermittent,
immune to phase, worse on high-transition bytes.

Baseline reconfirmed same-session before touching anything (3× `echo --count
100`): returned 72/75/75, mismatches 14/15/21 — consistent with the phase-sweep
baseline above.

**`SLEW FAST`** on the six TX ports (build clean, WNS +0.347 ns, WHS +0.033 ns
— no regression from the committed +0.336 ns): mismatches fell to 2/1/5 across
three `--count 100` runs, all 100 returned each time — a ~9× reduction. Step 4
re-confirmed PASS.

**`SLEW FAST` + `DRIVE 16`** (same direction as `SLEW FAST` — more drive
current, steeper edges — rather than `DRIVE 8` which would push the opposite
way): 2/5/3 at `--count 100`, then **14/500 = 2.8%** at `--count 500`. That
matches `SLEW FAST` alone (2.7%) closely enough to call it noise — `DRIVE 16`
added no measurable further improvement. Step 4 re-confirmed PASS again.

| configuration | mismatch rate |
|---|---|
| baseline (`SLEW SLOW`/`DRIVE 12`, Vivado defaults) | ~24% (14–21 of 72–75 returned, and separately 18–20 of 71–83 above) |
| `SLEW FAST` | ~2.7% (1–5 of 100, 3 runs) |
| `SLEW FAST` + `DRIVE 16` | ~2.8% (14 of 500) |

**Conclusion.** The edge-rate/rise-fall-asymmetry hypothesis is confirmed as
the dominant mechanism — not phase (settled above), not fabric logic, but I/O
driver characteristics on the TX pins. `SLEW FAST` closes roughly 9/10 of the
gap; the residual **~2.8% mismatch rate is real, reproducible across a 500-frame
run, and not moved by `DRIVE 16`**, the only other edge-rate lever `pins.xdc`
exposes on these ports. Both properties are committed as a partial mitigation.
**B.5-TX-1 remains open** for whatever accounts for the last ~2.8% — the more
likely next lever is the still-not-started I/O DELAY work against the
JL2121(D)'s confirmed 2 ns RXDLY/TXDLY straps (V-2,
`docs/reports/stage9/rgmii-jl2121-retiming-report.md`), not further tuning of
`SLEW`/`DRIVE`.

## Bring-up status after B.5-RX-1 (2026-08-27)

| step | state |
|---|---|
| 1–3 | PASS (unchanged) |
| **4 — receive** | **PASS** on the shipped bitstream. See § B.5-RX-1. |
| 5 — transmit / FCS | **Blocked on tooling.** Wireshark is not installed on this machine and a Windows NIC does not expose the FCS to a capture. Closes with B.5-TX-1. |
| **6 — round trip** | **FAIL, improved.** `SLEW FAST` + `DRIVE 16` on the TX pins cut the payload-mismatch rate from ~24% to ~2.8% (500-frame run) — mechanism confirmed (TX I/O edge rate), residual not yet explained. See § B.5-TX-1. |
| **7 — corruption** | **PASS, fully, 2026-08-27** — counters and both physical checks (`led[3]` = **LED4** lit by the oversize frames, dark again after **KEY1**, with every counter confirmed back at zero over UART). `rx_over +20` for 20 oversize frames and `rx_ok +22` for the 20 good frames sent after them plus 2 ambient — R10's recovery property on real hardware, with `rx_bad`/`rx_runt`/`rx_rxer` all still 0. Required enabling **Jumbo Frame = 4088 Bytes** on the `Ethernet` adapter (MTU 1500 → 4074): `GEM_MAX_FRAME_BYTES` is 1518, and a non-jumbo NIC caps a raw frame at 1514 + 4 FCS = exactly 1518, so no frame it can send is ever oversize. That is a host setting, not a repo change, and it is reversible — `bringup_checklist.md` step 7 now carries the command and the silent-failure warning. |
| 8 — soak | Not started; it is the acceptance test for a working round trip and step 6 does not pass yet. |

**Bench note for whoever repeats step 7:** the oversize half cannot be provoked from a PC at all unless the NIC's jumbo-frame support is switched on first, and the failure mode without it is silent and misleading — `rx_over` stays 0 and the run reads as a board defect when the frames simply never left the host. `rx_ok` advancing by exactly the number of *good* frames sent is the tell that the oversize ones never arrived. `bringup_checklist.md` step 7 should say so; it currently does not.

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
