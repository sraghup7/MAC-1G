# Task 4b report: the RX clock's BUFIO/BUFR path — BLOCKED

## Status: BLOCKED

The module is written, wired, placed and routed exactly as the brief describes,
and it does measurably what Task 4a predicted it would do. It is still not
enough, and the reason is a real correction to Task 4a's acceptance criterion
rather than a defect in this task's work.

| | Before (inferred BUFG, fanout 142) | After (`gem_rx_clkbuf`, BUFIO + BUFR) | Required |
|---|---|---|---|
| clock-vs-data skew **spread** | 2.746 ns | **1.759 ns** | < 1.761 ns |
| worst RX **hold** slack | −3.031 ns | **−1.559 ns** | ≥ 0 |
| worst RX **setup** slack | +2.004 ns | +1.518 ns | ≥ 0 |
| TX `WNS` | +0.058 ns | **+0.058 ns** | unchanged ✓ |
| gate 2 | refuses | **refuses** | passes |

**The falsifiable criterion is met — by about 2 ps — and the build still fails.**
That is the finding. Task 4a's criterion (`spread < 1.761 ns`) is exactly the
condition `setup_slack + hold_slack > 0`. It is necessary and it is not
sufficient, because it constrains only the **width** of the skew interval and
says nothing about **where that interval sits** — and the position is no more
movable by a constraint than the width is. Section "The correction to Task 4a's
criterion" below derives this. The short version: the allowed interval for this
design's own pin-to-IDDR clock-minus-data insertion delay is the *fixed*
`[−0.977, +0.784] ns`; BUFIO/BUFR narrowed the measured interval from
`[1.069, 3.815]` to `[0.584, 2.343]`, so it now fits but still sits 1.559 ns
too late.

Per the task's own stop condition, I stopped rather than reaching outside the
brief's scope for the fix that would close it (an MMCM/PLL deskew, quantified
below). **Nothing is committed.** The work is in the working tree, uncommitted,
alongside Task 4's `scripts/build.tcl` edit, which I did not touch.

---

## Step 1: the reference and the coding standard

`reference/verilog-ethernet/rtl/ssio_ddr_in.v`, `CLOCK_INPUT_STYLE == "BUFR"`
branch: `assign clk_int = input_clk;` then `BUFIO clk_bufio (.I(clk_int),
.O(clk_io));` and `BUFR #(.BUFR_DIVIDE("BYPASS")) clk_bufr (.I(clk_int),
.O(output_clk), .CE(1'b1), .CLR(1'b0));`. The two instantiations below are that,
port for port and parameter for parameter.

`coding_standard.md` "Vendor primitives": logic modules contain no vendor
primitives; the DDR cells live in `gem_oddr`/`gem_iddr` and the MMCM and its
BUFGs in `gem_mmcm`, "each with a Xilinx primitive and a plain-Verilog model
behind `GEM_BEHAVIORAL_IO`"; and "**the synthesisable path is the default**;
simulation and lint must ask for the model." `rtl/gem_rx_clkbuf.v` follows that
shape, and it is a fourth entry in the same list — every `BUFIO`/`BUFR`/`BUFG`
in this design is now in one of those four files.

---

## Step 2: `rtl/gem_rx_clkbuf.v` (new file, full text)

