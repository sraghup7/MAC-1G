# RGMII I/O timing derivation

Closes V-2's static half. Numbers sourced from `spec/PROJECT_SPEC.md` B.1b,
which cites the KSZ9031RNX datasheet (Microchip Rev 2.2) Table 19.

> **Correction (B.5 bring-up, 2026-08-27): the board's PHY is not a
> KSZ9031RNX.** It is a JLSemi JL2121(D) — confirmed by MDIO PHY-ID read
> against the JLSemi datasheet, not just marking-matching; see
> `spec/PROJECT_SPEC.md` A.2's B.5 correction. **Re-derived and confirmed by a
> real post-route build** in
> `docs/reports/stage9/rgmii-jl2121-retiming-report.md` — read that report
> before this one for the current numbers; what follows below this note is
> largely superseded, kept for its record of the KSZ9031RNX-era reasoning
> rather than edited in place. Headline results: `TsetupR_min`/`TholdR_min`
> turned out identical between the two chips (1.0 ns each), so the RX section
> below needed only its `Delta` term corrected (1.2 → 2.0 ns) and its deskew
> MMCM phase trim needed no change at all, confirmed by a post-route WNS
> matching task 4e's original measurement bit-for-bit. The TX section's
> mechanism changed entirely — the JL2121(D)'s TXDLY strap delays the clock
> internally at the PHY, not the FPGA — and the first attempt at the new
> phase shift (0 degrees) measured a real TX hold failure the datasheet alone
> did not predict; the retiming report has the swept, measured fix
> (`CLKOUT1_PHASE = +70.000`, not 0 and not the old `-55.000`).

## RX: rgmii_rxd[3:0], rgmii_rx_ctl, sampled by rgmii_rx_clk

*Rewritten after Stage 6 part 2. The version this replaces derived
`max = 3.000 / min = -1.000` at zero phase -- a constraint that declared a
zero-width data eye and checked edge pairs representing no capture event.
Task 4a found both defects; what stands below is the corrected derivation,
which `constrs/rgmii_timing.xdc` implements.*

**The phase relationship.** A virtual clock `rgmii_rx_clk_virt`, period
8.000 ns at phase 0, stands for the PHY's own undelayed reference -- its
edges are, by definition, the nominal data-transition instants. The real
`rgmii_rx_clk` arrives 1.2 ns later (KSZ9031RNX default RX_CLK delay, out of
reset, no MDIO write), so `constrs/clocks.xdc` declares it
`-waveform {1.200 5.200}`. The relative phase is the load-bearing quantity:
with it, Vivado checks the physically real capture event (launch and capture
one unit interval apart); without it, setup degenerates onto an edge 8 ns
out and both checks become meaningless -- measured in task-4a Step 5b.

**The input delays track the phase.** With Delta = 1.200 ns and the window's
worst-case bound TsetupR_min = TholdR_min = 1.0 ns:

```
max = Delta - TsetupR_min       = 1.200 - 1.000 = +0.200 ns
min = Delta - (UI - TholdR_min) = 1.200 - 3.000 = -1.800 ns
```

declared on both edges (`-clock` / `-clock_fall`), with four `set_false_path`
lines removing exactly the non-corresponding DDR edge pairs. The declared
transition uncertainty is then 2.000 ns per unit interval -- an eye of
exactly TsetupR_min + TholdR_min, the guarantee the datasheet actually gives.

**What captures, and where the margin comes from.** Since Stage 6 part 2 the
IDDR cells are clocked by the deskew MMCM's output
(`rtl/gem_rx_mmcm.v`), not by the raw pin: the feedback loop cancels the
clock network's delay, collapsing corner-to-corner insertion spread from
3.720 ns (raw BUFG, task-4a) to ~0.64 ns. The capture clock carries a static
**CLKOUT0_PHASE = -45 degrees (-1000 ps)** trim, centring the physical
capture interval inside the eye (task-4e: without it, slow-corner hold fails
by ~0.33 ns).

