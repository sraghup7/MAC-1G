//----------------------------------------------------------------------------
// tb_gem_ddr_io -- functional simulation of the XILINX PRIMITIVE branches of
// gem_iddr / gem_oddr. Compiled WITHOUT GEM_BEHAVIORAL_IO into its own library,
// which no other simulation in this repository does: every scenario, loopback
// and unit testbench runs the plain-Verilog behavioural models, so the code
// path that synthesis actually builds was elaborated by out-of-context
// synthesis alone and never executed -- until this test.
//
// WHAT IT PINS DOWN, and why each half exists:
//
//   ODDR -- that SAME_EDGE presents D1 across the high phase and D2 across the
//   low phase of the cycle in which they were captured. This is the RGMII
//   transmit mapping in gem_rgmii_tx (low nibble + TX_EN rising, high nibble +
//   TX_EN^TX_ER falling), and getting it backwards produces a MAC whose clean
//   traffic is perfect and whose error signalling is garbage.
//
//   IDDR -- that SAME_EDGE_PIPELINED delivers Q1 = the value sampled at the
//   RISING edge and Q2 = the value sampled at the FALLING edge, one cycle
//   later. WHICH HALF LANDS ON Q1 under a real PHY is exactly what V-17 got
//   wrong: the mapping was carried over from the behavioural model, whose
//   phase convention is right for clock-aligned testbench launch and wrong
//   for a PHY that delays its receive clock. Every received octet would have
//   arrived nibble-swapped -- 0xD5 reading as 0x5D -- and nothing in
//   simulation could see it, because simulation ran the other branch.
//
// THE SKEW IS MODELLED, NOT OPTIONAL. The KSZ9031RNX adds ~1.2 ns to RX_CLK
// relative to RXD out of reset (B.1b), and the Q1/Q2 mapping is only defined
// relative to that delayed clock: the rising edge walks into the middle of
// the rise-launched nibble, so Q1 is the LOW nibble. A zero-skew loopback
// would assert the opposite pairing and be wrong about hardware. So this
// testbench launches data just after the edges of `clk` -- what the PHY does
// on its own clock -- and clocks the IDDR with a copy of `clk` delayed by
// SKEW, inside the datasheet's 1.0-2.0 ns window. The skew assumption the
// RTL comment derives from the datasheet is thereby executable: change
// either the derivation or this constant and the test says so.
//
// Self-contained by construction: it shares no package with the other
// testbenches because it compiles into a different library than they do.
// Output format matches gem_tb_pkg's PASS/FAIL lines so scripts/run_sim.py
// adjudicates it identically.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_gem_ddr_io;

    localparam real TCK       = 8.0;   // 125 MHz
    localparam real TCO_DATA  = 0.3;   // PHY-style launch delay after the edge
    localparam real SKEW      = 1.0;   // RX_CLK delay, inside TsetupR/TholdR

    logic clk = 1'b0;
    always #(TCK/2.0) clk = ~clk;

    // Delayed copy of the clock, as the FPGA receives RX_CLK from the PHY.
    logic clk_rx;
    assign #(SKEW) clk_rx = clk;

    int n_checks   = 0;
    int n_failures = 0;

    // THE GLOBAL SET/RESET WAIT, which is not optional. The unisim models hold
    // their outputs at INIT while glbl's GSR is asserted, and glbl releases
    // GSR one ROC_WIDTH (100 ns) after time zero -- twelve 125 MHz cycles of
    // dead time that look exactly like "the primitive never toggled" if the
    // test starts at t=0. Both test loops therefore wait for the release.
    logic roc_done = 1'b0;
    initial begin : wait_for_roc
        wait (glbl.GSR === 1'b0);
        #1;
        roc_done = 1'b1;
    end

    task automatic check(input logic got, input logic want, input string what);
        n_checks++;
        if (got !== want) begin
            n_failures++;
            $display("FAIL %s: got %b, expected %b (t=%0t)", what, got, want, $time);
        end
    endtask

    //------------------------------------------------------------------
    // ODDR: D1 across the high phase, D2 across the low phase, captured at
    // the posedge that begins that cycle.
    //------------------------------------------------------------------
    logic       o_dr, o_df, o_r, o_f;
    wire        o_q;

    gem_oddr u_oddr (.clk(clk), .d_rise(o_dr), .d_fall(o_df), .q(o_q));

    initial begin : oddr_test
        o_dr = 1'b0;
        o_df = 1'b0;

        wait (roc_done);
        #(TCK);

        for (int k = 0; k < 24; k++) begin
            // Deterministic pattern touching all four (rise,fall) combinations.
            o_r = logic'(k[0] ^ k[3]);
            o_f = logic'(k[1] ^ ~k[2]);

            // Present inputs mid-low-phase, comfortably ahead of the capturing
            // posedge -- how fabric drives an ODDR in the real design.
            @(negedge clk);
            #(TCK/8.0);
            o_dr = o_r;
            o_df = o_f;

            @(posedge clk);
            #(TCK*3.0/8.0);
            check(o_q, o_r, $sformatf("oddr high phase k=%0d", k));
            #(TCK/2.0);
            check(o_q, o_f, $sformatf("oddr low phase k=%0d", k));
        end
    end

    //------------------------------------------------------------------
    // IDDR: with the PHY's skew, Q1 samples the rise-launched half (the low
    // nibble) and Q2 the fall-launched half (the high nibble); both appear
    // together one rx_clk cycle later. This is the V-17 mapping, held in
    // place by a test rather than by a comment.
    //------------------------------------------------------------------
    logic i_d, i_r, i_f;
    wire  i_qr, i_qf;

    gem_iddr u_iddr (.clk(clk_rx), .d(i_d), .q_rise(i_qr), .q_fall(i_qf));

    initial begin : iddr_test
        i_d = 1'b0;

        wait (roc_done);

        for (int k = 0; k < 24; k++) begin
            i_r = logic'(k[1] ^ ~k[3]);
            i_f = logic'(k[0] ^ k[2]);

            // Launch like the PHY: each half shortly after its own edge of
            // the transmitting clock.
            @(posedge clk);
            #(TCO_DATA);
            i_d = i_r;
            @(negedge clk);
            #(TCO_DATA);
            i_d = i_f;

            // With SKEW on its clock, the IDDR's posedge lands TCO_DATA..TCK/2
            // after the rise launch -- inside the rise-launched half -- and
            // its negedge lands inside the fall-launched half. Both sampled
            // values emerge together at the following posedge_rx, one full
            // cycle after capture, which is why cycle k's pair is checked
            // here rather than mid-cycle.
            @(posedge clk);
            #(SKEW + TCK/8.0);
            check(i_qr, i_r, $sformatf("iddr q_rise (low nibble) k=%0d", k));
            check(i_qf, i_f, $sformatf("iddr q_fall (high nibble) k=%0d", k));
        end
    end

    initial begin : supervise
        wait (n_checks >= 96);
        #(TCK);
        if (n_failures == 0) begin
            $display("[gem_tb] PASS ddr_primitive_selftest: %0d checks, 0 failures",
                     n_checks);
        end else begin
            $display("[gem_tb] FAIL ddr_primitive_selftest: %0d checks, %0d failures",
                     n_checks, n_failures);
        end
        $finish;
    end

    // Watchdog: a wedged primitive (no output transitions) must fail loudly
    // rather than hang the regression. Generous against the ROC wait: the
    // checks themselves finish in a few hundred nanoseconds once GSR lifts.
    initial begin : watchdog
        #(TCK * 1000);
        $display("FAIL ddr_primitive_selftest: watchdog -- only %0d checks ran",
                 n_checks);
        $display("[gem_tb] FAIL ddr_primitive_selftest: %0d checks, %0d failures",
                 n_checks, n_failures + 1);
        $finish;
    end

endmodule
