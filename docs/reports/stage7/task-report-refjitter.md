# Stage 7 task report: criterion A second pass -- REF_JITTER1 = 0.125

## Status: COMPLETE, with a measured finding that changes the criterion's premise

Acceptance criterion A (`Documents/RX Clock Deskew Design.md`, re-based in
Stage 7) required running the whole of A twice: at `REF_JITTER1 = 0.010` and
at the DS181 `MMCM_FINJITTER` ceiling of 0.125 UI. Both runs are now done.

## Method

1. Temp-edited `rtl/gem_rx_mmcm.v`: `REF_JITTER1 0.010 → 0.125`.
2. `python scripts/build.py impl gem_top` (fresh synthesis, place, route).
3. Confirmed the parameter actually reached the netlist:
   `get_property REF_JITTER1` on `u_clk_rst/u_rx_mmcm/u_mmcm` returns
   **0.125** on the routed checkpoint.
4. Read gate-2 numbers and the clock-uncertainty decomposition on a worst RX
   setup path from the same checkpoint.
5. Reverted to 0.010; clean rebuild confirmed.

## Result

| Quantity | REF_JITTER1 = 0.010 | REF_JITTER1 = 0.125 |
|---|---|---|
| WNS (waived RX setup) | −3.109 ns | **−3.109 ns** (identical) |
| WHS | +0.037…+0.049 ns (placement drift) | +0.049 ns |
| Clock uncertainty on RX path | 0.150 ns | **0.150 ns** (TSJ 0.050, DJ 0.111, PE 0.089) |

**Bit-identical, and the reason is the finding:** criterion A's premise --
"`REF_JITTER1` feeds Vivado's clock-uncertainty modelling on the derived
clock" -- is **false on Vivado 2024.2 for this MMCM configuration**. The tool
accepts the property (it reads back 0.125 from the cell) but the derived
clock's uncertainty decomposition does not change: DJ stays at the speed
file's own output-jitter model value (0.111 ns), not anything derived from the
input-jitter parameter. The modeled margins therefore cannot be pessimized
through this knob.

## Consequences

1. **The second pass is vacuous in STA, and that is now measured rather than
   assumed.** There is no optimistic number hiding behind the 0.010 default:
   the tool never consumed it.
2. The criterion's real exposure was always physical, not modeled: recovered-
   clock jitter enters the margins through the loop-equation's uncertainty
   term and through the PHY's actual RX_CLK jitter -- both owned by the bench
   half of criterion A (Stage 8). The physical derivation (+0.669 ns worst)
   carries ~0.15 ns of uncertainty already; a recovered-clock jitter budget up
   to DS181's 1 ns absolute would erode it and must be measured, not assumed.
3. Criterion A's jitter bullet should be read as satisfied-by-measurement of
   the modeling question ("does the parameter change anything?" -- no) plus
   the standing bench obligation.

## Verification state

* Reverted tree: `REF_JITTER1` back to 0.010; clean rebuild reproduces
  WNS −3.109 / WHS +0.049; `make check` green at close of task (29/29).
* No commit contains the 0.125 value.
