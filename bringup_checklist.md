# `gem_mac` — bring-up checklist

Document status: v1.0 — written at the close of Stage 5, before the board is in
hand. Derived from spec **B.5**, which fixed this order before any of it could
be attempted.

**The order is the point.** Each step below is performable only if the one above
it worked, and each fails in a way the previous step has already ruled out. Skip
one and a failure two steps later has a suspect list that includes everything.

**The one rule that overrides the rest:** when the board and a document
disagree, the board is right. This project has already been caught out
*twice* — the spec assumed a Realtek RTL8211 until someone pulled the actual
manual and found a Micrel KSZ9031RNX, and then Step 3 below, the first time it
was run, found that the manual was wrong too: the physical chip is a JLSemi
JL2121(D) (both corrections in A.2) — and the pin data here comes from a
schematic obtained third-hand (V-21).

---

## Before power

- [ ] **Add the `-2I` device pack to Vivado.** `scripts/part.tcl` targets
      `xc7a35tifgg484-1L` — confirmed live against this install
      (`get_parts -filter {DEVICE =~ "xc7a35t*" && PACKAGE == "fgg484"}` returns
      only that speed grade for the industrial temp range) — while the board is
      an **XC7A35T-2FGG484I**. The mismatch is safe in only one direction, and
      that direction is the one this repository is in: `-1L` is *slower* than
      the board's `-2I`, so every slack number measured so far is pessimistic,
      and timing that closes on `-1L` closes on the real part. Do not "fix" this
      by pointing `part.tcl` at the commercial `xc7a35tfgg484-2` this install
      also has — that part is *faster* than the board and would let a design
      that cannot make 125 MHz report a pass. Vivado's *Add Design Tools or
      Devices*, then change the one line in `part.tcl`, then re-run
      `make oocsynth` and record whatever WNS it prints in place of the current
      `-1L` number.
- [ ] Have ready: a USB cable for the JTAG programmer, a second for the UART, a
      Cat-5e or better cable, and a PC with a spare Ethernet port.
- [ ] `pip install -r sw/host/requirements.txt`, and **Npcap** on Windows.

---

## Step 1 — the board is alive

Load the Stage 2 blinker:

```
make program TOP=skeleton_top
```

(`program` depends on `bitstream`, so this one command builds and loads it.
`make program` alone now builds and loads `gem_top`, the board, since Stage 6
retargeted the default — `TOP=skeleton_top` is what this step needs instead.)

- [ ] Power LED lights.
- [ ] JTAG enumerates and Vivado's hardware manager sees the part.
- [ ] The blinker blinks.

**If the LEDs never light:** the first suspect is bank 16's supply voltage,
though this is now confirmed rather than assumed — the real manual
(`Manuals/AX7035B_UG.pdf`) names the populated LDO for bank 16 directly
(SPX3819M5-3.3, a fixed 3.3 V part) rather than leaving it to the general
3.3 V rule. If the LEDs still don't light, probe that LDO's output before
suspecting anything in the design; a wrong marking or a rework would be the
one way this confirmed value could still be stale.

---

## Step 2 — clocks

Load `gem_top`.

- [ ] **`led[0]` lights** — the MMCM has locked. This is the first thing the
      design does and nothing else can work without it.
- [ ] **`led[2]` blinks at about 1.9 Hz** — the heartbeat, which is a counter on
      `tx_clk`. A stopped clock and wedged logic look identical on every other
      indicator; this distinguishes them.
- [ ] Optionally confirm 125 MHz on `GTX_CLK` with a scope. (`make debug`'s
      ILA probes the RX pipeline, not this clock — see step 4 for where it
      does apply.)

**If `led[0]` never lights:** the MMCM is not locking, which means `clk50` is not
arriving. Check Y18 and the oscillator before anything else — no logic in this
design runs without it, and `tx_rst_n` is deliberately held until lock (B.1b).

---

## Step 3 — the PHY answers

Attach the serial cable and run:

```bash
python sw/host/gem_host.py monitor --port COM4
```

- [ ] A record arrives **once a second**, starting with `gem`.
- [ ] `phyok=00000001` and `phyid` reads **`0x937c4032`** — JLSemi's OUI and
      model for the JL2121(D) (`DS009-JL2121(D)-v1.09-Preliminary`), with the
      low nibble carrying the silicon revision, so `0x937c403x` is the expected
      family. **This superseded the KSZ9031RNX expectation** (`0x0022162x`) the
      ALINX manual implied — B.5's first pass through this step found that
      value and traced it to the physical chip, not a misread; see A.2's B.5
      correction. What matters most either way is that it is neither
      `00000000` nor `ffffffff`: both mean nothing is answering.
- [ ] Plug the cable into the PC. Within a few seconds **`led[1]` lights**,
      `link=00000001`, and `speed=00000002` (1000 Mbps, Clause 22).

