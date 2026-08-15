//----------------------------------------------------------------------------
// tb_gem_mac_rx -- drive a generated RGMII stream in, check the AXI-Stream
// beats and R17 counters against the golden model's expectations.
//
// Scenario is chosen at run time:
//     xsim tb_gem_mac_rx -testplusarg SCENARIO=rx_min_gap
// or  xsim tb_gem_mac_rx -testplusarg VECDIR=/path/to/vectors
//
// Against rtl/gem_mac_stub.v this testbench FAILS, and that is the point of
// running it in Stage 3. What is being checked here is not the design -- there
// is none -- but that the vector plumbing works end to end and that the
// failure message is worth reading. A scoreboard whose diagnostics are only
// exercised for the first time during a real debugging session is a scoreboard
// that will be rewritten during a real debugging session.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_mac_rx;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;      // 125 MHz (R19)

    //------------------------------------------------------------------
    // Scenario selection -- see gem_tb_pkg::get_scenario
    //------------------------------------------------------------------
    string scenario;
    string vecdir;

    //------------------------------------------------------------------
    // Clocks and resets (B.1b: async assert, sync deassert, per domain)
    //------------------------------------------------------------------
    logic tx_clk = 1'b0;
    logic rx_clk = 1'b0;
    logic tx_rst_n = 1'b0;
    logic rx_rst_n = 1'b0;

    always #(CLK_PERIOD/2) tx_clk = ~tx_clk;

    // rx_clk is asynchronous to tx_clk on real hardware (R19), so it is given
    // a deliberate offset here rather than being the same edge. Running them
    // edge-aligned would hide every CDC bug the async FIFO exists to prevent.
    initial begin
        #(CLK_PERIOD/3);
        forever #(CLK_PERIOD/2) rx_clk = ~rx_clk;
    end

    initial begin
        tx_rst_n = 1'b0;
        rx_rst_n = 1'b0;
        repeat (10) @(posedge tx_clk);
        tx_rst_n = 1'b1;
        repeat (10) @(posedge rx_clk);
        rx_rst_n = 1'b1;
    end

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire [3:0] rgmii_rxd;
    wire       rgmii_rx_ctl;

    wire [7:0] rx_axis_tdata;
    wire       rx_axis_tvalid;
    logic      rx_axis_tready = 1'b1;   // R18's no-stall user contract
    wire       rx_axis_tlast;
    wire       rx_axis_tuser;

    wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok, stat_rx_badfcs, stat_rx_runt;
    wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize, stat_rx_rxer;

    gem_mac u_dut (
        .tx_clk           (tx_clk),
        .tx_rst_n         (tx_rst_n),
        .rx_rst_n         (rx_rst_n),

        .rgmii_txd        (),
        .rgmii_tx_ctl     (),
        .rgmii_gtx_clk    (),
        .rgmii_rxd        (rgmii_rxd),
        .rgmii_rx_ctl     (rgmii_rx_ctl),
        .rgmii_rx_clk     (rx_clk),

        .mdc              (),
        .mdio_i           (1'b1),
        .mdio_o           (),
        .mdio_t           (),

        .tx_axis_tdata    (8'b0),
        .tx_axis_tvalid   (1'b0),
        .tx_axis_tready   (),
        .tx_axis_tlast    (1'b0),
        .tx_axis_tuser    (112'b0),

        .rx_axis_tdata    (rx_axis_tdata),
        .rx_axis_tvalid   (rx_axis_tvalid),
        .rx_axis_tready   (rx_axis_tready),
        .rx_axis_tlast    (rx_axis_tlast),
        .rx_axis_tuser    (rx_axis_tuser),

        .stat_tx_ok       (),
        .stat_tx_rejected (),
        .stat_rx_ok       (stat_rx_ok),
        .stat_rx_badfcs   (stat_rx_badfcs),
        .stat_rx_runt     (stat_rx_runt),
        .stat_rx_oversize (stat_rx_oversize),
        .stat_rx_rxer     (stat_rx_rxer),
        .stat_clear       (1'b0),
        .link_up          (),
        .link_speed       ()
    );

    //------------------------------------------------------------------
    // Stimulus: the PHY side of the RGMII bus
    //------------------------------------------------------------------
    logic drv_start = 1'b0;
    wire  drv_busy, drv_done;

    rgmii_driver u_drv (
        .clk       (rx_clk),
        .rst_n     (rx_rst_n),
        .start     (drv_start),
        .busy      (drv_busy),
        .done      (drv_done),
        .rgmii_d   (rgmii_rxd),
        .rgmii_ctl (rgmii_rx_ctl)
    );

    //------------------------------------------------------------------
    // Scoreboard
    //------------------------------------------------------------------
    beat_t  expected [];
    int     n_expected;
    int     beat_idx = 0;

    // R21 latency tracking. The golden model tells us which wire cycle carried
    // each frame's SFD; the driver tells us when cycle 0 was launched; the
    // clock period converts between them. So the measurement is
    //
    //     latency = (time of this frame's first beat)
    //             - (t0 + sfdCycle * CLK_PERIOD)
    //
    // which is exactly R21's "last bit of a field in to corresponding byte out
    // of the user interface", and needs no second SFD hunt in the testbench.
    int  last_frame_seen  = -1;
    int  worst_latency    = -1;
    int  worst_latency_frame = -1;
    int  latency_samples  = 0;

    // Every accepted beat is compared in the cycle it is accepted, rather than
    // collected and diffed at the end. Comparing live means the first divergence
    // is reported with the simulation still at that point, which is what makes
    // the waveform useful when the message is not enough.
    always @(posedge tx_clk) begin
        if (tx_rst_n && rx_axis_tvalid && rx_axis_tready) begin
            note_check();
            if (beat_idx >= n_expected) begin
                report_fail($sformatf("%s beat %0d", scenario, beat_idx),
                    $sformatf("design produced a beat past the end of the expected stream (data 0x%02h, last %0b)",
                              rx_axis_tdata, rx_axis_tlast));
            end else begin
                // First beat of a new frame: measure R21.
                if (expected[beat_idx].frameId != last_frame_seen) begin
                    automatic time sfd_time =
                        u_drv.t0 + expected[beat_idx].sfdCycle * CLK_PERIOD;
                    automatic int  cycles =
                        int'(($realtime - real'(sfd_time)) / real'(CLK_PERIOD));

                    last_frame_seen = expected[beat_idx].frameId;
                    latency_samples++;

                    if (cycles > worst_latency) begin
                        worst_latency = cycles;
                        worst_latency_frame = expected[beat_idx].frameId;
                    end

                    note_check();
                    if (cycles > `GEM_RX_LATENCY_MAX_CYCLES) begin
                        report_fail($sformatf("%s frame %0d",
                                              scenario, expected[beat_idx].frameId),
                            $sformatf("R21 latency %0d cycles exceeds the %0d-cycle ceiling (SFD at wire cycle %0d)",
                                      cycles, `GEM_RX_LATENCY_MAX_CYCLES,
                                      expected[beat_idx].sfdCycle));
                    end
                end

                if (rx_axis_tdata !== expected[beat_idx].data) begin
                    report_fail(beat_context(beat_idx, expected[beat_idx]),
                        $sformatf("tdata expected 0x%02h, got 0x%02h",
                                  expected[beat_idx].data, rx_axis_tdata));
                end
                if (rx_axis_tlast !== expected[beat_idx].last) begin
                    report_fail(beat_context(beat_idx, expected[beat_idx]),
                        $sformatf("tlast expected %0b, got %0b",
                                  expected[beat_idx].last, rx_axis_tlast));
                end
                // tuser only means anything on the tlast beat (R9), so it is
                // only checked there -- otherwise a design free to drive it
                // however it likes between frames would fail for no reason.
                if (expected[beat_idx].last && rx_axis_tuser !== expected[beat_idx].user) begin
                    report_fail(beat_context(beat_idx, expected[beat_idx]),
                        $sformatf("FCS verdict expected %0b, got %0b",
                                  expected[beat_idx].user, rx_axis_tuser));
                end
            end
            beat_idx <= beat_idx + 1;
        end
    end

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    // `actual` is passed by value, not by ref: the status ports are wires, and
    // a wire cannot bind to a ref argument.
    task automatic check_counter(input string name,
                                 input logic [`GEM_COUNTER_WIDTH-1:0] actual);
        longint exp;
        begin
            exp = read_counter({vecdir, "/counters_expected.txt"}, name);
            note_check();
            if (exp < 0) begin
                report_fail(scenario, $sformatf("counter '%s' missing from the expected file", name));
            end else if (longint'(actual) !== exp) begin
                report_fail(scenario,
                    $sformatf("counter %s expected %0d, got %0d", name, exp, actual));
            end
        end
    endtask

    initial begin
        bit ok;

        get_scenario(scenario, vecdir);
        begin_scenario(scenario);
        $display("[gem_tb] vectors from %s", vecdir);

        u_drv.load({vecdir, "/rx_rgmii.hex"});
        n_expected = read_beats({vecdir, "/rx_expected.txt"}, expected);
        $display("[gem_tb] expecting %0d beats", n_expected);

        wait (rx_rst_n && tx_rst_n);
        repeat (4) @(posedge rx_clk);

        drv_start = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b0;

        wait (drv_done);

        // Let the RX pipeline and the CDC FIFO drain. The bound is generous
        // on purpose: too short and a slow-but-correct design fails here,
        // which would be a testbench bug reported as a design bug.
        repeat (256) @(posedge tx_clk);

        if (beat_idx < n_expected) begin
            note_check();
            report_fail(scenario, $sformatf(
                "design delivered %0d of %0d expected beats -- first missing is beat %0d of frame %0d",
                beat_idx, n_expected, beat_idx, expected[beat_idx].frameId));
        end

        // Report the worst latency seen even when it passed. A budget that is
        // only mentioned when it is blown gives no warning as it erodes -- and
        // B.1b predicts 13 cycles, so a design measuring 30 is passing R21 and
        // still telling you something has gone wrong in the pipeline.
        if (latency_samples > 0) begin
            $display("[gem_tb] R21 worst RX latency: %0d cycles over %0d frames (ceiling %0d, B.1b predicts 13) -- frame %0d",
                     worst_latency, latency_samples,
                     `GEM_RX_LATENCY_MAX_CYCLES, worst_latency_frame);
        end else if (n_expected > 0) begin
            $display("[gem_tb] R21 latency not measured: no frames were delivered");
        end

        check_counter("rx_ok",       stat_rx_ok);
        check_counter("rx_badfcs",   stat_rx_badfcs);
        check_counter("rx_runt",     stat_rx_runt);
        check_counter("rx_oversize", stat_rx_oversize);
        check_counter("rx_rxer",     stat_rx_rxer);

        ok = check_done();
        if (!ok) begin
            // Nonzero exit status is what makes `make regress` a gate rather
            // than a report someone is supposed to read.
            $fatal(1, "[gem_tb] %s FAILED", scenario);
        end
        $finish;
    end

    // A hung DUT must not hang the regression.
    initial begin
        #20ms;
        $fatal(1, "[gem_tb] %s TIMED OUT after 20 ms of simulated time", scenario);
    end

endmodule
