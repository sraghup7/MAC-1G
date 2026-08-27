# RGMII timing re-derivation for the JL2121(D): what changed, what didn't,
# and what a real post-route build proved wrong on the first attempt

B.5 bring-up found the board's PHY is a JLSemi JL2121(D), not the KSZ9031RNX
`spec/PROJECT_SPEC.md` A.2 previously stated (full account there). Every RGMII
timing number in this repository -- the RX deskew MMCM's phase trim, the RX
input-delay constraints, the TX phase shift, the TX output-delay constraints,
the `tb_gem_ddr_io.sv` skew model -- was derived against the wrong chip's
datasheet. This report re-derives them against the JL2121(D)'s own datasheet
(`DS009-JL2121(D)-v1.09-Preliminary`, Chapter 4.7) and the AX7035B's actual
strap configuration (`Manuals/AX7035B_UG.pdf` Table 8-1), and records what a
real Vivado post-route build confirmed and, in one place, disproved on first
attempt.

**Status: DONE.** RX re-derived and confirmed unchanged by measurement (below).
TX re-derived, the first attempt measured wrong, corrected, and confirmed by
measurement. All four constraint/RTL files updated. `make lint` clean.

## 0. What the board actually has, confirmed from the real manual

`Manuals/AX7035B_UG.pdf` Table 8-1 ("PHY芯片默认配置值" / PHY default
configuration values):

| Strap | Function | Value |
|---|---|---|
| RXD3_ADR0 / RXC_ADR1 / RXCTL_ADR2 | MDIO PHY address | **1** (binary 001) |
| RXD1_TXDLY | TX clock delay | **2 ns, enabled** |
| RXD0_RXDLY | RX clock delay | **2 ns, enabled** |

Cross-checked against the JL2121(D) datasheet's own Table 16 ("JL2121(D)
Hardware Config"): "RXDLY: RGMII rx clock delay setting. 1: add 2ns delay to
rgmii RX_CLK, 0: no delay" and "TXDLY: RGMII tx clock delay setting. 1: add
2ns delay to rgmii TX_CLK, 0: no delay" -- the same two facts, from the chip
vendor rather than the board vendor, agreeing exactly.

`rtl/gem_mdio.v`'s `PHY_ADDR` default was fixed to `5'd1` in the same bring-up
session this report's timing work followed; see that file's header and
`spec/PROJECT_SPEC.md` A.2 for the full identity correction.

## 1. RX: the window didn't move, only the label did

### 1a. What the JL2121(D) datasheet gives for RX

Chapter 4.7.4 ("RGMII Timing With Delay Integrated At Transmitter"), which is
the applicable table when the delay strap is engaged (Figure 6 there
explicitly tags the RX diagram `RXDLY=1 (Internal delay added)`):

| Parameter | Min | Typ | Description |
|---|---|---|---|
| TsetupR | 1.0 ns | 2 ns | Data to Clock Input Setup Time (at Receiver) |
| TholdR | 1.0 ns | 2 ns | Clock to Data Input Hold Time (at Receiver) |

`TsetupR_min = TholdR_min = 1.000 ns` -- **identical** to the figures
`Documents/RGMII I-O Timing Derivation.md` already used for the assumed
KSZ9031RNX, because both chips target the same underlying RGMII v2.0 receive
window. Only the PHY's own added delay (`Delta`) differs: **2.000 ns**
(the confirmed RXDLY strap), not the KSZ9031RNX's assumed **1.200 ns**
"typical, no MDIO write needed" default.

### 1b. The constraint values, re-derived

Following the existing method in `constrs/rgmii_timing.xdc` exactly (virtual
zero-delay reference clock, `UI = 4.000 ns` the RGMII DDR half-period):

```
max = Delta - TsetupR_min       = 2.000 - 1.000 =  1.000 ns   (was 0.200)
min = Delta - (UI - TholdR_min) = 2.000 - 3.000 = -1.000 ns   (was -1.800)
```

`max - min = 2.000 ns` unchanged -- the eye width is `TsetupR_min + TholdR_min`,
which didn't move. Only the phase term shifted by the same `+0.800 ns` that
`Delta` moved by (`2.000 - 1.200`), so `constrs/clocks.xdc`'s
`rgmii_rx_clk` waveform moved from `{1.200 5.200}` to `{2.000 6.000}` and
`constrs/rgmii_timing.xdc`'s RX `set_input_delay` values moved from
`0.200/-1.800` to `1.000/-1.000`.

### 1c. Why the deskew MMCM's phase trim (`rtl/gem_rx_mmcm.v`, `CLKOUT0_PHASE
= -45.000`) needed no change at all

This is the one place a real measurement (`docs/reports/stage6-part2/
task-4e-report.md`) had already been done, against the KSZ9031RNX's assumed
1.200 ns. Task 4e's own formula:

```
capture edge = pin edge + IBUF+ccio + fwd - fb
  fast:  1.200 + 0.913 + 0.973 - 0.936 = +2.150 ns after the data transition
  slow:  1.200 + 2.569 + 2.041 - 1.974 = +3.836 ns
