# Stage 7 methodology triage — every finding fixed or justified

Scope: `build/gem_top_methodology.rpt` at the Stage 7 baseline — LUTAR-1 ×5,
TIMING-9 ×1 (TIMING-10 was fixed by the gate-4 ASYNC_REG work and no longer
appears). Per the plan: default is **document, do not restructure** — every one
of these sits on the deskew architecture's load-bearing reset structure
(`Documents/RX Clock Deskew Design.md` Step 3b).

## LUTAR-1 ×5 — LUT driving an asynchronous reset/clear pin

**The shared safety argument.** All five sites are the same structure: a
combinational AND of reset-domain gating terms feeding the asynchronous
`CLR` of a `gem_reset_sync` chain (directly, or through the FIFO's
`rst_eff_n`). Two properties make the glitch hazard the rule warns about
benign here:

1. **Failure direction is reset assertion, which is the safe direction.**
   These are active-low clears: a glitch can only *assert* reset, never
   deassert it early. A spurious assertion re-asserts the downstream domain
   resets -- exactly the event the architecture already handles by design
   (link drops cause it on purpose; the supervisor and Step 3b exist so
   recovery is clean). No data path can be corrupted without a reset
   assertion passing through the same flops that define correct recovery.
2. **Registered inputs, aligned edges.** Where the gating term derives from
   on-chip logic (`mmcm_locked`, `rx_mmcm_locked`, `rx_rst_n`, `tx_rst_n`),
   every LUT input is a register output released on its own domain's clock
   after synchronisation (`gem_reset_sync.v`, `locked_s` pair) -- so inputs
   transition together, which is precisely the condition under which a
   multi-input LUT cannot produce a runt pulse. The one asynchronous input,
   board `ext_rst_n`, is the master reset itself: a glitch on it is a real
   board event whose effect -- asserting reset everywhere -- is the
   intended function of pressing it.

Per site:

| Site | Drives | Gating term | Verdict |
|---|---|---|---|
| `#1` `u_clk_rst/u_mmcm/sync[1]_i_1` | `u_tx_rst` CLR | `ext_rst_n & mmcm_locked` | B.1b requirement: tx reset must never release onto an unlocked MMCM. Deliberate. |
| `#2` `u_clk_rst/u_rx_mmcm/sync[1]_i_1__0` | `u_rx_rst` CLR | `tx_rst_n & rx_mmcm_locked` | Step 3d lock-gated release. Deliberate. |
| `#4` `u_clk_rst/u_tx_rst/sync[1]_i_1__1` | `u_rx_path_rst` CLR | `tx_rst_n & rx_rst_n` | Step 3b: destination half of RX-domain crossings must reset with the source half. Deliberate. |
| `#3` `u_rx_path_rst/wr_gray_s1[6]_i_1` | `rd_bin`/`rd_gray` CLR chain | `rst_eff_n` inside FIFO read side | Same term as #4 propagated into the FIFO. Deliberate. |
| `#5` `u_mac/u_rx_fifo/wr_gray[5]_i_2` | `rd_gray_s1/s2` CLR | `rst_eff_n` inside FIFO write side | Symmetric counterpart: write-side pointer view resets with the read side. This is Step 3b property 1 -- both pointer sets always assert together. Removing it reintroduces the fabricated-frame defect. |

**Why not restructure.** Registering the AND terms would delay release by a
domain clock -- harmless -- but would also make *assertion* synchronous,
and assertion-on-a-dead-clock is exactly what Step 3b forbids: when the RX
clock disappears, only asynchronous assertion reaches the FIFO halves.
The alternative encoding (dedicated global reset buffers) spends scarce
clock resources on a net that is asserted rarely and recovered from cleanly.
Documented rather than changed.

## TIMING-9 ×1 — unknown CDC logic

The rule fires once per design when a CDC-constrained clock pair shows *any*
capture-side path its detector does not recognise as a two-flop
synchroniser. It carries no object-level detail (measured: the violation
exposes no intermediate points), and this design has four constrained
clock pairs, several of which intentionally contain structures the detector
cannot classify:

* the FIFO memory read (safe by Gray-pointer protocol, not a synchroniser);
* the two combinational reset-AND terms above (CDC-10 class);
* the FIFO's pointer re-synchronisation chains.

Gate 4 supersedes it: `scripts/build.tcl` runs `report_cdc -details` every
build and refuses unless every Critical crossing matches the asserted,
individually-named inventory, and any unmarked synchroniser refuses outright.
Every crossing TIMING-9 might be pointing at is inside that enumerated set
with its safety argument written down. **Verdict: superseded by gate 4;
no action.** If gate 4 ever refuses, TIMING-9's concern is answered by the
printed rows, not by this warning's existence.

## Residual obligations

None new. The standing bench items (recovered-clock jitter measurement,
criterion A's physical half) are tracked in V-24 and
`task-report-refjitter.md`.
