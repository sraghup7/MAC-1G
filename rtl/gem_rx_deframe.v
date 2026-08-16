//----------------------------------------------------------------------------
// gem_rx_deframe -- B.1a modules 7 and 8: SFD hunter, deframer, FCS holdback,
// and the frame classifier. Everything here is in the rx_clk domain.
//
// THE SFD IS HUNTED FOR, NOT COUNTED TO (R8). The hunter scans every octet
// while RX_DV is asserted and starts the frame at the first 0xD5, wherever it
// falls. It does not assume seven octets of preamble, because senders trim it:
// a deframer that skips eight octets and starts there works perfectly against
// its own transmitter and fails against a switch. Everything before that SFD is
// dropped silently, and a DV burst with no SFD in it touches nothing at all
// (R11) -- not a counter, not a flag. Inter-frame garbage is normal on a real
// link, which is why rx_garbage seeds the gap with 0xD5 octets: a hunter that
// scans while DV is low is caught by the only test that would ever catch it.
//
// THE FOUR-OCTET HOLDBACK, which is not an optimisation and not a choice.
// B.4a says the user port carries DA through pad and never the FCS, and R9
// says delivery is cut-through. Those two together force a delay line: nothing
// can know which four octets are the FCS until RX_DV drops, so the last four
// octets received must still be inside the pipeline at that moment in order to
// be discarded rather than delivered. Those are four of the thirteen cycles in
// B.1b's latency sum, and they are the four that v0.2's arithmetic missed.
//
// A fifth register follows the holdback, and it is what makes tlast possible:
// the octet about to be written is held one cycle so that when DV drops it can
// be tagged as the last beat and given the verdict. Without it the last beat
// would have to be written before anyone knew it was the last.
//
// CLASSIFICATION PRECEDENCE is rxer > oversize > runt > badfcs, decided in
// B.4a item 3 and implemented as a priority chain below. A frame can be in
// several classes at once -- a truncated frame is usually a runt AND an FCS
// failure -- so without a stated order the model and this module would pick
// differently and every counter comparison in the regression would mismatch.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_rx_deframe (
    input  wire        clk,            // rx_clk
    input  wire        rst_n,

    // ---- from the RGMII input stage ----
    input  wire [7:0]  gm_byte,
    input  wire        gm_dv,
    input  wire        gm_er,

    // ---- CRC accumulator ----
    output wire        crc_init,
    output wire        crc_en,
    output wire [7:0]  crc_data,
    input  wire        crc_residue_ok,

    // ---- to the async FIFO: {user, last, data} ----
    output reg         fifo_wr,
    output reg  [9:0]  fifo_din,

    // ---- R17 event pulses, rx_clk domain ----
    output reg         ev_rx_ok,
    output reg         ev_rx_badfcs,
    output reg         ev_rx_runt,
    output reg         ev_rx_oversize,
    output reg         ev_rx_rxer
);

    localparam [7:0]  P_SFD           = `GEM_SFD_OCTET;
    localparam [10:0] P_MIN_FRAME     = `GEM_MIN_FRAME_BYTES;
    localparam [10:0] P_MAX_FRAME     = `GEM_MAX_FRAME_BYTES;
    localparam [10:0] P_LEN_SAT       = 11'd2047;

    // Named for gem_internal_sva, which binds to state and frame_active by
    // those names. Only two of the five encodings the assertion permits are
    // used; the assertion is written against the encoding rather than the
    // count, so an FSM that grows a state later is still covered.
    localparam [2:0] ST_HUNT = 3'd0,
                     ST_RECV = 3'd1;

    reg  [2:0]  state;

    /* verilator lint_off UNUSEDSIGNAL */
    // Justified suppression (R22 permits one with a reason): frame_active is
    // driven for gem_internal_sva to bind to, not for this module's own logic.
    // a_rx_recovers_in_budget triggers on its falling edge -- R10's "recover
    // cleanly" measured against the 8-cycle gap floor -- and an assertion
    // cannot watch a condition the RTL never names. Deleting the signal would
    // silence the linter by deleting the observability.
    reg         frame_active;
    /* verilator lint_on UNUSEDSIGNAL */

    reg  [7:0]  hb0, hb1, hb2, hb3;   // the four-octet FCS holdback
    reg  [7:0]  out_byte;             // the fifth register: the pending beat
    reg         out_valid;
    reg  [10:0] len;                  // octets received, DA..FCS as received
    reg         er_sticky;

    wire        eof = (state == ST_RECV) && !gm_dv;

    //------------------------------------------------------------------
    // CRC control
    //------------------------------------------------------------------
    //
    // The accumulator runs straight through the received FCS and the verdict
    // is a residue comparison (R9, gem.fcsResidue) -- one comparator, no
    // second accumulator, no "freeze four octets early".
    //
    // init is asserted on the end-of-frame cycle as well as while hunting, one
    // cycle earlier than it looks like it needs to be. That is what makes
    // gem_internal_sva's a_crc_reseeded true on the *first* hunting cycle
    // rather than the second: re-seeding when the hunt begins would leave one
    // cycle in which the state says "hunting" and the accumulator still holds
    // the last frame's remainder. The assertion would be right to fail, and a
    // frame arriving at the 8-cycle gap floor would be poisoned by its
    // predecessor.
    assign crc_init = (state == ST_HUNT) || eof;
    assign crc_en   = (state == ST_RECV) && gm_dv;
    assign crc_data = gm_byte;

    //------------------------------------------------------------------
    // Classification, in B.4a's precedence order
    //------------------------------------------------------------------
    wire cls_rxer     = er_sticky;
    wire cls_oversize = !cls_rxer && (len > P_MAX_FRAME);
    wire cls_runt     = !cls_rxer && !cls_oversize && (len < P_MIN_FRAME);
    wire cls_badfcs   = !cls_rxer && !cls_oversize && !cls_runt && !crc_residue_ok;
    wire cls_ok       = !cls_rxer && !cls_oversize && !cls_runt && !cls_badfcs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_HUNT;
            frame_active   <= 1'b0;
            hb0            <= 8'd0;
            hb1            <= 8'd0;
            hb2            <= 8'd0;
            hb3            <= 8'd0;
            out_byte       <= 8'd0;
            out_valid      <= 1'b0;
            len            <= 11'd0;
            er_sticky      <= 1'b0;
            fifo_wr        <= 1'b0;
            fifo_din       <= 10'd0;
            ev_rx_ok       <= 1'b0;
            ev_rx_badfcs   <= 1'b0;
            ev_rx_runt     <= 1'b0;
            ev_rx_oversize <= 1'b0;
            ev_rx_rxer     <= 1'b0;
        end else begin
            ev_rx_ok       <= 1'b0;
            ev_rx_badfcs   <= 1'b0;
            ev_rx_runt     <= 1'b0;
            ev_rx_oversize <= 1'b0;
            ev_rx_rxer     <= 1'b0;

            //----------------------------------------------------------
            // The pending beat, written one cycle after it was chosen so
            // that end-of-frame can tag it. B.4a item 2: every frame ends
            // with exactly one tlast at the natural end of its DV burst,
            // whatever went wrong -- errors detectable mid-frame do not cut
            // the stream short, so there is one tlast timing here rather
            // than two.
            //----------------------------------------------------------
            fifo_wr  <= out_valid;
            fifo_din <= {cls_ok && eof, eof, out_byte};

            case (state)
                ST_HUNT: begin
                    out_valid <= 1'b0;
                    if (gm_dv && (gm_byte == P_SFD)) begin
                        state        <= ST_RECV;
                        frame_active <= 1'b1;
                        len          <= 11'd0;
                        er_sticky    <= 1'b0;
                    end
                end

                ST_RECV: begin
                    if (gm_dv) begin
                        // Deliver the octet leaving the holdback, once there
                        // is one: four octets in means the fifth pushes the
                        // first out.
                        out_byte  <= hb3;
                        out_valid <= (len >= 11'd4);

                        hb3 <= hb2;
                        hb2 <= hb1;
                        hb1 <= hb0;
                        hb0 <= gm_byte;

                        // Saturating, because a length that wraps would score
                        // a giant frame as a runt -- the one arithmetic error
                        // in this module that would produce a plausible-
                        // looking counter rather than an obvious one.
                        if (len < P_LEN_SAT) begin
                            len <= len + 11'd1;
                        end

                        if (gm_er) begin
                            er_sticky <= 1'b1;
                        end
                    end else begin
                        // End of the DV burst: classify, count, and go back to
                        // hunting immediately. R10's "recover cleanly" is
                        // measured against the 8-byte gap floor a compliant
                        // link may present (Table 4-2 Note 3), and this costs
                        // one cycle of it.
                        out_valid    <= 1'b0;
                        frame_active <= 1'b0;
                        state        <= ST_HUNT;

                        ev_rx_ok       <= cls_ok;
                        ev_rx_badfcs   <= cls_badfcs;
                        ev_rx_runt     <= cls_runt;
                        ev_rx_oversize <= cls_oversize;
                        ev_rx_rxer     <= cls_rxer;
                    end
                end

                default: begin
                    state        <= ST_HUNT;
                    frame_active <= 1'b0;
                    out_valid    <= 1'b0;
                end
            endcase
        end
    end

endmodule