```verilog
//----------------------------------------------------------------------------
// gem_rx_clkbuf -- the RGMII receive clock, split into the two buffers a
// 7-series part needs to make RX capture meet hold across PVT.
//
// It exists as its own file for the reason gem_mmcm, gem_oddr and gem_iddr do:
// the coding standard keeps vendor primitives out of logic modules, so every
// BUFIO/BUFR/BUFG in this design lives in one of those four files. Same
// two-branch shape, same define, same direction of default:
//
//   default (no define)   BUFIO + BUFR. This is what synthesis,
//                         implementation and the bitstream use.
//   GEM_BEHAVIORAL_IO     both outputs are the input, a plain wire, for XSim
//                         and Verilator.
//
// WHY THIS MODULE EXISTS AT ALL -- the finding, not the fashion. Until Stage 6
// part 2, rgmii_rx_clk entered gem_mac as a raw port and every consumer in the
// rx_clk domain took it directly, so synthesis inferred one BUFG with 142-way
// fanout: the IDDRs, the deframer, the CRC, the FIFO write port and the five
// pulse synchronisers all hung off the same global net. That is a perfectly
// ordinary thing to write and it is wrong here, for a reason no simulation can
// show. task-4a-report.md measured the clock's insertion delay from pin K18 to
// the IDDR C pins on the routed design and found 1.490 ns at the fast corner
// and 5.210 ns at the slow one -- a 3.720 ns spread, of which 2.746 ns is
// uncompensated once the data path's own IBUF spread is subtracted. RGMII
// v2.0 guarantees a 2.000 ns receive eye. A capture edge that sweeps 2.746 ns
// across a 2.000 ns eye is not in the eye at both corners, whatever the
// constraint says, and task-4a-report.md proves algebraically that the sum of
// the setup and hold slacks is invariant under every choice of clock phase and
// input delay -- so no XDC edit can close it. The number to beat is a skew
// spread below 1.761 ns; task-4b-report.md records what this file achieved.
//
// WHAT THE SPLIT BUYS. BUFIO drives ILOGIC (the IDDRs) and nothing else -- it
// has no fabric fanout capability at all, which is exactly why its path is
// short and its spread small: it stays inside one clock region and never
// touches the global spine. BUFR drives the fabric in the same region. Both
// are fed from the same clock-capable pin, so their skew relative to each
// other is regional rather than chip-wide. The BUFG cell and its two long
// nets -- 2.418 ns of the old 2.746 ns spread -- disappear from the capture
// path entirely.
//
// THE PLACEMENT THIS DEPENDS ON, verified rather than assumed
// (task-4a-report.md): rgmii_rx_clk lands on K18, IO_L13P_T2_MRCC_15, so it
// is clock-capable and can reach a BUFIO/BUFR at all -- a plain IO pin cannot,
// and the tool's refusal in that case is a placer error late in the flow, not
// an elaboration error. All six RX I/O sites sit in clock region X0Y1
// (rgmii_rx_clk IOB_X0Y74, rgmii_rxd[0..3] IOB_X0Y73/52/57/78, rgmii_rx_ctl
// IOB_X0Y80), which is what makes one BUFIO able to reach every IDDR: a BUFIO
// drives only its own region's ILOGIC. If a future pinout moves any RX pin out
// of X0Y1 this module stops being buildable, loudly, which is the right
// failure mode.
//
// THE REFERENCE. reference/verilog-ethernet/rtl/ssio_ddr_in.v's
// CLOCK_INPUT_STYLE == "BUFR" branch is the same pattern, and the two
// instantiations below follow it: BUFIO to the DDR input cells, BUFR with
// BUFR_DIVIDE("BYPASS") to the logic, both from the same raw input net. That
// file is the third thing this project has taken from that reference, after
// V-17's IDDR nibble mapping and the SDC structure constrs/rgmii_timing.xdc
// is built on.
//
// WHAT THE BEHAVIOURAL BRANCH IS FOR, AND WHAT IT IS NOT. It is a wire.
// Simulation cannot see clock-network insertion delay at all -- there is no
// routed netlist to have one -- so a model of these buffers would model
// nothing and would only add a delta cycle for the RX domain to be skewed by
// against gem_clk_rst's reset synchroniser, which is a difference simulation
// would then have to reason about for no gain. No testbench changes, and no
// scenario's behaviour changes; if one did, that would be a defect here.
// This is the same warning gem_iddr's header carries about its own model: what
// is left for static timing and a scope stays there (open item V-2).
//
// WHAT IS DELIBERATELY *NOT* HERE. gem_top wires the raw rgmii_rx_clk pin
// separately into gem_clk_rst, whose reset synchroniser is the only thing
// outside gem_mac in this domain. That stays on its own inferred BUFG: it is
// two flops, it has no external timing relationship, and moving it here would
// mean this module's outputs had to leave gem_mac, which is an interface
// change for no timing gain.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rx_clkbuf (
    input  wire clk_in,     // the raw rgmii_rx_clk pin, unbuffered

    // The capture clock, and only that. It reaches the IDDR C pins in
    // gem_rgmii_rx and must reach nothing else: a BUFIO cannot drive fabric,
    // so anything else connected here is a build error rather than a slow
    // path.
    output wire clk_io,

    // Everything else in the rx_clk domain: the deframer, the RX CRC, the
    // FIFO write port, the pulse synchronisers.
    output wire clk_logic
);

`ifdef GEM_BEHAVIORAL_IO

    assign clk_io    = clk_in;
    assign clk_logic = clk_in;

`else

    BUFIO u_bufio (
        .I (clk_in),
        .O (clk_io)
    );

    // BYPASS, not a divide: this is the same 125 MHz clock, taking the
    // regional route instead of the global one. A BUFR that divides would be
    // a different clock and would need its own create_generated_clock.
    BUFR #(
        .BUFR_DIVIDE ("BYPASS")
    ) u_bufr (
        .I   (clk_in),
        .O   (clk_logic),
        .CE  (1'b1),
        .CLR (1'b0)
    );

`endif

