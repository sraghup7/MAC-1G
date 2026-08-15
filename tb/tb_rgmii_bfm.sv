//----------------------------------------------------------------------------
// tb_rgmii_bfm -- a self-test of the bus functional model.
//
// The BFM is verification code, and nothing else verifies it. Every other
// testbench trusts it completely: if the driver puts nibbles on the wrong
// clock edge, or if its t0 contract is a cycle out, every scenario reports the
// design as broken and the design is fine.
//
// This is also the only testbench in the suite that PASSES today, because it
// has no DUT in it. That makes it the thing to run first when something looks
// impossible -- if this fails, nothing downstream means anything.
//
// Two properties, both of which the rest of the suite depends on:
//
//   1. driver -> pins -> monitor is lossless at real DDR. The monitor's
//      captured words must equal the driver's source words exactly, which
//      means the nibble/edge mapping agrees with gem.rgmiiEncode in MATLAB.
//
//   2. the t0 timing contract holds: cycle N is driven by the clock edge at
//      t0 + N*period. tb_gem_mac_rx turns the golden model's sfdCycle into an
//      R21 latency measurement using exactly this arithmetic, so an off-by-one
//      here becomes an off-by-one in every latency number the project reports.
//
// On (2), the precise convention, since "when is a cycle on the wire" has an
// edge of ambiguity in it: cycle N is *launched* by the edge at t0 + N*period
// and is visible on the pins throughout the interval that follows it. So a
// receiver samples cycle N at the edge t0 + (N+1)*period, and a hypothetical
// zero-latency design that captured the SFD and produced a byte on the very
// next edge would measure 1 cycle, not 0. B.1b's predicted 13 is on the same
// basis.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_rgmii_bfm;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
    end

    //------------------------------------------------------------------
    // Driver -> pins -> monitor, with nothing in between
    //------------------------------------------------------------------
    logic drv_start = 1'b0;
    wire  drv_busy, drv_done;
    wire [3:0] d;
    wire       ctl;

    rgmii_driver u_drv (
        .clk (clk), .rst_n (rst_n), .start (drv_start),
        .busy (drv_busy), .done (drv_done),
        .rgmii_d (d), .rgmii_ctl (ctl)
    );

    rgmii_monitor u_mon (
        .clk (clk), .rst_n (rst_n), .enable (1'b1),
        .rgmii_d (d), .rgmii_ctl (ctl)
    );

    //------------------------------------------------------------------
    // Property 2, checked live: at every posedge while the driver is
    // running, the pins must be showing the cycle that t0 predicts.
    //------------------------------------------------------------------
    int timing_checks = 0;

    // Checked at the negedge, where the rising-edge nibble of cycle N is stable
    // (see the sampling-phase note in rgmii_bfm.sv). At a negedge,
    // ($time - t0) / period truncates to exactly the cycle index on the pins.
    always @(negedge clk) begin
        if (rst_n && drv_busy && u_drv.t0 != 0 && $time > u_drv.t0) begin
            automatic int n = int'(($time - u_drv.t0) / CLK_PERIOD);
            if (n >= 0 && n < u_drv.n_words) begin
                timing_checks++;
                note_check();
                if (d !== u_drv.words[n][3:0] || ctl !== u_drv.words[n][8]) begin
                    report_fail($sformatf("t0 contract, cycle %0d", n), $sformatf(
                        "at t=%0t the pins should show word %03h (d_rise=%1h ctl_rise=%0b) but show d=%1h ctl=%0b",
                        $time, u_drv.words[n], u_drv.words[n][3:0],
                        u_drv.words[n][8], d, ctl));
                end
            end
        end
    end

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    string scenario, vecdir;

    burst_t      src_bursts [], cap_bursts [];
    logic [11:0] src_words  [], cap_words  [];
    int          n_src_bursts, n_cap_bursts;

    initial begin
        bit ok;
        int i, n_src, n_cap, n_compare, first_ctl;

        get_scenario(scenario, vecdir);
        begin_scenario("rgmii_bfm_selftest");
        $display("[gem_tb] driving %s/rx_rgmii.hex through the BFM", vecdir);

        u_drv.load({vecdir, "/rx_rgmii.hex"});
        n_src = u_drv.n_words;

        wait (rst_n);
        repeat (2) @(posedge clk);
        drv_start = 1'b1;
        @(posedge clk);
        drv_start = 1'b0;

        wait (drv_done);
        repeat (4) @(posedge clk);

        //--------------------------------------------------------------
        // Property 1: what came back must equal what went out.
        //--------------------------------------------------------------
        // The monitor starts capturing at the first cycle with CTL asserted,
        // so leading idle is skipped on the capture side; find the same point
        // in the source to line the two up.
        first_ctl = -1;
        for (i = 0; i < n_src; i++) begin
            if (u_drv.words[i][8]) begin
                first_ctl = i;
                break;
            end
        end

        n_cap = u_mon.n_words;
        $display("[gem_tb] source %0d cycles (first CTL at %0d), captured %0d",
                 n_src, first_ctl, n_cap);

        // Both are fixed-size arrays in their modules; split_bursts takes
        // dynamic ones.
        src_words = new [n_src];
        for (i = 0; i < n_src; i++) src_words[i] = u_drv.words[i];
        cap_words = new [n_cap];
        for (i = 0; i < n_cap; i++) cap_words[i] = u_mon.words[i];

        note_check();
        if (first_ctl < 0) begin
            report_fail("bfm", "source vector has no cycle with CTL asserted");
        end else begin
            n_compare = n_src - first_ctl;
            if (n_cap < n_compare) n_compare = n_cap;

            for (i = 0; i < n_compare; i++) begin
                note_check();
                if (u_mon.words[i] !== u_drv.words[first_ctl + i]) begin
                    report_fail($sformatf("bfm round trip, cycle %0d", i),
                        $sformatf("sent %03h, captured %03h",
                                  u_drv.words[first_ctl + i], u_mon.words[i]));
                end
            end
        end

        $display("[gem_tb] t0 contract checked on %0d cycles", timing_checks);
        note_check();
        if (timing_checks == 0) begin
            report_fail("bfm", "the t0 timing contract was never checked -- the check itself is broken");
        end

        //--------------------------------------------------------------
        // Property 3: burst segmentation survives the round trip.
        //--------------------------------------------------------------
        //
        // tb_gem_mac_tx compares transmit streams by splitting them into frame
        // bursts and gaps rather than diffing index for index, because the two
        // streams do not start at the same place: the golden model emits a full
        // IFG before its first packet and rgmii_monitor does not capture
        // leading idle at all. An index-for-index diff was skewed by exactly
        // one IFG, so against working RTL every cycle would have mismatched and
        // the design would have been blamed.
        //
        // This is the positive control for the fix. The capture here IS the
        // source, replayed, so segmentation must find the same bursts with the
        // same lengths, and identical gaps everywhere except in front of the
        // first burst. If that does not hold on a pure replay, the comparison
        // in tb_gem_mac_tx cannot be trusted on a real design either.
        n_src_bursts = split_bursts(src_words, n_src, src_bursts);
        n_cap_bursts = split_bursts(cap_words, n_cap, cap_bursts);

        $display("[gem_tb] segmentation: %0d bursts in source, %0d captured",
                 n_src_bursts, n_cap_bursts);

        note_check();
        if (n_cap_bursts != n_src_bursts) begin
            report_fail("segmentation", $sformatf(
                "source has %0d bursts, capture has %0d", n_src_bursts, n_cap_bursts));
        end else begin
            note_check();
            if (n_src_bursts < 2) begin
                report_fail("segmentation", $sformatf(
                    "only %0d burst(s) -- too few to check gap handling", n_src_bursts));
            end

            for (i = 0; i < n_src_bursts; i++) begin
                note_check();
                if (cap_bursts[i].len != src_bursts[i].len) begin
                    report_fail($sformatf("segmentation burst %0d", i), $sformatf(
                        "captured %0d active cycles, source has %0d",
                        cap_bursts[i].len, src_bursts[i].len));
                end
                // Burst 0 is exempt by construction: the monitor never saw the
                // leading idle, so its gapBefore is 0 while the source's is a
                // full gap. That asymmetry is the whole reason for segmenting.
                if (i > 0) begin
                    note_check();
                    if (cap_bursts[i].gapBefore != src_bursts[i].gapBefore) begin
                        report_fail($sformatf("segmentation burst %0d", i), $sformatf(
                            "gap before it captured as %0d, source has %0d",
                            cap_bursts[i].gapBefore, src_bursts[i].gapBefore));
                    end
                end
            end

            note_check();
            if (cap_bursts[0].gapBefore != 0) begin
                report_fail("segmentation", $sformatf(
                    "monitor captured %0d idle cycles before the first burst; it should start at the first active cycle",
                    cap_bursts[0].gapBefore));
            end
        end

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] BFM self-test FAILED");
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "[gem_tb] BFM self-test TIMED OUT");
    end

endmodule
