//----------------------------------------------------------------------------
// tb_gem_mac_tx -- drive payloads in at the AXI-Stream port, capture the RGMII
// pins, and diff the captured cycle stream against the golden model's.
//
// The comparison is at cycle granularity, not byte granularity, and that is
// deliberate. Diffing bytes would pass a design that emitted every octet
// correctly with the wrong inter-frame gap, or with the nibbles on the wrong
// clock edges -- and both of those are the kind of thing that simulates fine
// and fails on the bench. The captured stream carries gap and edge placement,
// so R5 and R13 are checked by the same comparison that checks R1.
//
// Like the RX testbench, this FAILS against rtl/gem_mac_stub.v by design.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_mac_tx;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;

    string scenario;
    string vecdir;

    //------------------------------------------------------------------
    // Clock and reset
    //------------------------------------------------------------------
    logic tx_clk   = 1'b0;
    logic tx_rst_n = 1'b0;
    logic rx_rst_n = 1'b0;

    always #(CLK_PERIOD/2) tx_clk = ~tx_clk;

    initial begin
        repeat (10) @(posedge tx_clk);
        tx_rst_n = 1'b1;
        rx_rst_n = 1'b1;
    end

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire [7:0]   tx_axis_tdata;
    wire         tx_axis_tvalid;
    wire         tx_axis_tready;
    wire         tx_axis_tlast;
    wire [111:0] tx_axis_tuser;

    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl;

    wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok, stat_tx_rejected, stat_tx_underrun;

    gem_mac u_dut (
        .tx_clk           (tx_clk),
        .tx_rst_n         (tx_rst_n),
        .rx_rst_n         (rx_rst_n),

        .rgmii_txd        (rgmii_txd),
        .rgmii_tx_ctl     (rgmii_tx_ctl),
        .rgmii_gtx_clk    (),
        .rgmii_rxd        (4'b0),
        .rgmii_rx_ctl     (1'b0),
        .rgmii_rx_clk     (tx_clk),

        .mdc              (),
        .mdio_i           (1'b1),
        .mdio_o           (),
        .mdio_t           (),

        .tx_axis_tdata    (tx_axis_tdata),
        .tx_axis_tvalid   (tx_axis_tvalid),
        .tx_axis_tready   (tx_axis_tready),
        .tx_axis_tlast    (tx_axis_tlast),
        .tx_axis_tuser    (tx_axis_tuser),

        .rx_axis_tdata    (),
        .rx_axis_tvalid   (),
        .rx_axis_tready   (1'b1),
        .rx_axis_tlast    (),
        .rx_axis_tuser    (),

        .stat_tx_ok       (stat_tx_ok),
        .stat_tx_rejected (stat_tx_rejected),
        .stat_tx_underrun (stat_tx_underrun),
        .stat_rx_ok       (),
        .stat_rx_badfcs   (),
        .stat_rx_runt     (),
        .stat_rx_oversize (),
        .stat_rx_rxer     (),
        .stat_clear       (1'b0),
        .link_up          (),
        .link_speed       ()
    );

    //------------------------------------------------------------------
    // Capture the wire
    //------------------------------------------------------------------
    logic mon_enable = 1'b0;

    rgmii_monitor u_mon (
        .clk       (tx_clk),
        .rst_n     (tx_rst_n),
        .enable    (mon_enable),
        .rgmii_d   (rgmii_txd),
        .rgmii_ctl (rgmii_tx_ctl)
    );

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    logic [11:0] expected_cycles [];
    int          n_expected;

    // Stimulus is driven by the shared axis_tx_driver, the same module the
    // loopback testbench uses. One implementation of the handshake, so the two
    // benches cannot disagree about the protocol they are exercising.
    axis_tx_driver u_drv (
        .clk    (tx_clk),
        .rst_n  (tx_rst_n),
        .tdata  (tx_axis_tdata),
        .tvalid (tx_axis_tvalid),
        .tready (tx_axis_tready),
        .tlast  (tx_axis_tlast),
        .tuser  (tx_axis_tuser)
    );

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    task automatic check_counter(input string name,
                                 input logic [`GEM_COUNTER_WIDTH-1:0] actual);
        longint exp;
        begin
            exp = read_counter({vecdir, "/counters_expected.txt"}, name);
            note_check();
            if (exp < 0) begin
                report_fail(scenario,
                    $sformatf("counter '%s' missing from the expected file", name));
            end else if (longint'(actual) !== exp) begin
                report_fail(scenario,
                    $sformatf("counter %s expected %0d, got %0d", name, exp, actual));
            end
        end
    endtask

    burst_t      exp_bursts [];
    burst_t      got_bursts [];
    logic [11:0] captured [];
    int          n_exp_bursts, n_got_bursts;

    initial begin
        bit ok;
        int i, b, n_captured, n_compare;

        get_scenario(scenario, vecdir);
        begin_scenario(scenario);
        $display("[gem_tb] vectors from %s", vecdir);

        n_expected = read_cycles({vecdir, "/tx_expected.hex"}, expected_cycles);
        $display("[gem_tb] expecting %0d RGMII cycles", n_expected);

        wait (tx_rst_n);
        repeat (4) @(posedge tx_clk);
        mon_enable = 1'b1;

        u_drv.play({vecdir, "/tx_stim.txt"});

        // Drain: the MAC still owes the last frame's FCS and its IFG.
        repeat (64) @(posedge tx_clk);
        mon_enable = 1'b0;

        n_captured = u_mon.n_words;
        $display("[gem_tb] captured %0d RGMII cycles", n_captured);

        note_check();
        if (n_captured == 0 && n_expected > 0) begin
            report_fail(scenario, $sformatf(
                "design transmitted nothing; expected %0d cycles", n_expected));
        end

        //--------------------------------------------------------------
        // Segment both streams, then compare packets and gaps separately
        //--------------------------------------------------------------
        // rgmii_monitor stores into a fixed-size array; split_bursts takes a
        // dynamic one, so copy the populated prefix across.
        captured = new [n_captured];
        for (i = 0; i < n_captured; i++) captured[i] = u_mon.words[i];

        n_exp_bursts = split_bursts(expected_cycles, n_expected, exp_bursts);
        n_got_bursts = split_bursts(captured,        n_captured, got_bursts);

        $display("[gem_tb] %0d frames expected, %0d transmitted",
                 n_exp_bursts, n_got_bursts);

        note_check();
        if (n_got_bursts != n_exp_bursts) begin
            report_fail(scenario, $sformatf(
                "transmitted %0d frames, expected %0d",
                n_got_bursts, n_exp_bursts));
        end

        n_compare = (n_got_bursts < n_exp_bursts) ? n_got_bursts : n_exp_bursts;

        for (b = 0; b < n_compare; b++) begin
            // --- frame content: fully determined, compared cycle for cycle ---
            note_check();
            if (got_bursts[b].len != exp_bursts[b].len) begin
                report_fail($sformatf("%s frame %0d", scenario, b), $sformatf(
                    "frame is %0d cycles on the wire, expected %0d",
                    got_bursts[b].len, exp_bursts[b].len));
            end else begin
                for (i = 0; i < exp_bursts[b].len; i++) begin
                    automatic logic [11:0] e = expected_cycles[exp_bursts[b].startIdx + i];
                    automatic logic [11:0] g = u_mon.words   [got_bursts[b].startIdx + i];
                    note_check();
                    if (g !== e) begin
                        report_fail($sformatf("%s frame %0d octet %0d", scenario, b, i),
                            $sformatf(
                            "expected %03h {ctl_f=%0b ctl_r=%0b d_f=%1h d_r=%1h}, got %03h {ctl_f=%0b ctl_r=%0b d_f=%1h d_r=%1h}",
                            e, e[9], e[8], e[7:4], e[3:0],
                            g, g[9], g[8], g[7:4], g[3:0]));
                    end
                end
            end

            // --- gap: only the R5 floor is required -----------------------
            //
            // Not compared against the model's gap. The model emits a fixed
            // IFG because it has no user-side timeline to derive one from, but
            // the real gap also carries however long user logic took to offer
            // the next frame -- after an abort, the MAC drains and discards the
            // rest of a frame it will never send (B.4b item 5), which can be
            // hundreds of cycles. A conforming MAC is free to be later than the
            // model. It is never free to be earlier.
            //
            // Burst 0 is exempt: rgmii_monitor does not capture leading idle,
            // so there is no gap in front of the first frame to measure.
            if (b > 0) begin
                note_check();
                if (got_bursts[b].gapBefore < `GEM_IFG_BYTES) begin
                    report_fail($sformatf("%s frame %0d", scenario, b), $sformatf(
                        "inter-frame gap was %0d cycles; R5 requires at least %0d",
                        got_bursts[b].gapBefore, `GEM_IFG_BYTES));
                end
            end
        end

        check_counter("tx_ok",       stat_tx_ok);
        check_counter("tx_rejected", stat_tx_rejected);
        // B.4b: an aborted frame counts here and NOT in tx_ok. Checking both
        // is what catches a MAC that aborts correctly on the wire but still
        // scores the frame as transmitted.
        check_counter("tx_underrun", stat_tx_underrun);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] %s FAILED", scenario);
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "[gem_tb] %s TIMED OUT after 20 ms of simulated time", scenario);
    end

endmodule