```

`IBUF+ccio`, `fwd` and `fb` are FPGA-internal clock-network insertion delays
-- properties of this part's routing, not of the PHY. Substituting
`Delta = 2.000` in place of `1.200` moves the *absolute* capture-edge position
(`+2.950 ns` fast / `+4.636 ns` slow after the data transition) but **not**
the *residual* relative to the PHY's own delayed edge (`+0.950` fast /
`+2.636` slow either way, since only the reference point moved, not the
FPGA's own chain). Task 4e's margin arithmetic is expressed entirely in terms
of that residual (`skew = residual - Ddat`), so every downstream number --
setup/hold margins, the `-1000 ps` (`-45 deg`) trim that centres them -- comes
out **identical**, algebraically, before any build was run.

**Confirmed, not just argued.** A real synthesis + implementation of `gem_top`
with the corrected `constrs/clocks.xdc`/`constrs/rgmii_timing.xdc` (RXDLY =
2.000 ns) and `rtl/gem_rx_mmcm.v` unchanged (`CLKOUT0_PHASE` still `-45.000`)
reports **`Setup WNS = -3.109 ns`** post-route -- the exact figure task 4e
measured for the old 1.200 ns case ("Measured confirmation... WNS = −3.109 ns
against the predicted ≈ −3.11"). Same five endpoints, same known ZHOLD
modelling artifact (`docs/reports/stage6-part2/task-4e-report.md` §1),
`scripts/build.tcl` gate 2's waiver unchanged and still exactly matched. The
Vivado STA model does not know or care that `Delta` changed, because the
constraint that actually drives this number (`constrs/clocks.xdc`'s waveform)
was updated consistently with it.

## 2. TX: the mechanism moved from the FPGA to the PHY, and the first fix was
   measured wrong

### 2a. What the JL2121(D) datasheet says, and what it does not settle by
    itself

TXDLY = 1 (confirmed, §0): "add 2ns delay to rgmii TX_CLK". `TX_CLK`/`TXC` is
an **input** to the PHY (Table 1, Pin Assignments), so this is the PHY
delaying its own internal use of the clock it receives, before latching
`TXD` -- the industry-standard "RGMII-ID" convention essentially every RGMII
PHY implements this way for both directions (the same mechanism this project
already accepted for RX in §1, where Figure 6 tags it explicitly). It is not
a description of what the FPGA must drive.

The FPGA-side target is therefore Chapter 4.7.3 ("RGMII Timing", the table
*without* "...Delay Integrated At Transmitter" in its title): `TskewT`,
data-to-clock output skew at the launching device, **-500 to +500 ps** -- the
window for a device that does *not* generate the PHY-side delay itself,
because something downstream (here, TXDLY) does.

**What the datasheet does not settle:** how tightly the FPGA can actually hit
that ±500 ps window, given its own internal clock-network behaviour. That
required a real build.

### 2b. First attempt: `CLKOUT1_PHASE = 0.000` -- measured, and wrong

Reasoning: if TXDLY handles the PHY-side margin, launch `GTX_CLK` and
`TXD`/`TX_CTL` from the identical clock phase and TskewT is satisfied by
construction. Built and routed. Result: **TX hold failed, worst -1.278 ns**
(`rgmii_txd[2]`, and comparably on the other four TX outputs), flagged by
Vivado's own CDC-aware timing report as a `clk0_raw -> rgmii_gtx_clk_gen`
hold violation.

**Root cause, read off the routed report, not guessed:** `GTX_CLK` is itself
forwarded through its own `ODDR`+`OBUF` (`gem_rgmii_tx.v`'s `u_oddr_gtx`) to
reach its pin -- an *extra* IOB hop that `TXD`/`TX_CTL`'s own launch
*reference* clock does not carry, because a launching flip-flop's clock path
is measured only to its own clock pin, not forwarded any further. Measured,
same corner, same build:

```
Destination Clock Delay (GTX_CLK, pin-to-pin): 5.117 ns
Source Clock Delay      (TXD launch reference): 2.616 ns
```

A native ~1.1 ns lag of `GTX_CLK` behind `TXD`'s reference exists at zero
declared phase shift, purely from this structural asymmetry. `TskewT`'s
±500 ps window cannot absorb it on its own -- exactly the "0.264 ns
clock-network insertion asymmetry between the launch and forwarded clocks"
the pre-B.5 documentation already named as an irreducible TX deficit, just
much larger in isolation now that the old -55 deg shift (which happened to
also compensate for part of it, incidentally, while solving a different
problem) is gone.

### 2c. The fix: a phase shift sized to cancel the FPGA's own asymmetry, not
    the PHY's window

Setup and hold slack trade off perfectly linearly against `CLKOUT1_PHASE`:
swept post-route, `(setup slack) + (hold slack)` is constant at **~1.502 ns**
at every phase tried, which is exactly what a fixed-width timing budget being
redistributed between two checks should do. The sweep (all measured,
post-route, `xc7a35tifgg484-1L`):

| `CLKOUT1_PHASE` | TX setup slack (worst of 5) | TX hold slack (worst of 5) |
|---|---|---|
| 0.000 deg (0 ns) | +2.780 ns | **-1.278 ns (FAILS)** |
| +35.000 deg (0.778 ns) | **-0.442 ns (FAILS)** | +1.945 ns |
| +50.000 deg (1.111 ns) | **-0.109 ns (FAILS)** | +1.611 to +1.617 ns |
| +55.000 deg (1.222 ns) | +0.003 ns (MET, too thin to trust) | +1.500 ns |
| **+70.000 deg (1.5556 ns)** | **+0.336 ns** | **+1.167 ns** |

Positive phase *advances* `GTX_CLK` earlier on this MMCM -- the opposite sign
convention from the old `-55.000`, which *delayed* it; the sign followed
directly from measurement (0 deg failed hold in the direction that meant
`GTX_CLK` needed to arrive *earlier*, not later).

**+70.000 was chosen over the thinner +55.000 for margin**, not because it is
numerically cleaner. 3 ps of measured slack is not a value to build a board
bring-up on, per this project's own standing rule about thin margins
(`rtl/gem_mmcm.v`'s own history with the old -55 deg value makes the same
point). +70.000 is 14 whole steps of the `45/CLKOUT1_DIVIDE(9) = 5` degree
grid -- exactly achievable, `AVAL-139` silent legitimately rather than
switched off.

### 2d. Final confirmation build

Full `gem_top` synthesis + implementation with every corrected file (`rtl/
gem_mmcm.v` at `CLKOUT1_PHASE = 70.000`, `rtl/gem_rgmii_tx.v`, `rtl/
gem_rx_mmcm.v` unchanged, `constrs/clocks.xdc`, `constrs/rgmii_timing.xdc`),
reproduced bit-for-bit:

```
Setup WNS = -3.109 ns   TNS = -15.459 ns   5 / 4190 endpoints failing
Hold  WHS = +0.097 ns   THS =  0.000 ns

