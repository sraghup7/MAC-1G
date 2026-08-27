# 1G Ethernet MAC on a Budget FPGA — Board Selection & Initial Specification

Document status: v0.15 — Stages 1–5 complete, Stage 6 part 2's timing
question **resolved**: task-4e measured the routed deskew feedback path and
proved the −2.1 ns STA failure was Vivado's ZHOLD compensation constant, not
routing — while uncovering a real slow-corner hold miss underneath it, fixed
by a −45° capture-clock trim with predicted worst physical margin +0.669 ns.
R20's RX half is signed off by that derivation plus bench measurement; gate 2
waives exactly the five RX IDDR endpoints under a fenced envelope and refuses
everything else. Versioned alongside the RTL.

**Changelog v0.14 → v0.15 (task 4e: the half-cycle residue resolved):**

* **The "structural" RX setup failure was an artifact of Vivado's ZHOLD
  model** — and the open question task-4d recorded is closed with evidence.
  Measuring the routed feedback path directly (0.936/1.974 ns fast/slow)
  against the arc the tool applies (−2.703/−6.062) shows the modeled
  capture-clock arrival is a constructed constant, invariant across buffer
  topologies and blind to routing, carrying ~2.3 ns of phantom spread onto
  exactly the five RX input-delay checks. Manual generated-clock
  re-declaration leaves the arc intact (measured); `COMPENSATION=EXTERNAL`
  is rejected for any on-chip feedback loop ([Timing 38-290], measured).
* **Underneath the artifact sat a real defect**: the input-side IBUF+route
  spread (~1.66 ns corner-to-corner) passes straight through a deskew loop,
  so at `CLKOUT0_PHASE = 0` the slow-corner hold margin was **−0.33 ns** on
  silicon even though STA showed hold passing. The v0.14 claim that hold was
  "completely fixed" was true of the model, not of the physics — recorded
  here because it is exactly the class of error this project's gates exist
  to catch and this one slipped past all of them in both directions at once.
* **Fix:** `CLKOUT0_PHASE = −45.000` (−1000 ps, centred in the feasible
  window). Predicted physical margins +0.68/+1.13 ns setup, +1.12/+0.67 ns
  hold (~+0.5 ns after uncertainty). Bench fine-trim remains available in
  111.1 ps steps; the MDIO pad-skew register alternative named here at the
  time does not exist on the physical chip (A.2's B.5 correction: JL2121(D),
  not KSZ9031RNX). STA still
  reports the five RX checks negative by ~3.1 ns of artifact; **R20's RX
  half is signed off by derivation plus bench measurement**, not WNS.
* Gate 2 reshaped: it waives exactly the five RX IDDR input endpoints (count
  asserted — four or six refuse), bounds the waiver at −5.000 ns as written here
  (since tightened to −3.500 ns and made setup-only by the V-26 audit — hold
  refuses at those pins unconditionally), refuses on
  any other violating path named individually, and refuses if violations
  cannot be fully enumerated. Demonstrated refusing both ways before
  trusted.

**Changelog v0.13 → v0.14 (Stage 6 part 2: RGMII I/O timing, deskew, reset
architecture):**

* **The receive domain runs on a deskewed clock.** A second MMCM
  (`rtl/gem_rx_mmcm.v`, VCO 1125 MHz, feedback through a regional buffer)
  cancels the FPGA's clock-network insertion delay for `rgmii_rx_clk`;
  `gem_mac.rx_clk` now takes the MMCM's output, not the pin. Reason and
  measured history: task-4a proved the raw-BUFG network's 3.720 ns
  corner-to-corner spread exceeds the entire RGMII eye. The deskew collapsed
  the spread to 0.635 ns and fixed hold completely — but setup still fails
  ~2.1 ns on all five RX pins, structurally (task-4d/4d2 reports). **R20's
  WNS >= 0 is not met today and the build refuses rather than shipping a
  broken bitstream.**
* **Reset architecture amended** (`Documents/RX Clock Deskew Design.md`): an
  MMCM on a recovered clock does not self-recover after its input stops
  (UG472 p.83/p.91), so a clk50 reset supervisor re-pulses it forever while
  unlocked (~428 µs worst-case recovery, not 100 µs); `rx_rst_n` moved to the
  deskewed clock and became lock-gated; and a second reset, `rx_path_rst_n`,
  covers the destination half of every crossing out of the RX domain — without
  which one link drop delivered up to 127 octets of stale FIFO contents as
  fabricated frames plus five phantom counter events. The B.1b rule this
  violates and its justification are written into B.1b below.
* **Sub-gigabit links stop working entirely** — the deskew MMCM cannot lock
  below `MMCM_FINMIN` (10 MHz) against RGMII's 25/2.5 MHz lower-speed clocks.
  R13 already scoped v1 to 1000BASE-T only; the failure mode changed from
  "captures garbage" to "captures nothing, `rxlock=0` says why".
