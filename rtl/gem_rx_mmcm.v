//----------------------------------------------------------------------------
// gem_rx_mmcm -- the recovered RGMII receive clock, deskewed.
//
// Documents/RX Clock Deskew Design.md is this module's specification; read it
// before changing anything here. The short version of why it exists:
//
// The IDDR cells capture RXD/RX_CTL on a clock network whose min/max
// insertion-delay spread (BUFG cell plus its two nets) measured 3.720 ns
// corner-to-corner on this part -- more than the entire 2.000 ns eye RGMII
// v2.0 guarantees (docs/reports/stage6-part2/task-4a-report.md). No phase,
// input-delay or buffering choice fixes that; the textbook BUFIO/BUFR answer
// was built and measured falling short too, on the BUFIO cell's own spread
// (task-4b-report.md). The one remaining lever is to cancel the clock-network
// delay instead of tolerating it, which is what a feedback path is for.
//
// TOPOLOGY (UG472 "Clock Network Deskew", Ch. 3, p.72/93; Figure 3-11):
//
//   CLKIN1   the raw rgmii_rx_clk pin. NO buffer between the port and here --
//            a BUFG-driven CLKIN is not compensated (p.89); the input IBUF's
//            delay stays in the budget either way.
//   CLKOUT0  through BUFG u_bufg_rx to clk_out: the whole rx_clk domain,
//            capture cells included. Exactly ONE forward buffer.
//   CLKFBOUT through BUFG u_bufg_fb back to CLKFBIN.
//
// Both buffers must be BUFG -- compensation is defined against the buffer type
// in the feedback path ("with the exception of BUFR. BUFR cannot be
// compensated for.", p.80), and BUFIO is not a legal CLKFBIN driver at all.
// The instance names u_bufg_rx / u_bufg_fb are load-bearing:
// constrs/rgmii_timing.xdc addresses the derived capture clock through them
// and refuses the build if that path goes stale.
//
// THE ARITHMETIC (DS181 Table 37, -1LI column):
//
//   PFD      = 125 MHz / DIVCLK_DIVIDE(1)  = 125 MHz   inside [10, 450] MHz
//   VCO      = 125 MHz x CLKFBOUT_MULT_F(9.000) = 1125 MHz, inside [600, 1200]
//   clk_out  = 1125 MHz / CLKOUT0_DIVIDE_F(9.000) = 125 MHz
//   CLKFBIN  = 1125 / 9 = 125 MHz = PFD, which is what Eq. 3-11 requires
//
// M = 9 rather than 8: higher VCO, lower output jitter, finer static-phase
// grid (111.1 ps against 125.0 ps), and it is the VCO gem_mmcm already runs,
// so a reviewer checking one configuration has checked the grid of both.
//
// CLKOUT0_PHASE'S -1000 ps TRIM COMPONENT IS A DERIVATION, NOT A DEFAULT
// (the whole parameter is -225.000: this trim, one unit interval back --
// see SECOND CORRECTION below, which is the part to read first) -- and
// it replaced an earlier 0.000 that was ALSO a derivation, honestly held and
// physically wrong. Task 4e (docs/reports/stage6-part2/task-4e-report.md)
// measured the routed feedback path on the real checkpoint and worked the
// loop's fixed point through per corner:
//
//   capture edge = pin edge + IBUF+ccio + fwd - fb
//     fast:  1.200 + 0.913 + 0.973 - 0.936 = +2.150 ns after the data transition
//     slow:  1.200 + 2.569 + 2.041 - 1.974 = +3.836 ns
//
// CORRECTION (B.5 bring-up, 2026-08-27): "1.200" above is the KSZ9031RNX's
// assumed default RX_CLK delay, and B.5 found the physical chip is a JLSemi
// JL2121(D) instead (spec/PROJECT_SPEC.md A.2's correction), whose RXDLY
// strap is confirmed populated for +2.000 ns, not 1.200 (Manuals/
// AX7035B_UG.pdf Table 8-1). Re-running task 4e's exact formula with 2.000 in
// place of 1.200 gives fast = 2.000+0.913+0.973-0.936 = +2.950 ns, slow =
// 2.000+2.569+2.041-1.974 = +4.636 ns after the data transition. Every SETUP
// AND HOLD margin is unchanged by that substitution, because this module's
// fb-vs-fwd arithmetic only depends on the FPGA's own clock-network insertion
// delay, not on what absolute delay the PHY chose: the "residual" relative to
// the PHY's own delayed edge (+0.950 fast / +2.636 slow, worked out below) is
// the same either way, and margins are computed from that residual.
//
// SECOND CORRECTION (B.5 bring-up, same day, from ILA evidence). THE MARGINS
// BEING INVARIANT IS NOT THE WHOLE QUESTION, AND TREATING IT AS THE WHOLE
// QUESTION IS WHAT LET A REAL DEFECT THROUGH. Margins are relative and did
// not move. WHICH NIBBLE the rising edge captures is ABSOLUTE -- it is the
// capture position modulo one 4.000 ns unit interval -- and 1.200 -> 2.000
// moved that by +0.800 ns. The corrected numbers, read after the -1000 ps
// trim below against the 4 ns nibble the edge has to stay inside:
//
//   fast   2.950 - 1.000 = +1.950 ns into the nibble, 2.050 ns of room left
//   slow   4.636 - 1.000 = +3.636 ns into the nibble, 0.364 ns of room left
//
// The slow corner sits 364 ps short of the next nibble's transition, where
// the KSZ-era numbers had 1.164 ns. The real board is past it. Six bring-up
// ILA captures across four protocols (gem_host, ARP, mDNS, IPv4/UDP) all show
// the pair (Q1, Q2) straddling an octet boundary -- Q1 holding one octet's
// high nibble and Q2 the NEXT octet's low nibble -- and all six decode
// byte-perfect once re-framed by one nibble. The rising edge is capturing one
// whole unit interval LATE.
//
// SO CLKOUT0_PHASE IS -225.000: -45.000 PULLED BACK BY ONE WHOLE UNIT
// INTERVAL (180 degrees = 4.000 ns at 125 MHz). Every setup/hold number below
// still stands exactly, and that is the reason for moving by a whole UI
// instead of re-deriving a centre: the edge lands at an identical position
// inside a nibble, just the preceding one. The captures measured zero bit
// errors across ~500 received octets at the present position, so that
// position is known-good and worth preserving rather than re-centring on
// paper. -225.000 is on this grid (45/9 = 5 degree steps) and inside the
// primitive's -360..+360 range. +135.000 is the SAME steady-state waveform,
// should the STA artifact below ever make the negative value awkward to gate;
// the negative one is written here because it matches the physical story --
// an edge arriving a unit interval late is pulled back, not pushed forward.
//
// DO NOT "FIX" A REPEAT OF THIS BY SWAPPING THE NIBBLE ORDER IN
// gem_rgmii_rx.v. Commit da81e24 tried exactly that. No ordering can repair a
// pair that straddles an octet boundary -- both {Q1,Q2} and {Q2,Q1} are then
// wrong -- and it failed the RX simulation, which that commit never re-ran.
//
// The input-side IBUF+route spread (~1.66 ns corner-to-corner) passes straight
// through a deskew loop -- only the fb-vs-fwd mismatch cancels -- so at slow
// corner the capture edge lands past the next bit's earliest arrival: hold
// fails by ~0.33 ns with the edge at 0 degrees. Shifting the output earlier by
// -1000 ps centres both checks: setup +0.68 (fast) / +1.13 (slow),
// hold +1.12 (fast) / +0.67 (slow) ns -- worst ~+0.5 after clock
// uncertainty, against the same-corner pairing: one die, one corner at a
// time. The step is legal on this grid: 45/9 = 5 degree steps.
//
// Vivado STA will still report RX input-delay violations after this trim, and
// by ~1 ns MORE than before: its ZHOLD model freezes the capture clock's
// arrival at a constant independent of the routed feedback path (task-4e).
// R20's RX half is signed off by this derivation plus bench measurement, not
// by WNS; scripts/build.tcl gate 2 encodes exactly that split. Fine trim on
// the bench moves in k x VCO_period/8 = 111.1 ps steps -- the JL2121(D) has
// no MDIO-programmable pad-skew register (the option named here before B.5
// assumed the KSZ9031RNX); its RX delay is the RXDLY strap above, fixed at
// board population -- and must remain an exact multiple of 5 degrees.
//
// STARTUP_WAIT IS "FALSE", AND THAT IS LOAD-BEARING. TRUE would hold the whole
// device out of startup until this MMCM locks -- and its input clock does not
// exist until a cable is plugged into a negotiating PHY. A board with no link
// would never come up at all.
//
// DO NOT SET CLOCK_DEDICATED_ROUTE FALSE ON ANY NET HERE. It silences the
// placer error a clock-capable-pin-to-MMCM path can raise by permitting the
// clock onto general interconnect, degrading exactly the insertion delay this
// module exists to control, invisibly to every gate. If the error appears, fix
// the placement or the pin, never the property.
//
// REF_JITTER1 = 0.010 is the primitive default, NOT a measurement: the
// JL2121(D)'s recovered-clock jitter is not a number this project has. The
// part's ceiling (DS181 MMCM_FINJITTER, "< 20% of period or 1 ns") is 0.125 UI
// at 8 ns. Acceptance criterion A in the design document requires the timing
// run at BOTH values; passing at 0.010 alone is an optimistic number built on
// an unverified input.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rx_mmcm (
    input  wire clk_in,     // the raw rgmii_rx_clk pin -- NO buffer before this
    input  wire rst,        // active high, asynchronous, from the clk50 supervisor
    output wire clk_out,    // 125 MHz, deskewed: the whole rx_clk domain
    output wire locked
);