**Sign-off status -- read before trusting any slack number on these pins.**
Task 4e measured the routed feedback path against the compensation arc
Vivado applies and proved the STA model freezes this MMCM's capture-clock
arrival at a routing-independent constant: the five RX input-delay checks
report ~-3.1 ns of pure modeling artifact and can never go green honestly.
R20's RX half is therefore signed off by the loop-equation derivation --
predicted worst same-corner margin +0.669 ns after the trim -- plus bench
measurement at bring-up (`scripts/build.tcl` gate 2 waives exactly those
five endpoints under that documented basis and refuses everything else).
Full evidence chain: `docs/reports/stage6-part2/task-4e-report.md`.

## TX: rgmii_txd[3:0], rgmii_tx_ctl, rgmii_gtx_clk, launched by gtx_clk_shifted

rgmii_gtx_clk is a *generated* clock: gem_rgmii_tx.v's u_oddr_gtx forwards
gtx_clk_shifted (the MMCM's phase-shifted CLKOUT1, -55.000 deg / 1.2222 ns as
committed in Stage 6 part 2 -- see the history section below for the two values
that preceded it) straight to the pin through an ODDR. The output
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

Stage 6 part 1 arrived at -73.125 deg / 1.625 ns. Stage 6 part 2 measured it,
found it does not hold, and ultimately replaced it with the -55.000 deg /
1.2222 ns now in `rtl/gem_mmcm.v` and quoted above. This section is the record
of how, so a future reader does not have to reassemble it from five task
reports.

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

**The ceiling.** At the 1000 MHz VCO the design carried at the time, setup slack runs
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

### 6. What was committed, and what it measures (Task 2e)

`rtl/gem_mmcm.v` now carries the 1125 MHz VCO configuration from row 2 of the
table above:

| Parameter | Was | Is |
|---|---|---|
| `CLKFBOUT_MULT_F` | 20.000 | **22.500** |
| `DIVCLK_DIVIDE` | 1 | 1 (unchanged) |
| `CLKOUT0_DIVIDE_F` | 8.000 | **9.000** |
| `CLKOUT1_DIVIDE` | 8 | **9** |
| `CLKOUT1_PHASE` | -73.125 | **-55.000** |

VCO = 50 MHz x 22.500 / 1 = **1125 MHz**, inside the Artix-7 MMCM's
600-1200 MHz range. Both outputs stay at **125 MHz** (1125/9), so `tx_clk`,
`sys_clk` and `gtx_clk_shifted` are all exactly the frequency they were and
nothing downstream is affected -- only the VCO and the phase grid it implies
moved. The grid is now 45/9 = 5 deg, and -55.000 is 11 whole steps of it, so
the value is exactly achievable rather than rounded; `report_drc -checks
AVAL-139` is silent on the routed checkpoint with `CLKOUT1_USE_FINE_PS = 0`,
i.e. legitimately rather than because the check was switched off.

Measured post-route on the committed tree (`build/post_route.dcp` with
`constrs/rgmii_timing.xdc` applied), all five TX outputs:

| Port | Setup (`-max`) | Hold (`-min`) |
|---|---|---|
| `rgmii_txd[0]` | **+0.058 ns** | +1.660 ns |
| `rgmii_txd[1]` | +0.065 ns | +1.651 ns |
| `rgmii_txd[2]` | +0.072 ns | +1.645 ns |
| `rgmii_txd[3]` | +0.068 ns | +1.650 ns |
| `rgmii_tx_ctl` | +0.068 ns | +1.649 ns |

`report_clocks` on the same checkpoint shows `clk0_raw` at 8.000 ns
`{0.000 4.000}` and `clk1_raw` at 8.000 ns `{-1.222 2.778}` -- the frequency
preservation and the 1.2222 ns shift, both read off the tool rather than
asserted.

**Worst case is `rgmii_txd[0]` at +58 ps**, the same port and the same number
Task 2d measured for this configuration on its own build. Setup was previously
violated by -0.351 ns, so this is the check going from failing to passing. It
is also thin, and nothing here claims otherwise: 58 ps is well inside what a
real board's trace skew and a real PHY's input characteristics can move, and
the numbers above are Vivado's `-1L` speed model on a `7a35ti-fgg484`, not
silicon. The bench is still the final word, which is V-2's remaining half.

## If 58 ps proves insufficient on the bench