endmodule
```

---

## Step 3: the `gem_mac.v` rewiring — which nets moved where

I re-derived the consumer list from the file rather than trusting the brief's.
`grep -n rgmii_rx_clk rtl/gem_mac.v` on the committed file gave **exactly ten**
references: the port declaration (line 88), a header mention (line 51), and
**eight** connections — the brief's list was exhaustive, and I confirmed it
rather than assumed it.

| Instance | Port | Was | Now |
|---|---|---|---|
| `u_rgmii_rx` (`gem_rgmii_rx`) | `.rx_clk` | `rgmii_rx_clk` | **`rx_clk_io`** (BUFIO) |
| `u_rx_ctrl` (`gem_rx_deframe`) | `.clk` | `rgmii_rx_clk` | `rx_clk_logic` (BUFR) |
| `u_rx_crc` (`gem_crc32`) | `.clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_rx_fifo` (`gem_rx_fifo`) | `.wr_clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_ev_rx_ok` (`gem_pulse_sync`) | `.src_clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_ev_rx_badfcs` | `.src_clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_ev_rx_runt` | `.src_clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_ev_rx_oversize` | `.src_clk` | `rgmii_rx_clk` | `rx_clk_logic` |
| `u_ev_rx_rxer` | `.src_clk` | `rgmii_rx_clk` | `rx_clk_logic` |

The raw `rgmii_rx_clk` port now appears exactly once below the port list, as
`u_rx_clkbuf`'s input. The new declarations and instantiation:

```verilog
    // THE RX CLOCK IS BUFFERED TWICE, ON PURPOSE. rgmii_rx_clk arrives as a
    // raw pin and used to fan straight out to everything below, which made
    // synthesis infer one BUFG carrying it 142 ways. That global path's
    // insertion delay varies by 3.720 ns between the fast and slow corners,
    // against a 2.000 ns receive eye -- so RX capture could not meet hold at
    // both corners regardless of the constraint, which task-4a-report.md
    // proves rather than asserts. gem_rx_clkbuf replaces the single BUFG with
    // a BUFIO for the capture cells and a BUFR for the rest of the domain;
    // its header carries the reasoning and task-4b-report.md the measurement.
    //
    // The split matters only if it is respected: rx_clk_io goes to the IDDRs
    // and nowhere else, rx_clk_logic goes everywhere else, and the raw
    // rgmii_rx_clk port is used nowhere below this point. A consumer left
    // accidentally on the raw pin would build, would pass a naive slack
    // check, and would put a third clock network under the same clock.
    wire rx_clk_io;         // BUFIO -- IDDR capture cells only
    wire rx_clk_logic;      // BUFR  -- the rest of the rx_clk domain

    gem_rx_clkbuf u_rx_clkbuf (
        .clk_in    (rgmii_rx_clk),
        .clk_io    (rx_clk_io),
        .clk_logic (rx_clk_logic)
    );
```

plus a line in the module header's structure list naming `u_rx_clkbuf` as "not
one of B.1a's nine".

**The external port list did not change.** `git diff rtl/gem_mac.v` contains no
added or removed `input wire`/`output wire` line. No testbench and no other RTL
file changed.

**The split was verified on the routed netlist, not assumed** (this is the
check that catches the "consumer left on the raw pin" and "outputs swapped"
mistakes the brief names):

```
u_mac/u_rx_clkbuf/u_bufio  net=u_mac/u_rx_clkbuf/clk_io     fanout=5    load ref types: IDDR
      u_mac/u_rgmii_rx/g_rxd[0].u_iddr/u_iddr/C
      u_mac/u_rgmii_rx/g_rxd[1].u_iddr/u_iddr/C
      u_mac/u_rgmii_rx/g_rxd[2].u_iddr/u_iddr/C
      u_mac/u_rgmii_rx/g_rxd[3].u_iddr/u_iddr/C
      u_mac/u_rgmii_rx/u_iddr_ctl/u_iddr/C
u_mac/u_rx_clkbuf/u_bufr   net=u_mac/u_rx_clkbuf/clk_logic  fanout=135  load ref types: FDCE FDPE FDRE SRL16E RAMD64E
rgmii_rx_clk_IBUF_BUFG_inst net=rgmii_rx_clk_IBUF_BUFG      fanout=2    load ref types: FDCE
      u_clk_rst/u_rx_rst/sync_reg[0]/C
      u_clk_rst/u_rx_rst/sync_reg[1]/C
