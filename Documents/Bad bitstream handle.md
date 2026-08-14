# Bad Bitstream Handling — R9 & R10 Explained

*Notes on PROJECT_SPEC.md requirements R9 and R10 (`gem_mac` RX path).*

> **R9 [M]** Verify FCS on every frame; deliver the frame with an end-of-frame good/bad flag. (Store-and-forward frame buffering is **not** required — cut-through delivery with a trailing verdict is the HFT-idiomatic choice; user logic drops on bad.)
>
> **R10 [M]** Discard as invalid, count separately, and recover cleanly from: runt (< 64 B), oversize (> 1518 B), bad FCS, RGMII RX_ER during frame. "Recover cleanly" = the next good frame is received intact.

These two requirements together define how the RX path handles the fundamental awkwardness of Ethernet: **you can't know if a frame is good until it's over**, because the CRC-32 (FCS) is the last 4 bytes of the frame.

---

## R9 — Cut-through with a trailing verdict

There are two ways a MAC can deliver received frames to user logic:

**Store-and-forward:** buffer the entire frame in a FIFO, check the FCS at the end, and only then release it — so user logic only ever sees known-good frames. Clean, but the first payload byte reaches user logic only after the *last* byte arrived. For a 1518-byte frame that's ~12 µs of added latency.

**Cut-through (what R9 asks for):** start streaming payload bytes to user logic *as they arrive*, while the CRC checker runs in parallel alongside the stream. When the frame ends, you assert `tlast` and simultaneously present a 1-bit verdict on `tuser` (per R15): FCS good or bad. If it's bad, the user logic is responsible for discarding what it already consumed.

Concretely in the design: as each byte comes off the RGMII interface, it goes two places at once — into the CRC-32 accumulator and out the AXI-Stream port. On end-of-frame detection, the accumulated CRC is compared against the expected residue, and that comparison result *is* the `tuser` flag on the `tlast` beat.

**Why the spec calls this "HFT-idiomatic":** in a trading system, latency is the product. A feed handler wants to start parsing the market-data payload the moment bytes arrive, not 12 µs later. The accepted trade-off is that downstream logic must be built to abort/roll back on a bad verdict — e.g., a feed handler doesn't commit an order-book update until the good flag lands. The spec is deliberately pushing drop responsibility onto user logic (restated in B.7's "weaknesses" note), and it saves a whole frame-sized BRAM buffer and its control logic.

---

## R10 — The four error classes, and what "recover cleanly" demands

The four things the RX path must detect and reject:

- **Runt (< 64 bytes DA→FCS):** legal Ethernet frames are minimum 64 bytes (that's why TX pads, per R3). Anything shorter is typically a collision fragment or truncated frame. Requires a per-frame byte counter.
- **Oversize (> 1518 bytes):** max legal Ethernet II frame is 1518 bytes (1500 payload + 14 header + 4 FCS). Longer means jumbo (out of scope, B.7) or a corrupted length — reject it.
- **Bad FCS:** the CRC check from R9 fails — bits got flipped on the wire.
- **RX_ER during frame:** RGMII has an error signal; the PHY asserts it mid-frame when *it* detected a physical-layer problem (bad symbol, carrier issue). Even if the CRC happens to pass, the PHY has flagged the data as untrustworthy.

Three obligations for each:

### 1. Discard as invalid

The frame must not be delivered as good. Note the interaction with R9: in cut-through you may have already streamed bytes out before discovering the problem, so "discard" means *flag bad at EOF*; for errors detectable early (oversize, RX_ER) the stream can also be terminated immediately with the bad verdict.

### 2. Count separately

One counter per error class, not one lumped "bad frames" counter (this feeds R17's register block). This is a debugging requirement: on the bench, "RX_ER counter climbing" points at RGMII timing/signal-integrity problems, "bad-FCS climbing" points at a CRC or byte-ordering bug, "runt counter climbing" points at SFD/EOF detection. One merged counter would say something is wrong but not what.

### 3. Recover cleanly

This is the real design constraint, defined operationally: *the next good frame is received intact.* The failure mode it guards against is a state machine that gets wedged by a malformed frame — e.g., it sees a runt, ends up in some half-state waiting for bytes that never come, and then mangles or drops the perfectly good frame that follows. The RX FSM must, from *any* error, deterministically return to "hunting for the next SFD" (R8/R11) with all per-frame state (byte count, CRC accumulator, FIFO write pointer if speculatively written) fully reset. No error may leave residue that poisons the next frame.

This is also why the verification plan (B.4) crosses every corruption type with frame lengths, and why bring-up step 7 deliberately fires bad frames at the board while good traffic flows: R10 isn't really tested by *one* bad frame — it's tested by the good frame *after* the bad one.

---

## Summary

The two requirements are complementary: **R9 defines the delivery contract for frames** (stream now, verdict at the end), and **R10 defines the containment contract for garbage** (classify it, count it, and never let it damage what comes next).
