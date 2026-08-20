# RGMII I/O timing derivation

Closes V-2's static half. Numbers sourced from `spec/PROJECT_SPEC.md` B.1b,
which cites the KSZ9031RNX datasheet (Microchip Rev 2.2) Table 19.

## RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk

The PHY delays RX_CLK 1.2 ns (typical) relative to RXD/RX_DV so the clock
edge lands inside the data eye rather than at its boundary. RGMII v2.0's
TsetupR/TholdR window is 1.0-2.0 ns -- the guaranteed minimum setup and hold
margin at the receiving pin once that delay is applied. This design uses the
window's worst-case bound, 1.0 ns, as the guaranteed budget: a design that
only requires the datasheet's stated minimum is safe across the PHY's full
1.0-2.0 ns delay range, not merely at its typical 1.2 ns value.

Using the virtual-clock method (matching
reference/verilog-ethernet/syn/quartus/rgmii_io.sdc's structure): a virtual
clock rgmii_rx_clk_virt, period 8.000 ns, phase 0, stands for the PHY's own
undelayed reference. Data transitions relative to that virtual clock's edges
by the datasheet's guaranteed window:

  max = period/2 - Tsetup_min = 4.000 - 1.0 = 3.000 ns
  min = -(Thold_min)           = -1.0 ns

applied on both -clock and -clock_fall (RGMII DDR carries data on both edges),
and constrained against rgmii_rx_clk's *own* falling/rising 90-degree-esque
sampling structure via the same set_false_path edge-pairing the reference
uses -- because rgmii_rx_clk_virt and rgmii_rx_clk are not the same clock and
Vivado would otherwise check non-corresponding edge pairs that do not
represent a real capture event.

## TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by gtx_clk_shifted

rgmii_gtx_clk is a *generated* clock: gem_rgmii_tx.v's u_oddr_gtx forwards
gtx_clk_shifted (the MMCM's phase-shifted CLKOUT1, corrected to -73.125 deg /
1.625 ns in Stage 6 part 1) straight to the pin through an ODDR. The output
delay is bounded by the PHY's required TsetupT/TholdT window, 1.2-2.0 ns, at
the PHY's pins -- i.e. it is a receiver requirement on this design's output,
not a margin this design measures on itself:

  max = 2.0 ns   (the window's upper bound: data may arrive no later than this
                   before the PHY's own sampling edge)
  min = 1.2 ns   (the window's lower bound: data must be held at least this
                   long after the PHY's edge)

applied against the generated clock on rgmii_gtx_clk, both -clock and
-clock_fall, with the same DDR edge-pairing false paths as RX.

## What this cannot check

Both derivations assume the datasheet's stated PHY-side numbers hold on the
physical board -- board trace length/skew is not in this budget because B.1b
never had trace-length data to put there. That is V-2's bench half: an ILA or
scope on GTX_CLK/TXD0 once the board is in hand. What Stage 6 closes is the
static half -- that the design's own clock relationships, as built, meet the
PHY's stated requirements before anything is placed on a real board.

## TX phase shift: the decision history, and the ceiling it ran into

The -73.125 deg / 1.625 ns figure above is the value Stage 6 part 1 arrived at
and the value still in `rtl/gem_mmcm.v`. Stage 6 part 2 measured it and found
it does not hold. This section is the record of that, so a future reader does
not have to reassemble it from four task reports.

### 1. The value in the file does not meet the constraint (Task 2)

Post-route, against the constraints derived above, all five TX data outputs
violate the setup (-max) check at -73.125 deg:

    rgmii_txd[0]  -0.351 ns      rgmii_txd[2]  -0.336 ns
    rgmii_txd[1]  -0.344 ns      rgmii_txd[3]  -0.341 ns
    rgmii_tx_ctl  -0.340 ns

The -min (hold) side passes with roughly 2 ns to spare at the same point. The
asymmetry is structural, not a constraint error: RGMII data is valid for half
a period either side of the forwarded edge, so the -min check has most of a
unit interval of slop while the -max check is the binding one. Every
conclusion below is therefore about the -max check.

### 2. The 5.625 deg grid has no good point in it (Task 2b)

Static phase resolution on an MMCM output is `45 / CLKOUTn_DIVIDE` degrees --
equivalently one eighth of a VCO period. At the design's VCO of 1000 MHz and
`CLKOUT1_DIVIDE = 8` that is 5.625 deg, or 0.125 ns. Sweeping every grid point
the PHY's 1.2-2.0 ns window permits found exactly one that is not outright
violated, and it clears by 24 ps. See `task-2b-report.md`.

### 3. It is not a placement problem (Task 2c)

99.939 % of the violated path is irreducible cell delay -- the ODDR's C-to-Q
and the OBUF's I-to-O -- and all six TX ODDRs already sit on the only OLOGIC
sites their pins allow. Routing contributes 0.001 ns. No LOC, pblock or SLEW
setting moves the number. See `task-2c-report.md`.

### 4. `CLKOUT1_USE_FINE_PS` is not a finer static phase (Task 2d)

The obvious next move -- the MMCM's "fine phase shift", resolution
`VCO_period / 56` instead of `VCO_period / 8` -- does not work as a static
mechanism, and fails in a way that is worse than an error. Three independent
checks against the tool itself, none of them from documentation memory:

  * `MMCME2_BASE`, which this design instantiates, has no `CLKOUT1_USE_FINE_PS`
    parameter at all. Synthesis refuses: *"parameter 'CLKOUT1_USE_FINE_PS'
    used as named parameter override, does not exist"* (Synth 8-7136).

  * On `MMCME2_ADV`, which does have it, Xilinx's own simulation model
    (`MMCME2_ADV.v`) initialises the fine-shift counter with `ps_in_init = 0`
    unconditionally and moves it only on `PSEN` pulses. Fine phase shift is a
    **runtime** interface. There is no configuration bit that preloads it, so
    with `PSEN` tied low the fine offset is permanently zero.

  * Xilinx's own Clocking Wizard never uses it to reach a static phase. Asked
    for -54.321 deg -- a value on no grid -- it rounds to -54.000 and leaves
    `USE_FINE_PS` false, retuning the VCO to 625 MHz so that -54.000 lands on
    the resulting 9 deg grid. Asked for -55.000 it picks a 1125 MHz VCO. It
    reaches an awkward phase by changing the VCO, never by fine phase shift.

**The trap.** Setting `CLKOUT1_USE_FINE_PS = TRUE` *disables* the DRC that
would otherwise catch an off-grid phase. Verified directly on the routed
checkpoint: with the flag false, an off-grid `CLKOUT1_PHASE` of -54.000 raises
`AVAL-139` ("MMCME2_ADV Phase shift and divide attr checks") as a Critical
Warning -- the same check that caught the original -72 deg literal. With the
flag true and nothing else changed, AVAL-139 goes silent and Vivado's timing
engine happily reports `clk1_raw` at `{-1.200 2.800}`. The build passes, the
timing report improves, and the silicon does not do it. Do not use this
parameter to buy resolution.

### 5. What actually changes the grid, and the ceiling that remains

The achievable set of shift magnitudes is `k * VCO_period / 8`, so the way to
put a wanted value on the grid is to choose the VCO. For a 1.200 ns shift on a
125 MHz output the only VCO in the Artix-7's 600-1200 MHz range that works is
625 MHz (`CLKFBOUT_MULT_F 12.500`, `CLKOUT1_DIVIDE 5`, 9 deg grid).

Measured post-route, worst case across all five TX outputs. The 1.2000 and
1.2222 ns rows are full builds run for this comparison; 1.6250 ns is the
committed baseline and 1.2500 ns is Task 2b's build, both re-confirmed here.

| Shift | Phase | VCO | `CLKOUT1_DIVIDE` | Worst setup | Worst hold | Clock uncertainty |
|---|---|---|---|---|---|---|
| 1.2000 ns | -54.000 | 625 MHz | 5 | **+0.055 ns** | +1.597 ns | 0.222 ns |
| 1.2222 ns | -55.000 | 1125 MHz | 9 | **+0.058 ns** | +1.645 ns | 0.196 ns |
| 1.2500 ns | -56.250 | 1000 MHz | 8 | +0.024 ns | +1.666 ns | 0.202 ns |
| 1.6250 ns | -73.125 | 1000 MHz | 8 | **-0.351 ns** | +2.041 ns | 0.202 ns |

Two things worth reading off that table. The smaller shift is not
automatically the better one: 1.2000 ns is the smallest the PHY window allows
and yet scores slightly *worse* than 1.2222 ns, because reaching it requires
dropping the VCO to 625 MHz and that costs 26 ps of extra clock uncertainty --
more than the 22 ps of shift it buys back. And 1.2222 ns keeps 22 ps of
distance from the window's own 1.2 ns floor, where 1.2000 ns sits exactly on
it.

**The ceiling.** At the design's present 1000 MHz VCO, setup slack runs
`1.274 ns - shift` across the whole measured range -- so within one VCO choice
it is maximised by the smallest shift the PHY permits, and across VCO choices
the jitter term above competes with it. With the grid
penalty removed entirely -- the best legal, silicon-achievable configuration
anywhere inside the PHY's 1.2-2.0 ns window -- the worst TX output clears
setup by **58 ps**. That is up from the 24 ps the 5.625 deg grid allowed, and
it is the physical limit of this approach: the remaining deficit is the OBUF
and ODDR cell delays Task 2c showed are irreducible, plus the 0.264 ns
clock-network insertion asymmetry between the launch and forwarded clocks.
Buying materially more margin than 58 ps requires changing something outside
the phase shift -- the I/O standard or drive on the TX pins, the PHY's own
RGMII delay configuration via MDIO, or the 1.2-2.0 ns window itself -- none of
which is a phase-shift decision.