**If no record arrives at all:** check the port and that it is 115200 8N1. If the
port is right and the line is silent, the next suspect is the UART pin itself —
`uart_tx` is on **G16** from ALINX's own demo and the schematic, but the naming
is from the FPGA's point of view and a swap with **G15** costs one rebuild to
test (V-21).

**If `phyid` reads `ffffffff`:** MDIO is not being answered. The PHY's reset is
held low for 10 ms after power-up by design (sourced to the KSZ9031RNX's tSR,
now known to be the wrong chip's datasheet — see A.2's B.5 correction; the
JL2121(D)'s own reset-timing figure is not yet checked, so 10 ms is a
plausible margin rather than a confirmed one) — if that pin is wrong the PHY
never comes out of reset. Check `phy_rst_n` on **L15**. `PHY_ADDR` should not
be the cause: it is now `5'd1`, confirmed against the real manual's strap
table (`Manuals/AX7035B_UG.pdf` Table 8-1), and even the old guessed default
of 0 worked, because the JL2121(D) treats address 0 as a standing broadcast
address regardless of its strap.

**If the link comes up at 100 Mbps:** the design does not implement 10/100
fallback — R13 is 1000BASE-T only, and 10/100 is a stated non-goal (B.7). Check
the cable is Cat-5e and all four pairs are intact.

---

## Step 4 — receive, and the counters

```bash
python sw/host/gem_host.py rx --port COM4 --iface Ethernet --count 100
```

- [ ] `rx_ok` advances by exactly 100.
- [ ] `rx_bad`, `rx_runt`, `rx_over`, `rx_rxer` stay at zero, and **`led[3]`
      stays dark**.

**Receive is tested before transmit on purpose:** Wireshark and a NIC are a
trusted generator, and at this point the board is not yet a trusted sink.

**If `rx_ok` stays at zero but the link is up:** the most likely cause is the
RGMII receive nibble mapping or the PHY's RX clock delay. B.1b assumed the
KSZ9031RNX's 1.2 ns default `RX_CLK` delay with no MDIO write required — the
board's actual chip is a JL2121(D) (A.2's B.5 correction), which delays
`RX_CLK` via the `RXDLY` **strap pin** instead. The real manual
(`Manuals/AX7035B_UG.pdf` Table 8-1) confirms this board's strap adds
**2 ns**, not 0 — a concrete number now, not an unconfirmed one, though it
has not yet been fed into a re-derived RGMII timing budget (A.2's B.5
correction, `Documents/RGMII I-O Timing Derivation.md`). `gem_iddr`'s mapping
was corrected for the KSZ9031RNX case (V-17) — on hardware a wrong mapping
means the SFD reads as `0x5D` instead of `0xD5` and no frame is ever found.
Nothing in simulation can see this, which is why it is called out here.

**If `rx_ok` advances but the error counters do too:** the data is arriving and
being corrupted, which points at skew rather than mapping. **There is no MDIO
pad-skew register on this chip** (the MMD `2h`/register `8h` path assumed the
KSZ9031RNX) — the only lever is the `RXDLY`/`TXDLY` strap pins, fixed at board
population (both confirmed 2 ns from the real manual, above) and not
adjustable from bring-up software. There is no rework fallback to reach for
here without a re-derived timing budget behind it — see the note above.

**To see which of these it is rather than guess:** `make debug` builds
`build/gem_top_debug.bit` and `.ltx` with an ILA on the RX pipeline — the
RGMII byte stream and `gm_dv`/`gm_er` as `gem_rgmii_rx` delivers them, the SFD
hunter's `state` (stuck at `ST_HUNT` means no SFD is ever being found, which
is the nibble-swap symptom above), the RX FIFO's write pointer and its
full/drop flags, and the deskew MMCM's lock. Load both files in Hardware
Manager alongside the normal bitstream; never flash it as the production
image.

---

## Step 5 — transmit

With Wireshark capturing on the PC, run the echo test below and look at what
comes back.

- [ ] Frames from the board appear in the capture.
- [ ] Wireshark reports the **FCS as correct** — this is what closes **V-6**, the
      last piece of CRC validation that simulation could not provide.
- [ ] Compare a frame byte for byte against what was sent.

**If nothing is transmitted:** check `GTX_CLK` and `TXD0` on a scope. R14's
mechanism puts a deliberate 1.2222 ns delay on `GTX_CLK` relative to the data,
and **no simulation in this project can confirm it** — that is open item
**V-2**, and this is where it closes. The MMCM is asked for −55.000° of the 8 ns
period, which its 1125 MHz VCO can produce exactly, and which lands near the
bottom of the datasheet's 1.2–2.0 ns window rather than in its middle — Stage 6
part 2 measured the design and found its own TX setup check improves as the
shift shrinks, so the centre is not the best point inside the window. Post-route
the worst TX output clears setup by **58 ps**: a pass, and a thin one.

