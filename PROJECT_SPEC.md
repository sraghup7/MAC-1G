# 1G Ethernet MAC on a Budget FPGA — Board Selection & Initial Specification

Document status: v0.1 — Stage 1 deliverable, to be reviewed and versioned alongside the RTL.

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
| Ethernet | 1× 10/100/1000 port, **Realtek RTL8211-family PHY, RGMII, wired to fabric I/O** |
| Memory | 256 MB DDR3 (not needed for this project — nice for later ones) |
| Other | HDMI in/out, USB-UART, MicroSD, 2× 40-pin expansion, JTAG programmer support |
| Collateral | Schematic, pin assignments, and **Verilog demo projects including Ethernet** — a reference XDC for the RGMII pins is worth real hours |

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
in synthesizable Verilog-2001 on the AX7035B, talking RGMII to the board's RTL8211 PHY on
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
  bytes; never emit an oversize frame.
- **R7 [M]** Sustain back-to-back frames at full line rate indefinitely (no growing gap,
  no stall) when user logic supplies data every cycle.

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

### Interfaces

- **R13 [M]** RGMII v2.0 to the PHY: 4-bit DDR data + control at 125 MHz each direction,
  1000 Mbps mode only. (10/100 fallback explicitly out of scope — see B.7.)
- **R14 [M]** The 90° clock-to-data skew required by RGMII is provided by a deliberate,
  documented mechanism (PHY delay straps/registers, MMCM phase, or IDELAY) — chosen at
  design time in the system-design phase, constrained in XDC, and never left to luck.
- **R15 [M]** User side: 8-bit AXI-Stream-style handshake per direction —
  `tdata[7:0], tvalid, tready, tlast` plus `tuser` (TX: DA/SA/EtherType sideband at SOF;
  RX: good/bad at EOF). Registered, no combinational paths through the handshake.
- **R16 [M]** MDIO/MDC master (≤ 2.5 MHz MDC) with a register-level request interface;
  bring-up software (or a hardware sequencer) uses it to read PHY ID, link status, and
  resolved speed/duplex.
- **R17 [M]** Status/debug register block readable over UART (or VIO): frame counters
  (TX ok, RX ok, RX bad-FCS, RX runt, RX oversize, RX_ER), link state, sticky error
  flags, all clearable.

### Performance & clocking

- **R18 [M]** Line rate 1.000 Gbps each direction simultaneously (full duplex); zero
  dropped frames on the RX path at line rate with minimum IFG.
- **R19 [M]** Three clock domains handled explicitly: `tx_clk` (125 MHz, MMCM from the
  50 MHz board oscillator), `rx_clk` (125 MHz, from PHY RXC pin — asynchronous to
  tx_clk), `sys_clk` (user/management domain; may equal tx_clk domain in v1). All
  domain crossings via async FIFOs or documented synchronizers; **zero undeclared CDC
  paths** (checked by `report_cdc`).
- **R20 [M]** Timing closed with WNS ≥ 0 at 125 MHz on all declared clocks, and RGMII I/O
  constrained with real input/output delay values derived from the RTL8211 datasheet —
  not left unconstrained.
- **R21 [M]** MAC-added latency (last bit of a field in → corresponding byte out of the
  user interface) ≤ 32 rx_clk cycles (256 ns) on RX. Measured in sim; a spec number to
  design against, generous enough to not distort the design.

### Resources (targets, to be checked per-module at Stage 4 step 6)

| Resource | Budget | XC7A35T has | Headroom rationale |
|---|---|---|---|
| LUTs | ≤ 2,000 | 20,800 | TX ~400, RX ~500, CRC×2 ~300, MDIO ~150, regs/dbg ~300, margin |
| FFs | ≤ 3,000 | 41,600 | pipeline + CDC + counters |
| BRAM36 | ≤ 4 | 50 | 2 async FIFOs + ILA capture |
| DSP | 0 | 90 | nothing multiplies here |
| MMCM | 1 | 5 | 125 MHz + 90°-shifted sibling if that skew option is chosen |

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
  ≥ 3× worst-case occupancy; the derivation goes in the system-design doc with the
  formula, per the "derive, don't choose" rule.
- **Where this architecture stops working:** at 10G (10 GbE = 64-bit datapath @ 156.25
  MHz, XGMII) the one-byte-per-cycle structure and the serial CRC both break — the
  scaling envelope ends at 1G/RGMII, and that boundary is worth stating in your README
  because "how would you scale this to 10G?" is the obvious interview follow-up.

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
- **Coverage criterion for "done"**: every requirement R1–R21 has ≥ 1 named test; every
  corruption type crossed with {min, typical, max} length; regression green from one
  `make regress` command.
- **Traceability table** (test ↔ requirement ↔ status) lives in `verification_plan.md`.

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
   FIFO high-water marks stable.

Step 8 passing = the acceptance test for "fully functional."

## B.6 Deliverables & repo layout

`spec/` (this doc, versioned) · `model/` (MATLAB golden + generator) · `rtl/` ·
`tb/` · `constrs/` (clocks / pins / exceptions split) · `scripts/build.tcl` ·
`sw/host/` (Scapy test harness) · `Makefile` · `verification_plan.md` ·
`bringup_checklist.md` · `README.md` with the block diagram and the B.3 arithmetic.

## B.7 Non-goals and open items

**Explicit non-goals (v1):** 10/100 fallback (R13) · jumbo frames · flow control
(802.3x pause) · VLAN tag awareness · any layer-3+ (ARP/IP/UDP — natural v2, out of
scope now) · half duplex/CSMA-CD · store-and-forward buffering.

**Open items to resolve in your system design (deliberately left to you):**

1. Which RGMII skew mechanism (R14) — PHY-side delay vs MMCM phase vs IDELAY — given the
   AX7035B schematic and the RTL8211 variant actually fitted.
2. Serial (bit-at-a-time ×8) vs byte-parallel CRC-32 update — one is simpler, one is the
   idiomatic answer at 1 byte/cycle; justify against the cycle budget.
3. Whether v1's user/management domain equals the tx_clk domain (fewer CDCs) or stands
   alone (cleaner scaling story).
4. Exact RX FIFO depth with the derivation written out (B.3 gives the method).

**Weaknesses stated up front:** single-clock-source board oscillator quality bounds your
ppm analysis; RGMII constraint values depend on a PHY datasheet you must actually read;
and the no-stall user contract (R18) pushes drop responsibility onto user logic — fine
here, but a real NIC would buffer.
