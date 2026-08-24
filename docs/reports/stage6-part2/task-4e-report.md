# Task 4e report: the half-cycle residue resolved -- Vivado's ZHOLD model,
# not routing; and a physical hold miss the trim fixes

## Status: ROOT CAUSE IDENTIFIED AND FIXED (CLKOUT0_PHASE = -45 deg)

Task 4d closed with an open question: the deskewed capture edge landed at
-1.452 ns relative to the declared waveform origin, the fb-minus-fwd residue
was 4.021 ns across two radically different buffer topologies, and nobody
could say whether that was silicon truth or tool fiction. This task measured
the routed feedback path directly and answered it. Both halves of the answer
matter: the -2.1 ns STA failure is a modeling artifact **and**, underneath it,
the physical design had a real slow-corner hold miss that no constraint could
have shown honestly.

Everything below was measured on the existing routed checkpoint
(`build/post_route.dcp`, the task-4d BUFH build) with read-only probes;
scratch scripts under `build/` (gitignored). The one RTL change this task
makes is `rtl/gem_rx_mmcm.v`'s `CLKOUT0_PHASE` 0 -> -45.000.

## 1. What the tool models vs what is routed

Direct probe of the feedback path (`report_timing` from CLKFBOUT to CLKFBIN,
both corners) against the compensation arc the timing engine applies:

| Quantity | Fast | Slow |
|---|---|---|
| Routed fb path: `clkfbout_raw` net + BUFH cell + `clkfb_buf` net | 0.936 | 1.974 |
| Tool's arc `Prop_mmcme2_adv_CLKIN1_CLKOUT0` | -2.703 | -6.062 |

The loop's fixed point (PFD drives until `t(CLKFBIN) = t(CLKIN)` at the
MMCM's pins) makes the physical input-to-output transfer exactly
`-fb_path`: the tool should subtract 0.936/1.974. It subtracts ~3x more, and
-- the damaging part -- applies a corner *spread* of 3.36 ns against the real
path's 1.04 ns, injecting ~2.3 ns of phantom spread into every RX check.

The arc is not derived from our route at all. Two proofs:

* **Topology invariance, explained.** Task 4d2's bit-identical slacks across
  BUFG and BUFH builds are now arithmetically necessary: the modeled DCD
  satisfies `DCD = IBUF+ccio + arc + fwd`, and comparing the two builds shows
  the arc moved by exactly minus the forward-route delta (-7.208 -> -6.062
  while fwd moved 3.187 -> 2.041). The product `IBUF+ccio + arc + fwd` is a
  constructed constant (-1.452 slow / -0.817 fast), not a measurement.
* **Manual clock declaration does not touch it.** Re-declaring the generated
  clock on CLKOUT0 by its own name (overwriting the auto-derived object) and
  re-reporting reproduced slack to the picosecond: the arc belongs to the
  primitive's ZHOLD timing model, not the clock definition.
* **COMPENSATION=EXTERNAL is illegal here.** Setting it on the cell is
  rejected outright: `[Timing 38-290] ... If the feedback loop goes outside
  the FPGA the property should be set to EXTERNAL. If the feedback loop is
  internal ... a value other than EXTERNAL.` Our loop is on-chip, so ZHOLD is
  forced and its constant comes with it.

UG906 ("MMCM/PLL Phase Shift Modes", Table 18 and around p.238-241) confirms
the negative insertion-delay arc is standard ZHOLD modeling. It cancels
harmlessly between two fabric registers, which is why every ordinary build
lives with it. It only corrupts **input interfaces**: there the launch edge is
the pin at zero latency while the capture edge carries the arc, so the
phantom lands straight in the skew.

## 2. The physical margin, from the loop's fixed point