`ifdef GEM_BEHAVIORAL_IO

    //------------------------------------------------------------------
    // Simulation model.
    //
    // WHAT IT REPRODUCES: clk_out is clk_in gated by locked; lock takes
    // LOCK_CYCLES of clk_in after rst releases AND the clock is running;
    // locked clears when rst asserts or when the input clock stops, detected
    // without needing a clk_in edge -- which is the property the reset
    // supervisor exists around, and the reason scenarios D3-D5 are not vacuous.
    //
    // WHAT IT DOES NOT REPRODUCE, in gem_mmcm's words because they apply
    // unchanged: this reproduces the *sequencing* and not the numbers. There
    // is no insertion delay in simulation for a deskew to cancel, so modelling
    // one would model nothing. Detection latency here is up to 80 ns against
    // the silicon's 8 ns (one PFD cycle, UG472 p.83); LOCK_CYCLES gives ~1 us
    // against MMCM_TLOCKMAX's 100 us; jitter, the static phase offset, the
    // CLKOUT0_PHASE = -225 degree (-1000 ps trim, one UI back) capture
    // placement and the
    // real deskew are absent entirely.
    //
    // Clock-stop detection is a time-based process sampling a toggle that
    // flips on every clk_in edge. It must not depend on clk_in edges -- a
    // stopped clock offers none -- and it has a non-zero delay of its own, so
    // there is no zero-delay simulation loop.
    //
    // (Note for the next person wrapping a comment here: a line whose text
    // starts with the word "verilator" is read as a metacomment, not as prose,
    // and the lint fails with "Unknown verilator comment". gem_mmcm's header
    // warned about this first.)
    //------------------------------------------------------------------

    localparam real CLKIN_WATCH_NS = 37.0;
    // Stop detection compares ELAPSED TIME SINCE THE LAST EDGE against the
    // window, not sampled toggle values: a state-comparison watchdog aliases
    // whenever its window is (or drifts across being) an integer number of
    // half-periods -- measured here as permanent "stopped" at exactly
    // 5 x 8 ns and intermittent re-asserts at 37 ns, each one clearing the
    // lock counter. Elapsed-time detection has no parity to alias: a running
    // 125 MHz clock gaps at most 8 ns between edges, far under the window,
    // and a stopped one trips it within about one window.
    localparam [7:0] LOCK_CYCLES = 8'd128;      // ~1 us at 125 MHz

    reg        clkin_seen = 1'b0;
    realtime   last_edge_ns = 0;
    reg        clk_stopped = 1'b1;

    always @(posedge clk_in or negedge clk_in) begin
        clkin_seen   <= 1'b1;
        last_edge_ns <= $realtime;
    end

    always begin
        #(CLKIN_WATCH_NS);
        clk_stopped <= !clkin_seen ||
                       (($realtime - last_edge_ns) > CLKIN_WATCH_NS);
    end

    reg [7:0] lock_cnt = 8'd0;

    always @(posedge clk_in or posedge clk_stopped or posedge rst) begin
        if (rst || clk_stopped) begin
            lock_cnt <= 8'd0;
        end else if (lock_cnt != LOCK_CYCLES) begin
            lock_cnt <= lock_cnt + 8'd1;
        end
    end

    // Combinational on purpose: locked must fall when the clock stops WITHOUT
    // waiting for a clk_in edge to carry the news -- there are no more edges.
    // Each term crosses its threshold once per event, so there is nothing here
    // to glitch into the asynchronous reset inputs it feeds.
    assign locked = !rst && !clk_stopped && (lock_cnt == LOCK_CYCLES);
    // clk_out tracks clk_in whenever rst is out and the clock runs -- NOT
    // gated on locked. Gating on locked makes the wire jump from 0 to
    // clk_in's current level the instant lock rises, a phantom first edge
    // whose phase is unrelated to the clock's own (measured: it desynchronised
    // the synchronous-deassert check by half a period). Safety before lock is
    // not this wire's job: UG472's "outputs should not be used prior to
    // LOCKED" is honoured by rx_rst_n being lock-gated upstream, so nothing
    // in the domain leaves reset until lock -- however many edges ran by.
    assign clk_out = (!rst && !clk_stopped) ? clk_in : 1'b0;

`else

    wire clkfbout_raw;
    wire clkfb_buf;
    wire clkout0_raw;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (8.000),     // 125 MHz recovered from the PHY
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (9.000),     // VCO = 1125 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (9.000),     // 125 MHz; phase -225 deg: see the header
        .CLKOUT0_PHASE      (-225.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .REF_JITTER1        (0.010),     // default, UNVERIFIED: criterion A runs 0.125 too
        .STARTUP_WAIT       ("FALSE")    // load-bearing: TRUE bricks a linkless board
    ) u_mmcm (
        .CLKIN1    (clk_in),
        .CLKFBIN   (clkfb_buf),
        .CLKFBOUT  (clkfbout_raw),
        .CLKFBOUTB (),
        .CLKOUT0   (clkout0_raw),
        .CLKOUT0B  (),
        .CLKOUT1   (),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .LOCKED    (locked),
        .PWRDWN    (1'b0),
        .RST       (rst)
    );

    // Regional buffers, one per path -- see Documents/RX Clock Deskew BUFH
    // Variant.md for why these are BUFH and not BUFG. Both live in the RX
    // clock region's horizontal row: short, structurally similar paths, so
    // the loop cancels a feedback network that actually resembles the forward
    // one -- which the BUFG variant's 7.2 ns spine trip did not.
    //
    // Names stay u_bufg_* despite the type: constrs/rgmii_timing.xdc anchors
    // the derived-clock lookup here and scripts/build.tcl's gate 1c keys off
    // exactly this path. Renaming buys nothing and breaks two gates.
    BUFH u_bufg_rx (.I (clkout0_raw),  .O (clk_out));
    BUFH u_bufg_fb (.I (clkfbout_raw), .O (clkfb_buf));

`endif

endmodule
