//----------------------------------------------------------------------------
// tb_gem_clk_rst -- the clock/reset block against the four promises B.1b makes
// about it.
//
// This module has no data path, so there is nothing for the scenario
// regression to compare and no golden model to compare it against. What it has
// instead is a small set of properties that are either true or catastrophic,
// and each of them fails in a way that would be blamed on something else:
//
//   1. RESET ASSERTS WITH NO CLOCK RUNNING. Asserting the board reset stops the
//      MMCM, which stops tx_clk -- so a reset that needed a tx_clk edge to take
//      effect would never take effect at all. Checked by pulling ext_rst_n low
//      deliberately between two tx_clk edges and confirming tx_rst_n drops with
//      no edge in between.
//
//   2. RESET RELEASES ON AN EDGE, NOT BETWEEN THEM. The other half of B.1b's
//      "asynchronous assert, synchronous deassert": every release is checked to
//      land exactly on its own domain's clock edge. A release that drifts off
//      the edge is a recovery/removal violation, which fails intermittently on
//      hardware and never in simulation.
//
//   3. tx_rst_n NEVER RELEASES ONTO AN UNLOCKED MMCM. Policed on every tx_clk
//      edge for the whole run rather than sampled once, because the window this
//      protects is a transient: during acquisition the output is not a 125 MHz
//      clock, it is whatever the VCO is doing on the way there.
//
//   4. rx_rst_n DOES NOT DEPEND ON THE MMCM. B.1b's rule that no domain's reset
//      release depends on another domain's clock. The test starts rx_clk while
//      the MMCM is still acquiring and requires rx_rst_n to be released before
//      LOCKED arrives -- so a stray `& mmcm_locked` in the rx chain, which
//      would look harmless and pass every other test, fails here. It also
//      starts rx_clk late, because on hardware the PHY is not driving RX_CLK
//      when the FPGA comes out of configuration.
//
// And the PHY's reset hold, which is a number rather than a property: >= 10 ms
// (KSZ9031RNX tSR). The sequencing is checked with a short override -- 50
// cycles instead of 500,000 -- and the real number is checked separately
// against the datasheet minimum, at elaboration, on an instance that never
// runs. Simulating 10 ms to watch a counter count is not evidence anyone needs,
// but "the default is long enough" is, and it is the half that would be wrong
// after somebody edits the parameter header.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_clk_rst;

    import gem_tb_pkg::*;

    // Short enough to simulate, long enough that the reset synchroniser's two
    // stages are not a rounding error on it.
    localparam int PHY_RST_TEST_CYCLES = 50;

    // The datasheet minimum, written here as a duration rather than as a cycle
    // count, so this check does not restate the RTL's arithmetic back at it.
    // KSZ9031RNX tSR: RST_N low >= 10 ms after the supplies are stable.
    localparam real PHY_TSR_MIN_NS = 10_000_000.0;

    localparam real CLK50_HALF_NS = 10.0;   // 50 MHz
    localparam real RXCLK_HALF_NS = 4.0;    // 125 MHz, from the PHY's CDR

    logic clk50      = 1'b0;
    logic rx_clk     = 1'b0;
    logic ext_rst_n  = 1'b0;
    logic rx_clk_run = 1'b0;   // the PHY is not driving RX_CLK yet

    wire tx_clk, gtx_clk_shifted, tx_rst_n, rx_rst_n, mmcm_locked, phy_rst_n;

    gem_clk_rst #(
        .PHY_RST_CYCLES (PHY_RST_TEST_CYCLES)
    ) u_dut (
        .clk50           (clk50),
        .ext_rst_n       (ext_rst_n),
        .rx_clk          (rx_clk),
        .tx_clk          (tx_clk),
        .gtx_clk_shifted (gtx_clk_shifted),
        .tx_rst_n        (tx_rst_n),
        .rx_rst_n        (rx_rst_n),
        .mmcm_locked     (mmcm_locked),
        .phy_rst_n       (phy_rst_n)
    );

    // A second instance carrying the real PHY_RST_CYCLES, held in reset for the
    // whole simulation so it costs nothing to have. It exists to be read, not
    // to run: check 5 asks what the default parameter would actually do.
    wire d_tx_clk, d_gtx_clk, d_tx_rst_n, d_rx_rst_n, d_locked, d_phy_rst_n;

    gem_clk_rst u_dut_default (
        .clk50           (clk50),
        .ext_rst_n       (1'b0),
        .rx_clk          (1'b0),
        .tx_clk          (d_tx_clk),
        .gtx_clk_shifted (d_gtx_clk),
        .tx_rst_n        (d_tx_rst_n),
        .rx_rst_n        (d_rx_rst_n),
        .mmcm_locked     (d_locked),
        .phy_rst_n       (d_phy_rst_n)
    );

    always #(CLK50_HALF_NS * 1ns) clk50 = ~clk50;
    always #(RXCLK_HALF_NS * 1ns) rx_clk = rx_clk_run ? ~rx_clk : 1'b0;

    //----------------------------------------------------------------------
    // Edge bookkeeping, so the checks can talk about "with no clock edge in
    // between" and "exactly on an edge" rather than about approximate times.
    //----------------------------------------------------------------------
    int  tx_edges = 0;
    int  clk50_edges = 0;
    real last_tx_edge_ns = -1.0;
    real last_rx_edge_ns = -1.0;

    always @(posedge tx_clk) begin
        tx_edges++;
        last_tx_edge_ns = $realtime;
    end

    always @(posedge rx_clk) begin
        last_rx_edge_ns = $realtime;
    end

    always @(posedge clk50) begin
        clk50_edges++;
    end

    // When phy_rst_n actually rose, recorded where it happens rather than
    // measured by a `wait` in the main sequence. The first version of this test
    // did it the other way and reported a 50-cycle hold as 132, because by the
    // time the sequence had finished checking the MMCM and got round to
    // looking, the signal had been up for eighty cycles. A test that measures
    // when it looked instead of when the event happened will pass a design that
    // holds reset for any duration at all.
    int phy_rise_edges = -1;

    always @(posedge phy_rst_n) begin
        phy_rise_edges = clk50_edges;
    end

    //----------------------------------------------------------------------
    // Property 3, as a continuous invariant rather than a sample.
    //----------------------------------------------------------------------
    always @(posedge tx_clk) begin
        note_check();
        if (tx_rst_n && !mmcm_locked) begin
            report_fail("gem_clk_rst",
                "tx_rst_n is released while the MMCM reports unlocked -- logic is running on an unlocked clock");
        end
    end

    //----------------------------------------------------------------------
    // Property 2: every release lands on its own domain's edge.
    //----------------------------------------------------------------------
    bit rx_released_before_lock = 1'b0;

    always @(posedge tx_rst_n) begin
        note_check();
        if ($realtime != last_tx_edge_ns) begin
            report_fail("gem_clk_rst", $sformatf(
                "tx_rst_n released at %0t, which is not a tx_clk edge (last edge %0t) -- deassert is not synchronous",
                $realtime, last_tx_edge_ns));
        end
        note_check();
        if (!mmcm_locked) begin
            report_fail("gem_clk_rst", "tx_rst_n released before LOCKED");
        end
    end

    always @(posedge rx_rst_n) begin
        note_check();
        if ($realtime != last_rx_edge_ns) begin
            report_fail("gem_clk_rst", $sformatf(
                "rx_rst_n released at %0t, which is not an rx_clk edge (last edge %0t)",
                $realtime, last_rx_edge_ns));
        end
        if (!mmcm_locked) begin
            rx_released_before_lock = 1'b1;
        end
    end

    //----------------------------------------------------------------------
    // The run
    //----------------------------------------------------------------------
    int  edges_at_release;
    int  phy_hold_cycles;
    int  tx_edges_before;
    real default_hold_ns;
    bit  ok;

    initial begin
        begin_scenario("gem_clk_rst");

        //--------------------------------------------------------------
        // 1. Held in reset: nothing is released, and rx_clk is not even
        //    running -- which is the state the board is actually in between
        //    configuration and the PHY coming alive.
        //--------------------------------------------------------------
        repeat (4) @(posedge clk50);

        note_check();
        if (tx_rst_n !== 1'b0 || rx_rst_n !== 1'b0 || phy_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "with ext_rst_n low: tx_rst_n=%b rx_rst_n=%b phy_rst_n=%b, expected all low",
                tx_rst_n, rx_rst_n, phy_rst_n));
        end

        note_check();
        if (mmcm_locked !== 1'b0) begin
            report_fail("gem_clk_rst", "the MMCM claims lock while held in reset");
        end

        //--------------------------------------------------------------
        // 2. Release. rx_clk starts here too -- deliberately during MMCM
        //    acquisition, so that property 4 has something to prove.
        //--------------------------------------------------------------
        @(posedge clk50);
        phy_rise_edges = -1;
        ext_rst_n  = 1'b1;
        rx_clk_run = 1'b1;
        edges_at_release = clk50_edges;

        // rx_rst_n must be out long before LOCKED: two rx_clk edges against
        // the model's 128 clk50 cycles of acquisition.
        wait (rx_rst_n === 1'b1);

        note_check();
        if (mmcm_locked === 1'b1) begin
            report_fail("gem_clk_rst",
                "the MMCM locked before rx_rst_n released, so this run cannot prove rx reset is independent of it");
        end

        wait (mmcm_locked === 1'b1);

        note_check();
        if (!rx_released_before_lock) begin
            report_fail("gem_clk_rst",
                "rx_rst_n was not released until LOCKED arrived -- the rx domain's reset depends on the MMCM (B.1b forbids it)");
        end

        // tx_rst_n follows lock within the synchroniser's depth, plus slack
        // for the edge the release lands on.
        repeat (8) @(posedge tx_clk);

        note_check();
        if (tx_rst_n !== 1'b1) begin
            report_fail("gem_clk_rst",
                "tx_rst_n is still asserted 8 cycles after LOCKED");
        end

        //--------------------------------------------------------------
        // 3. The PHY's reset hold, counted in clk50 cycles from the board
        //    reset releasing. Checked as ">= what was asked for, and not
        //    dramatically more" rather than as an exact edge count: the
        //    requirement is a minimum hold, and an exact count would just be
        //    the RTL's own arithmetic written twice, failing whenever the
        //    synchroniser depth changes for unrelated reasons.
        //--------------------------------------------------------------
        wait (phy_rise_edges >= 0);
        phy_hold_cycles = phy_rise_edges - edges_at_release;

        note_check();
        if (phy_hold_cycles < PHY_RST_TEST_CYCLES) begin
            report_fail("gem_clk_rst", $sformatf(
                "phy_rst_n released after %0d clk50 cycles, short of the %0d asked for",
                phy_hold_cycles, PHY_RST_TEST_CYCLES));
        end

        note_check();
        if (phy_hold_cycles > PHY_RST_TEST_CYCLES + 4) begin
            report_fail("gem_clk_rst", $sformatf(
                "phy_rst_n released after %0d clk50 cycles against %0d asked for -- more than the synchroniser can account for",
                phy_hold_cycles, PHY_RST_TEST_CYCLES));
        end

        // It rises once and stays up. A counter that wrapped instead of
        // stopping would re-assert the PHY's reset periodically, which
        // presents as a link that negotiates and then dies.
        repeat (PHY_RST_TEST_CYCLES * 10) @(posedge clk50);

        note_check();
        if (phy_rst_n !== 1'b1) begin
            report_fail("gem_clk_rst",
                "phy_rst_n went back down without a board reset -- the hold counter wraps instead of stopping");
        end

        //--------------------------------------------------------------
        // 4. Assert reset with no clock edge available to carry it.
        //
        //    The offset is deliberate: 1.3 ns after a tx_clk edge is 6.7 ns
        //    before the next one would have been, and asserting the MMCM's
        //    reset stops tx_clk entirely, so no next edge arrives at all. A
        //    reset that needed one would never assert.
        //--------------------------------------------------------------
        @(posedge tx_clk);
        #1.3ns;
        tx_edges_before = tx_edges;
        ext_rst_n = 1'b0;
        #0.1ns;

        note_check();
        if (tx_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst",
                "tx_rst_n did not assert without a clock edge -- the assert path is synchronous, which cannot work with the MMCM in reset");
        end

        note_check();
        if (tx_edges != tx_edges_before) begin
            report_fail("gem_clk_rst", $sformatf(
                "%0d tx_clk edge(s) arrived during the asynchronous-assert check, so it proved nothing",
                tx_edges - tx_edges_before));
        end

        note_check();
        if (rx_rst_n !== 1'b0 || phy_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "after asserting ext_rst_n: rx_rst_n=%b phy_rst_n=%b, expected both low",
                rx_rst_n, phy_rst_n));
        end

        //--------------------------------------------------------------
        // 5. Release a second time: the PHY hold has to run again from the
        //    start, not stay released because it once was.
        //--------------------------------------------------------------
        @(posedge clk50);
        phy_rise_edges = -1;
        ext_rst_n = 1'b1;
        edges_at_release = clk50_edges;

        wait (phy_rise_edges >= 0);
        phy_hold_cycles = phy_rise_edges - edges_at_release;

        note_check();
        if (phy_hold_cycles < PHY_RST_TEST_CYCLES) begin
            report_fail("gem_clk_rst", $sformatf(
                "on the second reset phy_rst_n was held only %0d cycles -- the hold does not restart",
                phy_hold_cycles));
        end

        //--------------------------------------------------------------
        // 6. The number that ships. Everything above ran with a 50-cycle
        //    override; this is the only check that looks at the real one, and
        //    it states the datasheet's requirement as a duration so that
        //    editing GEM_PHY_RESET_HOLD_US down to something plausible-looking
        //    fails here rather than on a bench weeks later.
        //--------------------------------------------------------------
        default_hold_ns = u_dut_default.PHY_RST_CYCLES * (2.0 * CLK50_HALF_NS);

        note_check();
        if (default_hold_ns < PHY_TSR_MIN_NS) begin
            report_fail("gem_clk_rst", $sformatf(
                "the default PHY reset hold is %0.3f ms, short of the KSZ9031RNX's 10 ms tSR",
                default_hold_ns / 1_000_000.0));
        end

        // ... and that this testbench's own clk50 is the frequency the RTL
        // derived that count from. Without this the check above is only as
        // good as an assumption made in two files.
        note_check();
        if ((1_000_000_000.0 / (2.0 * CLK50_HALF_NS)) != real'(`GEM_CLK50_HZ)) begin
            report_fail("gem_clk_rst", $sformatf(
                "this testbench drives clk50 at %0.1f Hz but the design derives its counts from %0d Hz",
                1_000_000_000.0 / (2.0 * CLK50_HALF_NS), `GEM_CLK50_HZ));
        end

        $display("[gem_tb] gem_clk_rst: PHY hold %0d cycles at the override, %0.1f ms at the default",
                 phy_hold_cycles, default_hold_ns / 1_000_000.0);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_clk_rst FAILED");
        $finish;
    end

    initial begin
        #1ms;
        $fatal(1, "[gem_tb] gem_clk_rst TIMED OUT");
    end

endmodule
