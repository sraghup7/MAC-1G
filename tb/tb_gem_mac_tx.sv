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

    // How long the driver waits on tready before calling it a failure. Well
    // above any legitimate stall -- the longest frame is 1518 octets -- and far
    // below the global timeout, so a wedged tready is reported as itself
    // instead of as a mystery hang.
    localparam int STALL_LIMIT = 5000;

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
    logic [7:0]   tx_axis_tdata  = 8'b0;
    logic         tx_axis_tvalid = 1'b0;
    wire          tx_axis_tready;
    logic         tx_axis_tlast  = 1'b0;
    logic [111:0] tx_axis_tuser  = 112'b0;

    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl;

    wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok, stat_tx_rejected;

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

    // Drives one frame. Backpressure is honoured but never generated inside a
    // frame -- see gem.genTxScenario for why mid-frame stalling is an open
    // spec item rather than something this testbench guesses at.
    task automatic send_frame(input logic [7:0] payload [],
                              input logic [7:0] da [],
                              input logic [7:0] sa [],
                              input logic [15:0] etherType,
                              input int readyGap);
        int i, stall;
        begin
            repeat (readyGap) @(posedge tx_clk);

            tx_axis_tuser <= {da[0], da[1], da[2], da[3], da[4], da[5],
                              sa[0], sa[1], sa[2], sa[3], sa[4], sa[5],
                              etherType};

            for (i = 0; i < payload.size(); i++) begin
                tx_axis_tdata  <= payload[i];
                tx_axis_tvalid <= 1'b1;
                tx_axis_tlast  <= (i == payload.size() - 1);
                @(posedge tx_clk);

                // Bounded wait. Spinning here until the global timeout would
                // report "TIMED OUT after 20 ms", which says nothing about the
                // cause and costs six seconds of wall clock per scenario. A
                // MAC that never raises tready is a specific, nameable failure
                // and deserves to be named.
                stall = 0;
                while (!tx_axis_tready) begin
                    @(posedge tx_clk);
                    stall++;
                    if (stall > STALL_LIMIT) begin
                        report_fail(scenario, $sformatf(
                            "tready never asserted -- stalled %0d cycles at payload octet %0d",
                            stall, i));
                        tx_axis_tvalid <= 1'b0;
                        tx_axis_tlast  <= 1'b0;
                        return;
                    end
                end
            end

            tx_axis_tvalid <= 1'b0;
            tx_axis_tlast  <= 1'b0;
            @(posedge tx_clk);
        end
    endtask

    task automatic play_stimulus(input string path);
        int fd, code, idx, readyGap, ethType, nPayload;
        string line, daHex, saHex, payloadHex;
        logic [7:0] da [], sa [], payload [];
        begin
            fd = $fopen(path, "r");
            if (fd == 0) $fatal(1, "gem_tb: cannot open stimulus file '%s'", path);

            while (!$feof(fd)) begin
                code = $fgets(line, fd);
                if (code <= 0) break;
                if (line.substr(0,0) == "#" || line.len() < 8) continue;

                if ($sscanf(line, "%d %d %h %s %s %s",
                            idx, readyGap, ethType, daHex, saHex, payloadHex) == 6) begin
                    void'(hex_to_bytes(daHex, da));
                    void'(hex_to_bytes(saHex, sa));
                    nPayload = hex_to_bytes(payloadHex, payload);
                    send_frame(payload, da, sa, 16'(ethType), readyGap);
                end
            end
            $fclose(fd);
        end
    endtask

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

    initial begin
        bit ok;
        int i, n_captured, n_compare;

        get_scenario(scenario, vecdir);
        begin_scenario(scenario);
        $display("[gem_tb] vectors from %s", vecdir);

        n_expected = read_cycles({vecdir, "/tx_expected.hex"}, expected_cycles);
        $display("[gem_tb] expecting %0d RGMII cycles", n_expected);

        wait (tx_rst_n);
        repeat (4) @(posedge tx_clk);
        mon_enable = 1'b1;

        play_stimulus({vecdir, "/tx_stim.txt"});

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

        // Compare over the shorter of the two and report the length difference
        // separately, so a design that is right for 900 cycles and then stops
        // says exactly that instead of drowning in mismatches.
        n_compare = (n_captured < n_expected) ? n_captured : n_expected;
        for (i = 0; i < n_compare; i++) begin
            note_check();
            if (u_mon.words[i] !== expected_cycles[i]) begin
                report_fail($sformatf("%s cycle %0d", scenario, i), $sformatf(
                    "expected %03h {ctl_f=%0b ctl_r=%0b d_f=%1h d_r=%1h}, got %03h {ctl_f=%0b ctl_r=%0b d_f=%1h d_r=%1h}",
                    expected_cycles[i], expected_cycles[i][9], expected_cycles[i][8],
                    expected_cycles[i][7:4], expected_cycles[i][3:0],
                    u_mon.words[i], u_mon.words[i][9], u_mon.words[i][8],
                    u_mon.words[i][7:4], u_mon.words[i][3:0]));
            end
        end

        if (n_captured != n_expected) begin
            note_check();
            report_fail(scenario, $sformatf(
                "transmitted %0d cycles, expected %0d", n_captured, n_expected));
        end

        check_counter("tx_ok",       stat_tx_ok);
        check_counter("tx_rejected", stat_tx_rejected);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] %s FAILED", scenario);
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "[gem_tb] %s TIMED OUT after 20 ms of simulated time", scenario);
    end

endmodule