```

5 + 135 + 2 = 142, the old BUFG's fanout, redistributed with nothing left
behind. The residual BUFG is `gem_top`'s separate wiring into `gem_clk_rst`,
which the brief says to leave alone — it now carries only the two reset-sync
flops.

Placement, read off the routed checkpoint: `BUFIO_X0Y5` and `BUFR_X0Y5`, in
clock region X0Y1 as Task 4a predicted, driving `ILOGIC_X0Y52` etc.

### One thing the brief did not name, that I checked because the change creates it

Leaving `gem_clk_rst` on its own BUFG means `rx_rst_n` is now launched on a
**BUFG**-clocked flop and captured by **BUFR**-clocked flops — a same-clock,
different-buffer crossing that did not exist before (everything was on one
BUFG). If the two buffers' insertion delays differ enough, that path can
violate hold, and it would be an entirely self-inflicted new failure. Measured
on the routed design:

```
setup  +2.518 ns   u_clk_rst/u_rx_rst/sync_reg[1]/C -> u_mac/u_rx_crc/crc_reg_reg[14]/PRE
hold   +1.185 ns   u_clk_rst/u_rx_rst/sync_reg[1]/C -> u_mac/u_rx_ctrl/out_valid_reg/CLR
```

Both comfortably positive; the crossing is fine. Worst `rx_clk`-internal
register-to-register hold is also positive (`+0.089 ns`,
`u_rx_fifo/wr_bin_reg[5]` → `mem_reg_0_63_9_9/DP/WADR5`). **Every failing path
in the design is one of the five RX input-capture paths and nothing else.**

---

## Step 4: Task 4a's constraint corrections, applied verbatim

`constrs/clocks.xdc` — the `create_clock` for `rgmii_rx_clk` now reads
`-waveform {1.200 5.200}`, with Task 4a's comment block above it, character for
character as its Step 2 gives them.

`constrs/rgmii_timing.xdc` — `-max 3.000 / -min -1.000` become
`-max 0.200 / -min -1.800` on all four `set_input_delay` lines, with Task 4a's
comment block above `create_clock -name rgmii_rx_clk_virt`. The four
`set_false_path` lines are unchanged, as Task 4a determined they should be. The
TX section was not touched.

Confirmed on the routed checkpoint (`report_clocks`):

```
rgmii_rx_clk       8.000  {1.200 5.200}   P     {rgmii_rx_clk}
rgmii_rx_clk_virt  8.000  {0.000 4.000}   V     {}
rgmii_gtx_clk_gen  8.000  {-1.222 2.778}  P,G   {rgmii_gtx_clk}
```

I did not re-derive any of it. Step 5's measurement does **not** disagree with
Task 4a's; it agrees to the picosecond where the two overlap (see "the
prediction" below).

---

## Step 5: measurement on the real build

`python scripts/build.py impl gem_top`, Task 4's `scripts/build.tcl` edit in
place and unmodified:

```
==> Critical-warning check: PASS (0 critical warnings)          <- gate 0
==> Latch check: PASS (0 inferred latches, 0 inference warnings) <- gate 1
==> WNS (setup) = 0.058 ns, WHS (hold) = -1.559 ns              <- gate 2
Build refused: negative hold slack (WHS = -1.559 ns).
impl FAILED (exit 1).
```

Gates 0 and 1 pass. Gate 2 refuses. Gate 3 not reached.

### Per RX port, both checks, individually

From the `build/post_route.dcp` that run wrote
(`get_timing_paths -from <port> -delay_type max|min`):

| Port | Setup | Hold | Sum | Task 4a's hold (BUFG) | Δhold |
|---|---|---|---|---|---|
| `rgmii_rxd[0]` | +1.530 ns | −1.524 ns | +0.006 | −3.001 | +1.477 |
| `rgmii_rxd[1]` | +1.557 ns | **−1.559 ns** (worst) | −0.002 | −3.031 | +1.472 |
| `rgmii_rxd[2]` | +1.536 ns | −1.538 ns | −0.002 | −3.011 | +1.473 |
| `rgmii_rxd[3]` | +1.526 ns | −1.521 ns | +0.005 | −2.996 | +1.475 |
| `rgmii_rx_ctl` | **+1.518 ns** (worst) | −1.516 ns | +0.002 | −2.987 | +1.471 |

Worst setup **+1.518 ns**, worst hold **−1.559 ns**. Every port improved by
1.47 ns on hold and lost 0.48 ns on setup — a uniform 0.99 ns of the deficit
recovered, structurally, on all five. Port-to-port spread is 39 ps on setup and
43 ps on hold, the same order Task 4a and Task 2c saw.

Note the **Sum** column: every port is now within 6 ps of zero. Task 4a showed
`setup + hold = 1.761 − spread`, so those sums *are* the spread measurement,
port by port: 1.755 / 1.763 / 1.763 / 1.756 / 1.759 ns. Three of five ports are
under the 1.761 ns bound and two are 2 ps over it. Call it 1.76 ns against a
1.761 ns budget — the criterion is met to within its own measurement noise, and
that is the most that can honestly be claimed for it.

### TX, confirmed unchanged

`WNS = +0.058 ns`, and the worst setup path is the same one Task 2e committed:

```
0.058  u_mac/u_rgmii_tx/g_txd[0].u_oddr/u_oddr/C -> rgmii_txd[0]   group rgmii_gtx_clk_gen
0.065  u_mac/u_rgmii_tx/g_txd[1].u_oddr/u_oddr/C -> rgmii_txd[1]
```

Identical to the picosecond. This task perturbed nothing on the TX side.

### The insertion-delay measurement, segment by segment

Read off the detailed reports for `rgmii_rxd[1]`, not from the summary slack:

| Segment | Fast corner | Slow corner | Spread |
|---|---|---|---|
| IBUF (K18) | 0.245 | 1.477 | 1.232 |
| net IBUF → BUFIO (fo=3) | 0.179 | 0.398 | 0.219 |
| **BUFIO cell** | **0.483** | **1.532** | **1.049** |
| net BUFIO → IDDR C (fo=5) | 0.098 | 0.330 | 0.232 |
| **total to IDDR C** | **1.005** | **3.738** | **2.733** |
| data IBUF → IDDR D, for comparison | 0.421 | 1.395 | 0.974 |
| **uncompensated (clock − data)** | **0.584** | **2.343** | **1.759** |

Against Task 4a's BUFG measurement (`1.490 / 5.210`, uncompensated spread
2.746 ns): the clock's own spread fell from 3.720 to 2.733 ns and the
uncompensated spread from 2.746 to **1.759 ns**.

**Task 4a's estimate of what BUFIO/BUFR would buy was optimistic, and it said
so.** Its concern 4 flagged the number as an estimate: it expected to remove
"the BUFG cell and both long nets (2.418 ns of the 2.746 ns spread)". The
actual saving is 0.99 ns, not 2.4. The BUFG cell's spread was only 0.070 ns to
begin with, and the BUFIO that replaces it contributes **1.049 ns** of its own
on this `-1L` part — it is now the single largest term in the budget. The two
nets did shrink (2.418 → 0.451 ns of spread), which is where the 0.99 ns came
from.

---

## The correction to Task 4a's criterion

This is the part that matters, and it is why the task is blocked rather than
merely short.

Substituting the constraint's own definitions back into Vivado's slack
expressions — `max_id = Δ − TsetupR`, `min_id = Δ − UI + TholdR`, with
`skew = Dclk − Ddat` the internal pin-to-IDDR insertion difference:

```
setup_slack = Δ + skew_fast − max_id − unc + tsu   =  TsetupR + skew_fast − unc + tsu
hold_slack  = min_id + UI − Δ − skew_slow − unc − thold = TholdR − skew_slow − unc − thold
```

Δ cancels from **both** — as does `max`, and `min`. So:

```
setup passes  iff  skew_fast >= −(TsetupR − unc + tsu)   = −0.977 ns
hold  passes  iff  skew_slow <=  (TholdR  − unc − thold) = +0.784 ns
```

The design must put its skew interval inside the **fixed** window
`[−0.977, +0.784]`, which is 1.761 ns wide. Two independent requirements: it
must **fit** (width < 1.761 ns, Task 4a's criterion) and it must **sit** inside.

```
BUFG:        [1.069, 3.815]  width 2.746   fails both  → hold −3.031
BUFIO/BUFR:  [0.584, 2.343]  width 1.759   fits, sits 1.559 too high → hold −1.559
```

Task 4a derived only the width condition, because it derived it from the
*sum* of the two slacks. The sum being positive is necessary for both halves to
be positive and is not sufficient; the sum is now ≈0, so even a perfectly
centred interval of this width would leave ~0 ns of margin on each side. Both
things are true at once: the criterion was met, and meeting it could not have
been enough.

Verified against the tool rather than asserted — predicting the two slacks from
the segment table *before* reading them off the report:

```
setup = 1.000 + 0.584 − 0.025 + 0.002 = +1.561   measured +1.557  (4 ps, display rounding)
hold  = 1.000 − 2.343 − 0.025 − 0.191 = −1.559   measured −1.559  (exact)
```

The model is the tool's model, on the new clocking as it was on the old.

### What would close it, quantified

The interval has to move down ~1.6 ns without widening past 1.761 ns.

* **IDELAYE2 on each RX data pin** (fixed mode; needs an `IDELAYCTRL` and a
  200 MHz reference this design does not have). Adding ~1.56 ns to the data
  moves the interval to `[−0.976, +0.783]` — inside by about **1 ps at each
  end**, because the width still consumes the whole budget. Not a fix. Note
  this also corrects Task 4a in the other direction: it dismissed a fixed
  IDELAY as "exactly like a phase change… one-for-one", but an IDELAY changes
  `skew` and a phase does not, so it is genuinely a different lever — just not
  a large enough one on its own.
* **An MMCM or PLL on `rgmii_rx_clk` with its output BUFG inside the feedback
  path** (Task 4a's option 2) cancels the network delay rather than tolerating
  it. The clock's insertion delay to the capture flops collapses to the input
  IBUF alone, giving a predicted interval of `[0.245−0.421, 1.477−1.395]` =
  `[−0.176, +0.082]`, **0.258 ns wide**, inside the window with ~0.8 ns of setup
  and ~0.7 ns of hold margin. This is the one with real headroom. It is an RTL
  change of a different size — a second MMCM on a clock that stops when the
  link drops, with lock-time, jitter and reset-policy questions this task has
  not answered, and it would likely make `gem_rx_clkbuf` redundant.

I did not build either. Both are outside this brief, and the brief says to
report rather than force a result.

---

## Step 6: the checked edge pairs are physically real

Read off `report_timing -input_pins` for `rgmii_rxd[1]`, both corners.

**Worst setup, slack +1.557 ns:**

```
Requirement:  1.200ns  (rgmii_rx_clk fall@5.200ns - rgmii_rx_clk_virt fall@4.000ns)
Input Delay:  0.200ns
Path Type:    Setup (Max at Fast Process Corner)
```

Launch is the virtual clock's fall at 4.000 (a nominal data transition);
capture is the real clock's fall at 5.200. The gap is **1.200 ns, the PHY's
delay** — the bit that changes when the PHY's undelayed clock falls is sampled
by the real clock's falling edge 1.2 ns later. A real capture event. The bound
`Input Delay: 0.200` is the corrected value, confirming no stale `-max` is
binding (Task 4a's contamination warning).

**Worst hold, slack −1.559 ns:**

```
Requirement: -2.800ns  (rgmii_rx_clk rise@1.200ns - rgmii_rx_clk_virt fall@4.000ns)
Input Delay: -1.800ns
Path Type:   Hold (Min at Slow Process Corner)
```

`−2.800 = 1.200 − 4.000` — the setup requirement less exactly one unit
interval. Vivado picked the other of the two equivalent representatives of the
same hold question this time (Task 4a's report showed
`fall@5.200 − rise@8.000`, also −2.800): the same relationship, expressed as
"capture one UI *before* the launch" rather than "launch one UI *after* the
capture". Either way the launch and capture edges are **one UI apart** and both
edges are real DDR capture events. Setup and hold are testing the same capture
event.

**And the clock path in both reports goes through the BUFIO**, which is the
wiring check a bare gate-2 result would not give:

```
K18            IBUF (Prop_ibuf_I_O)     0.245 / 1.477   rgmii_rx_clk_IBUF_inst/O
               net (fo=3, routed)       0.179 / 0.398   u_mac/u_rx_clkbuf/clk_in
