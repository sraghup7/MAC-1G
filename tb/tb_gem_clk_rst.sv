//----------------------------------------------------------------------------
// tb_gem_clk_rst -- the clock/reset block against the promises B.1b and the
// deskew design make about it.
//
// This module has no data path, so there is nothing for the scenario
// regression to compare and no golden model to compare it against. What it
// has instead is a small set of properties that are either true or
// catastrophic, rewritten for the Stage 6 part 2 reset architecture
// (Documents/RX Clock Deskew Design.md; criterion D scenarios D1-D5):
//
//   1. RESET ASSERTS WITH NO CLOCK RUNNING. Asserting the board reset stops
//      the crystal MMCM, which stops tx_clk -- so a reset that needed a
//      tx_clk edge to take effect would never take effect at all. Checked by
//      pulling ext_rst_n low between two tx_clk edges and confirming that
//      tx_rst_n, rx_rst_n AND rx_path_rst_n all drop with no edge in between.
//
//   2. RESET RELEASES ON AN EDGE, NOT BETWEEN THEM. Every release lands on
//      its own domain's clock edge -- now checked on three chains: tx_rst_n,
//      rx_rst_n (on the deskewed clock) and the new rx_path_rst_n (on tx_clk).
//
//   3. tx_rst_n NEVER RELEASES ONTO AN UNLOCKED MMCM. Policed continuously,
//      because during acquisition the output is not a 125 MHz clock.
//
//   4. THE RX DOMAIN'S NEW SEMANTICS, replacing the old "rx depends on
//      nothing" property the deskew deliberately retired:
//      a. COLD START, NO LINK. With rx_clk never running at all, rx_rst_n and
//         rx_path_rst_n stay asserted while everything clk50/tx side runs
//         normally -- no deadlock, board comes up and reports no link.
//      b. LATE START ORDERING. When rx_clk starts, lock arrives first;
//         rx_rst_n releases two deskewed-clock edges later, and rx_path_rst_n
//         two tx_clk edges after THAT (Step 3b property 2). The old property
//         "rx releases before LOCKED" is now the design's opposite by intent:
//         an MMCM on a recovered clock does not self-recover (UG472 p.83/91),
//         so its domain's release waits for the supervisor's re-lock.
//      c. LINK DROP MID-OPERATION. Stopping rx_clk asserts rx_rst_n with NO
//         further rx_clk edge available -- the async-assert property.
//      d. STOP-RESTART. The clk50 supervisor re-pulses the MMCM's RST (retry
//         period overridden short), the MMCM relocks, and the release order
//         repeats -- recovery never requires ext_rst_n. This is the scenario
//         chain the whole deskew task exists for.
//      e. RAPID FLAP. Several quick stop/start cycles faster than one retry
//         period still recover.
//
// And the PHY's reset hold: sequencing checked with a short override, the
// real number checked separately against the datasheet minimum at
// elaboration-time values, as before.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_clk_rst;

    import gem_tb_pkg::*;

    localparam int PHY_RST_TEST_CYCLES = 50;

    // Retry period override: 200 clk50 cycles = 4 us, long enough that a lock
    // acquisition (~1 us model + supervisor latency) cannot be interrupted,
    // short enough that several retries fit in the simulation. Same licence
    // PHY_RST_CYCLES' override carries.
    localparam int RX_MMCM_RETRY_TEST = 200;

    localparam real CLK50_HALF_NS = 10.0;   // 50 MHz
    localparam real RXCLK_HALF_NS = 4.0;    // 125 MHz, from the PHY's CDR

    logic clk50      = 1'b0;
    logic rx_clk     = 1'b0;
    logic ext_rst_n  = 1'b0;
    logic rx_clk_run = 1'b0;   // the PHY is not driving RX_CLK yet

    wire tx_clk, gtx_clk_shifted, tx_rst_n, rx_rst_n, mmcm_locked, phy_rst_n;
    wire rx_clk_deskew, rx_mmcm_locked, rx_path_rst_n;

    gem_clk_rst #(
        .PHY_RST_CYCLES       (PHY_RST_TEST_CYCLES),
        .RX_MMCM_RETRY_CYCLES (RX_MMCM_RETRY_TEST)
    ) u_dut (
        .clk50           (clk50),
        .ext_rst_n       (ext_rst_n),
        .rx_clk          (rx_clk),
        .tx_clk          (tx_clk),
        .gtx_clk_shifted (gtx_clk_shifted),
        .rx_clk_deskew   (rx_clk_deskew),
        .tx_rst_n        (tx_rst_n),
        .rx_rst_n        (rx_rst_n),
        .rx_path_rst_n   (rx_path_rst_n),
        .mmcm_locked     (mmcm_locked),
        .rx_mmcm_locked  (rx_mmcm_locked),
        .phy_rst_n       (phy_rst_n)
    );

    // A second instance carrying the real PHY_RST_CYCLES, held in reset for
    // the whole simulation so it costs nothing to have. It exists to be read,
    // not to run: the datasheet-minimum check asks what the default would do.
    wire d_tx_clk, d_gtx_clk, d_tx_rst_n, d_rx_rst_n, d_locked, d_phy_rst_n;
    wire d_rx_clk_deskew, d_rx_mmcm_locked, d_rx_path_rst_n;

    gem_clk_rst u_dut_default (
        .clk50           (clk50),
        .ext_rst_n       (1'b0),
        .rx_clk          (1'b0),
        .tx_clk          (d_tx_clk),
        .gtx_clk_shifted (d_gtx_clk),
        .rx_clk_deskew   (d_rx_clk_deskew),
        .tx_rst_n        (d_tx_rst_n),
        .rx_rst_n        (d_rx_rst_n),
        .rx_path_rst_n   (d_rx_path_rst_n),
        .mmcm_locked     (d_locked),
        .rx_mmcm_locked  (d_rx_mmcm_locked),
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
    real last_rx_edge_ns = -1.0;      // deskewed-clock edges
    real last_dsk_edge_ns = -1.0;     // alias, kept distinct for clarity below

    always @(posedge tx_clk) begin
        tx_edges++;
        last_tx_edge_ns = $realtime;
    end

    always @(posedge rx_clk_deskew) begin
        last_rx_edge_ns = $realtime;
    end

    always @(posedge clk50) begin
        clk50_edges++;
    end

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

    always @(posedge rx_path_rst_n) begin
        note_check();
        if ($realtime != last_tx_edge_ns) begin
            report_fail("gem_clk_rst", $sformatf(
                "rx_path_rst_n released at %0t, which is not a tx_clk edge (last edge %0t)",
                $realtime, last_tx_edge_ns));
        end
    end

    always @(posedge rx_rst_n) begin
        note_check();
        if ($realtime != last_rx_edge_ns) begin
            report_fail("gem_clk_rst", $sformatf(
                "rx_rst_n released at %0t, which is not a deskewed-clock edge (last edge %0t)",
                $realtime, last_rx_edge_ns));
        end
        note_check();
        if (!rx_mmcm_locked && rx_mmcm_locked !== 1'bx) begin
            rx_released_before_lock = 1'b1;
        end
    end

    //----------------------------------------------------------------------
    // The run
    //----------------------------------------------------------------------
    int  edges_at_release;
    int  phy_hold_cycles;
    real default_hold_ns;
    realtime t_lock, t_rx_release, t_path_release;
    realtime edge_at_rx_release;
    int      tx_edges_before;
    bit  ok;

    initial begin
        begin_scenario("gem_clk_rst");

        //--------------------------------------------------------------
        // D1a. Held in reset with NO rx_clk at all (the board between
        //      configuration and the PHY coming alive): nothing released,
        //      and the RX MMCM reports unlocked.
        //--------------------------------------------------------------
        repeat (4) @(posedge clk50);

        note_check();
        if (tx_rst_n !== 1'b0 || rx_rst_n !== 1'b0 || phy_rst_n !== 1'b0 ||
            rx_path_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "with ext_rst_n low and no rx_clk: tx=%b rx=%b path=%b phy=%b, expected all low",
                tx_rst_n, rx_rst_n, rx_path_rst_n, phy_rst_n));
        end

        note_check();
        if (mmcm_locked !== 1'b0 || rx_mmcm_locked !== 1'b0) begin
            report_fail("gem_clk_rst",
                "an MMCM claims lock while held in reset");
        end

        //--------------------------------------------------------------
        // D2. Release WITHOUT starting rx_clk (criterion D1 cold start):
        //     the tx/clk50 side must come up completely on its own -- PHY
        //     hold counted, tx reset released after lock -- while the RX
        //     domain stays parked. No deadlock anywhere.
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
                "phy_rst_n released after %0d clk50 cycles, short of the %0d asked for",
                phy_hold_cycles, PHY_RST_TEST_CYCLES));
        end

        wait (mmcm_locked === 1'b1);
        wait (tx_rst_n === 1'b1);

        note_check();
        if (rx_rst_n !== 1'b0 || rx_path_rst_n !== 1'b0 || rx_mmcm_locked !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "rx domain left reset without any receive clock: rx=%b path=%b locked=%b",
                rx_rst_n, rx_path_rst_n, rx_mmcm_locked));
        end

        $display("[gem_tb] gem_clk_rst: cold start clean -- tx/PHY up, RX domain parked");

        //--------------------------------------------------------------
        // D3. The link arrives: rx_clk starts late. Lock, then the release
        //     order rx_rst_n -> rx_path_rst_n, each on its own edge.
        //--------------------------------------------------------------
        rx_clk_run = 1'b1;

        wait (rx_mmcm_locked === 1'b1);
        t_lock = $realtime;

        wait (rx_rst_n === 1'b1);
        t_rx_release = $realtime;
        // Captured NOW, not after the next wait: the deskewed clock keeps
        // running while rx_path_rst_n releases, and a comparison made later
        // would measure the wrong edge (measured exactly that way).
        edge_at_rx_release = last_rx_edge_ns;

        note_check();
        if (rx_released_before_lock) begin
            report_fail("gem_clk_rst",
                "rx_rst_n was released before the RX MMCM reported locked");
        end

        wait (rx_path_rst_n === 1'b1);
        t_path_release = $realtime;

        note_check();
        if (!(t_lock < t_rx_release && t_rx_release <= t_path_release)) begin
            report_fail("gem_clk_rst", "release ordering violated: expected lock < rx_rst_n <= rx_path_rst_n");
        end

        note_check();
        if (t_rx_release != edge_at_rx_release) begin
            report_fail("gem_clk_rst", "rx_rst_n did not release exactly on a deskewed-clock edge");
        end

        $display("[gem_tb] gem_clk_rst: late-start ordering OK (lock %0t, rx %0t, path %0t)",
                 t_lock, t_rx_release, t_path_release);

        // Let everything settle before stressing it.
        repeat (20) @(posedge tx_clk);


        //--------------------------------------------------------------
        // D4. Link drops mid-operation: rx_clk stops. rx_rst_n must assert
        //     with NO further deskewed-clock edge available -- the
        //     async-assert property -- and rx_path_rst_n follows.
        //--------------------------------------------------------------
        @(posedge rx_clk_deskew);
        #(RXCLK_HALF_NS * 0.3 * 1ns);   // mid-cycle, like the old tx check
        rx_clk_run = 1'b0;

        // The watchdog's detection is not instantaneous -- it samples every
        // CLKIN_WATCH_NS -- so wait out one window plus margin before judging.
        repeat (10) @(posedge clk50);

        note_check();
        if (rx_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst",
                "rx_rst_n did not assert after the receive clock stopped -- the assert path needs a clock edge the stopped clock cannot provide");
        end

        note_check();
        if (rx_path_rst_n !== 1'b0 || rx_mmcm_locked !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "after the link dropped: path=%b locked=%b, expected both low",
                rx_path_rst_n, rx_mmcm_locked));
        end

        $display("[gem_tb] gem_clk_rst: link drop asserts both RX resets with no rx edge");

        // Hold long enough that the supervisor must have pulsed RST at least
        // once while the clock was gone (retry period is 4 us).
        repeat (300) @(posedge clk50);

        note_check();
        if (rx_mmcm_locked !== 1'b0 || rx_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst",
                "the supervisor let the RX domain out of reset while its clock was still gone");
        end

        //--------------------------------------------------------------
        // D5. The clock returns. The supervisor's next retry pulse resets
        //     the MMCM, it relocks WITHOUT ext_rst_n, and the release order
        //     repeats. This is the scenario chain the whole task exists for.
        //--------------------------------------------------------------
        rx_released_before_lock = 1'b0;
        rx_clk_run = 1'b1;

        wait (rx_mmcm_locked === 1'b1);
        wait (rx_rst_n === 1'b1);
        wait (rx_path_rst_n === 1'b1);

        note_check();
        if (rx_released_before_lock) begin
            report_fail("gem_clk_rst",
                "on recovery, rx_rst_n released before the RX MMCM relocked");
        end

        $display("[gem_tb] gem_clk_rst: stop-restart recovered without a board reset");

        //--------------------------------------------------------------
        // D6. Rapid flap, faster than one retry period, twice. Still
        //     recovers; nothing wedges.
        //--------------------------------------------------------------
        for (int flap = 0; flap < 2; flap++) begin
            rx_clk_run = 1'b0;
            repeat (30) @(posedge clk50);
            rx_clk_run = 1'b1;

            fork
                begin : wait_up
                    wait (rx_path_rst_n === 1'b1);
                end
                begin : watchdog
                    repeat (600) @(posedge clk50);
                    report_fail("gem_clk_rst", $sformatf(
                        "flap %0d did not recover within 600 clk50 cycles", flap));
                    disable wait_up;
                end
            join_any
            disable fork;
        end

        $display("[gem_tb] gem_clk_rst: rapid flaps recovered each time");

        //--------------------------------------------------------------
        // P1. Board reset asserted with no tx_clk edge available to carry
        //     it: all four resets must drop asynchronously.
        //--------------------------------------------------------------
        @(posedge tx_clk);
        #1.3ns;
        tx_edges_before = tx_edges;
        ext_rst_n = 1'b0;
        #0.1ns;

        note_check();
        if (tx_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst",
                "tx_rst_n did not assert without a clock edge -- the assert path is synchronous");
        end

        note_check();
        if (tx_edges != tx_edges_before) begin
            report_fail("gem_clk_rst", $sformatf(
                "%0d tx_clk edge(s) arrived during the asynchronous-assert check, so it proved nothing",
                tx_edges - tx_edges_before));
        end

        note_check();
        if (rx_rst_n !== 1'b0 || rx_path_rst_n !== 1'b0 || phy_rst_n !== 1'b0) begin
            report_fail("gem_clk_rst", $sformatf(
                "after asserting ext_rst_n: rx=%b path=%b phy=%b, expected all low",
                rx_rst_n, rx_path_rst_n, phy_rst_n));
        end

        //--------------------------------------------------------------
        // P2. Second release: the PHY hold restarts from zero rather than
        //     staying released because it once was.
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
        // P3. The number that ships: default PHY hold vs datasheet tSR,
        //     and this bench's clk50 vs the frequency the RTL derived from.
        //--------------------------------------------------------------
        default_hold_ns = u_dut_default.PHY_RST_CYCLES * (2.0 * CLK50_HALF_NS);

        note_check();
        if (default_hold_ns < 10_000_000.0) begin
            report_fail("gem_clk_rst", $sformatf(
                "the default PHY reset hold is %0.3f ms, short of the KSZ9031RNX's 10 ms tSR",
                default_hold_ns / 1_000_000.0));
        end

        note_check();
        if ((1_000_000_000.0 / (2.0 * CLK50_HALF_NS)) != real'(`GEM_CLK50_HZ)) begin
            report_fail("gem_clk_rst", $sformatf(
                "this testbench drives clk50 at %0.1f Hz but the design derives its counts from %0d Hz",
                1_000_000_000.0 / (2.0 * CLK50_HALF_NS), `GEM_CLK50_HZ));
        end

        // ... and the retry override actually made it into this instance.
        note_check();
        if (u_dut.RX_MMCM_RETRY_CYCLES != RX_MMCM_RETRY_TEST) begin
            report_fail("gem_clk_rst",
                "the RX_MMCM_RETRY_CYCLES override did not reach the instance -- the recovery checks above ran against the wrong period");
        end

        $display("[gem_tb] gem_clk_rst: PHY hold %0d cycles at the override, %0.1f ms at the default",
                 phy_hold_cycles, default_hold_ns / 1_000_000.0);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_clk_rst FAILED");
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "[gem_tb] gem_clk_rst TIMED OUT");
    end

endmodule

