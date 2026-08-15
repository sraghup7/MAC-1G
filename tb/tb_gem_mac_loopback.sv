//----------------------------------------------------------------------------
// tb_gem_mac_loopback -- payloads in at the TX user port, the same payloads
// out at the RX user port, having gone all the way to the RGMII pins and back
// through a link-partner model (spec B.4's "integrated loop").
//
// This is the only testbench that exercises the whole design as a system, and
// it reaches three things the unit benches structurally cannot:
//
//   1. TX and RX agree about the wire. tb_gem_mac_tx checks TX against the
//      golden model and tb_gem_mac_rx checks RX against the golden model, so
//      both could be wrong in the same direction -- a shared misreading of the
//      FCS byte order, say -- and both would pass. Here TX's output is RX's
//      input, and the check is against the payload that went in, so a shared
//      error no longer cancels.
//
//   2. The rx_clk -> sys_clk crossing runs for real. rgmii_loopback re-emits
//      on an independent receive clock rather than shorting the pins together,
//      so the async FIFO whose depth B.3a derives is actually used. CDC is the
//      number-one cause of "worked in simulation, fails on hardware", and it
//      is invisible to every test that drives one clock.
//
//   3. Full duplex, simultaneously. TX and RX are active at the same time on
//      the same design, which is R18's actual requirement and something
//      neither unit bench does.
//
// The expectation is computed here from what was sent, NOT read from a vector
// file -- deliberately. A vector file would make this a third comparison
// against the same golden model. Building the expected frame independently
// (header, payload, pad to the 46-octet minimum) is what makes this an
// independent check rather than a restatement.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_mac_loopback;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;

    string scenario, vecdir;

    //------------------------------------------------------------------
    // Clocks. rx_clk is a separate generator at the same nominal frequency
    // with a deliberate phase offset -- on hardware it is recovered by the
    // PHY's CDR from the link partner and is asynchronous to tx_clk (R19).
    // Running them edge-aligned would hide every CDC bug in the design.
    //------------------------------------------------------------------
    logic tx_clk = 1'b0;
    logic rx_clk = 1'b0;
    logic tx_rst_n = 1'b0;
    logic rx_rst_n = 1'b0;

    always #(CLK_PERIOD/2) tx_clk = ~tx_clk;

    initial begin
        #(CLK_PERIOD/3);
        forever #(CLK_PERIOD/2) rx_clk = ~rx_clk;
    end

    initial begin
        repeat (10) @(posedge tx_clk);
        tx_rst_n = 1'b1;
        repeat (10) @(posedge rx_clk);
        rx_rst_n = 1'b1;
    end

    //------------------------------------------------------------------
    // DUT, with its own transmit pins looped back to its receive pins
    //------------------------------------------------------------------
    wire [7:0]   tx_axis_tdata;
    wire         tx_axis_tvalid;
    wire         tx_axis_tready;
    wire         tx_axis_tlast;
    wire [111:0] tx_axis_tuser;

    wire [3:0] rgmii_txd,  rgmii_rxd;
    wire       rgmii_tx_ctl, rgmii_rx_ctl;

    wire [7:0] rx_axis_tdata;
    wire       rx_axis_tvalid;
    logic      rx_axis_tready = 1'b1;      // R18's no-stall user contract
    wire       rx_axis_tlast;
    wire       rx_axis_tuser;

    wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok, stat_rx_ok;

    gem_mac u_dut (
        .tx_clk           (tx_clk),
        .tx_rst_n         (tx_rst_n),
        .rx_rst_n         (rx_rst_n),

        .rgmii_txd        (rgmii_txd),
        .rgmii_tx_ctl     (rgmii_tx_ctl),
        .rgmii_gtx_clk    (),
        .rgmii_rxd        (rgmii_rxd),
        .rgmii_rx_ctl     (rgmii_rx_ctl),
        .rgmii_rx_clk     (rx_clk),

        .mdc              (),
        .mdio_i           (1'b1),
        .mdio_o           (),
        .mdio_t           (),

        .tx_axis_tdata    (tx_axis_tdata),
        .tx_axis_tvalid   (tx_axis_tvalid),
        .tx_axis_tready   (tx_axis_tready),
        .tx_axis_tlast    (tx_axis_tlast),
        .tx_axis_tuser    (tx_axis_tuser),

        .rx_axis_tdata    (rx_axis_tdata),
        .rx_axis_tvalid   (rx_axis_tvalid),
        .rx_axis_tready   (rx_axis_tready),
        .rx_axis_tlast    (rx_axis_tlast),
        .rx_axis_tuser    (rx_axis_tuser),

        .stat_tx_ok       (stat_tx_ok),
        .stat_tx_rejected (),
        .stat_tx_underrun (),
        .stat_rx_ok       (stat_rx_ok),
        .stat_rx_badfcs   (),
        .stat_rx_runt     (),
        .stat_rx_oversize (),
        .stat_rx_rxer     (),
        .stat_clear       (1'b0),
        .link_up          (),
        .link_speed       ()
    );

    rgmii_loopback u_loop (
        .tx_clk (tx_clk),
        .rx_clk (rx_clk),
        .rst_n  (tx_rst_n & rx_rst_n),
        .tx_d   (rgmii_txd),
        .tx_ctl (rgmii_tx_ctl),
        .rx_d   (rgmii_rxd),
        .rx_ctl (rgmii_rx_ctl)
    );

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    axis_tx_driver u_drv (
        .clk         (tx_clk),
        .rst_n       (tx_rst_n),
        .tdata       (tx_axis_tdata),
        .tvalid      (tx_axis_tvalid),
        .tready      (tx_axis_tready),
        .tlast       (tx_axis_tlast),
        .tuser       (tx_axis_tuser)
    );

    //------------------------------------------------------------------
    // Expectation, built here rather than read from a file
    //------------------------------------------------------------------
    //
    // What the RX port must deliver for frame k, per B.4a's delivery contract:
    // DA, SA, EtherType, payload, and pad up to the 46-octet minimum. No
    // preamble, no SFD, no FCS.
    function automatic void expected_frame(input int k, ref logic [7:0] out []);
        int payloadLen, padded, i;
        begin
            payloadLen = u_drv.f_len[k];
            padded = payloadLen;
            if (padded < `GEM_MIN_PAYLOAD_BYTES) padded = `GEM_MIN_PAYLOAD_BYTES;

            out = new [`GEM_HEADER_BYTES + padded];

            for (i = 0; i < 6; i++) out[i]     = u_drv.f_da[k][47 - 8*i -: 8];
            for (i = 0; i < 6; i++) out[6 + i] = u_drv.f_sa[k][47 - 8*i -: 8];
            out[12] = u_drv.f_et[k][15:8];
            out[13] = u_drv.f_et[k][7:0];

            for (i = 0; i < padded; i++) begin
                out[`GEM_HEADER_BYTES + i] =
                    (i < payloadLen) ? u_drv.f_payload[k][i] : 8'h00;
            end
        end
    endfunction

    //------------------------------------------------------------------
    // Scoreboard: every RX beat, checked live against the frame we sent
    //------------------------------------------------------------------
    logic [7:0] expected [];
    int  rx_frame = 0;      // which sent frame we are matching against
    int  rx_beat  = 0;      // beat index within it
    bit  have_expected = 1'b0;

    always @(posedge tx_clk) begin
        if (tx_rst_n && rx_axis_tvalid && rx_axis_tready) begin
            if (!have_expected) begin
                if (rx_frame >= u_drv.frames_sent) begin
                    note_check();
                    report_fail($sformatf("%s", scenario), $sformatf(
                        "design delivered a frame that was never transmitted (frame index %0d, only %0d sent)",
                        rx_frame, u_drv.frames_sent));
                    rx_frame++;
                end else begin
                    expected_frame(rx_frame, expected);
                    have_expected = 1'b1;
                    rx_beat = 0;
                end
            end

            if (have_expected) begin
                note_check();
                if (rx_beat >= expected.size()) begin
                    report_fail($sformatf("%s frame %0d", scenario, rx_frame),
                        $sformatf("frame is longer than expected: got beat %0d, expected %0d octets",
                                  rx_beat, expected.size()));
                end else if (rx_axis_tdata !== expected[rx_beat]) begin
                    report_fail($sformatf("%s frame %0d octet %0d", scenario, rx_frame, rx_beat),
                        $sformatf("looped back 0x%02h, sent 0x%02h",
                                  rx_axis_tdata, expected[rx_beat]));
                end

                if (rx_axis_tlast) begin
                    note_check();
                    if (rx_beat + 1 != expected.size()) begin
                        report_fail($sformatf("%s frame %0d", scenario, rx_frame),
                            $sformatf("frame ended after %0d octets, expected %0d",
                                      rx_beat + 1, expected.size()));
                    end
                    // A frame that went out clean must come back clean. If the
                    // verdict is bad here, the design corrupted its own frame
                    // somewhere between the two ports -- which is precisely
                    // what neither unit bench can observe.
                    note_check();
                    if (rx_axis_tuser !== 1'b1) begin
                        report_fail($sformatf("%s frame %0d", scenario, rx_frame),
                            "FCS verdict is bad on a frame this design transmitted itself");
                    end
                    rx_frame++;
                    have_expected = 1'b0;
                end else begin
                    rx_beat++;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    initial begin
        bit ok;

        get_scenario(scenario, vecdir);
        begin_scenario(scenario);
        $display("[gem_tb] loopback, stimulus from %s/tx_stim.txt", vecdir);

        wait (tx_rst_n && rx_rst_n);
        repeat (4) @(posedge tx_clk);

        u_drv.play({vecdir, "/tx_stim.txt"});

        // Drain: the last frame still has to cross the loopback queue, the RX
        // pipeline and the CDC FIFO.
        repeat (2000) @(posedge tx_clk);

        $display("[gem_tb] sent %0d frames, received %0d", u_drv.frames_sent, rx_frame);

        note_check();
        if (rx_frame != u_drv.frames_sent) begin
            report_fail(scenario, $sformatf(
                "sent %0d frames, got %0d back", u_drv.frames_sent, rx_frame));
        end

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] %s FAILED", scenario);
        $finish;
    end

    initial begin
        #40ms;
        $fatal(1, "[gem_tb] %s TIMED OUT", scenario);
    end

endmodule