BUFIO_X0Y5     BUFIO (Prop_bufio_I_O)   0.483 / 1.532   u_mac/u_rx_clkbuf/u_bufio/O
               net (fo=5, routed)       0.098 / 0.330   u_mac/u_rgmii_rx/g_rxd[1].u_iddr/clk_io
ILOGIC_X0Y52   IDDR                                     .../u_iddr/C
```

`fo=5` on the BUFIO output net and `fo=3` on the IBUF output net (BUFIO, BUFR,
and the reset-sync BUFG) are exactly the intended topology. No BUFG appears
anywhere in the capture clock path, and the outputs are not swapped — a
swapped pair would show `BUFR` in this trace and would have failed placement
anyway, since a BUFR cannot drive ILOGIC's clock the way this net does.

---

## Step 7: the derivation document and the two stale comments

### `Documents/RGMII I-O Timing Derivation.md`

The RX section is rewritten (was 26 lines, now ~144). It now contains:

* the phase, stated as the physical fact it encodes, with the `create_clock`
  line quoted;
* the derivation of `max = Δ − TsetupR_min = 0.200` and
  `min = Δ − (UI − TholdR_min) = −1.800`, from a single reference point;
* an explicit paragraph on what the old text got wrong — that
  `max = period/2 − Tsetup_min` and `min = −Thold_min` measure from *different*
  reference points, giving `max − min = 4.000 ns` and therefore a **declared eye
  of zero width**, and that it passed only because the zero-phase false-path
  structure put the two checks on capture edges 12 ns apart;
* the `skew_fast >= −0.977` / `skew_slow <= +0.784` derivation showing the
  phase and both delays cancel, so the requirement is on the design, not the
  constraint;
* the before/after skew-interval table and the segment-by-segment table above;
* the two candidate fixes with their predicted intervals, and why the IDELAY
  one is not a fix.

It states plainly that gate 2 still refuses. A derivation document that
recorded the fix as complete would be the same class of error as the one it is
correcting.

### `rtl/gem_rgmii_rx.v`

The "No IDELAY, and that is a decision rather than an omission" paragraph is
replaced. The new text keeps the half that is still correct (the PHY's 1.2 ns
delay leaves the RGMII window intact **at the pins**), names the half that was
missing (the FPGA's own pin-to-IDDR insertion delay, subtracted from the same
eye), cites `task-4a-report.md` for the measurement and the invariance proof
and `task-4b-report.md` for what the BUFIO/BUFR path achieved, and narrows the
standing claim to "no IDELAY *here*" with the two fallbacks named in order of
cost. It cites the prior reports by name rather than restating their numbers,
following `rtl/gem_mmcm.v`'s habit.

### `verification_plan.md`

**Which row I picked, and why.** I checked R9 and R21 first, as the brief
suggested. Neither fits: R9 is the FCS verdict and R21 the RX latency ceiling,
both **simulation** rows about logical behaviour, and this finding is invisible
to simulation by construction — filing it there would put a static-timing
result under a row whose evidence column is a testbench. The table's own
structure already separates those: **R13** carries "the pins' electrical timing
is V-2" and **R14** is the *clock/data skew mechanism* row, which is precisely
what this is — the receive-side counterpart of the transmit-side skew R14
documents. So:

* **new open item V-23** carries the substance (the finding, the measured
  before/after, the `[−0.977, +0.784]` window, what closes it, and an explicit
  statement that none of it is on `main`), placed next to V-2, which is its
  transmit-side sibling;
* **R14** gains a closing sentence saying the row is the TX half only and that
  the RX counterpart is not green, pointing at V-23;
* **R13** gains "…V-2 on the TX side and **V-23** on the RX side".

No row's status was changed to green. R14 stays green for what it actually
measures (TX), which is still true and still measured.

---

## Step 8: verification

* **`D:/Vivado/2024.2/gnuwin/bin/make.exe check` → 28 of 28 scenario(s)
  passed.** Run *after* the RTL change, which is the point: this task touches
  RTL for the first time in the chain. 8 per-module testbenches, 2 harness
  self-tests, 16 scenarios, 2 loopback scenarios, all PASS, with the same check
  counts as before. The `GEM_BEHAVIORAL_IO` branch of `gem_rx_clkbuf` is a pair
  of continuous assignments, so no scenario's behaviour can change, and none
  did.
* **`python scripts/lint.py` → clean, 7 tops, zero warnings (R22).** Run twice:
  after the wiring change and again after the comment edits (`gem_mmcm.v`'s
  header warns that a comment line beginning with the word "verilator" breaks
  the lint; neither new comment block does).
* **`python scripts/build.py impl gem_top` → gate 0 PASS, gate 1 PASS, gate 2
  REFUSES** (`WNS = 0.058`, `WHS = -1.559`). Gate 3 not reached.
* **`python scripts/build.py bitstream gem_top` → not run.** It cannot reach
  gate 3 or `write_bitstream` while gate 2 refuses; it would reproduce the same
  refusal more slowly. Instead I ran **`report_drc` directly on
  `build/post_route.dcp`**, which does answer the question that command would
  have answered about the new primitives: **zero DRC errors.** The only
  violations are pre-existing warnings unrelated to this change — `CFGBVS-1`,
  `PDRC-138` (a SLICE LUT-pair warning in `u_echo`), and 20 × `REQP-1840`
  (async control on `u_echo`'s RAMB18). Nothing about `BUFIO`, `BUFR`, clock
  region X0Y1 or the RX capture path.
* **No commit was made.** The bar in `CLAUDE.md` is that "verified" means the
  checks were run and passed; gate 2 does not pass.
* One Vivado batch invocation at a time throughout.

---

## Files changed (all uncommitted, in the working tree)

```
 Documents/RGMII I-O Timing Derivation.md | 148 ++++++++++++++++++++++-----
 constrs/clocks.xdc                       |  17 +++-
 constrs/rgmii_timing.xdc                 |  22 ++++-
 rtl/gem_mac.v                            |  46 ++++++--
 rtl/gem_rgmii_rx.v                       |  35 +++++--
 scripts/build.tcl                        |  41 +++------      <- TASK 4's, NOT MINE
 scripts/run_sim.py                       |   1 +
 verification_plan.md                     |   5 +-
 (untracked) rtl/gem_rx_clkbuf.v                              <- new