> **Correction (B.5 bring-up, 2026-08-27): this entire section describes a
> mechanism the physical board does not have.** It was written for the
> KSZ9031RNX's MMD `2h`/register `8h` pad-skew field, reached over MDIO. B.5
> found the board's actual PHY is a JLSemi JL2121(D) (`spec/PROJECT_SPEC.md`
> A.2's correction), whose datasheet
> (`DS009-JL2121(D)-v1.09-Preliminary`) has no MMD register-access chapter at
> all -- indirect access via Clause 22 registers 13/14 is a KSZ9031RNX
> mechanism, not a general one. What the JL2121(D) has instead: `RXDLY` (pin
> 25) and `TXDLY` (pin 24) are **hardware strap pins**, each adding a fixed 0
> or 2 ns to `RXC`/`TXC` respectively, sampled once at reset -- not written at
> runtime, not steppable, and not reachable from `gem_mdio.v`'s request port
> at all. **Both strap states are now known**, not a schematic unknown: the
> real AX7035B manual (`Manuals/AX7035B_UG.pdf` Table 8-1, obtained after
> this correction was first written) confirms `RXDLY` and `TXDLY` are both
> populated to add their 2 ns option. **The re-derivation is done** —
> `docs/reports/stage9/rgmii-jl2121-retiming-report.md` has it — and the
> number to beat is no longer 58 ps. The design now launches `GTX_CLK`
> advanced 1.5556 ns ahead of `tx_clk` (`rtl/gem_mmcm.v`, `CLKOUT1_PHASE =
> +70.000`) to cancel a measured FPGA-internal clock-forwarding asymmetry, not
> to hit the PHY's window directly, and clears TX setup by a measured
> **+336 ps** post-route — a real margin the KSZ9031RNX-era architecture never
> reached. If that proves insufficient on the bench, the fallback is still a
> board-level strap rework (no MDIO register exists on this chip, as above),
> not a phase-shift retune: the retiming report's swept table shows phase
> shift alone has already been pushed to its measured ceiling for this
> mechanism. The rest of this section is kept for its record of what was
> tried against the wrong chip and the wrong mechanism, not as a procedure to
> execute.

This is the fallback B.1b already names as R14's escape hatch. **It is
documented here, not implemented.** Nothing in the design drives it today, and
nothing should until a real shortfall has been measured on real hardware --
see "what is deliberately not built" at the end of this section.

**Step 1 -- measure the actual shortfall.** Scope or ILA on `GTX_CLK` and
`TXD0` at the PHY's pins, which is `bringup_checklist.md` B.5 step 5. What is
wanted is the real setup margin at the PHY, not the FPGA-side number above. If
it is positive with room, stop -- nothing below is needed.

**Step 2 -- convert the shortfall to steps.** The `GTX_CLK` pad-skew field
advertises 0.06 ns per step (B.1b), so the count is `ceil(shortfall_ns / 0.06)`
-- a 0.1 ns shortfall is 2 steps, 0.12 ns. Round up, never down: a step short
leaves the same failure with the fallback spent.

> **Confirm the step size and the field's usable range against the datasheet
> before computing anything.** B.1b's own numbers do not close arithmetically,
> and this document is not going to restate them as though they do. B.1b gives
> the `GTX_CLK` field as bits `[9:5]` -- five bits, 32 codes, so 31 steps of
> 0.06 ns is a 1.86 ns span -- but states the maximum as **+1.38 ns**, which is
> 23 steps. Worse, it gives the neighbouring `RX_CLK` field as bits `[4:0]`,
> also five bits, with a maximum of **2.58 ns**, which is 43 steps and does not
> fit in the field at all. At least one of {field width, step size, stated
> maximum} in B.1b is wrong, or the encoding is offset or signed in a way B.1b
> does not record. A.2 already flags the KSZ9031RNX datasheet as read online
> and unverified against the physical part. **Resolve this from the datasheet's
> own pad-skew table before writing a value.** Confirm the *direction* too:
> that increasing this field delays `GTX_CLK` relative to `TXD` rather than
> advancing it. Getting the sign wrong doubles the error instead of removing
> it, and nothing on the FPGA side of this project can detect that.