TX setup (rgmii_txd[0]->pin, Max):  slack +0.336 ns
TX hold  (rgmii_txd[2]->pin, Min):  slack +1.167 ns
RX setup (rgmii_rx_ctl->IDDR, the known artifact): slack -3.109 ns, waived
```

The five failing endpoints are exactly the five RX `IDDR` inputs
`scripts/build.tcl` gate 2 already waives on task 4e's documented basis (§1c
above); nothing else in the design regressed. `make lint` (Verilator,
zero warnings) is clean on the corrected RTL.

## 3. What still isn't done

- **`Documents/RGMII I-O Timing Derivation.md`'s TX decision-history table**
  (the `-72.000`/`-73.125`/`-55.000` sweep against the assumed KSZ9031RNX
  window) is kept as the historical record of that sub-project; it is not
  the live derivation any more, and both that file and `rtl/gem_mmcm.v`'s
  header say so.
- **The PHY reset hold time (`tSR`, ≥10 ms) and the exact TX/RX duty-cycle
  and rise/fall figures** are still KSZ9031RNX-sourced in places; §1/§2 above
  only re-derive `TsetupT`/`TholdT`/`TsetupR`/`TholdR` and the strap delays,
  because those are the numbers this project's constraints actually consume.
  A full read of the JL2121(D)'s remaining AC specification rows against
  every other B.1b claim has not been done.
- **This is still simulation and static-timing derivation, not the board.**
  R14/R20/V-2 remain bench items exactly as before -- the derivation and the
  Vivado measurement above are the static half this project's own convention
  (`docs/reports/stage9/known-issues.md`) requires signing off before bring-up
  step 5, not a replacement for it.
