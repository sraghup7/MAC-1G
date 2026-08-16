//----------------------------------------------------------------------------
// gem_tx_ingress -- B.1a module 1: the AXI-Stream ingress register.
//
// Two octets deep, and the depth is derived rather than picked. R15 requires a
// registered handshake with no combinational path through it, so tready is a
// register output; a one-deep holding register with a registered tready can
// only ever run at half rate, because the cycle that fills it is a cycle in
// which tready must already have gone low. Two entries is the smallest depth
// that sustains one octet per cycle, which B.3 says is not negotiable: at
// exactly 1.0 cycles per byte a single bubble mid-frame is an underrun, and
// per B.4b an underrun is an aborted frame.
//
// What is NOT here is any attempt to buffer a frame. This is a skid register
// that keeps the datapath fed, not a store-and-forward buffer -- B.4b rejected
// buffering on the project's own latency terms, and two octets is three orders
// of magnitude short of a frame in any case.
//
// tready's D input depends on tvalid and tlast, which is not the same thing as
// a combinational path from tvalid to tready: the port is driven by a flop, so
// nothing downstream of the user's tvalid reaches a pin or another module in
// the same cycle. Every AXI-Stream sink that accepts back-to-back beats is
// built this way; the alternative -- deriving tready from tvalid through logic
// -- is the one R15 forbids.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_tx_ingress (
    input  wire        clk,
    input  wire        rst_n,

    // ---- user side (R15) ----
    input  wire [7:0]  s_tdata,
    input  wire        s_tvalid,
    output reg         s_tready,
    input  wire        s_tlast,

    // ---- engine side ----
    // accept: the engine is willing to take octets of the current frame. It
    //         goes high two cycles before the payload phase, because tready is
    //         registered and the first octet has to be sitting here on the
    //         first payload cycle -- the datapath has no cycle to wait in.
    input  wire        accept,
    input  wire        pop,

    output wire        beat_valid,
    output wire [7:0]  beat_data,
    output wire        beat_last
);

    reg  [8:0] q0, q1;          // {last, data}
    reg  [1:0] level;

    // A frame's last beat has been taken but the engine has not finished with
    // the frame yet. Without this, tready would go back up in the cycle after
    // tlast and the ingress would swallow the first octet of the *next* frame
    // while the engine was still emitting this one's FCS -- a beat that then
    // belongs to a frame whose header was never captured.
    reg        frame_taken;

    wire       push     = s_tvalid && s_tready;
    wire       pop_eff  = pop && (level != 2'd0);
    wire       last_taken = push && s_tlast;

    wire [1:0] level_next = level + {1'b0, push} - {1'b0, pop_eff};

    assign beat_valid = (level != 2'd0);
    assign beat_data  = q0[7:0];
    assign beat_last  = q0[8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q0    <= 9'd0;
            q1    <= 9'd0;
            level <= 2'd0;
        end else begin
            case ({push, pop_eff})
                2'b10: begin
                    if (level == 2'd0) q0 <= {s_tlast, s_tdata};
                    else               q1 <= {s_tlast, s_tdata};
                    level <= level + 2'd1;
                end
                2'b01: begin
                    q0    <= q1;
                    level <= level - 2'd1;
                end
                2'b11: begin
                    if (level == 2'd1) begin
                        q0 <= {s_tlast, s_tdata};
                    end else begin
                        q0 <= q1;
                        q1 <= {s_tlast, s_tdata};
                    end
                end
                default: begin
                    q0    <= q0;
                    q1    <= q1;
                    level <= level;
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_taken <= 1'b0;
        end else if (!accept) begin
            frame_taken <= 1'b0;
        end else if (last_taken) begin
            frame_taken <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_tready <= 1'b0;
        end else begin
            s_tready <= accept && !frame_taken && !last_taken
                        && (level_next <= 2'd1);
        end
    end

endmodule
