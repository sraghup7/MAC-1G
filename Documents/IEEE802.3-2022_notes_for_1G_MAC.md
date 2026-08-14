# IEEE Std 802.3-2022 — Notes for the 1G MAC Project

Source: *IEEE Std 802.3-2022, IEEE Standard for Ethernet* (the file `IEEE_Standard_for_Ethernet.pdf`, 7025 pages). All page numbers below are the printed page numbers in the footer of the PDF, which line up with the PDF page index.

This is a working extract, not a replacement for the standard. Where a rule is genuinely subtle (the FCS bit-ordering above all), the full clause text is reproduced or paraphrased closely so you don't have to re-derive it from the standard's terse wording.

---

## Clause 1 — Introduction (skim only, pp. 167–234)

Not reproduced in full — this is an index of where things live so you can jump back in when a term confuses you.

- **1.1 Overview / Basic concepts (pp. 167–171):** Defines half duplex vs. full duplex at a conceptual level. Full duplex requires: (a) medium supports simultaneous TX/RX, (b) exactly two stations on a point-to-point link, (c) both ends configured for full duplex. Full duplex is described as "a proper subset of the MAC functionality required for half duplex operation" — i.e. everything a full-duplex MAC does, a half-duplex MAC also has to do, plus CSMA/CD.
- **Figure 1–1 — layer diagram (p. 168):** Maps the 802.3 stack onto the OSI model:
  ```
  OSI Data Link Layer  = LLC (or other MAC client)
                          MAC Control (optional)
                          MAC — Media Access Control
                          Reconciliation Sublayer (RS)
  OSI Physical Layer   = xMII  (MII @100M, GMII @1G, XGMII @10G, ...)
                          PCS / PMA / PMD  (collectively "PHY")
                          MDI
                          Medium
  ```
  For your project: **MAC** sits directly above the **Reconciliation Sublayer + GMII**, and directly below an optional **MAC Control** sublayer, then **LLC/MAC client**. Your AXI-Stream port replaces the MAC-client interface (Clause 2); your GMII port replaces the RS/GMII boundary (Clause 35).
- **1.1.4 Layer interfaces (p. 172):** Confirms MAC↔client interface = "facilities for transmitting/receiving frames + status for error recovery" (this is Clause 2); MAC↔PHY interface = "framing signals (carrier sense, receive data valid, transmit initiation), collision detect, serial bit streams, and a wait function for timing" (this is Clause 4.3.3 / Clause 35).
- **1.1.6 Word usage (p. 172):** `shall` = mandatory, `should` = recommended, `may` = permitted, `can` = capability statement. Standard boilerplate but matters when reading the rest of the standard — `should` is not a requirement.
- **1.2.1 State diagram notation (p. 173, "Figure 1–1" again — the standard reuses the figure number):** Rectangles = states (name in caps on top, any asserted output signal below the line). `( )` = condition, `[ ]` = action, `*` = AND, `+` = OR, `UCT` = unconditional transition, open arrows = global transitions to a state from *any* other state. **State diagrams take precedence over prose when they conflict.** Relevant later for Clause 4/28's actual state-diagram figures.
- **1.2.2 Service primitive notation (p. 174):** REQUEST flows layer N → N−1, INDICATION flows N−1 → N. This is the abstraction Clause 2 and Clause 6 use, and it's the model your AXI-Stream port concretizes (`AXIS master = REQUEST`, `AXIS slave receiving = INDICATION`, roughly).
- **1.2.5 Hexadecimal notation (p. 175):** `0x` prefix or subscript-16; uppercase A–F; for a value not a multiple of 4 bits, the *leftmost* hex digit is truncated.
- **1.3 Normative references:** pp. 176–187.
- **1.4 Definitions:** pp. 187–227 (alphabetical glossary — ~40 pages). Come back here for terms like "octet", "frame", "packet", "PAUSE", "basic frame", "envelope frame", etc.
- **1.5 Abbreviations:** pp. 227–234 (acronym table — GMII, MDIO, MII, PCS, PMA, PMD, xMII, etc. are all defined here in one line each).

---

## Clause 2 — MAC service specification (pp. 235–238, full)

Short and abstract by design — this is literally the spec your AXI-Stream slave/master ports have to satisfy semantically, minus any implementation detail.

**Figure 2–1** shows the MAC sitting between a MAC client and the Physical Layer, exposing exactly two service primitives up top (`MA_DATA.request`, `MA_DATA.indication`) and internal variables shared with the PHY (`carrierSense`, `receiveDataValid`, `collisionDetect`, `transmitting`) plus functions `TransmitBit`/`ReceiveBit`/`Wait`.

### MA_DATA.request — "please transmit this frame" (2.3.1)

```
MA_DATA.request(
    destination_address,
    source_address,          -- optional; MAC fills in if omitted
    mac_service_data_unit,   -- the payload; length is implicit in the parameter
    frame_check_sequence     -- optional; MAC computes it if omitted
)
```
- If `destination_address` is a group address, the frame is multicast/broadcast.
- If `frame_check_sequence` is supplied by the client, the client is also responsible for supplying Pad (2.3.1.2), and must respect Clause 3.3's bit-transmission-order rule when doing so.
- Effect: MAC prepends DA/SA, inserts Length/Type, and passes the assembled frame down to the Physical Layer.