* The UART record gained a field: `rxlock=` (the deskew MMCM's lock),
  closing design-doc Step 3f. `sw/host` parses it; fixtures regenerated from
  simulation output.
* **B.1b's "no IDELAY needed for v1" claim is retracted** — it reasoned about
  the PHY's delay at the pins and omitted the FPGA's own clock-network
  insertion delay, which task-4a measured as the entire problem.
* Gate additions: gate 1c (the derived RX capture-clock anchor must resolve or
  the build refuses), gate 3 upgraded from reporting to refusing on
  unconstrained I/O, and gate 3 moved ahead of gate 2 because coverage gates
  the meaning of slack.

**Changelog v0.12 → v0.13 (Stage 5 closes):** `sw/host/` and `bringup_checklist.md`,
the two deliverables B.6 has listed as deliberately absent since v0.2, both exist. The
host tooling has its own tests, which run with no board and no dependencies and are now
a gate in `make check`, because the record format is a contract between
`rtl/gem_stat_report.v` and `sw/host/gem_records.py` and nothing else in this build
reads both halves. Their fixtures are lines the design actually printed in simulation.
**One honest limitation is now written down rather than discovered at a bench:** a
commodity NIC computes the FCS in hardware and pads runts before transmitting, so of
R10's four receive error classes a PC can provoke exactly one — oversize. B.5 step 7 is
scoped accordingly, the other three rest on simulation, and what a bench would need to
add them is stated in `sw/host/README.md`.

**Changelog v0.11 → v0.12 (there is a board):** `rtl/gem_top.v` ties the MAC, the
clocking block and the readout together and gives them pins, and `rtl/gem_echo.v`
gives the transmit path something to transmit — **B.5 step 6's echo mode**, good
frames only, with DA and SA exchanged so a reply reaches the host that sent it.
Echo is deliberately **store-and-forward**, which B.4b rejected inside the MAC and
which is right here for the opposite reason: a frame's verdict arrives with its last
octet, so an echo that streamed could not know whether the frame was worth echoing.
It costs one BRAM18 of the four B.2 budgets and zero the design was using. B.2's
measured column now has a whole-board row: **1123 LUTs, 1422 FFs, 1 BRAM18, 1 MMCM,
WNS +1.546 ns** at 125 MHz post-synthesis with `constrs/` applied. `constrs/pins.xdc`
carries every pin the board needs, all confirmed against the schematic (V-21), and
`constrs/clocks.xdc` declares `rgmii_rx_clk` and states that it is asynchronous to
everything the MMCM makes.

**Changelog v0.10 → v0.11 (R17's counters can leave the chip):** the UART readout
**B.7 item 5** decided in v0.9 is built — `rtl/gem_uart_tx.v` and
`rtl/gem_stat_report.v` — which closes **V-20**. B.7 item 5 now carries the record
format itself, because `sw/host/` will parse it and a format nobody wrote down is a
format that changes silently. The one design decision the obligations list did not
anticipate is the **snapshot**: every field of a line is captured in the same cycle,
since a record takes ~17 ms to clock out and fields sampled across that window would
show divergence that never happened. Its cost is most of 373 flip-flops. The LUT
estimate in B.7 item 5 held: 249 measured against 150–250 predicted.

**Changelog v0.9 → v0.10 (Stage 5's first block exists):** the **clock/reset module**
B.1a has described as absent since v0.1 is built — `rtl/gem_clk_rst.v`, with
`rtl/gem_mmcm.v` and `rtl/gem_reset_sync.v` under it — so the sentence saying there is no
reset synchroniser anywhere in this repository is no longer true and no longer here.
B.1a's bullet records what it owns, including the PHY's 10 ms reset hold, which had a
requirement in B.1b and no module. Two constants join the parameter header, `GEM_CLK50_HZ`
and `GEM_PHY_RESET_HOLD_US`, so the hold is derived rather than typed: 500,000 cycles, and
the model parses both.

**B.2's MMCM row is corrected**, and the correction is worth stating because the row was
wrong in a way that reads as fine: it carried four cells against a five-column header, so
the device's MMCM count had slid into the measured column and the table appeared to say
`gem_mac` had instantiated **five** MMCMs against a budget of one. The out-of-context MAC
contains none — the MMCM is the top level's, which is exactly what B.1a says — and the
device has five. No measurement changed; a table did.

**Changelog v0.8 → v0.9 (a decision taken before the stage that needs it):** **R17**'s
status readout is **UART**, not VIO, and **B.7 item 5** records why and what it obliges
Stage 5 to build. The requirement had carried "(or VIO)" since v0.1, which is a choice
left open, and an open choice discovered mid-integration is a choice made under
schedule pressure. The reasoning is B.5 step 8: the acceptance test is a four-hour
soak, and a readout that needs Vivado attached over JTAG cannot log, cannot be
scripted, and cannot produce evidence after the fact. Nothing else in this revision
changes — no RTL, no vectors, no gates.

**Changelog v0.7 → v0.8 (what building the RTL forced):** added **B.4d**, the one
question Stage 4 found that Stage 3 could not have: R6 as written and B.4b as written
could not both be satisfied, and the frozen `tx_reject_oversize` vector was the place
they collided. Resolved in R6's favour as B.4b would have resolved it — the octet that
would be the 1501st proves the payload is oversize, so the 1500th is refused
before it is transmitted and the wire carries a 1517-octet frame marked bad
rather than an oversize one or nothing at all — and that
one vector was regenerated. **B.2**'s
resource table gains a measured column — 993 LUTs and 1403 FFs against budgets of 2000
and 3000 — which closes the weakness B.7 states about those numbers being untraceable
guesses, and corrects one of them in kind: the RX FIFO uses no block RAM at all.
**B.1a** records the one addition to the interface the stub froze, an input carrying the
phase-shifted GTX_CLK that R14's mechanism cannot be built without. **B.4**'s status
paragraph reports Stage 4. **R16** gained the ports it always required: the frozen
interface had no request channel and no PHY-ID output, which left "a register-level
request interface" half-implemented and B.5 step 3 — read the PHY ID to prove the PHY
is alive — impossible to perform. Both are additive and no testbench changed
behaviour. An independent review of the finished stage found three defects that every gate had
passed, and they are recorded as **V-17, V-18 and V-19**: the IDDR nibble mapping was
inverted for a PHY that delays its receive clock (simulation cannot see it, and on
hardware nothing would have been received); the RX FIFO's memory had dissolved into 648
flip-flops because a RAM cannot have an asynchronous reset, while this table claimed
distributed RAM; and MDIO could begin a frame mid-MDC-period and drive only 31 preamble
ones. Each is fixed, and each now has something that would have caught it — a synthesis
gate, a testbench check, and a derivation replacing an "unknowable" comment.
Added `coding_standard.md`, the last Stage 4 deliverable the flow doc lists and the
only one that had no file — written from the RTL rather than before it, so every
rule in it is one the repository already follows and names what enforces it. **R12** is settled rather than left hanging: the DA filter is
not implemented in v1, the receive path is promiscuous, and B.7 now lists it as a
non-goal instead of describing it as undecided — a stretch requirement nobody has ruled
on is how a release ends up unable to say what it does.

**Changelog v0.6 → v0.7 (coherence pass across every document):** **B.1a**'s abort now
also appears in [`block_diagram.md`](block_diagram.md), which still drew a transmit path
that could not abort — the same disagreement between architecture and contract that v0.5
fixed in the prose. B.4's status paragraph counts 70 tests and eighteen scenarios, and now
records all **seven** gates rather than the four in `make check`, since Stage 2's build
carries three more. Added a top-level `README.md`, which B.6 had listed as a deliverable
since v0.2 without it existing.

**Changelog v0.5 → v0.6 (from an independent review of the Stage 3 vectors):** added
**B.4c** — two limits R15's interface imposes that Ethernet does not, both of which the
frozen transmit vectors were violating. A zero-length payload cannot be expressed on an
AXI-Stream port (no beat to carry `tlast`) yet `tx_padding` contained two, with expected
wire output no design could ever produce; and the inter-frame gap was frozen at exactly
12 octets when R5 requires only a floor, so any design that was merely *later* than the
model — which after a B.4b abort it must be, by up to 1400 cycles — would have failed.
Also corrected R21's prose and B.3a's latency row, which still quoted the pre-holdback
9 cycles / 3.6× that v0.3 superseded in B.1b.

**Changelog v0.4 → v0.5 (accuracy pass at the close of Stage 3):** **B.1a** now shows the
abort in the transmit path — v0.4 specified it in B.4b but left the architecture section
describing a TX path that could not do it. **B.7** gains the TX store-and-forward
alternative and the threshold-buffer v2 note that B.4b already claimed were recorded there
(they were not — a dangling cross-reference). **B.6** now separates what the repo actually
contains from what is committed-to but deliberately absent; three of the paths it listed
did not exist. **B.4**'s status paragraph and coverage criterion were stale: the test count
was 55 and is now 68, seventeen scenarios not sixteen, R1–R24 not R1–R21.

**Changelog v0.3 → v0.4:** added **B.4b**, the TX underrun contract — the last question
Stage 3 left genuinely open, and one Stage 4 cannot be written around. Resolved as
**cut-through with abort on underrun** (`TX_ER` plus an inverted FCS, counted, never
resumed), rejecting store-and-forward because its 12.14 µs of added transmit latency
contradicts the latency premise this design exists to demonstrate. R7's conditional
wording is now explicit about which branch B.4b specifies, and R17 gains
`stat_tx_underrun`.

**Changelog v0.2 → v0.3 (all changes forced by writing the reference model, which is
what Stage 3 is for):** added **B.4a**, the RX delivery contract — three questions that
were genuinely ambiguous in v0.2 and that the model could not be written without
answering (what `rx_axis_tdata` carries, when `tlast` fires for a bad frame, and which
error class wins when a frame is in several at once); corrected **B.1b's R21 latency
sum** from 9 cycles to 13, adding the four-cycle FCS holdback register that cut-through
delivery requires and v0.2 omitted — margin against R21's ceiling drops from 3.6× to
2.5×, still comfortable; recorded the Stage 3 status against B.4's verification strategy.

**Changelog v0.1 → v0.2:** corrected the AX7035B's Ethernet PHY identity (it is a Micrel/
Microchip **KSZ9031RNX**, not a Realtek RTL8211 — see the note in A.2); resolved all four
B.7 open items with datasheet-grounded derivations instead of leaving them open; added
B.1a (architecture/block diagram), B.1b (clocking & reset), and B.3a (parameter derivation
table); moved into `spec/` per the B.6 repo layout; re-centered the `GTX_CLK` MMCM phase
target from 2.0 ns (the PHY window's edge, zero margin) to 1.6 ns (the window's center,
±0.4 ns margin both sides); added a bottom-up pipeline sum for R21's latency budget
instead of asserting the 32-cycle ceiling as "generous" without checking it.

---

# Part A — Board selection

## A.1 The requirement that filters everything

This project needs a **gigabit Ethernet PHY whose data pins route to FPGA fabric I/O**
(RGMII or GMII). That single requirement eliminates most popular budget boards:

- **Digilent Arty A7 / Nexys A7 / Basys 3** — the Arty family's PHY is **10/100 only**
  (MII). No 1G possible. This is the classic trap purchase for this exact project.
- **Zynq boards (PYNQ-Z2, Arty Z7, Zybo)** — they *have* gigabit PHYs, but wired to the
  **processor subsystem's hard MAC (GEM) via MIO pins**, not to fabric. You'd be
  configuring someone else's MAC, not building one.
- **Your Kria KV260** — same story: its PHY hangs off the PS GEM. Great DSP board, wrong
  board for a fabric MAC.

## A.2 Recommendation

**Primary: ALINX AX7035B — ~$150 direct from Alinx**

| Item | Value |
|---|---|
| FPGA | AMD Artix-7 **XC7A35T**-2FGG484I (industrial, -2 speed) |
| Vivado support | Free tier (Artix-7 has always been in WebPACK/Standard; still free after the 2026.1 licensing restructure) |
| Ethernet | 1× 10/100/1000 port, **Micrel/Microchip KSZ9031RNX PHY, RGMII, wired to fabric I/O** |
| Memory | 256 MB DDR3 (not needed for this project — nice for later ones) |
| Other | HDMI in/out, USB-UART, MicroSD, 2× 40-pin expansion, JTAG programmer support |
| Collateral | Schematic, pin assignments, and **Verilog demo projects including Ethernet** — a reference XDC for the RGMII pins is worth real hours |

> **Correction (v0.2):** earlier drafts of this spec assumed a Realtek RTL8211-family PHY.
> The ALINX AX7035 user manual states the actual chip is a **Micrel/Microchip KSZ9031RNX**
> (RGMII interface) — confirmed from the manual text and cross-checked against the
> KSZ9031RNX datasheet (Microchip, Rev 2.2, May 2015). Every RGMII timing number in this
> document (R14, R20, B.1b, B.7) is now KSZ9031RNX-specific. **Re-confirm the chip marking
> against the physical board** the moment it arrives (Stage 2 bring-up step 1) — board
> revisions occasionally swap PHY vendors without renaming the SKU.

> **Correction (from B.5 bring-up, 2026-08-27): the manual was wrong too. The physical
> chip is a JLSemi JL2121(D), not a KSZ9031RNX.** The manual's own text said
> KSZ9031RNX; the silkscreen on the board's actual Ethernet PHY IC reads
> `JL2121 N040I 042MA9CF`, and B.5 step 3's MDIO read confirms it with certainty,
> not just marking-matching: `phyid` came back `0x937c4032`, and the JLSemi
> datasheet (`DS009-JL2121(D)-v1.09-Preliminary`, jlsemi.com) gives PHYIDR1's
> reset value as `0x937c` and PHYIDR2 as a fixed `0x402x` with the low nibble the
> silicon revision — `0x4032` is exactly revision 2. Neither the KSZ9031RNX
> assumption nor its A.2 predecessor (RTL8211) was ever checked this way; this
> one is, and closes the identity question completely.
>
> **What this does and does not invalidate.** BMSR, PHYIDR1, PHYIDR2 and the
> other Clause 22 basic registers (0x0–0xF) sit at the same standard addresses
> on both chips, so `link_up` (BMSR bit 2) and the PHY-ID read `rtl/gem_mdio.v`
> already relied on are unaffected. Two things are not:
>
> - **Register 0x1F is not a speed/duplex register on the JL2121(D).** It is
>   the Page Select Register — the chip banks its vendor registers (PHY
>   Specific Status at page `0xA43`, LED control, SGMII, ...) behind it, and
>   reading it back returns the selected page, not a speed encoding.
>   `rtl/gem_mdio.v`'s poll sequencer read it directly and decoded bits
>   assuming a KSZ9031RNX-style layout; on the physical chip the pattern it
>   was matching against never asserts, so `link_speed` would have silently
>   frozen at its reset value forever. **Fixed** — the sequencer now selects
>   page `0xA43`, reads the PHY Specific Status Register (register `0x1A`,
>   bits `[5:4]`), and restores the default page, atomically against the R16
>   request port. See the header comment and `POLL_PHYSR`/`POLL_PAGE_SEL`/
>   `POLL_PAGE_RESTORE` in `rtl/gem_mdio.v`.
> - **There is no MDIO pad-skew register.** B.1b's RX default-delay claim and
>   the RGMII TX escalation path documented in
>   `Documents/RGMII I-O Timing Derivation.md` ("If 58 ps proves insufficient
>   on the bench") both assume the KSZ9031RNX's MMD `2h`/register `8h`
>   pad-skew field, reached over MDIO. The JL2121(D) datasheet has no MMD
>   register-access mechanism at all: `RXDLY`/`TXDLY` (pins 25/24) are
>   **hardware strap pins**, each adding a fixed 0 or 2 ns, sampled once at
>   reset — not written at runtime. That escalation path does not exist on
>   this chip. **Not fixed here** — the strap pins' as-populated state on the
>   AX7035B is a schematic question this repository cannot answer without the
>   board's schematic in hand; see `docs/reports/stage9/known-issues.md`.
>
> Every other KSZ9031RNX-sourced number in this document (the 1.2 ns RX
> default delay used to centre the deskew MMCM's phase, the RGMII timing
> budget's `TsetupR`/`TholdR`/`TsetupT`/`TholdT` window, the PHY reset hold
> time `tSR`) is a KSZ9031RNX datasheet figure applied to a JL2121(D) board and
> is now **unconfirmed pending a JL2121(D)-specific re-derivation** — not
> necessarily wrong, since the RGMII v2.0 windows both chips claim to meet are
> the same standard's numbers, but sourced to the wrong datasheet until checked
> against the JL2121(D)'s own AC specifications (Chapter 4.7, in
> `DS009-JL2121(D)-v1.09-Preliminary`). This did not block B.5 steps 3-6, which
> proceed on Clause 22 registers alone (vendor-independent), but it must be
> resolved before trusting the pad-skew escalation path or the RX deskew
> MMCM's timing-closure claims.

Why it wins: cheapest board with fabric-attached gigabit, ships with schematics and Ethernet
demo RTL, and the 35T is comfortably large for a MAC (budget in Part B shows <10%
utilization). Buy direct from `en.alinx.com` or Amazon (Amazon runs slightly higher).

**Alternatives:**

- **Numato Mimas A7 (~$230, XC7A50T, RTL8211E RGMII, DDR3)** — US vendor with English docs
  and a published Vivado gigabit-Ethernet tutorial; DigiKey stocks it. Pick this if you
  prefer a US seller / better documentation over the $80 difference.
- **Digilent Nexys Video (~$580, XC7A200T, RGMII)** — the "no-questions" academic board.
  Overkill and over budget here; listed so you know the ladder.

One licensing note in your favor: because you are **writing the MAC yourself**, you never
touch AMD's Tri-Mode Ethernet MAC IP — which is a *paid* license. The vendor demo projects
use it; your design won't. Everything you need (IDDR/ODDR/IODELAY primitives, MMCM, BRAM
FIFOs) is free fabric.

---

# Part B — Initial Specification: `gem_mac`, a 1000BASE-T Ethernet MAC

## B.1 Problem statement

Modern electronic trading systems receive market data and send orders as Ethernet frames,
and the FPGA sits directly on the wire: the first piece of logic a market-data packet meets,
and the last piece an order leaves, is the **Media Access Controller (MAC)** — the layer-2
block that turns the PHY's raw nibble stream into validated frames and turns outgoing
frames into a correctly framed, correctly timed wire signal. Every HFT FPGA design —
feed handler, order gateway, tick-to-trade pipeline — is built on top of one.

**You will design, verify, and bring up on real hardware a full-duplex 1 Gbps Ethernet MAC**
in synthesizable Verilog-2001 on the AX7035B, talking RGMII to the board's KSZ9031RNX PHY on
one side and presenting a clean streaming interface to user logic on the other. "Done"
means: the board, connected by CAT5e to your PC's NIC, exchanges real frames with software
on the PC, survives sustained full-rate traffic and deliberately corrupted input, and
reports what it saw through readable counters — verified by Wireshark on the PC and an ILA
on the chip.

The MAC's job, precisely:

- **Transmit path:** accept a payload stream from user logic; prepend preamble and SFD;
  insert destination/source addresses and EtherType; pad short payloads to the legal
  minimum; compute and append the CRC-32 frame check sequence; drive it out the RGMII pins
  at 1 Gbps with legal inter-frame gaps.
- **Receive path:** recover the byte stream from RGMII; hunt for SFD; strip preamble;
  check frame length legality and verify the FCS; deliver good frames to user logic with a
  per-frame good/bad verdict; count and discard bad ones without corrupting subsequent
  frames.
- **Management:** an MDIO controller to read/configure the PHY (link status, speed,
  negotiated mode) — because a MAC that can't confirm the link is up is undebuggable.

What makes this non-trivial is not the framing logic — it's that the design has **three
clock domains** (the PHY hands you a receive clock you don't control), a datapath that runs
at **exactly one byte per cycle with zero slack** during a frame, and I/O timing at
double-data-rate 125 MHz where a wrongly-constrained pin produces a design that passes
every simulation and fails on the bench.

## B.1a Top-level architecture

`gem_mac` is ten modules across three clock domains. Dataflow diagram: [`spec/block_diagram.md`](block_diagram.md).
Stage 4 implemented them as thirteen files — the extra four were the two DDR I/O cells,
the pulse synchroniser the counters cross on, and the CRC accumulator, which is one
module instantiated twice rather than two implementations of the same arithmetic.
The tenth module arrived at V-25's close: `gem_rx_abort`, downstream of the egress
register, closes a frame a link event took away with an in-band synthetic beat
(`tlast=1, tuser=0`) instead of leaving the port to go quiet mid-frame — see B.4a's
amendment and module 9's description below.

**One port was added in Stage 4**, and it is the only change to the interface the
Stage 3 stub froze: `gtx_clk_shifted`, an input carrying the MMCM's second output.
R14's mechanism is that GTX_CLK leaves the chip a deliberate 1.222 ns after the data it
clocks, so the cell that forwards it needs a clock the MAC does not otherwise have;
the alternative is to move that cell outside `gem_mac`, which puts half of the RGMII
output stage somewhere B.1a does not describe. The addition is backward compatible —
every Stage 3 testbench elaborates unchanged, leaving it unconnected.

**Transmit path (tx_clk domain):**
1. **AXI-S ingress register** — registers `tdata/tvalid/tready/tlast` plus the `tuser`
   sideband (DA/SA/EtherType, presented at SOF per R15); no combinational path to `tready`.
   Also detects the mid-frame starve that B.4b turns into an abort: `tvalid` low while a
   frame is in flight and no octet buffered.
2. **Frame assembler / padder** — prepends preamble+SFD, inserts DA/SA/EtherType, pads
   payloads < 46 B with zeros (R3), rejects payload > 1500 B (R6).
3. **Parallel CRC-32 generator** — byte-parallel update running alongside the payload
   stream (resolved in B.7 item 2); appends FCS at frame end, or its bitwise inversion
   when the frame is being aborted (B.4b) — one XOR on the output mux.
4. **TX arbiter / IFG counter** — tracks a local `transmitting` flag and enforces the
   96-bit (12-byte) inter-frame gap (R5); full-duplex, so no CSMA/CD, deference, or
   collision logic (IEEE 802.3-2022 §4.2.3.2.6). Owns the abort sequence: assert `TX_ER`
   across the inverted FCS, drop `TX_EN`, take a full IFG, discard the rest of the
   starved frame rather than resuming it, and count `stat_tx_underrun` (B.4b).
5. **RGMII output stage** — ODDR primitives drive `TXD[3:0]`/`TX_CTL`; a second,
   phase-shifted MMCM output drives the `GTX_CLK` pin (mechanism in B.1b).

**Receive path (rx_clk domain, crossing to sys_clk at the FIFO):**
6. **RGMII input stage** — IDDR primitives capture `RXD[3:0]`/`RX_CTL` on `rx_clk`.
7. **SFD hunter / deframer** — scans for the SFD (R8/R11), strips preamble, and
   streams the frame onward byte-by-byte. It does **not** extract DA/SA/EtherType:
   B.4a item 1 resolved that `rx_axis_tdata` carries DA through pad and that there is
   no RX header sideband, so user logic reads the header from the first 14 beats. This
   wording said otherwise until Stage 4, which is the contradiction B.4a itself names.
8. **Parallel CRC-32 checker + frame classifier** — running CRC check in parallel with
   the stream (R9's cut-through contract, detailed in `Documents/Bad bitstream handle.md`);
   classifies runt/oversize/bad-FCS/RX_ER (R10) with one counter per class (R17).
9. **RX async FIFO** (rx_clk → sys_clk, depth derivation in B.3a) **→ AXI-S egress
   register → `gem_rx_abort`**, verdict on `tuser` at the `tlast` beat (R9). The
   abort module (V-25) watches the handshake downstream of the egress register and,
   when a link event resets the receive domain with a frame open on this port, closes
   it in band with one synthetic beat — `tlast=1, tuser=0`, `tdata=8'h00` — so every
   frame ends with exactly one `tlast` (B.4a's rule 2 as amended); it is reset by
   `tx_rst_n` only, so it survives the event it exists to observe.

**Shared:**
- **MDIO master** — register-level request interface *and* a sequencer that polls
  the PHY unprompted, ≤ 2.5 MHz MDC (R16). The request port is what "register-level"
  means: any register, read or write, on demand — including the pad-skew registers
  B.1b names as the RGMII timing fallback, which no fixed poll list could reach. The
  sequencer reads PHY ID, BMSR twice (its link bit latches low) and the vendor speed
  register, and publishes `phy_id`, `link_up` and `link_speed` on pins, so B.5's
  bring-up steps 2 and 3 can be done with an ILA and no software attached. Neither
  half was expressible on the port list Stage 3 froze; both ports were added in Stage
  4 rather than the requirement trimmed.
- **Register/status block** (sys_clk domain) — frame counters, link state, sticky error
  flags, all clearable, readable over UART/VIO (R17).
- **Clock/reset module** — MMCM + per-domain reset synchronizers (B.1b). Deliberately
  not part of Stage 4: it is board-level integration, not MAC logic, and `gem_mac`
  accordingly takes `tx_clk`, `gtx_clk_shifted` and two already-synchronised resets as
  inputs and contains no reset synchroniser of its own. **Built in Stage 5** as
  `rtl/gem_clk_rst.v`, with the MMCM isolated in `rtl/gem_mmcm.v` (the coding standard's
  rule that vendor primitives do not appear in logic modules) and the synchroniser
  itself in `rtl/gem_reset_sync.v`, instantiated once per domain. It also owns the PHY's
  power-on reset hold, counted on `clk50` because that is the only clock running before
   the MMCM locks. `tb_gem_clk_rst` checks the properties B.1b asserts and nothing
   else can: reset asserting with no clock edge available, releasing only on its own
   domain's edge, `tx_rst_n` never releasing onto an unlocked MMCM — and, since the
   Stage 6 part 2 deskew architecture amended B.1b, `rx_rst_n`'s lock-gated release
   (`tx_rst_n & rx_mmcm_locked`, on the deskewed clock) with `rx_path_rst_n` asserting
   and releasing in the right order. That amendment retired the bullet this sentence
   previously carried — "`rx_rst_n` not depending on the MMCM at all" — which was true
   of the pre-deskew design and is deliberately false of this one.

## B.1b Clocking and reset

**Clocks (R19):**

| Clock | Freq | Source | Drives |
|---|---|---|---|
| `tx_clk` | 125 MHz | MMCM, locked to the board's 50 MHz oscillator | TX datapath, register block, `sys_clk` (= `tx_clk`, B.7 item 3) |
| `gtx_clk_shifted` | 125 MHz | Same MMCM, second output (`CLKOUT1`), phase-shifted −55° (1.222 ns) from `tx_clk` — the committed value; see Documents/RGMII I-O Timing Derivation.md §5 for why not the 1.6 ns centre | Only the ODDR driving the `GTX_CLK` pin — a delayed copy for I/O timing, not an independent logic domain |
| `rx_clk` | 125 MHz nominal | Recovered by the KSZ9031RNX's CDR from the link partner's transmit clock, driven in on `RX_CLK` | The RX deskew MMCM only (Stage 6 part 2) — **asynchronous to `tx_clk`** |
| `rx_clk_deskew` | 125 MHz | Second MMCM, feedback deskewed against the raw pin clock | RGMII input capture, SFD hunt, deframe, CRC check, classify, FIFO write side — the whole receive domain. See B.7 item 6 and `Documents/RX Clock Deskew Design.md` |

**RGMII skew mechanism (R14) — resolved from the KSZ9031RNX datasheet (Microchip, Rev
2.2), "RGMII Timing" section and Table 19. See A.2's B.5 correction: the physical
board carries a JLSemi JL2121(D), not a KSZ9031RNX, and every number below is
unconfirmed against that chip's own datasheet pending a re-derivation:**

- **RX:** the PHY adds **1.2 ns typical** delay to `RX_CLK` relative to `RXD`/`RX_DV`
  **by default, out of reset — no MDIO write required.** This sits inside the RGMII v2.0
  `TsetupR`/`TholdR` window (1.0–2.0 ns). ~~Consequence: the FPGA RX side needs
  **no IDELAY** for v1 — an IDDR clocked directly by `RX_CLK` is sufficient.~~
  **Retracted in Stage 6 part 2:** that reasoning accounted for the PHY's delay at
  the *pins* and omitted the FPGA's own clock-network insertion delay, which
  task-4a measured at 3.720 ns corner-to-corner — more than the entire guaranteed
  eye, and invariant under every IDELAY or phase choice. The fix was a deskew MMCM
  (`Documents/RX Clock Deskew Design.md`), not an IDELAY; its outcome is recorded
  in the v0.14 changelog and `docs/reports/stage6-part2/`.
- **TX:** the datasheet is explicit that the PHY does **not** add delay on its `GTX_CLK`/
  `TX_EN`/`TXD` inputs — *"the KSZ9031RNX does not add any delay locally... and expects
  the GTX_CLK delay to be provided on-chip by the MAC."* Required window at the PHY pins:
  `TsetupT`/`TholdT` = 1.2–2.0 ns. Mechanism: the MMCM's second output (`gtx_clk_shifted`
  above), phase-shifted **−55° = 1.222 ns of the 8 ns period** from `tx_clk`, feeds the
  ODDR driving `GTX_CLK`. The committed value is a measured choice, not the window's
  naive centre: −72°/1.6 ns was never achievable on this VCO's phase grid, and the
  sweep across every legal grid point inside the PHY window (task-2b/2d/2e, recorded in
  `Documents/RGMII I-O Timing Derivation.md` §5) put −55° on the 1125 MHz VCO's exact
  5° grid with the best measured post-route margin — worst TX setup +0.058 ns, hold
  +1.645 ns. Fallback: the PHY's `GTX_CLK` pad-skew
  register (MMD `2h`, reg `8h`, bits `[9:5]`) can add up to +1.38 ns if the MMCM phase
  alone proves insufficient once measured on the bench (ILA or scope on `GTX_CLK`/`TXD0`).

**R21 latency budget — bottom-up check** (previously asserted as "generous," now summed):

| RX pipeline stage | Cycles (`rx_clk`/`sys_clk`) |
|---|---|
| IDDR capture + nibble combine (DDR → 1 byte/cycle) | 1 |
| SFD hunt / deframer FSM | 2 |
| **FCS holdback register (added v0.3 — see below)** | **4** |
| CRC-32 verdict generation at EOF (parallel accumulator, registered compare) | 1 |
| Async FIFO CDC, `rx_clk` → `sys_clk` — same structural cost as the sync-latency term in B.3a | 4 |
| Registered AXI-S egress stage (R15: no combinational paths through the handshake) | 1 |
| **Total** | **13 cycles = 104 ns** |

**The FCS holdback term, and why v0.2 missed it.** The RX user port must not emit the
four FCS octets (B.4a's delivery contract: DA through pad, nothing else). But cut-through
delivery cannot know *which* four octets are the FCS until `RX_DV` drops — by which time
a naive implementation has already streamed them out. The only way to keep them off the
port is a four-octet delay line: bytes are held back four cycles so that when the frame
ends, the FCS is still inside the register and is discarded rather than delivered. This
is not optional and not an implementation choice; it falls directly out of combining R9's
cut-through requirement with a port that excludes the FCS. v0.2's sum listed the stages
that transform data and omitted the one that only delays it.

13 cycles against R21's 32-cycle (256 ns) ceiling is **2.5× margin** (`spec/budget.m`,
`rxLatencyBudget()`) — down from the 3.6× v0.2 claimed, and still comfortable. The
async FIFO crossing and the FCS holdback are now joint largest contributors at 4 cycles
each, and they are there for opposite reasons: one is a genuine CDC boundary, the other
is pure latency bought to satisfy a delivery contract. Were R21 ever tightened, the
holdback is the term to attack first — delivering the FCS to user logic and letting it
discard four octets would buy all four cycles back, at the cost of a messier interface.

*Found in Stage 3 while writing the golden model's `expectedBeats` function, which is
exactly the kind of omission the flow doc predicts a reference model will surface: the
question "what precisely comes out of this port, on which cycle?" cannot be answered
hand-wavily by working code.*

**Reset strategy:**

- Per-domain: asynchronous assert, synchronous deassert (2-flop synchronizer) on that
  domain's own clock — no domain's reset release depends on another domain's
  clock running, **with one exception, added in Stage 6 part 2: a domain whose own
  clock is not free-running may have its reset release depend on `clk50` and clocks
  derived from it, because `clk50` is the board oscillator — free-running, never
  gated, and already the root every other reset depends on. Any use of this exception
  must be acyclic and must be written down.** `rx_clk_deskew`'s reset takes this
  exception: an MMCM on a recovered clock does not self-recover after its input stops,
  so its release waits for the clk50-clocked supervisor's re-lock and is additionally
  gated on `tx_rst_n`. The reasoning is in `Documents/RX Clock Deskew Design.md`,
  Steps 3a–3e and 5; the dependency graph is a strict DAG rooted at `clk50`.
- `tx_clk`-domain reset release is additionally gated on MMCM lock (never leave reset on
  an unlocked MMCM).
- **`rx_path_rst_n`** — a second reset, in the `tx_clk` domain, covering the destination
  half of every crossing out of the RX domain (FIFO read side, egress, the five counter
  event synchronisers, the FIFO-drop LED pulse). Both halves of any such crossing now
  always assert together; without this, an RX-only reset drained stale FIFO contents
  onto the AXI-S port as fabricated frames and fired phantom counter events
  (`Documents/RX Clock Deskew Design.md`, Step 3b). Consequence stated plainly: a frame
  in flight on the RX AXI-S port during a link event aborts **without `tlast`**
  (owner decision (a), recorded in B.4a).
- PHY reset (`RST_N`, active-low, board-level): datasheet specifies **tSR ≥ 10 ms** from
  stable supply voltage to reset de-assertion. Hold `RST_N` low ≥ 10 ms after power-up and
  treat MDIO as invalid until it's released — this is bring-up checklist step 2/3 (B.5).

## B.2 Requirements

Numbered so the verification plan can trace to them. **[M]** = must, **[S]** = stretch.

### Functional — transmit

- **R1 [M]** Encapsulate user payloads into Ethernet II frames: 7-byte preamble (0x55),
  1-byte SFD (0xD5), 6-byte DA, 6-byte SA, 2-byte EtherType, payload, 4-byte FCS.
- **R2 [M]** DA, SA, EtherType are per-frame inputs alongside the payload stream (not
  compile-time constants).
- **R3 [M]** Pad payloads shorter than 46 bytes with zeros so the frame (DA→FCS) is ≥ 64
  bytes.
- **R4 [M]** Compute FCS as IEEE 802.3 CRC-32: polynomial 0x04C11DB7, bit-reflected
  in/out, init 0xFFFFFFFF, final complement, transmitted least-significant-byte-first.
- **R5 [M]** Enforce inter-frame gap ≥ 96 bit-times (12 byte-times) between frames.
- **R6 [M]** Reject (and flag via a status pulse + counter) requests with payload > 1500
  bytes; never emit an oversize frame. Because transmission is cut-through (B.4b), the
  MAC learns the length only when the request exceeds it — so "reject" means: refuse the
  **1500th** payload octet on the cycle a 1501st is known to exist, *before* that octet
  is transmitted, and terminate the frame the
  way B.4b terminates an abort (`TX_ER` plus an inverted FCS), counted in
  `stat_tx_rejected`. The frame that reaches the wire is 1517 octets and is marked bad;
  no oversize frame is ever emitted. **B.4d** is where this wording comes from and why
  the alternative — silence on the wire — is not available to any cut-through MAC.
- **R7 [M]** Sustain back-to-back frames at full line rate indefinitely (no growing gap,
  no stall) when user logic supplies data every cycle. When it does *not* — a stall
  mid-payload — the frame is aborted per **B.4b**, marked with `TX_ER` and an inverted
  FCS, counted in `stat_tx_underrun`, and never silently stalled or silently completed.
  The conditional in this requirement is deliberate and B.4b is where the other branch
  is specified.

### Functional — receive

- **R8 [M]** Detect SFD anywhere in the incoming stream; tolerate shortened/absent
  preamble down to SFD-only.
- **R9 [M]** Verify FCS on every frame; deliver the frame with an end-of-frame
  good/bad flag. (Store-and-forward frame buffering is **not** required — cut-through
  delivery with a trailing verdict is the HFT-idiomatic choice; user logic drops on bad.)
- **R10 [M]** Discard as invalid, count separately, and recover cleanly from: runt
  (< 64 B), oversize (> 1518 B), bad FCS, RGMII RX_ER during frame. "Recover cleanly" =
  the next good frame is received intact.
- **R11 [M]** Ignore inter-frame garbage (anything before a valid SFD) silently.
- **R12 [S]** Optional DA filter: promiscuous mode vs. match-my-MAC + broadcast.
  **Not implemented in v1, by decision** (B.7, and V-7 in the verification plan). The
  receive path is promiscuous: every frame is delivered with its verdict and user logic
  decides what to do with it. That is not a shortfall dressed up as a choice — it is the
  mode bring-up step 4 requires anyway, and address filtering in the MAC would hide
  exactly the frames a bring-up session needs to see. Promoting it later is additive: a
  comparator on the first six delivered octets and a mode bit in R17's register block,
  with no change to any other contract.

### Interfaces

- **R13 [M]** RGMII v2.0 to the PHY: 4-bit DDR data + control at 125 MHz each direction,
  1000 Mbps mode only. (10/100 fallback explicitly out of scope — see B.7.)
- **R14 [M]** The clock-to-data skew required by RGMII is provided by a deliberate,
  documented mechanism, resolved in B.1b: **RX** relies on the KSZ9031RNX's default
  1.2 ns PHY-side delay plus the deskew MMCM's −45° capture trim (this number is
  sourced to the wrong chip's datasheet — see A.2's B.5 correction, JL2121(D)
  not KSZ9031RNX); **TX** is generated FPGA-side via a
  second MMCM output phase-shifted −55° (1.222 ns, the measured-best legal grid point
  in the PHY's window — see `Documents/RGMII I-O Timing Derivation.md` §5)
  relative to `tx_clk`, driving `GTX_CLK` through an ODDR — constrained in
  XDC, and never left to luck.
- **R15 [M]** User side: 8-bit AXI-Stream-style handshake per direction —
  `tdata[7:0], tvalid, tready, tlast` plus `tuser` (TX: DA/SA/EtherType sideband at SOF;
  RX: good/bad at EOF). Registered, no combinational paths through the handshake.
- **R16 [M]** MDIO/MDC master (≤ 2.5 MHz MDC) with a register-level request interface;
  bring-up software (or a hardware sequencer) uses it to read PHY ID, link status, and
  resolved speed/duplex.
- **R17 [M]** Status/debug register block readable over **UART**: frame counters
  (TX ok, TX rejected, **TX underrun**, RX ok, RX bad-FCS, RX runt, RX oversize, RX_ER),
  link state, sticky error
  flags, all clearable. The "(or VIO)" this requirement carried until v0.9 is resolved
  in favour of UART — **B.7 item 5** has the reasoning, the record format, and the
  measured cost. The counters themselves exist and are verified (Stage 4); the readout
  that gets them out of the chip is built in Stage 5 (`gem_uart_tx`, `gem_stat_report`),
  which closes V-20. Its pin is **G16** on this board (V-21, confirmed against the
  schematic).

### Performance & clocking

- **R18 [M]** Line rate 1.000 Gbps each direction simultaneously (full duplex); zero
  dropped frames on the RX path at line rate with minimum IFG.
- **R19 [M]** Three clock domains handled explicitly: `tx_clk` (125 MHz, MMCM from the
  50 MHz board oscillator), `rx_clk` (125 MHz, from PHY RXC pin — asynchronous to
  tx_clk), `sys_clk` (user/management domain; may equal tx_clk domain in v1). All
  domain crossings via async FIFOs or documented synchronizers; **zero undeclared CDC
  paths** (checked by `report_cdc` — build.tcl gate 4, which asserts the exact
  inventory of structurally-unprovable-but-documented crossings and refuses on any
  unmarked synchroniser or new finding).
- **R20 [M]** Timing closed with WNS ≥ 0 at 125 MHz on all declared clocks, and RGMII I/O
  constrained with real input/output delay values derived from the KSZ9031RNX datasheet
  (Table 19, "RGMII Timing") — not left unconstrained. Status and the RX-half sign-off
  mechanism: `verification_plan.md`'s R20 row (TX/fabric by STA; the five RX input checks
  by derivation plus bench, waived in gate 2 — task-4e).
- **R21 [M]** MAC-added latency (last bit of a field in → corresponding byte out of the
  user interface) ≤ 32 rx_clk cycles (256 ns) on RX. Measured in sim; a spec number to
  design against — confirmed generous by the bottom-up pipeline sum in B.1b (13 cycles,
  2.5× margin), not just asserted.

### Resources (targets, to be checked per-module at Stage 4 step 6)

| Resource | Budget | **Measured (Stage 4)** | XC7A35T has | Headroom rationale |
|---|---|---|---|---|
| LUTs | ≤ 2,000 | **745** | 20,800 | TX ~400, RX ~500, CRC×2 ~300, MDIO ~150, regs/dbg ~300, margin |
| FFs | ≤ 3,000 | **788** | 41,600 | pipeline + CDC + counters |
| BRAM36 | ≤ 4 | **0** | 50 | 2 async FIFOs + ILA capture |
| DSP | 0 | **0** | 90 | nothing multiplies here |
| MMCM | 2 | **0** (in `gem_mac`) · **1** crystal + **1** RX deskew (in `gem_clk_rst`) | 5 | two MMCMs: crystal (tx_clk 125 MHz + gtx_clk_shifted ≈1.222 ns, B.1b) and RX deskew (125 MHz, feedback-compensated — see B.7 item 6) |

The measured column is `make oocsynth`: `gem_mac` synthesised alone, out of context,
at Stage 4 step 6 — the step B.7's closing paragraph names as where these numbers stop
being guesses. LUTs and FFs are **cell counts** (`get_cells` by primitive group), not
Vivado's "Slice LUTs" line, which packs and therefore reports lower: 669 slice LUTs for
the same design. Cell counts are the conservative number and the one that compares
against a budget written per block.

The estimates were right in order of magnitude and conservative in degree: 3.6% of the
device's LUTs against a budget that was itself under 10%. B.3a's 64-entry FIFO occupies
14 LUTs of distributed RAM and no block RAM at all, which is cheaper than the derivation
assumed and leaves the derivation intact.

**That last sentence was false for two weeks and no gate caught it.** The FIFO's memory
was written inside a block with an asynchronous reset, which a RAM cannot have, so
Vivado built the array out of 648 flip-flops and a multiplexer tree — nearly half the
design's registers — and said so in the log while every gate passed. The numbers above
are the corrected ones (993 → 745 LUTs, 1403 → 788 FFs, WNS +2.135 → +2.262 ns), and
`scripts/synth_module.tcl` now refuses a build on `Synth 8-4767` so that "printing a
report" and "reading it" stop being different things.

**Scarce resource: MMCM**, not LUTs. By percentage of what the device has, MMCM is the
tightest line in this table (1 of 5 = 20%), ahead of LUTs (~10% even at the budget
ceiling), BRAM36 (8%), and FFs (~7%). It isn't a real constraint at v1 — 4 MMCMs stay
free — but it is the first thing a v2 that adds another PHY, a DDR3 controller, or a
second independent clock domain (B.7 item 3) would have to budget against, since MMCMs
don't subdivide the way LUTs/FFs do: one instance is used or it isn't.

A MAC blowing past 10% of a 35T means something structural is wrong.

### Quality gates

- **R22 [M]** Verilator lint clean, zero warnings (suppressions require a justifying
  comment).
- **R23 [M]** Zero inferred latches; build script fails the build on any.
- **R24 [M]** Bit-exact agreement with the golden model on the full regression suite
  (below); build refused on negative slack.

## B.3 Rate and cycle budget (the Stage-1 arithmetic)

```
Line rate:            1 Gbps  =  125 MB/s
Datapath:             8 bits wide @ 125 MHz  =  1 byte/cycle  =  exactly 1 Gbps
Cycles per byte:      125 MHz ÷ 125 MB/s  =  1.0
```

**Cycles-per-item is exactly 1.** Consequences you must design around, not discover:

- During a frame there is **no spare cycle**. Any state machine that needs "one extra
  cycle to think" between payload bytes drops data. Everything on the through-path is
  single-cycle-per-byte, decisions precomputed or pipelined.
- The breathing room is **between** frames only: preamble(8) + IFG(12) = 20 byte-times per
  frame. For minimum frames that's 20 cycles of slack every 64 payload-path cycles; for
  1518-byte frames, 20 every 1518. Anything that takes longer than 20 cycles (e.g. a CRC
  "finalize" step) must be pipelined into the stream, not appended after it.
- Worst-case frame rate: `1 Gbps ÷ ((64+20)×8 bits)` = **1.488 Mframes/s** — the rate
  every per-frame mechanism (counters, verdict delivery, FIFO pointer updates) must
  sustain.
- **Buffer sizing is derived, not chosen:** the RX async FIFO exists only to cross
  rx_clk→user domain, not to absorb rate mismatch (both sides run ≥ line rate), so its
  depth is set by clock ppm skew + handshake latency across the deepest user-side stall
  you permit. With a no-stall user contract (R18), 64 entries — one BRAM18 — is already
  ≈ 15× worst-case occupancy; full derivation in B.3a.
- **Where this architecture stops working:** at 10G (10 GbE = 64-bit datapath @ 156.25
  MHz, XGMII) the one-byte-per-cycle structure breaks, and the byte-wide (8-bit/cycle)
  parallel CRC-32 (B.7 item 2) would need re-widening to 64 bits/cycle — the scaling
  envelope ends at 1G/RGMII, and that boundary is worth stating in your README because
  "how would you scale this to 10G?" is the obvious interview follow-up.

## B.3a Parameter derivation table

Every number in this spec traces to a formula, per the flow doc's "derive, don't choose"
rule. Re-derivable by running [`spec/budget.m`](budget.m), which reads the frame-geometry
and datapath constants live from `rtl/gem_mac_params.vh` via `gem.params()` (the same
mechanism the golden model uses) rather than keeping a second hardcoded copy.

| Parameter | Value | Derivation |
|---|---|---|
| Line rate | 1 Gbps = 125 MB/s | 1000BASE-T definition |
| Datapath width | 8 bits @ 125 MHz | `125 MB/s × 8 bits ÷ 125 MHz = 8 bits/cycle` — matches RGMII's 4-bit DDR ⇒ 8 bits/cycle |
| Cycles per byte | 1.0 | `125 MHz ÷ 125 MB/s` |
| Min inter-frame gap | 96 bit-times = 12 byte-times | IEEE 802.3-2022 Table 4-2, all speeds |
| Slack per min-size frame | 20 cycles / 64 payload-path cycles | preamble(8) + IFG(12) |
| Worst-case frame rate | 1.488 Mframes/s | `1 Gbps ÷ ((64+20)×8 bits)` — every per-frame mechanism (counters, verdict, FIFO pointers) must sustain this |
| MAC-added latency budget | ≤ 32 rx_clk cycles (256 ns) | R21 ceiling; bottom-up pipeline sum (IDDR 1 + SFD/deframer 2 + **FCS holdback 4** + CRC verdict 1 + FIFO CDC 4 + egress reg 1, B.1b) = 13 cycles, 2.5× margin — confirmed, not asserted; measured per frame by `tb_gem_mac_rx` |
| RGMII clock tolerance (each side) | ±100 ppm | IEEE 802.3-2022 Clause 40 (1000BASE-T transmit clock tolerance) — board-oscillator ppm not yet confirmed against the actual AX7035B BOM part (stated weakness, B.7) |
| RX FIFO drift term | `2 × 100 ppm × 1518 B ≈ 0.3 B` | worst-case relative skew (`tx_clk` vs. recovered `rx_clk`) accumulated over one max-length frame (12.14 µs) — negligible, because the FIFO drains every IFG rather than absorbing sustained rate mismatch |
| RX FIFO sync-latency term | ~4 bytes | dual-flop gray-code pointer synchronizer, 2 destination-clock cycles of pointer visibility delay, rounded up with margin |
| **RX FIFO depth (chosen)** | **64 entries (1 BRAM18)** | drift term + sync-latency term ≈ 4.3 bytes (`spec/budget.m`); 64 gives ≈ 15× headroom over the derived minimum, at zero extra BRAM cost (one BRAM18 gives ≥ 512 entries at 8-bit width natively, so 64 is a convenience round number, not a squeeze) |
| TX `GTX_CLK` phase shift | −55° = 1.222 ns | best measured legal grid point inside the KSZ9031RNX's `TsetupT`/`TholdT` window (1.2–2.0 ns, datasheet Table 19): the 1125 MHz VCO's 5° grid puts −55° exactly on 1.222 ns, and the post-route sweep (task-2e) measured it at worst setup +0.058 ns — ahead of both the 1.2000 ns window edge (which sits on the floor and costs 26 ps of extra VCO jitter) and every other grid point — see `Documents/RGMII I-O Timing Derivation.md` §5 and B.1b |
| RX capture delay | 1.2 ns (PHY default, no FPGA action) | KSZ9031RNX default RX_CLK-to-RXD delay, inside `TsetupR`/`TholdR` (1.0–2.0 ns) — see B.1b |
| PHY reset hold time | ≥ 10 ms | KSZ9031RNX datasheet `tSR`: stable supply → reset de-assertion |
| MDC max frequency | 2.5 MHz | IEEE 802.3-2022 Clause 22 MII management interface ceiling (R16) |

## B.4 Verification strategy (decided now, per flow-doc Stage 3)

- **Golden model** (MATLAB, see companion guide): frame builder + CRC-32, integer-exact,
  validated against the standard CRC check value and a Wireshark capture before use.
- **Parametric stimulus generator**: seeded; knobs for payload length (sweep 1→1500 +
  boundary set {45,46,47,63,64,65,1499,1500,1501}), corruption type (bad FCS, bad SFD,
  truncation, oversize, RX_ER injection, inter-frame garbage), gap length (min IFG,
  bursts, long idles), and reset-mid-frame. Failures self-describe: seed, frame index,
  corruption, offset.
- **Self-checking testbenches**, per module then integrated: TX out → golden compare;
  golden frames → RX in → payload+verdict compare. The integrated loop: TX output wired
  to RX input through an RGMII bus-functional model that inserts the DDR timing.
- **Assertions** (separate bound files): valid/ready protocol legality, IFG never
  violated, FIFO never overflows, state machines never enter illegal states.
- **Coverage criterion for "done"**: every requirement R1–R24 has ≥ 1 named test, except
  R12, which is a stated non-goal for v1 and has no logic to test (B.7); every
  corruption type crossed with {min, typical, max} length; regression green from one
  `make regress` command.
- **Traceability table** (test ↔ requirement ↔ status) lives in [`verification_plan.md`](../verification_plan.md).

**Stage 4 status (complete):** the design is written and the regression it was built
to answer to is green. All sixteen frozen scenarios pass bit-exactly, both 600-frame
random sweeps pass, the loopback passes across an independent receive clock, and the
three per-module testbenches Stage 4 step 4 calls for (CRC, async FIFO, MDIO) pass.
`gem_internal_sva`, written in Stage 3 against modules that did not exist, was bound
unchanged and immediately caught a real defect that every data comparison passed: a
CRC accumulator re-seeded one cycle too late. One frozen vector was amended —
`tx_reject_oversize`, for the reason set out in **B.4d** — and it is the only vector
datum in the repository that changed during Stage 4. R21's measured worst-case RX
latency is **13 cycles**, which is exactly what B.1b's bottom-up sum predicted.

**Stage 3 status (complete):** all of the above is built and running. The golden model is
MATLAB (`model/+gem/`), validated by 70 tests — the published CRC-32 check value, agreement
with Python's `zlib` over 2000 random vectors, the residue property, a full
build→RGMII→deframe→parse round trip across the length sweep, and B.4b's abort contract.
Eighteen scenarios generate vector files, each cross-checked by reading its own wire back
with the golden RX path. The SystemVerilog layer (`tb/`) runs against a port-only stub
(`rtl/gem_mac_stub.v`) and fails informatively, which is the intended Stage 3 result.

The gates, enumerated by where they live rather than by a total that goes stale
every time one is added: `make check` runs five -- model tests, committed-vector
staleness, Verilator lint per R22, the host record parser, and the scenario
regression. `scripts/build.tcl` refuses on: CRITICAL WARNINGs counted after
synthesis (gate 0) and again after implementation (gate 0b), an RX capture-clock
anchor that does not resolve to exactly one clock (gate 1c), surviving latch cells
(gate 1), Synth 8-327 latch inference (gate 1b), the six hard `check_timing`
coverage conditions plus unconstrained I/O ports (gate 3), negative setup or hold
slack outside the fenced task-4e RX I/O waiver, and unexplained clock-domain
crossings per gate 4's asserted inventory (`report_cdc`; R19). `scripts/synth_module.tcl` adds the same two
latch checks, negative slack, B.2's resource budget for `gem_mac`, and the Stage-4
memory gate (Synth 8-4767: an array that dissolved into flip-flops instead of
becoming RAM). **Every one has been observed to fail**, not merely to pass --
each was tested by planting the defect it exists to catch: an injected width
mismatch trips the lint gate, one corrupted octet trips the vector gate, a
planted assertion trips the regression, an inferred latch trips the build twice
over (once as a surviving cell and once as a synthesis warning for a latch
optimised away), commenting out `create_clock` trips the timing gate, a renamed
port trips gate 0, a stale anchor path trips gate 1c, a renamed IDDR endpoint and
planted TX output-delay violations trip gate 2's waiver fences, and removing a
synchroniser's ASYNC_REG property trips gate 4. The stub trips everything else.

Two harness self-tests (`tb_rgmii_bfm`, `tb_axis_tx_driver`) have no DUT in them and are
the only runs green today; both exist because the harness had bugs that presented as
design bugs. Remaining open items, all blocked on hardware or on Stage 4 RTL rather than
on analysis, are tracked in [`verification_plan.md`](../verification_plan.md).

## B.4a RX delivery contract (resolved in Stage 3)

Three questions the golden model could not be written without answering. Each was
genuinely ambiguous in v0.2, and each is now binding on the Stage 4 RTL.

1. **`rx_axis_tdata` carries DA through pad** — the whole frame except preamble, SFD and
   FCS. Consequently `rx_axis_tuser` stays the single good/bad bit R15 specifies, and no
   RX header sideband exists; user logic reads DA/SA/EtherType from the first 14 beats.
   This resolves a contradiction between R15 (RX `tuser` = good/bad at EOF, one bit) and
   B.1a module 7 ("extracts DA/SA/EtherType, streams payload onward"), which could not
   both hold. Pad is not stripped either: with a Type-interpreted Length/Type field there
   is no length in the frame to strip against (Clause 3.2.6), and the standard puts that
   burden on the client. A 20-octet payload therefore arrives as 46 octets, and that is
   correct.
2. **Every frame ends with exactly one `tlast`**, at the natural end of its `RX_DV`
   burst, carrying the verdict — whatever went wrong. Errors detectable mid-frame
   (oversize, RX_ER) do **not** cut the stream short. `Documents/Bad bitstream handle.md`
   said early termination "can also be" done, which is not a decision; one delivery rule
   for all five classes means one `tlast` timing for the RTL, the assertions and the
   model to agree on rather than two.
   One carve-out falls out of the four-octet holdback and is part of this rule rather
   than an exception to it: a received frame of four octets or fewer — too short for
   even the holdback register to have anything behind the FCS — delivers **zero**
   beats and therefore no `tlast` at all. It is still counted (a runt), still
   classified by the same precedence, and the model's `expectedBeats` returns the
   same empty delivery; the rule above describes every frame from which at least
   one octet is delivered.
3. **Error class precedence is `rxer > oversize > runt > badfcs`.** R10 requires one
   counter per class (R17) and a single frame can be in several at once — a truncated
   frame is usually both a runt and an FCS failure. The order is argued from diagnostic
   value in `model/+gem/parseFrame.m`; the short version is that RX_ER outranks
   everything because every other classification is computed from bits the PHY just told
   us to distrust, and runt outranks bad-FCS because scoring truncation as bad-FCS would
   leave the runt counter permanently at zero.

A consequence of (1) is the four-cycle FCS holdback added to B.1b's latency sum.

**Amendment (Stage 6 part 2, owner decision (a); superseded below): rule 2 gained a
second carve-out.** On a link event, the receive domain resets (`rx_path_rst_n`), and
a frame in flight on this port aborted **without `tlast`**: `rx_axis_tvalid` simply
dropped mid-frame. Resetting egress was traced better than the alternative — an
un-reset egress resumes the old frame with the new frame's octets and emits a
well-formed frame spliced from two different ones, which is silent corruption; the
reset was reasoned to make the failure loud instead.

**Amendment superseded (V-25): the loud-failure argument did not survive contact with
the one consumer that exists.** `gem_echo` holds per-frame state and is reset by
`tx_rst_n`, not `rx_path_rst_n` (deliberately — R17's counters have to survive a link
flap) — so a silent `tvalid` drop leaves its `in_frame` flag stuck open across the
event. The next genuinely new frame, once the link recovers, is not lost: it is
spliced onto that stale state and echoed back wearing the *previous* frame's DA/SA,
with a payload that is the old fragment concatenated with the new one. That is
exactly the silent-corruption failure mode this rule's own reasoning was written to
avoid — just relocated one frame later and one module downstream, where nothing was
watching for it.

**Rule 2 now reads: every frame ends with exactly one `tlast`, full stop, including
one a link event cuts short.** A frame in flight when `rx_path_rst_n` lands is closed
with a synthetic beat — `tlast=1, tuser=0` (bad; R9's single good/bad bit, no second
meaning) — rather than left to trail off. `tdata` on that beat is `8'h00`, the same
convention `gem_rx_egress` already uses when nothing is loaded. `gem_rx_abort`
(downstream of `gem_rx_egress`, in `tx_clk`, reset only by `tx_rst_n` so it survives
the event it is watching for) is what generates it; see that module's header for why
the abort cannot be produced by `gem_rx_egress` itself. No new R17 counter — this
presents as an ordinary bad frame, the same as the four classes already sharing that
one bit, and `rx_mmcm_locked` already tells a host a link just dropped at the record
level. Verification is V-25 (`verification_plan.md`) and `tb_gem_top` criteria D8/D9,
including the concrete evidence for the corruption paragraph above: a dedicated
two-frame fixture, not `rx_clean_sweep`, because that vector's frames all share one
header and cannot make a stale one visible.

## B.4b TX underrun contract (resolved in Stage 3)

v0.3 left one question genuinely open, and Stage 4 cannot be written without an
answer: **what does the TX path do when user logic stops supplying data in the
middle of a frame?**

The constraint is physical. Once `TX_EN` rises, RGMII has no pause: the MAC must
present exactly one octet every 8 ns until the frame ends. There is no legal way
to stall the wire mid-frame. So a MAC that has committed to a frame and then runs
dry has exactly two options — never commit until it can finish (buffer the whole
frame first), or commit and abort when it runs out.

**Decision: cut-through, abort on underrun.**

Store-and-forward was rejected on the project's own terms. Buffering a maximum
frame before starting adds 1518 cycles — **12.14 µs** — of transmit latency, in a
design whose opening paragraph is about being the last piece of logic an order
passes through, and whose R21 caps *receive* latency at 32 cycles for exactly
that reason. It would also need a BRAM the B.2 resource table does not carry.
Trading 12 µs of latency to protect against user logic that misbehaves is the
wrong trade for this design; a threshold buffer (start after N octets) is a
recognised middle option and is recorded as a v2 possibility in B.7, but it
reduces the probability of underrun rather than removing it, so it needs the
abort path anyway and is therefore not a substitute for this decision.

**The head start.** Before the MAC needs the user's first payload octet it must
emit preamble (7) + SFD (1) + DA (6) + SA (6) + EtherType (2) = **22 octets it
generates from its own state**. Padding (R3) is MAC-generated too. So the user
has 22 cycles of free slack at every frame start, and the exposure is confined to
mid-payload. This is a lower bound the design must honour — a deeper pipeline
only adds slack — and it means a user that hesitates briefly at SOF is safe.

**The contract, precisely:**

1. The MAC begins transmitting as soon as it has a frame to send. It does not
   wait for the frame to be complete.
2. If `tx_axis_tvalid` deasserts while the MAC is emitting payload and the MAC
   has no octet to send that cycle, the frame is **aborted**, not stalled.
3. An abort terminates the frame immediately: the MAC emits the FCS it has
   computed over what it has already sent, **bitwise inverted** so the value is
   guaranteed not to satisfy the receiver's residue check, with `TX_ER` asserted
   across those four cycles. It then deasserts `TX_EN` and enforces a full IFG
   (R5) before the next frame.
4. The abort is marked **twice, deliberately**. `TX_ER` (RGMII: CTL low on the
   falling edge while high on the rising — the encoding `gem.rgmiiEncode`
   already implements) is the IEEE 802.3 mechanism and causes a conforming PHY
   to emit invalid symbols. The inverted FCS is the belt-and-braces: it makes
   the frame fail any receiver's CRC check whether or not `TX_ER` survived the
   link. One XOR buys independence from the link partner's behaviour.
5. The remainder of the aborted frame is **discarded, not resumed**. When the
   user eventually resumes and asserts `tlast`, the MAC drains and drops those
   octets. A MAC that picked up where it left off would emit a frame with a hole
   in it and a valid FCS, which is far worse than a frame plainly marked bad.
6. The event increments `stat_tx_underrun` (R17) and does **not** increment
   `stat_tx_ok`. An aborted frame is not a transmitted frame.

**What this does not specify.** Whether a MAC absorbs a short stall using head-
start slack is left to the implementation: it is an optimisation, not a
requirement, and pinning it down would bake a pipeline depth into the frozen
vectors. The `tx_underrun` scenario therefore stalls deep in the payload and for
far longer than any head start could cover, so that its expected wire output is
the same for every conforming implementation.

Note that the aborted frame's content is deterministic regardless of pipeline
depth, which is what makes this testable at all: the MAC can only have sent
octets the user actually supplied, so an abort after payload octet *S* always
produces preamble, SFD, header, payload `0..S-1`, and the inverted FCS over
exactly that.

## B.4c Two limits the transmit interface imposes (resolved in Stage 3)

Both were found by an independent review of the Stage 3 vectors, and both are
properties of R15's interface rather than of Ethernet — which is why neither
appears in Clause 3 and why both were easy to miss.

**1. Minimum transmit payload is one octet.** An AXI-Stream frame is a run of
beats terminated by `tlast` on the last one, so a zero-beat frame has nothing to
carry `tlast` and cannot be expressed. Padding would cheerfully turn an empty
payload into a legal 64-octet frame on the wire (R3), which is precisely the
trap: the model would specify a frame no conforming design could ever be asked
to send. `gem.genTxScenario` now rejects length 0 with `gem:zeroLengthPayload`.
The framing model itself is unchanged and still pads an empty payload, because
that is an interface limit, not a framing one.

**2. The inter-frame gap a design produces is not fully determined by the MAC.**
R5 requires *at least* 96 bit times. What actually appears on the wire is that
floor plus however long user logic took to offer the next frame — and after an
abort, plus however long the MAC spends draining a frame it will never send
(B.4b item 5), which for a maximum-size frame is over 1400 cycles.

A golden model with no user-side timeline cannot predict that number, and should
not pretend to. So the transmit comparison is split:

| Property | How it is checked | Why |
|---|---|---|
| Frame content, preamble→FCS | cycle for cycle against the model | fully determined by the MAC |
| Inter-frame gap | `>= GEM_IFG_BYTES` only | R5's floor is the whole requirement |

Freezing an exact gap would have over-constrained R5 into "exactly 96 bit
times" and failed every conforming design that was merely *later* than the
model. A design is always free to be later; it is never free to be earlier.

## B.4d R6 and B.4b collided (found in Stage 4, resolved by amending R6)

Stage 3 closed every question it could see. This is the one it could not: **R6 and
B.4b, both as originally written, could not both be satisfied**, and the frozen
`tx_reject_oversize` vector was where they met.

R6 requires that a payload over 1500 octets be rejected and that no oversize frame
ever be emitted, and the vector freezes that as *nothing at all on the wire*.
B.4b requires cut-through: transmission begins as soon as there is a frame to send,
which is at latest 22 octets before the first payload octet is needed.

The transmit interface carries no length. R15's port is a run of beats terminated by
`tlast`, so a frame's length is known only when `tlast` arrives — by which time, under
B.4b, TX_EN has been high for a long time. For the MAC to know the length before
committing, it must hold the entire frame first. That is store-and-forward, which
B.4b rejected on this project's own terms (12.14 µs of added transmit latency and a
BRAM the B.2 table does not carry), and a threshold buffer does not avoid it: a buffer
deep enough to decide *is* a whole-frame buffer. There is no third arrangement.

**Decision: refuse the octet, not the frame.** The MAC refuses the **1500th** payload
octet, on the cycle a 1501st is known to exist — the beat is present and carries no
`tlast`, so the payload cannot be 1500 or fewer — and refuses it *before* it is
transmitted. The frame on the wire is therefore
14 + 1499 + 4 = **1517 octets** — inside maxBasicFrameSize, so R6's "never emit an
oversize frame" holds literally, not approximately — marked bad twice over with
`TX_ER` and an inverted FCS exactly as B.4b marks an abort, counted in
`stat_tx_rejected` and not in `stat_tx_ok`, with the remainder of the request drained
and discarded (B.4b item 5). R6's wording above now says this; `gem.abortedFrame`
already modelled it, since an abort after payload octet *S* is the same object
whatever caused it; and `tx_reject_oversize` was regenerated.

**The alternative, and why it was rejected.** Keeping the old vector would have meant
reopening B.4b's rejection of store-and-forward — buying literal silence on the wire
for 12.14 µs of transmit latency and a BRAM the B.2 table does not carry, in a design
whose opening paragraph is about being the last logic an order passes through. That is
the same trade B.4b already refused, and refusing it twice for consistency is the
whole point of having written B.4b down.

**What the amendment cost, precisely:** one file. `tx_reject_oversize/tx_expected.hex`
is the only vector datum that changed; every other frozen scenario regenerated
byte-identically, which is the evidence that this was a contained specification error
and not a design that had drifted from its model. The counters did not move at all —
they were right before and after — which is why the failure showed up as five frames
on the wire where four were expected, and not as a counter mismatch.

A frame plainly marked bad is also the better engineering answer, quite apart from
what is implementable. A receiver that sees TX_ER and a failing FCS discards the frame
and counts it, so the error is visible at both ends of the link; silence is visible at
neither. What R6 was really asking for — that a MAC never put a frame longer than
maxBasicFrameSize on the wire — is what the design does.

*Found by Stage 4 rather than by Stage 3, and it could not have been otherwise: the
model had no reason to ask whether a MAC could know a length it is never told. That
question only arises when something has to actually drive TX_EN.*

## B.5 Bring-up order (written before hardware is touched)

1. Board alive: power, JTAG enumerates, blinky bitstream from the Stage-2 skeleton.
2. Clocks proven: MMCM lock + 125 MHz on a debug pin / ILA.
3. MDIO reads PHY ID registers correctly (proves MDIO + PHY alive) → read link-up and
   confirm 1000 Mbps negotiated against your PC NIC.
4. RX first, promiscuous, counters only: PC blasts frames with Scapy; RX-good counter
   advances at the sent count, bad counters stay zero. (RX before TX: Wireshark gives you
   a trusted generator; you have no trusted sink yet.)
5. TX: send fixed frames; verify byte-exact in Wireshark, FCS "correct" per capture.
6. Echo mode: RX payload looped to TX; Scapy round-trips randomized frames, compares.
7. Corruption on the wire: Scapy sends bad-FCS/runt frames; bad counters advance, good
   traffic continues (R10 on real hardware).
8. Soak: ≥ 4 hours full-rate bidirectional randomized traffic; zero counter divergence,
   FIFO high-water marks stable. Counters are read over the UART (R17, B.7 item 5) and
   **logged**, so the result is a file that can be diffed rather than a recollection —
   which is the whole reason that readout is a UART and not a JTAG probe.

Step 8 passing = the acceptance test for "fully functional."

## B.6 Deliverables & repo layout

**Present:** `spec/` (this doc, versioned) · `model/` (MATLAB golden model, generator,
tests, and the committed vectors) · `rtl/` · `tb/` (testbenches, BFM, bound assertions) ·
`constrs/` (clocks / pins / exceptions split) · `scripts/` (`build.tcl`, `program.tcl`,
`run_sim.py`, `check_vectors.py`, `lint.py`, `clean.py`) · `Makefile` ·
`verification_plan.md` · `coding_standard.md` (the RTL conventions, written from the
RTL at the close of Stage 4, with what enforces each one) · `Documents/` (derivations
too long to inline here) ·
`README.md` (the repository's front door: status, the B.3 arithmetic, the block
diagram, and how to run the gates — it summarises and links rather than restating,
so that no number lives in two places).

**Added in Stage 5:** `rtl/gem_top.v` (the board), `rtl/gem_echo.v` (B.5 step 6),
`rtl/gem_clk_rst.v` with `gem_mmcm` and `gem_reset_sync` (B.1b), `rtl/gem_uart_tx.v`
and `rtl/gem_stat_report.v` (R17's readout, B.7 item 5), and the pin and clock
constraints in `constrs/`.

`sw/host/` (the Scapy harness and the record parser, with its own tests) and
`bringup_checklist.md` (B.5's order, with what each failure would mean) were listed
here as deliberately absent from v0.2 until Stage 5 built them. Listing them was the
commitment; a file that exists but is empty would have been worse than one that does
not. **Nothing on this page is now outstanding.**

## B.7 Non-goals, architecture decisions, and weaknesses

**Explicit non-goals (v1):** 10/100 fallback (R13) · jumbo frames · flow control
(802.3x pause) · VLAN tag awareness · any layer-3+ (ARP/IP/UDP — natural v2, out of
scope now) · half duplex/CSMA-CD · store-and-forward buffering · **destination-address
filtering (R12 — the receive path is promiscuous)**.

R12 was the last [S] item still described as undecided, and leaving a stretch
requirement in that state past the point where the design exists is how a release ends
up unable to say what it does. It is now a stated non-goal rather than an open
question: v1 filters nothing, and R12's own wording lists promiscuous mode as one of
the two acceptable behaviours.

**Architecture decisions (the four items formerly left open — all resolved now, not
deferred to RTL time):**

1. **RGMII skew mechanism (R14).** Resolved in B.1b from the KSZ9031RNX datasheet:
   PHY-side default delay on RX (1.2 ns, no MDIO write), FPGA-side MMCM phase shift on
   TX (−55° = 1.222 ns, the measured-best legal grid point in the datasheet's window —
   since the PHY does not delay its GTX_CLK input by default). This replaced an earlier
   assumption that the board used a Realtek RTL8211 — corrected after pulling the actual
   ALINX AX7035 manual and Microchip KSZ9031RNX datasheet; see the note in A.2.
2. **Serial vs. byte-parallel CRC-32.** Resolved: **byte-parallel** (8-bit LUT/XOR-tree
   update, one step per cycle). B.3 already proves this is the only option that fits —
   cycles-per-byte is exactly 1.0, so a bit-serial CRC (8 cycles to process one byte)
   cannot keep up with R7's back-to-back line-rate requirement; it isn't a style choice,
   the arithmetic forces it.
3. **sys_clk domain: shared with tx_clk, or standalone?** Resolved: **sys_clk = tx_clk**
   for v1. R17's register block is debug/status, not datapath — no throughput reason to
   isolate it — and sharing collapses the CDC surface to just rx_clk↔user (already
   mandatory), instead of adding a second independent-clock boundary. Cost, stated
   plainly: management/register access is coupled to whatever tx_clk's frequency is; a
   v2 control plane (e.g. AXI-Lite or PCIe-backed register access at a different
   frequency) would reopen this and add back a CDC boundary here.
4. **RX FIFO depth.** Resolved: **64 entries**, derived in B.3a from clock-skew drift
   over one max-length frame (~0.3 B, negligible) plus CDC pointer-sync latency
   (~4 B) — roughly an order of magnitude below the chosen depth, which costs nothing
   extra since a single BRAM18 natively holds far more than 64 entries at 8-bit width.
5. **How R17's counters are read: UART, not VIO.** Decided before Stage 5 starts, so
   that the integration work has one answer rather than a choice to make mid-build.

   VIO is the cheaper option and was the obvious default: no RTL, a probe in the Vivado
   hardware manager, working the moment the bitstream loads. It was rejected on what
   B.5 step 8 needs. **The acceptance test for "fully functional" is a four-hour soak**,
   and a readout that requires Vivado attached over JTAG is a readout that cannot log,
   cannot be scripted against, and cannot be left running overnight in a way that
   produces evidence afterwards. A soak whose result is "I watched it for a while and
   the numbers looked fine" is not the test B.5 asks for. UART gives a stream a host
   script can timestamp and diff, which is what "zero counter divergence" over four
   hours actually requires.

   Two further reasons, both from this project's own constraints: the board has a
   USB-UART already (A.2's collateral list), so the physical path costs nothing; and
   `sw/host/` exists as a Stage 5 deliverable regardless, for the Scapy side of B.5
   steps 4–7 — the same host program can hold both ends of the test, sending frames and
   reading counters, instead of correlating Wireshark against a GUI by eye.

   **Built in Stage 5** as `rtl/gem_uart_tx.v` (framing) and `rtl/gem_stat_report.v`
   (the formatter and its snapshot). The obligations below are met as written; what
   they did not pin down, and what is now a contract with `sw/host/`, is the record
   itself:

   ```
   gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 link=00000001 speed=00000002 phyid=00221622 phyok=00000001 rxlock=00000001
   ```

   208 characters and a newline, once a second. Every field is named on every line and
   every value is eight hex nibbles including the one-bit ones, so a parser has one rule
   rather than a width per field. **Every field in a line is captured in the same cycle**
   — a record takes ~17 ms to clock out at 115200 baud, and without that snapshot its
   fields would each be true at a different instant, which is exactly the divergence a
   soak exists to detect and would have manufactured.

   **Measured cost: 249 LUTs and 373 flip-flops** (`gem_stat_report` 209 + 40 for
   `gem_uart_tx`), against the 150–250 LUTs estimated below. The estimate held, at its
   top end; the flip-flops are mostly the 13×32-bit snapshot, which the estimate did not
   name because the coherence problem it solves had not been thought about yet.

   **What this obliges Stage 5 to build**, stated here so the decision is actionable and
   not just recorded:
   - a UART transmitter in the `sys_clk` (= `tx_clk`) domain, 125 MHz to a standard baud;
     **115200 8N1** unless there is a reason to go faster, since the whole counter set is
     a few dozen octets and the soak reads it at human intervals, not at line rate;
   - a periodic dump of every R17 counter plus `link_up`, `link_speed`, `phy_id` and
     `phy_id_valid`, in a format a script can parse without ambiguity — one record per
     line, fields named, so a change to the set is visible in the log rather than
     silently shifting a column;
   - a receive path is **not** required for v1. `stat_clear` can be tied to a button or
     asserted at reset; a command interface is a v2 nicety and would need its own
     protocol decisions. If one is added, the natural pairing is with the MDIO request
     port already built in Stage 4, which would make the pad-skew registers B.1b names
     as the RGMII timing fallback reachable from the host as well;
   - the counters are already correct and verified against the golden model in all
     sixteen frozen scenarios, so the new verification obligation is narrow: that the
     UART's framing and baud are right, and that what it prints is what the counter
     ports hold. A loopback testbench that decodes its own transmitter's output is the
     cheap way to get both.

   Cost, stated plainly: a UART transmitter, a formatter and a divider are real RTL —
   perhaps 150–250 LUTs against the 1,255 still free under B.2's budget — where VIO
   would have been zero. That is the price of a soak test that produces a file.

6. **The receive clock is deskewed by its own MMCM (Stage 6 part 2).** Resolved from
   measurement, not preference: task-4a proved the raw clock network's insertion-delay
   spread (3.720 ns corner-to-corner) exceeds the entire RGMII eye and is invariant
   under every phase, input-delay and buffering choice; task-4b built the textbook
   BUFIO/BUFR answer and measured it falling short on the BUFIO cell's own spread.
   The remaining lever — cancelling the network delay with feedback compensation —
   is what `rtl/gem_rx_mmcm.v` implements. Its timing outcome (hold fixed, setup
   still failing structurally) and the open half-cycle question are recorded in
   `docs/reports/stage6-part2/task-4d-report.md` and `task-4d2-report.md`; the reset
   architecture it forced is B.1b's amended strategy above.

**Alternatives considered, restated for traceability:**
- **Store-and-forward vs. cut-through (RX delivery):** cut-through with a trailing
  verdict, per R9 — HFT-idiomatic (first byte out as soon as it arrives, not after the
  whole frame), at the cost of pushing bad-frame rollback onto user logic (see
  `Documents/Bad bitstream handle.md` for the full reasoning).
- **Store-and-forward vs. cut-through (TX admission), resolved in B.4b:** cut-through,
  aborting on underrun. Buffering a whole frame before asserting `TX_EN` would make an
  underrun structurally impossible, but costs up to 1518 cycles (12.14 µs) of transmit
  latency and a BRAM the B.2 table does not carry — the wrong trade in a design whose
  premise is latency, and whose R21 caps *receive* latency at 32 cycles for the same
  reason. **A threshold buffer — begin transmitting once N octets are queued — is the
  recognised middle option and is the natural v2 change here** if user logic proves hard
  to drive at one octet per cycle. It is not a substitute for the abort path: it lowers
  the probability of underrun without removing it, so a v2 that adds it still needs
  everything B.4b specifies.
- Items 2 and 3 above are also, in effect, "alternatives considered" — each rejects a
  simpler-looking option (bit-serial CRC, a standalone sys_clk) for a stated, derivable
  reason rather than by default.

**Weaknesses stated up front:** the board-oscillator ppm rating used in B.3a's FIFO
derivation is the 1000BASE-T standard's ±100 ppm ceiling, **not yet confirmed against
the actual crystal/oscillator part on the AX7035B BOM** — revisit once the schematic is
in hand; the no-stall user contract (R18) pushes drop responsibility onto user logic —
fine here, but a real NIC would buffer; the RGMII timing numbers throughout this
document (B.1b, R14, R20) come from the KSZ9031RNX datasheet read online, and **B.5
bring-up cross-checked against the physical board and found the premise itself
wrong, not just unconfirmed: the chip is a JLSemi JL2121(D)** (A.2's B.5
correction). The register-level and pad-skew-mechanism consequences are fixed or
flagged there; the numeric RGMII timing budget (B.1b's 1.2 ns RX default, the
`TsetupR`/`TholdR`/`TsetupT`/`TholdT` window, `tSR`) is not yet re-derived from the
JL2121(D)'s own datasheet and should be treated as unconfirmed until it is; and the
LUT/FF/BRAM line items in B.2's Resources table
are **estimates whose derivation predates this revision and isn't traceable** — unlike
the FIFO depth, GTX_CLK phase, and R21 latency numbers, which were derived bottom-up and
checked by `spec/budget.m`, the resource counts are inherited, plausible-looking
per-block guesses (they do line up with B.1a's module list and land comfortably under
10% device utilization even at the budget ceiling, so the order of magnitude is very
likely right) but have not been checked against a real synthesis of a comparable module.
That check is Stage 4 step 6's job, not Stage 1's, and is deliberately deferred rather
than done now.
