# Why RX Recovery Gets 8 Cycles, Not 20

*Notes on the RX-side control-logic budget implied by PROJECT_SPEC.md B.3 and R10, and by IEEE 802.3-2022 Table 4-2's Note 3.*

---

## The starting number: 20 cycles of slack per frame

B.3 of the spec makes the core cycle-budget point: at 1 byte/cycle, **during a frame there is no spare cycle** — every state machine on the through-path must make its decision and move a byte in the same cycle, every cycle, with nothing left over. The only place any module gets a cycle to do "bookkeeping" instead of moving data is *between* frames, and that gap is built from two fields:

- **Preamble + SFD = 8 bytes** — 7 bytes of `0x55` then 1 byte of `0xD5`, sent before every frame (R1, IEEE 802.3-2022 Clause 3.2.1–3.2.2).
- **Inter-frame gap (IFG) = 12 bytes** — the mandatory ≥96-bit-time spacing between frames (R5, Table 4-2).

`8 + 12 = 20 byte-times` of slack surrounding every minimum-size (64-byte) frame — the tightest case, since larger frames get the same 20 cycles of slack against more payload cycles, making the ratio easier.

This 20-cycle number is correct **for the transmitter**, because the transmitter is the one producing that gap. It is not a safe number for the receiver, for two independent reasons the standard itself states.

---

## Reason 1: the 96-bit IFG is enforced at the sender, not preserved to the receiver

`interPacketGap` (Table 4-2) is a rule about when the *transmitting* MAC is allowed to start its next frame — Clause 4.2.3.2.6 defines it as measured from the transmitter's own `transmitting` signal going false. It is a promise about what the sender puts onto the wire, not a promise about what survives cable propagation, the PHY's receive path, and clock recovery back onto the receiver's `RX_CLK` domain.

IEEE 802.3-2022 Table 4-2, Note 3 says this explicitly:

> the *measured* IFG at the GMII receive signals can shrink to as little as **64 bit-times** due to network delays/clock tolerance even though `interPacketGap` (the transmit-side minimum you enforce) is 96 bits — so a receiver shouldn't be strict about requiring a full 96-bit gap between received frames.

64 bits = **8 byte-times**. So a fully standard-compliant transmitter, talking to a fully standard-compliant receiver over a fully standard-compliant link, is permitted to present a gap as small as 8 bytes at the point your RX logic actually observes it. Nothing in the standard obligates the full 12 bytes to survive the trip. Designing RX recovery against the 12-byte figure means designing against a best case the standard never promised you — a wire that has always been legal could still break that assumption.

## Reason 2: the 8-byte preamble is not guaranteed either

The other half of the 20-cycle figure — the preamble — is even less reliable as slack, and for a reason baked directly into this project's own requirements. R8 states:

> Detect SFD anywhere in the incoming stream; **tolerate shortened/absent preamble down to SFD-only.**

This requirement exists because real senders — switches, NICs that trim preamble to save time, cut-through forwarding devices — are permitted to send little or no preamble before the SFD. If your own MAC has to tolerate an absent preamble, you cannot simultaneously bank on 8 bytes of preamble as a cushion for your own recovery logic. Those bytes are a bonus when present, never a floor.

## Combining the two: the real floor is 8 cycles, not 20

Put together, the quantity that actually matters for RX recovery — the time between the last bit of one frame's FCS and the first bit of the next frame's SFD — is:

```
gap_at_receiver = IFG_observed + preamble_observed
                ≥ 8 byte-times   (IFG floor, Note 3)
                + 0 byte-times   (preamble floor, R8)
                = 8 byte-times
```

The 20-cycle figure is what a *generous, idealized* sender produces at its own TX pins. The 8-cycle figure is the number the standard actually lets a receiver assume will be there — and it's the only one R10's "recover cleanly" claim can honestly stand behind, because R10 is a promise about behavior on a compliant wire, not about behavior under a best-case sender.

---

## What has to fit in 8 cycles

Everything the RX FSM needs to be "ready for the next frame" has to provably complete within 8 `rx_clk` cycles of the previous frame ending, whether that ending was a clean EOF or an error abort (R10):

- Reset the CRC-32 accumulator back to its initial value (`0xFFFFFFFF` seed, per the FCS notes in [IEEE802.3-2022_notes_for_1G_MAC.md](IEEE802.3-2022_notes_for_1G_MAC.md)).
- Re-arm the SFD hunter so it's scanning for `10101011` again (R8/R11).
- Finalize and commit the error classification for the frame that just ended (runt / oversize / bad-FCS / RX_ER — R10) into its counter.
- Retire any speculative FIFO write state for that frame (write pointer, `tlast`/`tuser` beat) so the next frame's writes start clean.
- Return the RX control FSM to its idle/hunting state.

None of this is expensive in isolation, but "provably done within 8 cycles" is a real constraint on how these steps are structured — e.g. it rules out any design where error classification is a multi-cycle sequential process that only starts after EOF, and argues for precomputing/pipelining the verdict so it's ready at the same cycle the frame ends, not some cycles after.

## TX does not have this problem

Symmetry matters here: on the **transmit** side, the MAC itself is the one deciding when the next frame starts, so it can simply choose to always emit preamble + the full 96-bit IFG — the 20-cycle figure is real and safe to design against for TX-side bookkeeping (CRC reset before the next frame's first byte, returning the TX FSM to idle, etc.). The asymmetry exists because IFG-shrinkage and preamble-trimming are things that happen to a receiver, not things a compliant transmitter is required to do to itself.

## Why this belongs in the verification plan

B.4's stimulus generator already lists "gap length (min IFG, bursts, long idles)" as a knob to sweep. This note is the reason the sweep has to go *below* the nominal 96-bit/12-byte IFG, down toward the 64-bit/8-byte floor Note 3 permits, and should be crossed with minimum-size (64-byte) back-to-back frames specifically — that combination is the one that actually exercises the 8-cycle recovery budget. A regression that only ever generates a full 12-byte IFG between frames would pass even if the RX recovery logic silently needed 15 cycles to reset — and that bug would then surface for the first time against real hardware, which is exactly the failure mode Stage 1's verification strategy exists to catch before RTL is written.