### MA_DATA.indication — "a frame arrived for you" (2.3.2)

```
MA_DATA.indication(
    destination_address,
    source_address,
    mac_service_data_unit,
    frame_check_sequence,   -- optional pass-through
    reception_status
)
```
- Only reported for **validly formed, error-free** frames addressed to the local MAC (individual, active group, or broadcast address) — see 3.4 for what makes a frame invalid.
- A frame addressed to the local station's own DA (e.g. broadcast) is delivered back to that station's own MAC client too — this may be implemented in the MAC or fall out naturally from full-duplex loopback-like behavior.

**Practical takeaway:** your AXI-Stream TX port is a concrete `MA_DATA.request`; your AXI-Stream RX port is a concrete `MA_DATA.indication`, restricted to the case where FCS is *not* passed by the client on TX (you compute it) and reception status is conveyed some other way (e.g. a `tuser`/error sideband signal) since AXI-Stream has no native "reception_status" parameter.

---

## Clause 3 — MAC frame and packet specifications (pp. 239–244, full — this is your FCS module)

### 3.1 Overview / Figure 3–1 — packet format

Three frame types exist (basic, Q-tagged, envelope) but **they all share one physical layout**:

| Field | Size | Notes |
|---|---|---|
| Preamble | 7 octets | `10101010` × 7, lets PHY/PLS reach steady-state sync |
| SFD | 1 octet | fixed pattern `10101011` |
| Destination Address | 6 octets (48 bits) | |
| Source Address | 6 octets (48 bits) | |
| Length/Type | 2 octets | dual-meaning field, see below |
| MAC Client Data | 46–1500 (or 1504 Q-tagged, or 1982 envelope) octets | |
| Pad | 0..N octets | inserted only if needed to hit the frame-size minimum |
| FCS | 4 octets (32 bits) | CRC-32 |
| Extension | 0..N bits | **half duplex 1000 Mb/s only** |

Critical framing facts from Figure 3–1's caption:
- **"Octets of a packet are transmitted top to bottom"** (i.e., in the field order above) **"and the bits of each octet are transmitted from left to right."** In the figure, bit 0 (LSB) is drawn on the left and bit 7 (MSB) on the right — so "left to right" transmission order means **LSB of each octet goes out first**, for every field except the FCS (see 3.3 below, and the CRC subclause has its own, different rule).
- "Minimum/maximum MAC frame size" (defined in 4.4) counts from **DA through FCS inclusive** — Preamble/SFD/Extension are not part of the frame proper, just the packet.

### 3.2 Elements of the frame, in transmission order

- **3.2.1 Preamble** — 7 octets, `10101010` repeated, purely for PLS synchronization.
- **3.2.2 SFD** — 1 octet, `10101011`, immediately followed by the MAC frame itself.
- **3.2.3 Address fields (Figure 3–3):** Each address is 48 bits.
  - Bit 0 (first bit, i.e. LSB, transmitted first) of the **Destination** address is the **I/G bit**: `0` = individual, `1` = group (multicast/broadcast).
  - Bit 1 is the **U/L bit**: `0` = globally administered (OUI-based), `1` = locally administered. (For Source Address, bit 0 is reserved/must be 0; U/L still applies.)
  - **"Each octet of each address field shall be transmitted least significant bit first."**
  - All-ones DA = broadcast address; every station must recognize it (not necessarily generate it).
- **3.2.6 Length/Type field (2 octets, transmitted/received high-order octet first — i.e. this field is the exception to "LSB-of-octet-first" at the *octet* level, though bits within each octet still go LSB-first):**
  - value ≤ 1500 (0x05DC) → **Length** interpretation (number of MAC Client Data octets).
  - value ≥ 1536 (0x0600) → **Type** interpretation (EtherType).
  - 1501–1535 is an undefined gap by construction — Length and Type ranges never overlap.
  - When used as Type, the MAC client is responsible for correctly handling whatever padding the MAC sublayer may have added.
- **3.2.7 MAC Client Data** — arbitrary octets, up to 1500 (basic), 1504 (Q-tagged), or 1982 (envelope) octets. Support at least one of these three maximums.
- **3.2.8 Pad field:** Added only if needed so the frame (DA..FCS inclusive) reaches `minFrameSize` bits. Formula:
  ```
  padBits = max(0, minFrameSize - (clientDataBits + 2*addressSize + 48))
  ```
  where `48` accounts for the 16-bit Length/Type + 32-bit FCS. For 1000 Mb/s, `minFrameSize = 512 bits = 64 octets` (see Table 4–2 below) — **this is where "64-byte minimum frame" comes from.**
- **3.2.9 Frame Check Sequence — full CRC-32 definition** (see dedicated section below).
- **3.2.10 Extension field:** Only relevant to **half duplex** 1000 Mb/s operation (carrier extension, 4.2.3.4). Length is `0` to `(slotTime − minFrameSize)` bits. **Not covered by the FCS.** For full-duplex-only 1G MAC implementations (the overwhelmingly common case today), this field is always zero-length and you can effectively ignore it — but know it exists so an all-zeros/omitted Extension in your design is intentional, not an oversight.

### 3.3 Order of bit transmission

> "Each octet of the MAC frame, **with the exception of the FCS**, is transmitted least significant bit first."

