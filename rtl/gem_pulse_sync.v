//----------------------------------------------------------------------------
// gem_pulse_sync -- carry a one-cycle event across a clock domain boundary.
//
// A pulse cannot be synchronised directly: two flops sample the destination
// clock's view of it, and a pulse narrower than that clock's period may be
// missed entirely or stretched. The standard answer, used here, is to convert
// the event to a level change in the source domain, synchronise the level, and
// recover the edge in the destination domain.
//
// THE RATE THIS IS SAFE AT, since it is not safe at any rate. A toggle
// synchroniser needs the source events to be at least two or three destination
// clocks apart, because a second toggle arriving before the first has been
// seen simply cancels it. Here both domains run at 125 MHz nominal and the
// events are per-frame: B.3a's worst-case frame rate is 1.488 Mframe/s, one
// event per 84 cycles at the very fastest, with the five RX classes mutually
// exclusive within a frame. Eighty-four cycles against a requirement of three
// is not a close call, but it is the reason this structure is allowed here and
// would not be for, say, a per-octet event.
//
// R19 counts this as a documented synchroniser rather than an undeclared CDC
// path -- which is the distinction report_cdc will be asked to confirm at
// Stage 6.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg toggle;
    reg sync1, sync2, sync3;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            toggle <= 1'b0;
        end else if (src_pulse) begin
            toggle <= ~toggle;
        end
    end

    // Two flops to resolve metastability, a third to give the edge detector
    // something stable to compare against.
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync1 <= 1'b0;
            sync2 <= 1'b0;
            sync3 <= 1'b0;
        end else begin
            sync1 <= toggle;
            sync2 <= sync1;
            sync3 <= sync2;
        end
    end

    assign dst_pulse = sync3 ^ sync2;

endmodule