```

`scripts/build.tcl` is **untouched**: `git diff --numstat scripts/build.tcl`
reports `14 27`, byte-identical in shape to what Task 4's report recorded and
what Task 4a confirmed twice. I checked it before starting and again at the
end.

`scripts/run_sim.py` is a one-line addition (`"rtl/gem_rx_clkbuf.v"` in
`RTL_SOURCES`) that the brief did not name. It is required: `xvlog` takes an
explicit list, and without it `make check` cannot elaborate. `scripts/build.tcl`
and `scripts/synth_module.tcl` glob `rtl/*.v` and needed nothing;
`scripts/lint.py` finds modules by name under `-Irtl` and needed nothing.

`docs/` and `stage6_plan.md` remain untracked, pre-existing, untouched.

---

## Self-review

* **Did I confirm the consumer list myself rather than trust the brief?** Yes —
  by grepping the committed file (10 references, 8 of them connections) and
  then by reading the *routed netlist's* fanouts back (5 + 135 + 2 = 142, the
  old BUFG's exact fanout). The second check is the one that would have caught
  a consumer silently left on the raw pin.
* **Did I confirm the edge pairs rather than trust the slack?** Yes — Step 6,
  both corners, including the `Input Delay:` line (Task 4a's stale-`-min`
  contamination warning) and the full clock trace showing `BUFIO_X0Y5` in the
  capture path.
* **Did I predict before measuring?** Yes — `+1.561 / −1.559` predicted from
  the segment table, `+1.557 / −1.559` measured.
* **All five ports, both checks, individually?** Yes, on the real build, not
  generalised from one.
* **Did I check for damage the change could cause that the brief did not
  name?** Yes — the new BUFG→BUFR reset crossing (`+2.518` setup, `+1.185`
  hold) and the `rx_clk`-internal register-to-register worst hold (`+0.089`).
  Both positive. This was a real risk: splitting one clock net into three
  buffers under one `create_clock` creates intra-clock skew that did not exist
  before.
* **Did I resist reporting a pass?** This is the test the brief set, and it
  cut the other way from the obvious reading: the stated falsifiable criterion
  *was* met (1.759 < 1.761), and reporting DONE on that basis would have been
  defensible against the letter of the brief and wrong. Gate 2 refuses, on
  physically real edge pairs, on all five ports. I also did not reach for the
  MMCM that would close it, since that is a different design decision with
  consequences (lock time on a clock that stops with the link) nobody has
  signed off.
* **Did I touch the TX side, `scripts/build.tcl`, or `gem_mac`'s ports?** No,
  no, and no.
* **One Vivado at a time?** Yes, every invocation sequential.

---

## Concerns

1. **Task 4a's acceptance criterion was necessary but not sufficient, and this
   task is the evidence.** `spread < 1.761 ns` is exactly `setup + hold > 0`.
   Meeting it at the boundary means the best achievable margin is ~0 ns on each
   side, and the *position* of the skew interval — which no constraint moves
   either — is a second, independent requirement. Anyone picking this up should
   use the two-sided form: `skew_fast >= −0.977` **and**
   `skew_slow <= +0.784`, at both corners.
2. **The BUFIO's own corner spread (1.049 ns on this `-1L` part) is now the
   binding term**, and no amount of placement or wiring changes it. This is why
   the fix landed on the bound instead of under it, and it is a limit of the
   BUFIO/BUFR approach on this speed grade rather than of this implementation.
3. **The remaining fix is an MMCM/PLL deskew on a recovered clock, and it has
   real design consequences nobody has decided about**: `rgmii_rx_clk` stops
   when the link drops, so the MMCM loses lock and the whole `rx_clk` domain
   loses its clock; `gem_clk_rst`'s reset policy (which deliberately does *not*
   gate `rx_rst_n` on the existing MMCM's `LOCKED`, for exactly this reason —
   see its header) would need re-reading against that. That decision belongs to
   the project owner, not to this task.
4. **What to do with this working tree is a call for the user.** The BUFIO/BUFR
   module is correct, lint-clean, simulation-neutral (28/28), DRC-clean, and a
   1.47 ns measured improvement; the corrected XDC is Task 4a's verified text.
   Together they leave `impl`/`bitstream` failing at gate 2 — which is the
   honest state of the design and has been since Task 4 first wired the
   constraint in. Landing them makes the failure visible in the build instead
   of hidden in three report files; not landing them keeps `main` green on a
   check that was never actually checking. Task 4a raised the same question
   (its concern 3) and left it open. It is still open, and it is now a
   three-file decision rather than a two-file one.
5. **Task 4a's concern 2 stands unchanged.** Everything here rests on
   `TsetupR_min = TholdR_min = 1.0 ns` — Task 1's worst-case reading of B.1b,
   which A.2 already flags as a datasheet read online and not verified against
   the physical part. A more generous real window would shrink the deficit; it
   would take an eye of ~3.3 ns to make the current BUFIO/BUFR interval close,
   which RGMII v2.0 does not guarantee.
6. **`scripts/run_sim.py` needed a line the brief did not list.** Minor, but
   worth noting for whoever writes the next brief that adds an RTL file: three
   of the four source lists in this repo discover files automatically and the
   simulation one does not.