With the arc replaced by the measured `-fb`, per corner. Two reference
frames, stated once and kept distinct: the capture edge lands at
**+2.150 ns (fast) / +3.836 ns (slow) after the data transition** --
equivalently **+0.950 / +2.636 ns after the pin's own nominal edge**
(the PHY's 1.200 ns delay):

```
after transition : pin_edge(1.200) + IBUF+ccio + fwd - fb
fast : 1.200 + 0.913 + 0.973 - 0.936 = +2.150 ns   (residual +0.950)
slow : 1.200 + 2.569 + 2.041 - 1.974 = +3.836 ns   (residual +2.636)
```

(fwd-fast 0.973 recovered from the tool's own DCD arithmetic on the routed
build; every other term read off the probe reports.)

Same-corner pairing throughout -- one die sits at one corner at a time, so
clock-slow-with-data-fast pessimism is not physical here. With data
insertion Ddat_f/s = 0.263/1.496 and the RGMII v2.0 window (TsetupR =
TholdR = 1.0 ns about the PHY's nominal 1.2 ns delayed edge), margins in
skew form -- skew = residual - Ddat, setup margin = 1.0 + skew + tsu,
hold margin = 1.0 - skew - thold:

```
skew_fast = 0.950 - 0.263 = +0.687     skew_slow = 2.636 - 1.496 = +1.140

setup:  fast 1.0 + 0.687 - 0.011 = +1.676   slow 1.0 + 1.140 - 0.011 = +2.129
hold :  fast 1.0 - 0.687 - 0.191 = +0.122   slow 1.0 - 1.140 - 0.191 = -0.331  FAILS
```

So underneath the artifact sat a genuine defect: **at slow corner the capture
edge lands ~0.33 ns too late** -- the next bit can replace the current one
before the IDDR samples it. An added shift s must satisfy

```
hold, slow : s <= -0.331          setup, fast : s >= -1.676
hold, fast : s <= +0.122          setup, slow : s >= -2.129
        =>  s in [-1.676, -0.331], centred near s = -1.0 ns
```

(The earlier session arithmetic that found "no static shift closes" was run
against the tool's phantom-widened interval, where the sum really is
negative. Physically the sum has ~1.2 ns of room.)

## 3. The fix: CLKOUT0_PHASE = -45.000

One parameter. -45 degrees on this VCO is exactly -1000 ps
(45/360 x 8000), a legal multiple of the 45/CLKOUT0_DIVIDE = 5 degree grid.
Predicted margins after trim, same formulae:

```
setup: fast +0.676, slow +1.129     hold: fast +1.122, slow +0.669
```

Worst case +0.669 ns before clock uncertainty (~0.15 ns), ~+0.5 after --
comfortable, and symmetric enough that bench fine-trim (111.1 ps steps, or
the KSZ9031RNX's MMD pad-skew registers, which move the eye without a
rebuild) has room in both directions.

STA will still show the RX checks red after the trim -- about 1 ns redder
than task 4d's numbers, since WAVEFORM-mode phase moves the modeled edge
too. That is expected and documented: R20's RX half is signed off by this
derivation plus bench measurement, and gate 2 in `scripts/build.tcl` now
encodes that split explicitly instead of refusing globally.

## 4. Falsified escapes (each tested, not assumed)

1. Manual generated-clock override -- arc persists (measured).
2. COMPENSATION=EXTERNAL -- rejected by the tool for on-chip loops (Timing
   38-290).
3. PHASESHIFT_MODE -- governs CLKOUT*_PHASE semantics (UG906 Table 18), not
   the ZHOLD insertion arc; does not bear on this failure.
4. Any input-delay value or virtual-clock reference -- shifts centering only,
   cannot remove the phantom spread (task 4a's invariant, still true).

## 5. Measured confirmation, and the fences proven

The post-trim build landed exactly on the derivation: **WNS = −3.109 ns**
against the predicted ≈ −3.11 (task-4d's −2.109 plus the −1.0 ns modeled
phase move), WHS +0.037 ns, and the gate partitioned precisely 5 waived
setup paths with no real violations. TX/fabric unaffected.

Both refusal fences were demonstrated before trusted, per the repository's
standard for gates:

* **Stale endpoint** — `g_rxd[0]` renamed to `g_rxd[9]` in the fence list:
  refused with "resolved to 4 pin(s), expected exactly 5". (First wiring
  attempt also caught reality: the generate block's netlist names are
  dot-separated — `g_rxd[0].u_iddr` — which is why the fence uses five exact
  names rather than a wildcard.)
* **Real violation outside the waiver** — TX output delay planted from
  2.000 to 6.000 ns: refused, all five violating paths named individually
  (`u_mac/u_rgmii_tx/... -> rgmii_txd[n] : −3.94 ns`). A harsher over-
  constraint (clk50 at 8 ns) additionally demonstrated the enumeration-cap
  refusal.
* **Envelope** — not demonstrated by plant; it is a two-line numeric
  comparison against a constant printed above, and the worst waived slack
  observed (−3.109) sits well inside it.

## 6. What survives / what changes

* The BUFH topology and pblock stay: nothing about the artifact implicates
  routing, and the physical spread argument is topology-independent for the
  input side.
* `rtl/gem_rx_mmcm.v`: CLKOUT0_PHASE 0 -> -45.000, header rewritten with the
  derivation. Behavioral sim model unchanged (it never modeled static phase;
  noted explicitly there now).
* Gate 2 split: refuses on any non-RX-I/O violation; reports the five RX
  input-delay paths against the waiver instead of counting them as failure.
  Demonstrated both ways before trusted (see commit message).
* Deferred, unchanged from task 4d: criterion A REF_JITTER rerun, D6/D7/D8.
