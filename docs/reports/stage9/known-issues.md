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
| **R14 / R20 / V-2** | RGMII I/O timing margin is thin on both directions and neither can be confirmed by simulation. Re-derived for the real chip, a JLSemi JL2121(D) (A.2's B.5 correction, `docs/reports/stage9/rgmii-jl2121-retiming-report.md`): TX now closes at **+336 ps** worst case (was +58 ps under the wrong-chip derivation — the mechanism changed too, from an FPGA-generated phase shift to one cancelling an FPGA-internal clock-forwarding asymmetry), and the five RX input-delay checks **closed outright at +0.891 to +0.933 ns setup, with no waiver exercised, on the pre-flood-mode build** — see § B.5-RX-1 below, which found the capture edge was landing one whole unit interval late and corrected it; most of what task 4e attributed to a ZHOLD modeling artifact was a real misalignment. **Update 2026-09-01: the waiver is exercised again** on the current committed build (`gem_traffic_gen` wired in, § "Flood mode" below) — worst −0.331 ns setup on those same five endpoints, still comfortably inside the −3.500 ns envelope, so gate 2 still passes legitimately. Nothing about the RX fix itself is wrong; adding the traffic-generator mux to `gem_top` nudged routing enough to move these five numbers back under the waiver. Re-measure after any future change that touches `gem_top`'s routing footprint rather than assuming this figure holds. The RX half is confirmed on hardware either way (`rx_ok` advancing, zero error counters); what remains open on this row is the **TX** side. **There is no MDIO pad-skew fallback on this chip** — the JL2121(D) has no MMD register-access mechanism at all; its RX/TX clock delay is a hardware strap, fixed at board population. If the bench shows either margin insufficient, the fallback is a strap rework, not an MDIO write. | Bring-up step 5, a scope or the `make debug` ILA on `GTX_CLK`/`TXD0` and the RX side. | README's timing section · `Documents/RGMII I-O Timing Derivation.md` · `docs/reports/stage9/rgmii-jl2121-retiming-report.md` · `docs/reports/stage6-part2/task-4e-report.md` · `verification_plan.md` rows V-2, R14, R20 |
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

### B.5-RX-2: `rx_bad` advances under sustained load — step 8 blocked

**Found 2026-08-27 by the first step 8 attempt, six minutes in.** The soak was
stopped rather than run its four hours, because its pass criterion is that no
error counter moves and one already had.

| | |
|---|---|
| window | 17:13:35 → 17:19:21, `rx_ok` +102,891 |
| **`rx_bad`** | **+22 — 0.021%, about 1 frame in 4,700** |
| `rx_runt` / `rx_over` / `rx_rxer` | **+0** |

**The TX fix held, and held far harder than it had been tested.** Over the same
run the echo loop sent **116,000 frames with zero payload mismatches** — an
order of magnitude beyond the 12,000 that B.5-TX-1 was signed off on, at
~285 frames/s sustained. That result is strengthened, not in doubt.

**What the shortfall actually was.** Echo returned 115,972 of 116,000 — a
shortfall of 28, against `rx_bad` +24 over the same window. Those are the same
frames: the board rejected them on FCS, so it never echoed them. **Every
earlier echo run showed the same "returned 998-1000 of 1000" and it was
attributed to `gem_echo` holding one frame at a time by design.** Some of it
was. Some of it was this, and nothing was watching `rx_bad` during those runs
to tell the two apart. This defect may well predate today's changes entirely;
nothing measured so far can date it.

**THE COUPLING HYPOTHESIS IS REFUTED (tested 2026-08-27).** Rebuilt at a
uniform `DRIVE 12` with phase and `SLEW` unchanged, and measured `rx_bad` per
received frame at matched load (100,000 echo frames per point, counters read
before and after):

| config | `rx_bad` / `rx_ok` | rate |
|---|---|---|
| **`DRIVE 16`** | 20 / 100,187 | **0.0200%** |
| | 22 / 102,891 (soak) | 0.0214% |
| `DRIVE 12` | 64 / 100,204 | 0.0639% |
| `DRIVE 12` (settled link) | 56 / 100,184 | 0.0559% |

Lowering the drive made receive errors **~3x WORSE**, which is the opposite of
what simultaneous-switching noise predicts. There is no TX-quality-versus-
RX-margin trade-off here: `DRIVE 16` is better on both paths, so the committed
setting stands and needs no revisiting.

A confound was checked rather than assumed. The first `DRIVE 12` point started
at `rx_ok=41`, immediately after reprogramming, while the baseline started at
`rx_ok=138729` with the link long settled -- link-up transients could have
inflated it. Re-running on a settled link gave 0.0559% against 0.0639%, so the
transient explains none of it.

**The mechanism is now unknown, and that is the honest state.** Board TX drive
should not influence what the board *receives* at all, yet it reproducibly
does, and in the direction opposite to crosstalk. Both configurations are
self-consistent across independent runs, so the effect is real even though no
proposed mechanism survives.

**Superseded hypothesis, kept because it was tested: TX-to-RX coupling.** All six TX outputs were
raised to `SLEW FAST` / `DRIVE 16` earlier today. Faster edges and more drive
current mean more simultaneous-switching noise, and RX and TX share bank 15.
The board only transmits heavily when it is echoing, which is exactly when
this appears — idle-link monitoring shows `rx_bad` flat. If true, today's TX
fix bought transmit quality at the cost of receive margin, and there is a
trade-off to find rather than a free win.

**One thing every run agrees on:** the echo shortfall equals `rx_bad` almost
exactly, at every configuration -- 22 vs 20, 64 vs 64, 56 vs 56, 28 vs 24.
The frames that "do not come back" are the frames the board rejected on FCS,
not frames `gem_echo` dropped while busy. That is now measured, not inferred.

**Also worth recording: the TX fix is holding at enormous scale.** 216,000
frames at the committed configuration with **zero** payload mismatches, plus
200,000 more at `DRIVE 12`, also zero. B.5-TX-1 is not in doubt.

**The original discriminating test, now run:** The obvious probe — load the
receive path *without* the board transmitting — cannot be done with this
bitstream, because `gem_echo` returns everything it accepts (`tx_ok` tracks
`rx_ok` almost exactly). So the test is to rebuild at a lower `DRIVE` and/or
`SLEW SLOW` and compare `rx_bad` per received frame at matched load. Watch
`rx_bad`, not the echo mismatch count — the two measure different paths, and
conflating them is what hid this.

**Do not re-run step 8 until this is settled.** It fails in minutes, and the
soak harness itself works correctly — it caught this exactly as designed.

**B.5-RX-2 IS FIXED — the RX phase was mis-centred, 2026-08-27 (step 8 attempt
continued).** The coupling hypothesis above was refuted (see the entry right
before this one); `CLKOUT0_PHASE` had never been swept on hardware and was the
next suspect, following exactly the method that found and fixed B.5-TX-1:
phase as a measuring instrument, 100k+ frames per point, board counters read
directly (not the echo tool's own drop count).

Before sweeping, the committed `-225.000` baseline was re-measured and did
**not** reproduce at its originally-recorded rate: 72/100,165 and 77/100,171
(0.072%/0.077%) against the earlier 20/100,187 and 22/102,891 (0.020%/0.021%)
— roughly 3.5x higher, at a higher achieved frame rate (389-403 vs ~285
frames/s). Rate-dependence was tested directly and ruled out: throttling the
same `-225` configuration to 237 frames/s gave 69/100,314 (0.069%) — no
better than the unthrottled runs. The cause of that day-to-day drift at a
fixed phase is still unknown (thermal drift over a long bring-up day is the
leading guess, untested) and is separate from the phase question; it is
recorded here rather than chased further because the phase sweep answered
the actual blocking question regardless.

The sweep itself:

| `CLKOUT0_PHASE` | frames | `rx_bad` | step 4 |
|---|---|---|---|
| -220.000 | 100 | 10 (+4 in a 4s idle window) | **FAIL** |
| -225.000 (committed) | 100k x2 + 100k throttled | 72, 77, 69 per ~100k | PASS |
| -230.000 | 400,487 (100k + 300k confirm) | **0** | PASS |
| -235.000 | 100,161 | **0** | PASS |

`-220` is a real cliff one 5-degree step from the committed value — it fails
step 4 outright, a different and more severe failure than B.5-RX-2's FCS
rate. `-230` and `-235` are both clean, giving margin evidence on both sides
of the chosen point. `CLKOUT0_PHASE` is now `-230.000` in
`rtl/gem_rx_mmcm.v` (see that file's THIRD CORRECTION for the full account);
reconfirmed 0/100,162 on the exact rebuilt/reprogrammed bitstream that was
committed, for 500,809 total error-free frames at `-230` across every run.
`pins.xdc` and everything else in the committed configuration is untouched.

Gate re-run after the RTL change: `check_vectors.py` up to date, `lint.py`
clean (8/8), 84/84 host unit tests, 29/29 simulation scenarios — all pass.

Step 8 (the 4-hour soak) can now be attempted again.

### B.5-TX-1 IS FIXED — the TX clock phase was wrong, 2026-08-27

**`CLKOUT1_PHASE` 70 -> 60. Step 6 passes. 0 payload errors in 12000 frames,
with the per-line DRIVE trims removed.**

Swept on the real board at uniform `SLEW FAST` / `DRIVE 16`:

| phase | errors / frames | WNS | |
|---|---|---|---|
| 55.0 | 0 / 4000 | +0.019 ns | gate 2 nearly refuses |
| **60.0** | **0 / 12000** | +0.130 ns | **committed** |
| 65.0 | 3 / 4000 | +0.241 ns | |
| 70.0 | 11 / 1000 | +0.322 ns | the old value |
| 80.0 | 3626 / 2000 | +0.574 ns | ~27% of frames corrupt |

**The WNS column rises monotonically as the hardware gets worse.** Setup slack
against the TX output-delay constraint is *anti-correlated* with whether the
link works, because that constraint models FPGA-internal skew only —
`Documents/RGMII I-O Timing Derivation.md` says so outright: "board trace
length/skew is not in this budget because B.1b never had trace-length data to
put there." The real limit is that missing term. **`+70.000` was partly chosen
for having more margin than `+60.000`, which is optimising the wrong number in
the wrong direction.** Warnings to that effect are now at the constraint itself
and in `rtl/gem_mmcm.v`.

**The per-line DRIVE trims are removed.** They reached 0.075% by holding
`txd[3]` and `txd[2]` a drive step slower — real, causal, and treating a
symptom: they were compensating skew the wrong phase was producing. They were
also board-specific calibration that nothing could validate. At the right
phase they had nothing left to correct.

**What was not established:** the working window's lower edge. Gate 2 refuses
below ~55 degrees, so 60.0 is confirmed clean but **not confirmed centred** —
one 5-degree step (111 ps) above a clean 55.0 and one step below a dirty 65.0.
If this drifts on another board or a temperature corner, 55.0 is the direction
to move, and the constraint is what blocks going further.

**How it was found, since the method transfers:** `CLKOUT1_PHASE` was used as a
*measuring instrument*. Phase moves the clock against all data equally, so the
per-line failure histogram at a bad phase ranks the lines by skew. At 80
degrees that ranking was TXD[3] 2748, TXD[2] 801, TXD[0] 397, TXD[1] 82 — the
exact order the DRIVE trims had needed, arrived at independently. That was the
substitute for the oscilloscope this bench does not have.

### Superseded: per-line `DRIVE` trim — B.5-TX-1 down ~320x, and still not fixed

**`SLEW` and `DRIVE` are per-PORT, which reopened a lever the section below
declared exhausted.** There is no `ODELAYE2` on this device, so per-pin *delay*
is impossible — but per-pin *edge rate* is not, and edge rate moves the
threshold crossing, which is the same thing to first order. Less drive on one
line = slower edge = crosses later = holds the old nibble longer, which is
exactly the correction "the PHY sampled after this line already advanced" asks
for.

| config | rate | frames | line(s) then leading |
|---|---|---|---|
| `SLEW SLOW`, `DRIVE 12` (Vivado default) | ~24% | — | bits 4, 6 and 7 |
| `SLEW FAST`, all `DRIVE 16` | 1.1% | 1000 | **TXD[3], 11 of 11** |
| + `txd[3] = 12` | 0.22% | 4999 | TXD[2] leading |
| + `txd[2] = 12` | **0.075%** | 8000 | TXD[3] and TXD[0] |

**TXD[2] vanished from the histogram after its own trim** — 4 of 6 before,
0 of 6 after — which is what makes this causal rather than coincidental. The
falling-nibble signature held at every stage: 11/11, then 6/6, then 6/6, always
0 -> 1, always in the high nibble, never more than one octet per frame.

All six TX pins sit in bank 15 on IOB33 sites, and TXD[3] is *not* the furthest
from `gtx_clk` (TXD[0] at IOB_X0Y71 vs Y77 is), so this is per-line **board
trace** skew, not die-side placement.

**Two things this is not.**

1. **Not a fix.** 0.075% is one corrupted frame in ~1300. A real link delivers
   essentially zero. Step 6 still fails.
2. **Not portable.** These values are calibrated to one physical board's trace
   lengths. Another AX7035B may want different ones and nothing here detects
   that. It is a bench calibration, not a design constant.

**The measurement cost grows as the rate falls, and this is where the effort
stops being worth it.** Distinguishing 0.075% from 0.03% needs tens of
thousands of frames per build. A single 0/1000 run was seen twice during this
work and was wrong both times — the same config later gave 1 and 4. The proper
fix is the TX timing budget itself (the `TXDLY` strap, a scope on
`GTX_CLK`/`TXD0`), not further drive trimming.

### THERE IS NO `ODELAYE2` ON THIS DEVICE — the TX "I/O delay" lever does not exist

Checked against the implemented design on the real part, not from memory:

```
part           xc7a35tifgg484-1L
IDELAYE2       250 sites      <- INPUTS only
ODELAYE2         0 sites      <- does not exist
banks 14/15/16/34/35 = BT_HIGH_RANGE   (all HR)
```

In 7-series, `ODELAYE2` exists only in **HP** I/O banks. Every user bank on this
Artix-7 is **HR**, so there is no output delay primitive to instantiate at any
price. **Any plan that proposes per-pin output delay to fix B.5-TX-1 is dead on
arrival** — including the one an earlier revision of this page recommended.

The 250 `IDELAYE2` sites are real but are **input-only**, so they can serve the
receive path, which already works. They cannot help transmit.

**Beware `current_project` when checking this.** A first attempt at this query
returned `xc7vx485tffg1157-1` (a Virtex-7) with different site counts, because
Vivado's leftover default "New Project" won the context over the in-memory
design. Query `current_design`, and print the part alongside the answer so a
wrong-device result cannot be mistaken for a real one.

### What is actually left for B.5-TX-1

**Partly superseded:** "the FPGA-side levers are exhausted" was written before
anyone tried setting `DRIVE` per line rather than uniformly, which then bought
another ~15x (see the section above). Per-pin *delay* is genuinely unavailable;
per-pin *edge rate* was not. What remains after that is board-side:

1. **The PHY's `TXDLY` strap.** Confirmed populated for +2.000 ns
   (`Manuals/AX7035B_UG.pdf` Table 8-1). The JL2121(D) has no MMD register
   access, so this is a hardware rework, not an MDIO write — which
   `bringup_checklist.md` step 5 already names as the fallback. Removing the
   strap moves the PHY's sampling point by a whole 2 ns and re-opens the
   `CLKOUT1_PHASE` window, which was only ever swept *with* `TXDLY` in circuit.
   This is now the primary remaining lever, and it is the one worth costing.
2. **A scope on `GTX_CLK`/`TXD0`.** Still never done, and it is what step 5's
   "if the scope says setup timing is not being met" branch assumes. It would
   measure the rise/fall asymmetry directly instead of inferring it from
   mismatch rates.

**A tooling gap blocks the next diagnosis either way.** `gem_host.py echo`
truncates its `sent`/`got` display to the first 16 octets, and the residual
corruption falls beyond that, so the residual's per-bit signature cannot be
characterised the way the original 13-of-13 nibble analysis was. Whoever picks
this up should fix that print first — it is a few lines — rather than
speculating about a signature nobody can currently see.

## Flood mode: R7 and R18's minimum-frame-size half close, 2026-09-01

**R7 (board transmit at line rate) and R18's still-open minimum-frame-size
half are both CLOSED ON HARDWARE.** `gem_traffic_gen` (task 004a: an
AXI-Stream source offering one payload octet per cycle, 1 Gbit/s by
construction at any frame size) is wired into `gem_top` behind a new board
key, KEY2, through a mux gated to switch only at a frame boundary (task
005a — a naive combinational mux would let a mid-frame key press drop
`tx_tvalid` before `tlast`, which reads as an underrun nobody actually
caused; simulation proved the gate closes that hole, task 005b, before this
ever reached the board). Procedure: `docs/reports/stage9/flood-mode-checklist.md`.

| | frame size | measured | `tx_urun` | `tx_rej` | sample |
|---|---|---|---|---|---|
| **R7** | 1518 octets wire (1500 payload) | **96.78%** of 81,274.4 fps line rate (78,656.0 fps) | **0** | **0** | 2,438,231 frames, 31.0 s |
| **R18-min** | 64 octets wire (46 payload) | **96.77%** of 1,488,095.2 fps line rate (1,440,086.9 fps) | **0** | **0** | 44,642,857 frames, 31.0 s |

Both measured with `gem_host.py rate`, reading the board's own UART counters
— the same instrument the 2026-08-28 RX-direction measurement below used, not
a second independent one (see that entry's own caveat about V-6). After each
run, KEY2 pressed again and `gem_host.py echo` confirmed `gem_echo` actually
resumed (50/50 frames, 0 mismatches both times) — proving the mux reverts on
real hardware, not just in `tb_gem_top`.

**R18-min is the more striking number.** The RX-direction attempt at this
frame size (below) topped out at 1.22% because it was limited by *host
software* — a Scapy sender is frame-rate limited, not bandwidth limited, and
parallelising ran out of process budget. `gem_traffic_gen` has no such
ceiling: sourced from the fabric, minimum-size frames reach the same ~96.8%
maximum-size frames do, exactly as the module's own header claimed ("1 Gbit/s
of payload by construction, at any frame size").

**One real bug found by the board, not by review or simulation.** The first
hardware build of 005a's wiring refused outright: gate 3 (`check_timing`)
reported one input port with no input delay specified. 005a's task contract
added `traffic_gen_key_n`'s pin constraint (`constrs/pins.xdc`) but missed
the matching `set_false_path` every other async board key already carries in
`constrs/exceptions.xdc` — same class of port, same three-flop `ASYNC_REG`
synchroniser, same justification, just an entry nobody wrote. Fixed same
session, commit `4d91a61`. Worth remembering: 005b's simulation passing
30-of-30 said nothing about this, because `tb_gem_top` never runs
`check_timing` — a reminder that "simulated" and "will synthesise" are
different claims, made explicit rather than assumed here.

Configuration: committed RGMII config unchanged (`CLKOUT0_PHASE=-280.000`,
`CLKOUT1_PHASE=60.000`, `SLEW FAST`, `DRIVE 16`) — flood mode is a TX-side
AXI-Stream source change inside `gem_mac`'s existing datapath, not a new I/O
timing path, so nothing here touches the RGMII derivation V-2/R14/R20 track
in the table above.

## Line-rate measurement, 2026-08-28: **96.05% of line rate at 1518 octets**

The first measurement this project has ever taken near the rate it was designed
for. Every previous bench number ran at about 440 frames/s, roughly 0.5% of
gigabit line rate.

| offered | board `rx_ok` | % of line rate | frames | errors |
|---|---|---|---|---|
| 18,050 fps (1 sender) | 17,424 fps | 21.4% | 453,000 | **0** |
| 78,374 fps (6 senders) | 75,367 fps | 92.7% | 1,959,563 | **0** |
| **80,742 fps (10 senders)** | **78,063 fps** | **96.05%** | **2,419,981** | **0** |
| 19,242 fps, 64-octet frames | 18,187 fps | 1.22% | 472,868 | **0** |

`rx_bad`, `rx_runt`, `rx_over` and `rx_rxer` never left zero in any run.
Across the whole session the board received **9,336,376 frames** with no error
counter moving, on the committed configuration (`CLKOUT0_PHASE = -280.000`,
`CLKOUT1_PHASE = 60.000`, `SLEW FAST`, uniform `DRIVE 16`).

**R18's receive half is no longer simulation-only at maximum frame size.** What
is still unproven is R18 at *minimum* frame size and R7 in either direction —
see "What this does not establish" below.

### `rx_drop` stayed at zero, which falsifies the reason it was added

`rx_drop` was added earlier the same day (commit `c79f185`) on the stated
expectation that "at line rate the echo path will overflow the FIFO constantly
and by design". **That expectation was wrong**, and this measurement is what
showed it. At 96% of line rate `rx_drop` is still zero.

The reason is in `gem_echo`'s own header: frames are "dropped rather than
queued". It refuses a frame at its input while busy rather than back-pressuring
the path behind it, so the RX FIFO never fills and its `drop` output never
fires. In the 10-sender run `tx_ok` came back at **almost exactly half** of
`rx_ok` — 1,211,158 returned out of 2,419,981 received — and every one of those
~1.21M missing frames was refused by `gem_echo`, not lost by the FIFO.

So the counter does not measure what it was advertised as measuring. It is still
worth its 65 flip-flops, for a different reason than the one given at the time:
**B.3a derives that the RX FIFO cannot fill under R18's no-stall contract, and
that derivation is now a measured zero at 96% of line rate instead of an
assumption.** That property was previously unobservable.

### The real observability gap is `echo_dropped`, not the FIFO

`gem_echo`'s `dropped` output is deliberately discarded in `gem_top`'s
`_unused_ok` list, with a comment arguing it "reports a condition the echo
path's own header explains is expected under load and is not an R17 counter".
That reasoning was sound when nothing ran fast enough for it to fire. Under
load it is now **the number that actually moves**, and it is recoverable only by
subtracting `tx_ok` from `rx_ok`. If any further line-rate work is done, count
it.

### iperf3 cannot be used here, and installing it will not help

Recorded because it is the obvious first idea and it is a dead end. `iperf3`
opens a **TCP control connection to an iperf3 server** before sending anything,
including in UDP mode. `gem_top` is a MAC and an echo path: no ARP, no IP, no
TCP, nothing to connect to. The same objection applies to any generator that
expects an IP peer.

What works is raw Ethertype frames sent straight at `02:00:00:00:00:01`, which
is what `sw/host/flood.py` does.

### Parallel senders are the whole trick

A single Scapy sender is **frame-rate limited, not bandwidth limited**: it
managed 18,050 fps at 1518 octets and 19,242 fps at 64 octets — near-identical
frame rates, 219 Mbit/s versus 9.9 Mbit/s. The bottleneck is per-call overhead
in the Python/Npcap send path, and it is per *process*, so it parallelises
almost linearly. Ten concurrent senders reached 99.3% of line rate offered.

To reproduce:

```
for i in 1 2 3 4 5 6 7 8 9 10; do
  python sw/host/flood.py --iface Ethernet --seconds 50 --size 1500 &
done
python sw/host/gem_host.py rate --port COM5 --window 30 --frame-bytes 1518
```

### What this does not establish

- **R18 at minimum frame size.** The 64-octet case reached only **1.22%**.
  Because the send path is frame-rate limited per process, 1,488,095 fps would
  need roughly 77 parallel senders, which this host cannot sustain. Minimum-IFG
  line rate still needs Linux `pktgen` or DPDK, on hardware this bench does not
  have. **CLOSED 2026-09-01 at 96.77%** — see § "Flood mode" above; this
  paragraph's limit was the host's send path, not the board, and an RTL
  generator has no such ceiling.
- **R7, in either direction.** Nothing here makes the board *transmit* at line
  rate. `gem_echo` is the only thing driving the transmit path and it is
  store-and-forward, one frame at a time — the 50% return rate above is that
  limit being measured, not a defect. Sourcing line-rate transmit needs a small
  RTL generator feeding `gem_mac`'s AXI-Stream ingress; no external tool can do
  it. **CLOSED 2026-09-01 at 96.78%** — see § "Flood mode" above.
- **V-6**, the golden CRC against a real capture, is untouched by this.

## Step 8 soak, attempt 3 (2026-08-28 00:27 → 04:27): **PASS**

```
14400 records over 4.0 h
totals: tx_ok+6268150 rx_ok+6268355
anomalies: 0
PASS step 8: no divergence
```

**Bring-up is complete.** `bringup_checklist.md`: "Passing step 8 is the
definition of *fully functional* (B.5). At that point Stage 8 is complete and
what remains is Stage 9: release and handoff."

| | |
|---|---|
| duration | 4.0 h, 14,400 records, **0 anomalies** |
| frames received | **6,268,355** |
| `rx_bad` / `rx_runt` / `rx_over` / `rx_rxer` | **0** — never left zero |
| `tx_rej` / `tx_urun` | **0** — never left zero |
| link / rxlock down samples | **0** |
| echo traffic | 3,171 iterations, **6,342,000 frames sent** |
| echo payload mismatches | **0** |
| echo shortfall | 74 frames, 0.0012% — `gem_echo`'s by-design one-at-a-time buffering |

Run on the committed configuration: `CLKOUT0_PHASE = -280.000`,
`CLKOUT1_PHASE = 60.000`, `SLEW FAST`, uniform `DRIVE 16`, NIC at stock
MTU 1500 with jumbo disabled. Nobody touched the bench.

**Against attempt 2, the difference is exactly the one predicted.** That run
was clean across 5.9M frames and failed on a single 4-second link drop caused
by the operator moving the hardware. Left alone, the same design ran 6.3M
frames with zero anomalies of any kind. The fail was recorded honestly rather
than argued down, and this run is what a release should point at.

**What it does NOT establish**, unchanged by this result: the soak runs at
about 0.5% of line rate, because the host tooling does a Python round trip per
frame. **R7 and R18 at minimum frame size were both simulation-only when this
was written; both are now closed on hardware, 2026-09-01 — see § "Flood
mode" above.** V-6, the golden CRC against a real capture, is still open.
R18's receive half at *maximum* frame size was subsequently measured at
96.05% of line rate with zero errors — see § "Line-rate measurement,
2026-08-28" above, which supersedes this paragraph on that one point. Passing
step 8 means the datapath is stable and correct under sustained real traffic
for four hours; it does not mean the line-rate requirements are proven. See
§ A1-A4 of the blockers list.

## Step 8 soak, attempt 2 (2026-08-27 20:15 → 2026-08-28 00:15): FAIL on one event

**The tool's own verdict, verbatim:**

```
14401 records over 4.0 h
totals: tx_ok+5915740 rx_ok+5915977
anomalies: 1
FAIL step 8: see the log
```

**The single anomaly is a 4-second link drop at 20:49:21-24, and its cause is
known and external: the operator moved the hardware.** `phyok` stayed 1
throughout, so the board's PHY kept answering MDIO the whole time — it was
alive, it lost its partner. Nothing else in 14,401 one-second records.

**Everything else was clean, and the margin is not small.**

| | |
|---|---|
| duration | 4.0 h, 14,401 records |
| frames received | **5,915,977** |
| `rx_bad` / `rx_runt` / `rx_over` / `rx_rxer` | **0**, never left zero |
| `tx_rej` / `tx_urun` | **0**, never left zero |
| echo traffic | 2,977 iterations, **5,954,000 frames sent** |
| echo payload mismatches | **0** |
| echo shortfall | 70 frames, 0.0012% |

Those 70 missing frames are `gem_echo`'s by-design one-at-a-time dropping plus
the five in flight when the link went down. Not corruption — `rx_bad` stayed
at zero, and the shortfall-equals-`rx_bad` relationship established earlier
holds: with `rx_bad` at 0 the shortfall collapsed from ~0.02% to 0.0012%.

**What the run demonstrated, even though it failed:** both RGMII directions
were broken at the start of the day — receive failing every frame, transmit
corrupting about a quarter of them. The same datapath then carried 5.9 million
frames through IDDR capture, SFD hunt, deframe, CRC check, the FIFO clock
crossing, egress, echo, ingress, assembly, CRC generation and ODDR with **zero
errors of any class**.

**And the MAC handled the link loss correctly**, which is the one thing this
run tested that no one planned: traffic stopped, five in-flight frames were
lost, the link recovered, and **not one error counter moved**. That is the
link-event behaviour `tb_gem_top` checks in simulation (V-25), now confirmed on
hardware by accident.

**Status: step 8 is NOT passed.** The criterion is "no link drop" and there was
one. It is recorded as a fail rather than argued down, because a soak that gets
its result rounded up is not an acceptance test. A clean re-run — four hours,
nobody touching the bench — is what should be pointed at when tagging a
release. On this evidence it is expected to pass, but expectation is not a
result.

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

**R7 and R18's minimum-frame-size half closed 2026-09-01** — see § "Flood
mode" above. Neither was ever a row in the five-item table (they were never
assigned a `verification_plan.md` letter of their own the way the table's
rows are), which is why they don't disappear from a table above; they were
tracked in this page's own narrative instead, and that narrative now says
they're closed rather than open.
