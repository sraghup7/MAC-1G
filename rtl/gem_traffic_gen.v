//----------------------------------------------------------------------------
// gem_traffic_gen -- a transmit-only AXI-Stream source that lets the board
// source its own line-rate traffic, at one payload octet per cycle. At 125 MHz
// that is 1 Gbit/s of payload by construction, at any frame size.
//
// WHY THIS MODULE EXISTS. tx_urun (B.5) counts aborted frames, and an
// abort only happens when the transmit side starves. A host cannot produce a
// starvation test that means anything: the PCIe/USB path that feeds the board
// cannot deliver a 125 MHz octet stream with no gaps, so every gap a capture
// shows could be blamed on the host instead of the MAC. This module removes
// that excuse -- while enabled it offers one octet every cycle, forever, so
// any gap that appears on the wire is the MAC's, not the source's.
//
// THE NO-BUBBLE RULE IS THE WHOLE MODULE. The transmit path of gem_mac runs
// at exactly 1.0 cycles per octet, end to end. There is no buffering here for
// the MAC to draw on, so a single cycle where tvalid is low between a frame's
// first and last octet is an underrun, and B.4b records that an underrun is
// an aborted frame that steps tx_urun. Idling *between* frames is harmless --
// the MAC fills its own inter-frame gap -- so the only rule that matters is:
// once a frame starts, tvalid does not fall until its last octet has been
// accepted. When tready drops that is the sink's gap, not ours: tdata and
// tlast are held and nothing advances. This module never invents a gap of
// its own.
//
// PAYLOAD IS A COUNTER. Octet i of a frame is i[7:0]. Deterministic and one
// adder, and it makes the frame offset directly visible in a capture. No
// LFSR: nothing here needs randomness, and a wrong one looks like a link
// fault while a counter that is off by one is obvious.
//
// THE CLAMP. payload_len below 46 or above 1500 is a caller error. This
// module clamps into range where the length is sampled rather than refusing,
// because it has no way to report an error, and a silent zero-length frame
// (tlast on the very first beat, no payload at all) is far harder to
// diagnose on a capture than a frame that is merely a little long or short.
//
// THE HEADER. gem_mac carries the frame header out of band on tuser as
// {DA, SA, EtherType}, MSO first, so this module emits it as a constant
// rather than counting it through tdata. The defaults mirror sw/host/flood.py,
// which sends *to* ...:01; this module transmits *from* it. They are correct
// as written -- do not swap them.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_traffic_gen #(
    parameter [47:0] DA        = 48'h02_00_00_00_00_02,   // the host
    parameter [47:0] SA        = 48'h02_00_00_00_00_01,   // the board
    parameter [15:0] ETHERTYPE = 16'h88B5
) (
    input  wire        clk,           // tx_clk
    input  wire        rst_n,         // tx_rst_n, async assert, active low
    input  wire        enable,        // level
    input  wire [10:0] payload_len,   // payload octets per frame

    output wire [7:0]   m_tdata,
    output wire         m_tvalid,
    input  wire         m_tready,
    output wire         m_tlast,
    output wire [111:0] m_tuser
);

    localparam [10:0] MIN_LEN = 11'd46;    // Ethernet minimum payload
    localparam [10:0] MAX_LEN = 11'd1500;  // Ethernet maximum payload

    // payload_len, clamped where it is sampled. Clamping rather than
    // refusing: no way to report an error, and a silent zero-length frame is
    // harder to diagnose than a clamped one. See the header.
    wire [10:0] len_clamped =
        (payload_len < MIN_LEN) ? MIN_LEN :
        (payload_len > MAX_LEN) ? MAX_LEN :
                                  payload_len;

    // active: a frame is in progress. This register is the entire no-bubble
    // guarantee: it is set in exactly one place (a frame start, below) and
    // cleared in exactly one place (the last beat accepted, below), and the
    // clear only happens when tready is high -- so tvalid (= active) cannot
    // fall mid-frame for any reason other than the sink's own backpressure.
    reg active;

    // count: the payload octet currently being offered. Octet i of a frame
    // is i[7:0], so m_tdata is count's low byte.
    reg [10:0] count;

    // len: this frame's payload length, sampled at the frame start and held,
    // so changing payload_len mid-frame cannot truncate a frame.
    reg [10:0] len;

    wire last_beat = active && (count == (len - 11'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            count  <= 11'd0;
            len    <= 11'd0;
        end else if (!active) begin
            // Idle. A frame starts only here, at a frame boundary, and only
            // while enabled.
            if (enable) begin
                active <= 1'b1;
                len    <= len_clamped;
                count  <= 11'd0;
            end
        end else if (m_tready) begin
            // A beat was accepted. Advance, or end the frame.
            if (last_beat) begin
                if (enable) begin
                    // Back to back: the next frame's first octet is offered
                    // next cycle and its length is sampled now, which is
                    // still a frame boundary. One idle cycle is allowed
                    // between frames but not required; none is used.
                    count <= 11'd0;
                    len   <= len_clamped;
                end else begin
                    // enable dropped mid-frame: the frame finishes, and then
                    // it stops. Stopping in the middle would create exactly
                    // the underrun this module exists to avoid.
                    active <= 1'b0;
                end
            end else begin
                count <= count + 11'd1;
            end
        end
        // else: tready is low -- the sink is backpressuring. Nothing moves;
        // tdata and tlast hold. That gap belongs to the sink, not to us.
    end

    assign m_tdata  = count[7:0];
    assign m_tvalid = active;             // low whenever idle, so this can be
                                          // muxed against another master
                                          // without two drivers
    assign m_tlast  = last_beat;
    assign m_tuser  = {DA, SA, ETHERTYPE};

endmodule