This is the single most important sentence in the clause for RTL purposes: every field (addresses, Length/Type octet-internally, data, pad) ships LSB-first per octet. The FCS field alone follows a different, explicit rule (below) — this asymmetry is exactly the "genuinely fiddly" part.

### 3.4 Invalid MAC frame

A received frame is invalid if **any** of:
1. Frame length is inconsistent with a Length-interpreted Length/Type field (a Type-interpreted field can never make a frame "invalid" on length grounds).
2. Frame is not an integral number of octets.
3. Recomputed CRC over the frame (excluding the FCS field itself) doesn't match the received FCS.

Invalid frames must **not** be passed to the MAC client / LLC / MAC Control sublayer. They may be silently dropped, counted by management, or used privately (e.g. for statistics) — that's implementation-defined.

### CRC-32 (FCS) — read three times, exactly as the standard states it

**Generating polynomial (3.2.9):**
```
G(x) = x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1
```
This is the well-known constant **`0x04C11DB7`** (bits 31..0 of G(x) with the implicit leading `x^32` dropped) — the standard doesn't spell out the hex form, but it's a direct transcription of the polynomial above and is the value used almost universally in hardware CRC-32 tables/shift registers.

**The five-step procedure, verbatim in substance (3.2.9 a–e):**
1. **Complement the first 32 bits of the frame.** — In hardware terms, this is equivalent to **seeding the CRC accumulator/shift register with all ones (`0xFFFFFFFF`)** rather than zero, instead of literally inverting frame bits.
2. Treat the "protected fields" (DA, SA, Length/Type, Data, Pad — everything except FCS) as coefficients of a polynomial `M(x)`. **The first bit of the DA field is the highest-degree term `x^(n-1)`; the last bit of Data/Pad is `x^0`.**
   - Because addresses/data are transmitted LSB-of-octet-first (3.3), "first bit of DA" = the LSB of the first transmitted octet of the DA. So **the bit order you feed into the CRC math is the transmission order (LSB-of-each-octet first)**, not the "natural" MSB-first reading of the octet values. This is the standard "reflected input" CRC convention.
3. Multiply `M(x)` by `x^32`, divide by `G(x)`, keep the remainder `R(x)` (degree ≤ 31).
4. Take the 32 coefficients of `R(x)` as a 32-bit value.
5. **Complement that 32-bit value** — equivalent to a **final XOR with `0xFFFFFFFF`**.

**Output bit order (3.2.9, last paragraph) — the other half of the gotcha:**
> "The 32 bits of the CRC value are placed in the FCS field so that the x^31 term is the left-most bit of the first octet, and the x^0 term is the right-most bit of the last octet. (The bits of the CRC are thus transmitted in the order x^31, x^30, ..., x^1, x^0.)"

So, **unlike every other field in the frame, the FCS's 4 octets are transmitted MSB-first (x^31 first)** — this is exactly the "exception to the FCS" carved out in 3.3.