**Step 3 -- reach the register.** The pad-skew register is not in the Clause 22
address space. It is an MMD register (device `2h`, register `8h`, B.1b),
reached by indirect access through two standard Clause 22 registers:

| Clause 22 addr | Register name |
|---|---|
| **13** (`0x0D`) | MMD Access Control |
| **14** (`0x0E`) | MMD Access Address/Data |

**Those two addresses are confirmed** -- not from memory, and not from B.1b,
which does not mention them. They are IEEE Std 802.3-2022 Table 22-6, the
MII/GMII management register set, reproduced in this repository at
`Documents/IEEE802.3-2022_notes_for_1G_MAC.md:308-309`. Both are 5-bit Clause
22 addresses, so `gem_mdio.v`'s `req_regad` reaches them as-is.

The access is a four-transaction sequence: point register 13 at the MMD
register, then use register 14 as a data window onto it.

1. Write **13** with {function = *address*, device address = `2h`}.
2. Write **14** with `0x0008` -- the MMD register number, `8h`.
3. Write **13** with {function = *data, no post-increment*, device address =
   `2h`}. Register 14 is now a window onto MMD `2h` register `8h`.
4. Read **14** for the current value; modify bits `[9:5]` to the Step 2 count,
   leaving bits `[4:0]` (the `RX_CLK` skew) and every other bit exactly as
   read; write **14** back.

Read-modify-write in step 4 rather than a blind write, because the same
register holds the `RX_CLK` skew that B.1b relies on being left at its default.

> **What is NOT confirmed: the bit layout of register 13.** The two register
> *addresses* above are confirmed; the *contents* of register 13 are not. The
> IEEE extract in this repository gives Table 22-6's register names only, not
> their bit fields, and no KSZ9031RNX datasheet is in this repository. So the
> two braced fields in the sequence above are named by function and left
> unencoded on purpose. Before executing, confirm from the KSZ9031RNX
> datasheet's MDIO / MMD register-access section:
>
> - which bits of register 13 carry the function select, and which carry the
>   5-bit MMD device address;
> - the function-code values for "address" and for "data, no post-increment"
>   (there are post-increment variants that must *not* be used here, since this
>   sequence touches a single register);
> - that the KSZ9031RNX implements this convention rather than a vendor
>   variant, and what register `8h` reads as out of reset.
>
> A guessed encoding here does not fail loudly. It points the window at some
> other MMD register, and the write in step 4 lands somewhere unintended. This
> is the one part of the procedure with no in-repo source behind it, and it is
> called out rather than filled in with a plausible-looking number.

**Step 4 -- what would have to be built, and why it is not.** `gem_mdio.v`
already has the primitive this rides on: the R16 register-level request port,
`req_valid`/`req_ready`/`req_write`/`req_phyad`/`req_regad`/`req_wdata` with
`rsp_data`/`rsp_valid` coming back -- any register, read or write, on demand,
which is exactly the four transactions above. It is deliberately unconnected:
`rtl/gem_top.v:158-163` ties `mdio_req_valid` to `1'b0` and the rest to zero,
so nothing drives it today.

**Wiring something to it is a bring-up-time decision, not a committed part of
this design.** When the time comes the sensible shapes are a JTAG VIO driving
the request port, or a temporary RTL edit for the duration of the bring-up
session -- either way driven by a human who has just measured the shortfall on
a scope and can measure again afterwards.

**What is deliberately not built: an automatic power-on sequence.** The
tempting version of this is a small state machine that pokes the computed value
into MMD `2h`/`8h` every time the design leaves reset. That would be strictly
worse than the current state. The step size, the field's usable range and the
sign are all unconfirmed (see the two boxes above); the design has no way to
observe whether the write helped, hurt, or landed in the wrong register; and it
would apply on every boot, on every board, forever. A wrong constant here
degrades RGMII TX timing silently, with no gate in this project able to catch
it -- unlike the MMCM change above, which `make bitstream` and `report_timing`
check completely before any hardware exists. So the correction stays a
measured, human-gated bench action until there is a board to validate it
against (`MEMORY.md`: the AX7035B is not in hand).