**If the scope says setup timing is not being met, read this before reaching for
the pad-skew procedure `Documents/RGMII I-O Timing Derivation.md` names.** Do
not start re-deriving the phase shift — 58 ps is the ceiling of what phase
shift alone reaches on this design, and that was established by measurement
across every configuration the PHY's window allows, not by estimate. But the
document's escalation path (`Documents/RGMII I-O Timing Derivation.md`,
section **"If 58 ps proves insufficient on the bench"**) was written for the
KSZ9031RNX's MMD `2h`/register `8h` pad-skew register, reached over MDIO — B.5
found the physical chip is a JL2121(D) (A.2's correction), which has **no such
register**. Its RGMII clock delay is set by `RXDLY`/`TXDLY` strap pins, both
confirmed populated to add 2 ns (`Manuals/AX7035B_UG.pdf` Table 8-1, not a
schematic pull any more). If 58 ps proves insufficient on this board, the
fallback is a hardware rework of those straps to a different configuration,
not an MDIO write — and the 58 ps figure itself was derived assuming the
KSZ9031RNX's 1.2 ns default, not this board's confirmed 2 ns, so re-deriving
the RGMII timing budget from the JL2121(D)'s own datasheet (A.2's B.5
correction) comes before planning any rework.

---

## Step 6 — the round trip

```bash
python sw/host/gem_host.py echo --port COM4 --iface Ethernet --count 100
```

- [ ] Every frame comes back, with **DA and SA exchanged**.
- [ ] Payloads match, allowing for pad: a request shorter than 46 octets returns
      zero-extended, because B.4a does not strip pad and there is no length field
      to strip against.
- [ ] `tx_ok` advances in step.

One round trip proves the entire chain — IDDR, SFD hunt, deframe, CRC check,
FIFO crossing, egress, the echo path, ingress, assembly, CRC generation, ODDR.
This is the same property `tb_gem_top` checks in simulation, now on real
silicon and a real PHY.

**Frames not coming back under a blast is not a fault.** The echo path holds one
frame at a time and drops what arrives while it is busy; `sw/host/README.md` has
the arithmetic. Only a *mismatch* is a failure.

---

## Step 7 — corruption and recovery

```bash
python sw/host/gem_host.py corrupt --port COM4 --iface Ethernet
```

- [ ] `rx_over` advances, and **`led[3]` lights** and stays lit.
- [ ] `rx_ok` still advances for the good frames sent afterwards — R10 is about
      recovery, and the receive path is specified to be ready again within 8
      cycles.
- [ ] Press **KEY1** and confirm every counter returns to zero and `led[3]` goes
      dark.

**Only one of R10's four error classes can be provoked from a PC.** A NIC
computes the FCS in hardware and pads runts before transmitting, so bad-FCS and
runt frames never reach the wire, and RX_ER is the PHY's to assert. All four are
covered bit-exactly in simulation; `sw/host/README.md` explains what a bench
would need to add the other three.

---

## Step 8 — the soak, which is the acceptance test

```bash
python sw/host/gem_host.py soak --port COM4 --hours 4 --log soak.log
```

...with `echo` running from a second terminal, or a traffic generator pointed at
the board.

- [ ] **Four hours, zero counter divergence.** No error counter moves, no
      underrun, no link drop.
- [ ] The log is a file that can be diffed afterwards — which is the whole reason
      R17's readout is a UART and not a JTAG probe (B.7 item 5). A soak whose
      result is "I watched it for a while and it looked fine" is not this test.

**Counter wrap is expected, not divergence.** 32 bits at the worst-case frame
rate wraps in about 48 minutes; the host tooling subtracts modulo 2³² for that
reason.

**Passing step 8 is the definition of "fully functional"** (B.5). At that point
Stage 8 is complete and what remains is Stage 9: release and handoff.

---

## What this checklist cannot tell you

Four things are settled only by the bench, and each is tracked as an open item
— full reasoning for all of them, plus why they are a bench question rather
than a coverage gap, in `docs/reports/stage9/known-issues.md`:

| Item | What is unresolved | Closes at |
|---|---|---|
| **V-2** | R14's 1.2222 ns `GTX_CLK` skew is an I/O timing property; simulation passes at any phase, and post-route static timing clears it by only 58 ps | step 5, with a scope |
| **V-6** | The golden CRC has never been checked against a real capture | step 5, in Wireshark |
| **V-22** | Three of R10's four RX error classes cannot be provoked from a PC — only oversize reaches the wire malformed | not scoped to any step; needs a second transmitter |
| **A.2 (B.5)** | The board's PHY is a JL2121(D), not the KSZ9031RNX B.1b's RGMII timing budget was derived from; the strap-confirmed 2 ns RXDLY/TXDLY delays and PHY address 1 are fixed in the design, but the numeric timing budget itself is not yet re-derived from the JL2121(D)'s own datasheet | gates trusting R14/R20's margin numbers and the RX deskew MMCM's phase target — not scoped to a single step |
