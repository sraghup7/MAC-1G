//----------------------------------------------------------------------------
// axis_tx_driver -- plays a tx_stim.txt file into the MAC's TX user port.
//
// Extracted from tb_gem_mac_tx so the loopback testbench can drive the same
// stimulus without a second copy of the handshake logic. Two testbenches
// driving the same port through two implementations of the same protocol is
// how they end up disagreeing about it -- which is exactly the class of bug
// the bound AXI-S assertions exist to catch, and not one worth manufacturing
// in the testbench itself.
//
// It also records what it sent (header fields and payload per frame), which is
// what lets the loopback testbench build its expectation independently of the
// golden model's vector files.
//
// BACKPRESSURE: stalls are inserted only *between* frames, never inside one.
// See gem.genTxScenario -- what a MAC should do when the user stalls mid-frame
// is an open spec item (V-1 in verification_plan.md), and the testbench does
// not get to invent the answer.
//----------------------------------------------------------------------------

`ifndef AXIS_TX_DRIVER_SV
`define AXIS_TX_DRIVER_SV

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module axis_tx_driver #(
    parameter int MAX_FRAMES  = 4096,
    // Well above any legitimate stall -- the longest frame is 1518 octets --
    // and far below any global timeout, so a wedged tready is reported as
    // itself rather than as a mystery hang.
    parameter int STALL_LIMIT = 5000
) (
    input  wire         clk,
    input  wire         rst_n,

    output reg  [7:0]   tdata,
    output reg          tvalid,
    input  wire         tready,
    output reg          tlast,
    output reg  [111:0] tuser
);

    // Read hierarchically (u_drv.stalled, u_drv.frames_sent) rather than
    // exposed as ports, for the same reason the recorded frame data is: `int`
    // and `bit` are 2-state and cannot be net types, so they cannot cross a
    // port to a wire. Consistent access beats two mechanisms.
    bit stalled     = 1'b0;
    int frames_sent = 0;

    // What was sent, kept for whoever needs to predict what should come back.
    logic [47:0] f_da      [MAX_FRAMES];
    logic [47:0] f_sa      [MAX_FRAMES];
    logic [15:0] f_et      [MAX_FRAMES];
    logic [7:0]  f_payload [MAX_FRAMES][];
    int          f_len     [MAX_FRAMES];

    initial begin
        tdata  = 8'b0;
        tvalid = 1'b0;
        tlast  = 1'b0;
        tuser  = 112'b0;
    end

    task automatic send_frame(input logic [7:0]  payload [],
                              input logic [47:0] da,
                              input logic [47:0] sa,
                              input logic [15:0] etherType,
                              input int          readyGap);
        int i, stall;
        begin
            repeat (readyGap) @(posedge clk);

            tuser <= {da, sa, etherType};

            for (i = 0; i < payload.size(); i++) begin
                tdata  <= payload[i];
                tvalid <= 1'b1;
                tlast  <= (i == payload.size() - 1);
                @(posedge clk);

                stall = 0;
                while (!tready) begin
                    @(posedge clk);
                    stall++;
                    if (stall > STALL_LIMIT) begin
                        gem_tb_pkg::report_fail(gem_tb_pkg::scenario_name,
                            $sformatf("tready never asserted -- stalled %0d cycles at frame %0d octet %0d",
                                      stall, frames_sent, i));
                        // Blocking, so `play`'s loop guard sees it on the very
                        // next iteration. A nonblocking assignment here let
                        // one more frame start before the stall took effect.
                        stalled = 1'b1;
                        tvalid  <= 1'b0;
                        tlast   <= 1'b0;
                        return;
                    end
                end
            end

            tvalid <= 1'b0;
            tlast  <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic play(input string path);
        int fd, code, idx, readyGap, ethType, n;
        string line, daHex, saHex, payloadHex;
        logic [7:0] da [], sa [], payload [];
        begin
            fd = $fopen(path, "r");
            if (fd == 0) $fatal(1, "axis_tx_driver: cannot open '%s'", path);

            while (!$feof(fd) && !stalled) begin
                code = $fgets(line, fd);
                if (code <= 0) break;
                if (line.substr(0,0) == "#" || line.len() < 8) continue;

                if ($sscanf(line, "%d %d %h %s %s %s",
                            idx, readyGap, ethType, daHex, saHex, payloadHex) == 6) begin
                    void'(gem_tb_pkg::hex_to_bytes(daHex, da));
                    void'(gem_tb_pkg::hex_to_bytes(saHex, sa));
                    n = gem_tb_pkg::hex_to_bytes(payloadHex, payload);

                    if (frames_sent < MAX_FRAMES) begin
                        f_da[frames_sent]      = {da[0], da[1], da[2], da[3], da[4], da[5]};
                        f_sa[frames_sent]      = {sa[0], sa[1], sa[2], sa[3], sa[4], sa[5]};
                        f_et[frames_sent]      = 16'(ethType);
                        f_payload[frames_sent] = payload;
                        f_len[frames_sent]     = n;
                    end

                    send_frame(payload,
                               {da[0], da[1], da[2], da[3], da[4], da[5]},
                               {sa[0], sa[1], sa[2], sa[3], sa[4], sa[5]},
                               16'(ethType), readyGap);
                    frames_sent++;
                end
            end
            $fclose(fd);
        end
    endtask

endmodule

`endif