**Net effect, in familiar CRC-parameter terms** (derived from the above, not stated this way in the standard, but this is what it computes to, and it's the standard way to describe/verify a "CRC-32" implementation — commonly called **CRC-32/ISO-HDLC**):
- Poly: `0x04C11DB7`
- Init: `0xFFFFFFFF`
- RefIn (reflect each input byte / process LSB-first): **true**
- RefOut (reflect the final remainder before the final XOR): **true**
- XorOut: `0xFFFFFFFF`
- Check value (CRC of ASCII `"123456789"`): `0xCBF43926` — a useful self-test vector for verifying your FCS module against a known-good implementation independent of the standard text.

**FCS validation on receive (4.2.4.1.2):** identical computation over the incoming frame (excluding the FCS field itself); mismatch ⇒ invalid frame (3.4).

---

## Clause 4 — Media Access Control (pp. 245–283)

The bulk of this clause (4.2.2–4.2.10, the Pascal-language "precise specification") is the formal CSMA/CD half-duplex algorithm — deferral, jamming, truncated binary exponential backoff. You don't need to implement it, but two summary facts are worth knowing so you understand *why* full duplex is simpler:

- **Truncated binary exponential backoff (4.2.3.2.5):** after a collision, wait `r` slot times where `r` is uniform random in `[0, 2^k)`, `k = min(attempt_number, 10)`. Give up after `attemptLimit` (16) failed attempts.
- **Collision handling (4.1.2.2, 4.2.3.2.4):** on collision, the transmitter keeps sending a `jamSize`-bit jam pattern to guarantee all stations notice, then backs off and retries.
- **Full duplex made this moot:** with exactly two stations on a dedicated point-to-point link and no shared medium, there is no contention, so none of the above applies (4.1.1(b), 4.2.3.2.6): *"there is never any need to jam or reschedule transmissions."*

### 4.1.1 / 4.1.2.1 / 4.2.3.2.6 — Full duplex operation, what actually applies to you

- Full duplex requires: medium supports simultaneous TX/RX, exactly two stations, both configured for full duplex (repeated from Clause 1, now normative).
- **4.2.3.2.6 Full duplex transmission (the operative rule):** *"there is never contention for a shared physical medium... a MAC operating in full duplex mode does not react to [Physical Layer collision] indications... Full duplex stations do not defer to received traffic, nor abort transmission, jam, backoff, and reschedule transmissions... Transmissions may be initiated whenever the station has a frame queued, subject only to the interpacket gap."*
- **4.2.3.2.1(b) Deference, full duplex mode:** No dependence on `carrierSense` at all. Instead there's an internal `transmitting` variable; after the last bit of a transmitted frame (`transmitting` goes false→true→false), the MAC just waits out `interPacketGap` before it's allowed to start the next frame. **This is essentially your entire TX-side arbitration logic in full duplex: track "am I currently sending," and enforce the IFG timer between frames. No carrier sense, no backoff, no jam.**
- **4.1.2.2 / 4.2.3.2.6:** the PHY *may* still assert a collision-detect-like indication in full duplex mode, but a full-duplex MAC must ignore it.
- CRS/COL behavior at the GMII is explicitly **unspecified in full duplex mode** (see Clause 35 section below) — don't build logic that depends on them when full duplex.

### 4.2.3.2.2 Inter-frame (interpacket) gap — the definition

- `interPacketGap` = **minimum** spacing between frames, in bit times, "to provide interpacket recovery time for other CSMA/CD sublayers and for the physical medium." You may use a *larger* gap (at a throughput cost) but never smaller.
- Half duplex: timed from `carrierSense` false (medium goes idle) until transmission starts.
- **Full duplex: timed from your own `transmitting` signal going false** (i.e., from the end of your own last transmitted frame) — you are not watching the medium at all.
- Value (Table 4–2): **96 bit times**, all speeds including 1 Gb/s.
- Optional robustness measure (informative note in 4.2.3.2.1(a), half-duplex only, not applicable to you in full duplex): split the IFG timer into two parts and allow the timer to reset if carrier reappears during the first ⅔ of the interval, to avoid a falsely-short IFG after a collision glitch.

### 4.2.7.1 / 4.4.2 — MAC parameters (Table 4–2), values for 1 Gb/s

| Parameter | Up to 100 Mb/s | **1 Gb/s** | Notes |
|---|---|---|---|
| slotTime | 512 bit times | **4096 bit times** | half duplex only — collision window |
| interPacketGap | 96 bits | **96 bits** | applies in both duplex modes |
| attemptLimit | 16 | **16** | half duplex only |
| backoffLimit | 10 | **10** | half duplex only |
| jamSize | 32 bits | **32 bits** | half duplex only |
| maxBasicFrameSize | 1518 octets | **1518 octets** | |
| maxEnvelopeFrameSize | 2000 octets | **2000 octets** | |
| **minFrameSize** | 512 bits (64 octets) | **512 bits (64 octets)** | ← the "64-byte minimum" |
| burstLimit | n/a | **65 536 bits** | half duplex 1G packet-bursting only |

`interFrameGap`/`interFrameSpacing` mentioned elsewhere (Clause 13, 35, 42) is the same thing as `interPacketGap` — just an older/alternate name (footnote a to Table 4–2).

Note on 1G specifically (Note 3 to Table 4–2): the *measured* IFG at the GMII receive signals can shrink to as little as **64 bit times** due to network delays/clock tolerance even though `interPacketGap` (the transmit-side minimum you enforce) is 96 bits — so a receiver shouldn't be strict about requiring a full 96-bit gap between received frames.

### 4.2.5 / 4.2.6 — Preamble and SFD generation/detection

- Preamble pattern: `10101010` × 7 octets, transmitted left-to-right (i.e. this specific bit pattern reads the same either way, but note it "ends with a 0").
- On TX: send preamble then SFD (`10101011`) before the first frame bit; if collision-detect becomes true mid-preamble (half duplex only), finish sending preamble+SFD anyway.
- On RX: once `receiveDataValid` asserts and the `10101011` SFD sequence is recognized, everything after that is passed up as frame data.

### 4.2.3.3 — Minimum frame size (mechanism, ties to 3.2.8)

If `frameSize < minFrameSize`, the MAC pads (octet-granularity) between MAC Client Data and FCS until the DA-through-FCS span reaches `minFrameSize` bits (64 octets at any speed up to and including 1G). Pad content is unspecified (all-zero is conventional and simplest for an RTL pad generator).

### Control-flow diagrams — the closest thing to FSM pseudocode (Figures 4–2a/b, 4–3a/b)

These are literally titled "Control flow summary," derived from the Pascal procedural model, and are the standard's own diagrammatic version of your TX/RX FSM:

**Figure 4–2a — `TransmitFrame` control flow:**
```
TransmitFrame
  → [if !transmitEnabled: Done(transmitDisabled)]
  → assemble frame
  → [if burst continuation: skip straight to "start transmission"]   (half-duplex 1G only)
  → [if deferring: wait]
  → start transmission
  → [halfDuplex && collisionDetect?]
       yes → send jam → increment attempts
              → [late collision && speed>100Mb/s?] yes→Done(lateCollisionErrorStatus)
              → [too many attempts?] yes→Done(excessiveCollisionError)
              → compute backoff → wait backoff time → retry from "start transmission"
       no  → [transmission done?] → Done(transmitOK)
```

**Figure 4–2b — `ReceiveFrame` control flow:**
```
ReceiveFrame
  → [if !receiveEnabled: Done(receiveDisabled)]
  → start receiving
  → [done receiving? no→loop]
  → [frame too small (collision fragment)?] yes→Done(discard, not an error)
  → [recognize address?] no→discard
  → [frame too long?] yes→Done(frameTooLong)
  → [valid FCS?] no→Done(frameCheckError)
  → [valid length/type field?] no→[extra bits?]→Done(lengthError) / Done(alignmentError)
  → disassemble frame → Done(receiveOK)
```

**Figure 4–3a/b — `BitTransmitter`/`BitReceiver`, `Deference`, `BurstTimer`, `SetExtending` processes** — bit-level companions to the above; mostly half-duplex/1G-burst-specific (marked `*` = "applicable only to half duplex operation at 1000 Mb/s"), so for a full-duplex-only implementation you can largely collapse these into: transmit bits while `transmitting` is asserted and end-of-frame hasn't been reached; receive bits while `receiveDataValid` is asserted.

### Figures 4–6 / 4–7 — MAC client interface state diagrams (4.3.2) — the actual bubble-and-arrow FSMs

These use the formal state-diagram notation from 1.2.1 and are the cleanest, smallest FSMs in the whole clause — essentially your **AXI-Stream ⇄ MAC** boundary behavior:

**Figure 4–6 — transmit interface (client side):**
```
BEGIN → WAIT_FOR_TRANSMIT
  --[MA_DATA.request(dest, src, msdu, fcs)]--> GENERATE_TRANSMIT_FRAME
       [ TransmitFrame(dest, src, lengthOrType, data, fcs, fcsPresent) : TransmitStatus ]
  --UCT--> (back to WAIT_FOR_TRANSMIT)
```

**Figure 4–7 — receive interface (client side):**
```
BEGIN → WAIT_FOR_RECEIVE
  [ ReceiveFrame() ]
  --[ReceiveFrame(dest, src, lengthOrType, data, fcs, fcsPresent) : ReceiveStatus]--> PASS_TO_CLIENT
       [ MA_DATA.indication(dest, src, msdu, fcs, ReceiveStatus) ]
  --UCT--> (back to WAIT_FOR_RECEIVE)
```
i.e. at the client boundary it really is just "wait for a request → do the transfer synchronously → indicate completion → repeat." Two states each. All the real complexity lives one layer down, in the (mostly half-duplex-only) processes above.

### 4.3.3 — Services required from the Physical Layer (Table 4–1)

The MAC↔PHY interface consists of: function `Wait`, procedures `TransmitBit`/`ReceiveBit`, and Boolean variables `carrierSense`, `transmitting`, `collisionDetect`, `receiveDataValid`. This is the abstract version of what Clause 35 (GMII) makes concrete with real pins.

---

## Clause 22 — Reconciliation Sublayer (RS) and MII (MDIO focus, pp. 700–732 of ~757)

You mainly need 22.2.4 (management functions / MDIO). The MII data-signal definitions (TX_EN, TXD, etc.) are superseded for your purposes by the GMII versions in Clause 35 — same concepts, wider bus.

### 22.2.4 — Management functions overview

The **MII Management Interface** = 2 signals (**MDC** clock, **MDIO** data), a frame format, a transaction protocol, and a register set. GMII reuses this unchanged (35.2.2.13/14 just point back to 22.2.2.13/14). Basic register set = registers 0 (Control) and 1 (Status), mandatory for any MII-managed PHY. A **GMII** PHY additionally must implement register 15 (Extended Status) — this is how a station management entity knows a PHY is 1000BASE-capable at all.

### Table 22–6 — MII/GMII management register set

| Addr | Register | MII | GMII |
|---|---|---|---|
| 0 | Control | Basic | Basic |
| 1 | Status | Basic | Basic |
| 2,3 | PHY Identifier | Ext | Ext |
| 4 | Auto-Negotiation Advertisement | Ext | Ext |
| 5 | Auto-Negotiation Link Partner Base Page Ability | Ext | Ext |
| 6 | Auto-Negotiation Expansion | Ext | Ext |
| 7 | Auto-Negotiation Next Page Transmit | Ext | Ext |
| 8 | Auto-Negotiation Link Partner Received Next Page | Ext | Ext |
| 9 | MASTER-SLAVE Control | Ext | Ext |
| 10 | MASTER-SLAVE Status | Ext | Ext |
| 11 | PSE Control | Ext | Ext |
| 12 | PSE Status | Ext | Ext |
| 13 | MMD Access Control | Ext | Ext |
| 14 | MMD Access Address/Data | Ext | Ext |
| 15 | Extended Status | Reserved | **Basic** |
| 16–31 | Vendor Specific | Ext | Ext |

This is "the standard register set (registers 0–15)."

### Register 0 — Control (Table 22–7)

| Bit | Name | Meaning |
|---|---|---|
| 0.15 | Reset | 1 = reset (self-clearing, PHY must complete within 0.5 s) |
| 0.14 | Loopback | 1 = internal loopback (TX path looped to RX, RX_DV asserted <512 BT after TX_EN) |
| 0.13 & 0.6 | Speed Selection | `{0.6,0.13}`: `00`=10 Mb/s, `01`=100 Mb/s, `10`=1000 Mb/s, `11`=reserved. Only meaningful when Auto-Neg (0.12) is disabled. |
| 0.12 | Auto-Negotiation Enable | 1 = enable AN (0.13/0.8/0.6 then have no effect on link config) |
| 0.11 | Power Down | 1 = low power state |
| 0.10 | Isolate | 1 = electrically isolate PHY from MII/GMII |
| 0.9 | Restart Auto-Negotiation | 1 = restart AN (self-clearing) |
| 0.8 | Duplex Mode | 1 = full duplex, 0 = half duplex (only meaningful when AN disabled) |
| 0.7 | Collision Test | 1 = force COL to assert within 512 BT of TX_EN (diagnostic) |
| 0.5 | Unidirectional Enable | allow TX without a valid link (only relevant with AN off + full duplex, e.g. EEE/OAM) |
| 0.4:0 | Reserved | write 0, ignore on read |

### Register 1 — Status (Table 22–8, all read-only unless noted)

| Bit | Name | Meaning |
|---|---|---|
| 1.15 | 100BASE-T4 ability | |
| 1.14 / 1.13 | 100BASE-X full/half duplex ability | |
| 1.12 / 1.11 | 10 Mb/s full/half duplex ability | |
| 1.10 / 1.9 | 100BASE-T2 full/half duplex ability | |
| 1.8 | **Extended Status** | 1 = status extended into register 15 — **all 1000 Mb/s PHYs must set this** |
| 1.7 | Unidirectional ability | |
| 1.6 | MF Preamble Suppression ability | 1 = PHY accepts MDIO frames without the 32-bit preamble |
| 1.5 | Auto-Negotiation Complete | latching-ish; 0 if AN disabled or unsupported |
| 1.4 | Remote Fault | latching high, cleared on read or PHY reset |
| 1.3 | Auto-Negotiation Ability | does the PHY support AN at all |
| 1.2 | **Link Status** | 1 = link up; latching low (clears to 0 on link-down event, cleared again on read) — **the bit you poll for link-up** |
| 1.1 | Jabber Detect | always 0 for ≥100 Mb/s PHYs (function moves to the repeater at those speeds) |
| 1.0 | Extended Capability | 1 = extended register set (2–15) present |

Register 15 (Extended Status) additionally reports **1000BASE-X/1000BASE-T full/half duplex ability** (35.2.4.4.x-ish content — bits 15.15:12), which is what a management entity checks to confirm 1G capability and default speed selection.

### 22.2.4.5 — Management frame structure (Table 22–12) — **the 32-bit MDIO transaction**

Transmitted MSB (left) first, bit-serial over MDIO clocked by MDC:

```
        PRE(32)   ST(2)  OP(2)  PHYAD(5)  REGAD(5)  TA(2)   DATA(16)
READ    111...1    01     10     AAAAA     RRRRR     Z0    DDDDDDDDDDDDDDDD
WRITE   111...1    01     01     AAAAA     RRRRR     10    DDDDDDDDDDDDDDDD
```

- **PRE** — 32 contiguous logic-1 bits (with 32 MDC cycles) for synchronization at the start of every transaction. May be suppressed if the STA knows every PHY on the bus supports preamble suppression (status bit 1.6).
- **ST** — fixed `01`, guarantees a 1→0→1 transition to mark frame start.
- **OP** — `10` = read, `01` = write.
- **PHYAD** — 5 bits, MSB first, up to 32 PHY addresses. PHY address `00000` is the default/required address for a PHY wired via the standard mechanical MDIO interface.
- **REGAD** — 5 bits, MSB first, up to 32 registers per PHY. `00000` = Control, `00001` = Status (fixed by spec, not convention).
- **TA (turnaround)** — 2 bit times between REGAD and DATA, to avoid bus contention:
  - Read: both STA and PHY stay high-Z for bit 1; PHY drives `0` for bit 2.
  - Write: STA drives `1` then `0`.
- **DATA** — 16 bits, MSB first (bit 15 of the addressed register goes out/comes in first).
- **IDLE** — MDIO is high-Z between transactions (pulled to `1` by the PHY's pull-up).

So: **32 preamble bits + 32 "frame" bits (2+2+5+5+2+16) = 64 MDC cycles per transaction**, and the "32-bit MDIO frame" your earlier notes referenced is this second half (ST/OP/PHYAD/REGAD/TA/DATA), not counting the preamble.

---

## Clause 28 — Auto-Negotiation over twisted pair (overview + base page, pp. 933–940 of ~987)

You won't implement this (the PHY handles the FLP-burst signaling on the analog side), but you'll read its outcome via the MDIO registers above, so the bit layout matters.

### 28.1 Overview — what AN actually does

- Exchanges ability information between two link partners using a modified 10BASE-T **Normal Link Pulse** sequence, called a **Fast Link Pulse (FLP) Burst** — a burst of closely-spaced link pulses (~62.5 µs apart) forming a clock/data sequence, repeated roughly every 16 ms. No packets or upper-layer overhead involved.
- Purely a Physical Layer function (Figure 28–2: sits at PMA/MDI, does **not** cross the MII/GMII as a signal — only its *result* is exposed via MDIO registers).
- Provides: ability advertisement, handshake/acknowledge, a priority-resolution function to pick the best common mode when several are shared, and a **Parallel Detection** fallback so non-AN 10BASE-T/100BASE-TX/100BASE-T4 partners can still be recognized.
- Backward compatible with plain 10BASE-T (which just sees NLPs and stays link-up).

### 28.2.1.2 — Base Page encoding (Figure 28–7) — what registers 4 & 5 actually contain

16-bit link codeword, **D0 transmitted first**:

```
 D0  D1  D2  D3  D4 | D5  D6  D7  D8  D9 D10 D11 | D12 | D13 | D14 | D15
 S0  S1  S2  S3  S4 | A0  A1  A2  A3  A4  A5  A6 | XNP |  RF | Ack |  NP
 └── Selector Field ┘ └── Technology Ability Field ┘
```

- **Selector Field S[4:0]** (D0–D4): identifies the protocol family being negotiated (802.3 CSMA/CD = one specific value; defined in Annex 28A). Reserved combinations must not be sent.
- **Technology Ability Field A[6:0]** (D5–D11): bitmap of supported modes *for that selector*, e.g. 10BASE-T, 10BASE-T FD, 100BASE-TX, 100BASE-TX FD, 100BASE-T4, PAUSE, ASM_DIR (exact bit assignment in Annex 28B). Multiple bits can be set simultaneously — you advertise everything you support in parallel.
- **XNP (D12)** — Extended Next Page supported by this device (1 = yes).
- **RF (D13)** — Remote Fault; mirrors control-register-driven fault signaling; default 0.
- **Ack (D14)** — Acknowledge: set to 1 once ≥3 consistent FLP bursts have been received from the partner. This is the AN handshake bit.
- **NP (D15)** — Next Page: 1 = "I have more pages to send" (used for extended ability signaling, e.g. how 1000BASE-T capability actually gets negotiated — 1G copper AN uses the Next Page mechanism plus registers 9/10, not the 7-bit Technology Ability Field alone, since that field predates gigabit).

**Where this shows up over MDIO:** register 4 = what *you* advertise (Auto-Negotiation Advertisement, same bit layout as Figure 28–7); register 5 = what the **link partner** advertised (Auto-Negotiation Link Partner Base Page Ability) — same 16-bit layout, just the received codeword instead of the transmitted one. This is exactly "what the advertised-ability and link-partner-ability registers actually contain."

- **Priority resolution** (mentioned, detail in Annex 28B): when multiple common modes exist between the two ends, a fixed priority order picks the winner — you don't need the table, just know that AN completion (status bit 1.5) implies this resolution already happened and the PHY is configured accordingly; you read the *result* via speed/duplex status bits, not by re-deriving it from the ability bits yourself.

---

## Clause 35 — Reconciliation Sublayer and GMII (pp. 1407–1425, full — your PHY-side port contract)

### 35.1 Overview

- GMII = MII (Clause 22) generalized to 1000 Mb/s: independent 8-bit-wide TX and RX data paths (vs. MII's 4-bit nibble), same MDIO management interface, same signal *names* carried over with extended valid-combination semantics.
- **Figure 35–2 signal inventory** (this is your MAC's PHY-side port list):
  - TX: `TXD<7:0>`, `TX_EN`, `TX_ER`, `GTX_CLK` (sourced **by the MAC/RS**, not the PHY — note the direction, opposite of RX_CLK)
  - RX: `RXD<7:0>`, `RX_ER`, `RX_DV`, `RX_CLK` (sourced by the PHY)
  - Status: `CRS` (carrier sense), `COL` (collision) — both driven by the PHY
  - Management: `MDC`, `MDIO` (Clause 22 semantics, unchanged)
- `GTX_CLK` nominal **125 MHz** (1000 Mb/s ÷ 8 bits); `RX_CLK` also nominally 125 MHz ±0.01% when locked to a valid signal, recovered-clock or free-running as needed when no signal is present.
- GMII "provides for full duplex operation" as a stated design characteristic (35.1 item f). EEE/Low-Power-Idle (LPI, Clause 78) support is optional and layered on top via specific TX_ER/TXD/RXD encodings — mentioned here since your MAC needs to at least not misinterpret those codes if the PHY supports EEE, even if you never enable it.

### Signal-by-signal rules — the load-bearing part

**TX_EN / TX_ER / TXD encoding (Table 35–1):**

| TX_EN | TX_ER | TXD<7:0> | Meaning |
|---|---|---|---|
| 0 | 0 | 00–FF | Normal inter-frame (idle) |
| 0 | 1 | 01 | Assert LPI (EEE) |
| 0 | 1 | 0F | Carrier Extend |
| 0 | 1 | 1F | Carrier Extend Error |
| 0 | 1 | others | Reserved |
| 1 | 0 | 00–FF | Normal data transmission |
| 1 | 1 | 00–FF | Transmit error propagation (force a coding error onto the wire) |

- `TX_EN` asserted synchronously with the first preamble octet, held through every octet to transmit, deasserted before the first `GTX_CLK` rising edge after the final data octet (35.2.2.3).
- `TX_ER` asserted **while `TX_EN` is also asserted** ⇒ tells the PHY to emit an invalid/error code-group somewhere in the frame (exact position not required to line up) — this is how you'd deliberately corrupt a frame, e.g. for test purposes (35.2.2.5).
- `TXD<0>` = LSB (35.2.2.4) — matches the frame-level "LSB first" convention from Clause 3.3, i.e. bit 0 of your octet-serial MAC frame data maps directly to `TXD<0>`.

**RX_DV / RX_ER / RXD encoding (Table 35–2):**

| RX_DV | RX_ER | RXD<7:0> | Meaning |
|---|---|---|---|
| 0 | 0 | 00–FF | Normal inter-frame |
| 0 | 1 | 00 | Normal inter-frame (alt encoding) |
| 0 | 1 | 01 | Assert LPI |
| 0 | 1 | 0E | False Carrier indication |
| 0 | 1 | 0F | Carrier Extend |
| 0 | 1 | 1F | Carrier Extend Error |
| 0 | 1 | others | Reserved |
| 1 | 0 | 00–FF | Normal data reception |
| 1 | 1 | 00–FF | Data reception error (bad code-group detected somewhere in this frame) |

- `RX_DV` asserted continuously from the first recovered octet through the final octet of the frame, deasserted before the RX_CLK edge following the final octet; must cover **at least the SFD onward** for the RS/MAC to correctly frame the packet (35.2.2.7).
- `RX_ER` asserted with `RX_DV` asserted ⇒ "somewhere in this frame there was a PHY-detectable coding error" (not necessarily localized) — **this is your cue to mark the frame as errored / invalid regardless of what the FCS check says**, since RX_ER can catch things the CRC alone might miss depending on where the corruption occurred relative to what got sampled. Handle this as an independent error source alongside the FCS check from Clause 3.4.
- `RXD<0>` = LSB, matching `TXD<0>` and Clause 3.3 (35.2.2.8).
- **False Carrier** (`RX_DV`=0, `RX_ER`=1, `RXD`=0x0E): the PHY saw *something* on the medium that looked briefly like a carrier/activity but wasn't a valid frame (e.g. noise). Purely informational/statistical — not a frame, don't try to parse it.

**CRS (35.2.2.11) / COL (35.2.2.12):**
- In **half duplex**: `CRS` asserts whenever TX or RX medium is non-idle, deasserts when both are idle, and must stay asserted through a collision. `COL` asserts on collision detection.
- **In full duplex, the behavior of both `CRS` and `COL` is explicitly unspecified.** Don't build any TX-arbitration logic in your full-duplex MAC that depends on reading these — this directly corroborates Clause 4's full-duplex deference rule (track your own `transmitting` state instead).
- Neither signal is required to be synchronous to `GTX_CLK` or `RX_CLK`.

### 35.2.3 — GMII data stream and bit/octet mapping

- Frame structure at the GMII: `<inter-frame><preamble><sfd><data><efd><extend>` (35.2.3.1/.2), same logical fields as Clause 3, just re-expressed as GMII signal sequences instead of a serial bit stream.
- **Figure 35–18 — the bit/octet mapping you'll implement in RTL:** for a given octet `D0..D7` of the MAC's conceptual serial bit stream (D0 = first bit, i.e. LSB per Clause 3.3), the parallel mapping is direct:
  ```
  TXD<0> = D0 (first/LSB)  ... TXD<7> = D7 (last/MSB)
  RXD<0> = D0 (first/LSB)  ... RXD<7> = D7 (last/MSB)
  ```
  So there's no bit-reversal needed between your internal octet representation and the GMII bus **as long as your internal octet representation is already "bit 0 = first-transmitted bit."** If your datapath instead treats an octet the conventional software way (bit 0 = LSB of the *numeric value*, which for these fields is the same thing per 3.2.3(d)'s LSB-first rule — but for the **FCS octets specifically**, remember 3.2.9 flips this to MSB-first-transmitted), you need to explicitly bit-reverse the 4 FCS octets before driving them onto `TXD<7:0>`/before interpreting them off `RXD<7:0>`, while every other field's octets map straight across. This is the same fiddly point from Clause 3, now at the pin level.
- `interFrameSpacing`/`interPacketGap` at the GMII, within a burst, is measured from `TX_EN` deassert to next `TX_EN` assert; between bursts, from `CRS` deassert to `CRS` assert (35.2.3.1) — not applicable to a full-duplex-only design (no bursting, no CRS dependency), but useful if you ever add half-duplex 1G burst mode.

---

## Summary — what maps to what in your design

| Standard clause | Your RTL block |
|---|---|
| Clause 2 (MA_DATA primitives) | AXI-Stream TX/RX port semantics |
| Clause 3 (frame fields, CRC-32) | Frame assembler/parser + FCS (CRC-32) module |
| Clause 4 §4.1–4.2.3.2.6 (full duplex only) | TX arbitration: track `transmitting`, enforce 96-bit IFG, no CSMA/CD logic needed |
| Clause 4 §4.3.2 (Fig 4-6/4-7) | AXI-Stream ⇄ MAC handshake FSM (2-state each side) |
| Clause 4 Table 4-2 | Parameter/constant block: `minFrameSize=64B`, `IPG=96 bit`, `maxFrameSize=1518B` |
| Clause 22 §22.2.4 | MDIO master controller (64-cycle transaction, register map) |
| Clause 28 (read-only) | Decode logic for AN result registers (4, 5, 1.5, 1.2, speed/duplex bits) |
| Clause 35 | GMII pin-level TX/RX datapath + TX_EN/TX_ER/RX_DV/RX_ER encode/decode |
