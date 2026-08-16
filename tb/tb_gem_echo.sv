//----------------------------------------------------------------------------
// tb_gem_echo -- the echo path on its own, before the top level makes its
// failures look like PHY problems.
//
// Four properties, and each of them fails on hardware in a way that would be
// blamed on something else:
//
//   1. A GOOD FRAME COMES BACK WITH ITS ADDRESSES EXCHANGED and its payload
//      untouched. Get the swap wrong and every reply is addressed to the board
//      itself; the host's NIC drops them and the board looks dead.
//   2. A BAD FRAME IS NOT ECHOED. The whole reason this module buffers instead
//      of streaming, so it is the reason to check it.
//   3. A FRAME ARRIVING MID-TRANSMISSION IS DROPPED, AND DOES NOT CORRUPT THE
//      FRAME ALREADY GOING OUT. This is the one that matters. The capture
//      register keeps shifting whether or not the frame is being kept, so a
//      header held in the same register would leave with the right payload and
//      the wrong destination -- under load only, intermittently, on hardware.
//      That defect was in the first version of this module and this check is
//      why it did not reach a board.
//   4. BACKPRESSURE MID-FRAME CHANGES NOTHING. The transmit port can stall for
//      its own reasons, and a buffer that advances on `tvalid` rather than on
//      `tvalid && tready` loses an octet exactly when the MAC is busiest.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_echo;

    import gem_tb_pkg::*;

    localparam real CLK_HALF_NS = 4.0;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [7:0] rx_tdata = 8'h00;
    logic       rx_tvalid = 1'b0;
    logic       rx_tlast = 1'b0;
    logic       rx_tuser = 1'b1;
    wire        rx_tready;

    wire [7:0]   tx_tdata;
    wire         tx_tvalid;
    logic        tx_tready = 1'b1;
    wire         tx_tlast;
    wire [111:0] tx_tuser;
    wire         dropped;

    gem_echo u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx_tdata  (rx_tdata),
        .rx_tvalid (rx_tvalid),
        .rx_tlast  (rx_tlast),
        .rx_tuser  (rx_tuser),
        .rx_tready (rx_tready),
        .tx_tdata  (tx_tdata),
        .tx_tvalid (tx_tvalid),
        .tx_tready (tx_tready),
        .tx_tlast  (tx_tlast),
        .tx_tuser  (tx_tuser),
        .dropped   (dropped)
    );

    always #(CLK_HALF_NS * 1ns) clk = ~clk;

    //----------------------------------------------------------------------
    // Collect whole frames off the transmit port
    //----------------------------------------------------------------------
    logic [7:0]   got_payload [$];
    logic [111:0] got_tuser [$];
    logic [7:0]   current [$];
    int           frames_out = 0;
    int           drops_seen = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (dropped) drops_seen++;
            if (tx_tvalid && tx_tready) begin
                current.push_back(tx_tdata);
                if (tx_tlast) begin
                    got_tuser.push_back(tx_tuser);
                    got_payload = {}; // one frame at a time is enough here
                    foreach (current[i]) got_payload.push_back(current[i]);
                    current = {};
                    frames_out++;
                end
            end
        end
    end

    //----------------------------------------------------------------------
    // Stimulus
    //----------------------------------------------------------------------
    localparam logic [47:0] HOST_MAC  = 48'h001122334455;
    localparam logic [47:0] BOARD_MAC = 48'hAABBCCDDEEFF;
    localparam logic [15:0] ETYPE     = 16'h0800;

    // Send one frame as gem_mac's receive port delivers it: DA, SA, EtherType,
    // then payload and pad, with the verdict on the final beat.
    task automatic send_frame(input logic [47:0] da, input logic [47:0] sa,
                              input logic [15:0] et, input int n_payload,
                              input logic good, input logic [7:0] first_byte);
        int i;
        @(posedge clk);
        for (i = 0; i < 6; i++) begin
            rx_tdata  <= da[47 - 8*i -: 8];
            rx_tvalid <= 1'b1;
            rx_tlast  <= 1'b0;
            @(posedge clk);
        end
        for (i = 0; i < 6; i++) begin
            rx_tdata <= sa[47 - 8*i -: 8];
            @(posedge clk);
        end
        rx_tdata <= et[15:8]; @(posedge clk);
        rx_tdata <= et[7:0];  @(posedge clk);
        for (i = 0; i < n_payload; i++) begin
            rx_tdata <= first_byte + 8'(i);
            rx_tlast <= (i == n_payload - 1);
            rx_tuser <= good;
            @(posedge clk);
        end
        rx_tvalid <= 1'b0;
        rx_tlast  <= 1'b0;
    endtask

    localparam int PAY = 46;   // the minimum a good frame can deliver

    int  i;
    bit  ok;
    logic [111:0] want_tuser;

    initial begin
        begin_scenario("gem_echo");

        want_tuser = {HOST_MAC, BOARD_MAC, ETYPE};   // swapped: was DA=board

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        //--------------------------------------------------------------
        // 1. A good frame comes back, addresses exchanged
        //--------------------------------------------------------------
        send_frame(BOARD_MAC, HOST_MAC, ETYPE, PAY, 1'b1, 8'h10);
        wait (frames_out == 1);
        repeat (2) @(posedge clk);

        note_check();
        if (got_tuser[0] !== want_tuser) begin
            report_fail("gem_echo", $sformatf(
                "header came back as %028h, expected %028h -- DA and SA are not exchanged",
                got_tuser[0], want_tuser));
        end

        note_check();
        if (got_payload.size() != PAY) begin
            report_fail("gem_echo", $sformatf(
                "echoed %0d payload octets, expected %0d", got_payload.size(), PAY));
        end else begin
            for (i = 0; i < PAY; i++) begin
                note_check();
                if (got_payload[i] !== 8'(8'h10 + i)) begin
                    report_fail("gem_echo", $sformatf(
                        "payload octet %0d came back as 0x%02h, sent 0x%02h",
                        i, got_payload[i], 8'(8'h10 + i)));
                end
            end
        end

        //--------------------------------------------------------------
        // 2. A bad frame is not echoed at all
        //--------------------------------------------------------------
        send_frame(BOARD_MAC, HOST_MAC, ETYPE, PAY, 1'b0, 8'h80);
        repeat (200) @(posedge clk);

        note_check();
        if (frames_out != 1) begin
            report_fail("gem_echo", $sformatf(
                "%0d frames transmitted after a bad frame arrived, expected the count to stay at 1",
                frames_out));
        end

        //--------------------------------------------------------------
        // 3. A frame arriving mid-transmission is dropped, and the frame in
        //    flight keeps its own header.
        //
        //    tx_tready is held low so the first frame cannot drain, which is
        //    what guarantees the second one overlaps it.
        //--------------------------------------------------------------
        drops_seen = 0;
        tx_tready  = 1'b0;
        send_frame(BOARD_MAC, HOST_MAC, ETYPE, PAY, 1'b1, 8'h20);
        repeat (4) @(posedge clk);

        // A second frame from a different host, while the first is stalled.
        send_frame(BOARD_MAC, 48'h665544332211, 16'h86DD, PAY, 1'b1, 8'hC0);

        note_check();
        if (drops_seen == 0) begin
            report_fail("gem_echo",
                "a frame arrived while another was in flight and nothing reported a drop");
        end

        tx_tready = 1'b1;
        wait (frames_out == 2);
        repeat (2) @(posedge clk);

        note_check();
        if (got_tuser[1] !== want_tuser) begin
            report_fail("gem_echo", $sformatf(
                "the frame in flight left with header %028h, expected %028h -- a dropped frame overwrote it",
                got_tuser[1], want_tuser));
        end

        note_check();
        if (got_payload.size() > 0 && got_payload[0] !== 8'h20) begin
            report_fail("gem_echo", $sformatf(
                "the frame in flight starts with 0x%02h, expected 0x20 -- a dropped frame reached the buffer",
                got_payload[0]));
        end

        // The dropped frame must not appear afterwards either.
        repeat (300) @(posedge clk);
        note_check();
        if (frames_out != 2) begin
            report_fail("gem_echo", $sformatf(
                "%0d frames out, expected 2 -- a dropped frame was queued rather than dropped", frames_out));
        end

        //--------------------------------------------------------------
        // 4. Backpressure in the middle of a frame
        //--------------------------------------------------------------
        send_frame(BOARD_MAC, HOST_MAC, ETYPE, PAY, 1'b1, 8'h40);

        // Stall every other cycle for a while, then let it finish.
        for (i = 0; i < 40; i++) begin
            @(posedge clk);
            tx_tready <= ~tx_tready;
        end
        tx_tready <= 1'b1;
        wait (frames_out == 3);
        repeat (2) @(posedge clk);

        note_check();
        if (got_payload.size() != PAY) begin
            report_fail("gem_echo", $sformatf(
                "under backpressure the frame came back %0d octets long, expected %0d",
                got_payload.size(), PAY));
        end else begin
            for (i = 0; i < PAY; i++) begin
                note_check();
                if (got_payload[i] !== 8'(8'h40 + i)) begin
                    report_fail("gem_echo", $sformatf(
                        "under backpressure octet %0d came back as 0x%02h, sent 0x%02h",
                        i, got_payload[i], 8'(8'h40 + i)));
                end
            end
        end

        $display("[gem_tb] gem_echo: %0d frames echoed, %0d drop(s) reported", frames_out, drops_seen);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_echo FAILED");
        $finish;
    end

    initial begin
        #2ms;
        $fatal(1, "[gem_tb] gem_echo TIMED OUT");
    end

endmodule
