//----------------------------------------------------------------------------
// gem_tx_engine -- B.1a modules 2 and 4: frame assembler, padder, and the
// transmit arbiter that owns the inter-frame gap and the abort sequence.
//
// One octet per cycle, every cycle, from the first preamble octet to the last
// FCS octet. B.3 is the constraint that shapes everything here: cycles per byte
// is exactly 1.0, so there is no cycle anywhere in a frame in which this state
// machine may think. Every decision is made from state that already exists --
// which is why padding is counted rather than computed, and why the FCS comes
// out of a register that was updated by the octet emitted on the previous
// cycle rather than out of a finalisation step.
//
// THE THREE WAYS A FRAME CAN END, and only the first is the happy one:
//
//   1. tlast, pad if short (R3), append the FCS (R4), take the gap (R5),
//      count stat_tx_ok.
//
//   2. UNDERRUN (B.4b). The user stops supplying mid-payload. RGMII has no
//      pause once TX_EN is up, so the frame is aborted, not stalled: the FCS
//      over what was actually sent goes out bitwise inverted with TX_ER across
//      those four octets, the remainder of the frame is drained and discarded
//      rather than resumed, and stat_tx_underrun counts it. Not stat_tx_ok --
//      an aborted frame is not a transmitted frame.
//
//   3. OVERSIZE (R6). See the long note below; this is the one place where
//      what the frozen vectors expect and what a cut-through MAC can physically
//      do are not the same thing.
//
// -------------------------------------------------------------------------
// R6, AND WHY THIS IMPLEMENTATION CANNOT MATCH THE tx_reject_oversize VECTOR
// -------------------------------------------------------------------------
// R6 says reject payloads over 1500 octets and never emit an oversize frame.
// The frozen vector goes further: it expects *nothing at all* on the wire for
// the 1501-octet request, and that expectation cannot be met by any design
// that also satisfies B.4b.
//
// The transmit interface carries no length. A frame's length is known only
// when tlast arrives, and B.4b's cut-through decision means TX_EN went up long
// before that -- 22 MAC-generated octets in, at the latest. To know the length
// before committing, the MAC would have to hold the whole frame first, which is
// store-and-forward: 1518 cycles (12.14 us) of added transmit latency and a
// BRAM the B.2 table does not carry, rejected in B.4b on this project's own
// latency premise. The two requirements are jointly unsatisfiable, and no
// arrangement of buffering resolves it -- a threshold buffer deep enough to
// decide is exactly a whole-frame buffer.
//
// So this engine does the strongest thing that is physically available, which
// is stronger than a plain abort: it refuses the payload octet that would be
// the 1501st *before* transmitting it. The frame on the wire is then
// 14 + 1499 + 4 = 1517 octets -- inside maxBasicFrameSize, so R6's "never emit
// an oversize frame" holds literally -- marked bad twice over with TX_ER and an
// inverted FCS, counted in stat_tx_rejected, with the rest of the request
// drained and discarded. All three R17 counters therefore match the frozen
// expectation exactly; what does not match is that the wire carries a marked-
// bad frame rather than silence.
//
// This is a specification finding, not an implementation shortcut. Closing it
// means amending the model (a rejected frame's expected cycles), regenerating
// tx_reject_oversize, and recording the decision in the spec -- deliberately
// not done here, because changing a frozen Stage 3 vector to suit the RTL is
// exactly backwards unless the decision is made explicitly first.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_tx_engine (
    input  wire         clk,
    input  wire         rst_n,

    // ---- ingress register ----
    input  wire         beat_valid,
    input  wire [7:0]   beat_data,
    input  wire         beat_last,
    output reg          accept,
    output reg          pop,

    // ---- per-frame header sideband (R2/R15), sampled at SOF ----
    input  wire         s_tvalid,
    input  wire [111:0] s_tuser,

    // ---- CRC accumulator ----
    output wire         crc_init,
    output reg          crc_en,
    output wire [7:0]   crc_data,
    input  wire [31:0]  crc,

    // ---- GMII-style stream to the RGMII output stage ----
    output reg  [7:0]   gm_byte,
    output reg          gm_dv,
    output reg          gm_er,

    // ---- R17 event pulses, one cycle each, tx_clk domain ----
    output reg          ev_tx_ok,
    output reg          ev_tx_rejected,
    output reg          ev_tx_underrun
);

    // Sized copies of the shared constants. The params header keeps them
    // unsized so the MATLAB parser can read them as plain numbers; Verilog
    // cannot part-select or width-match an unsized literal, so each one is
    // given its width exactly once, here.
    localparam [3:0]  P_PREAMBLE_BYTES = `GEM_PREAMBLE_BYTES;
    localparam [3:0]  P_HEADER_BYTES   = `GEM_HEADER_BYTES;
    localparam [3:0]  P_IFG_BYTES      = `GEM_IFG_BYTES;
    localparam [10:0] P_MIN_PAYLOAD    = `GEM_MIN_PAYLOAD_BYTES;
    localparam [10:0] P_MAX_PAYLOAD    = `GEM_MAX_PAYLOAD_BYTES;

    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_PRE   = 3'd1,
                     ST_HDR   = 3'd2,
                     ST_PAY   = 3'd3,
                     ST_PAD   = 3'd4,
                     ST_FCS   = 3'd5,
                     ST_DRAIN = 3'd6;

    reg  [2:0]   state;
    reg  [3:0]   sub_cnt;      // within preamble (0..7) or header (0..13)
    reg  [1:0]   fcs_idx;
    reg  [10:0]  dat_cnt;      // payload + pad octets emitted (R3's counter)
    reg  [111:0] hdr;
    reg          invert;       // this frame is being aborted (B.4b)
    reg  [3:0]   ifg_cnt;

    //------------------------------------------------------------------
    // Header octet select. tuser is {DA[47:0], SA[47:0], EtherType[15:0]}
    // and goes out most significant octet first -- DA first, and the
    // Length/Type field big-endian at octet granularity (Clause 3.2.6), which
    // is the one field in the frame that is.
    //------------------------------------------------------------------
    wire [6:0] hdr_off  = {sub_cnt, 3'b000};
    wire [7:0] hdr_byte = hdr[(7'd104 - hdr_off) +: 8];

    //------------------------------------------------------------------
    // FCS octets. Transmission order is least significant octet first (R4),
    // and the abort's inverted FCS is the same register without the final
    // complement -- literally the one XOR B.4b item 4 budgets for.
    //------------------------------------------------------------------
    wire [4:0] fcs_off  = {fcs_idx, 3'b000};
    wire [7:0] fcs_good = ~crc[fcs_off +: 8];
    wire [7:0] fcs_bad  =  crc[fcs_off +: 8];

    //------------------------------------------------------------------
    // The two ways a payload octet is refused
    //------------------------------------------------------------------
    wire underrun_now = (state == ST_PAY) && !beat_valid;
    wire oversize_now = (state == ST_PAY) && beat_valid && !beat_last &&
                        (dat_cnt == (P_MAX_PAYLOAD - 11'd1));
    wire abort_now    = underrun_now || oversize_now;

    // ifg_cnt counts idle cycles completed BEFORE the current one, and the
    // current one is idle too -- so the gap the wire will show if a frame
    // starts on the next cycle is ifg_cnt + 1. Getting this accounting wrong
    // by one is the difference between a compliant 12 and an 11 that a link
    // partner is entitled to drop.
    wire ifg_ok = ((ifg_cnt + 4'd1) >= P_IFG_BYTES);

    assign crc_init = (state == ST_IDLE) || (state == ST_PRE);
    assign crc_data = gm_byte;

    //------------------------------------------------------------------
    // Output mux. Defaults first, so no path through this block can leave a
    // signal unassigned -- an incomplete always @(*) is an inferred latch, and
    // R23 refuses the build over one whether or not it survives optimisation.
    //------------------------------------------------------------------
    always @(*) begin
        gm_byte = 8'h00;
        gm_dv   = 1'b0;
        gm_er   = 1'b0;
        pop     = 1'b0;
        crc_en  = 1'b0;

        case (state)
            ST_PRE: begin
                gm_dv   = 1'b1;
                gm_byte = (sub_cnt == P_PREAMBLE_BYTES) ?
                              `GEM_SFD_OCTET : `GEM_PREAMBLE_OCTET;
            end

            ST_HDR: begin
                gm_dv   = 1'b1;
                gm_byte = hdr_byte;
                crc_en  = 1'b1;
            end

            ST_PAY: begin
                gm_dv = 1'b1;
                if (abort_now) begin
                    // The abort tail starts in this very cycle: the wire may
                    // not be given a bubble, so the octet that would have been
                    // payload is the first inverted FCS octet instead. crc
                    // already covers everything transmitted, because it was
                    // updated by the octet emitted on the previous cycle.
                    gm_byte = crc[7:0];
                    gm_er   = 1'b1;
                end else begin
                    gm_byte = beat_data;
                    crc_en  = 1'b1;
                    pop     = 1'b1;
                end
            end

            ST_PAD: begin
                // R3 / Clause 3.2.8. Zeros are conventional and are what the
                // golden model expects; pad content is not specified.
                gm_dv   = 1'b1;
                gm_byte = 8'h00;
                crc_en  = 1'b1;
            end

            ST_FCS: begin
                gm_dv   = 1'b1;
                gm_byte = invert ? fcs_bad : fcs_good;
                gm_er   = invert;
            end

            ST_DRAIN: begin
                // B.4b item 5: the rest of a frame that was aborted is
                // discarded, never resumed. A MAC that picked up where it left
                // off would emit a frame with a hole in it and a valid FCS,
                // which is far worse than one plainly marked bad.
                pop = beat_valid;
            end

            default: begin
                gm_byte = 8'h00;
            end
        endcase
    end

    //------------------------------------------------------------------
    // Sequencer
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            sub_cnt        <= 4'd0;
            fcs_idx        <= 2'd0;
            dat_cnt        <= 11'd0;
            hdr            <= 112'd0;
            invert         <= 1'b0;
            accept         <= 1'b0;
            ifg_cnt        <= 4'd0;
            ev_tx_ok       <= 1'b0;
            ev_tx_rejected <= 1'b0;
            ev_tx_underrun <= 1'b0;
        end else begin
            ev_tx_ok       <= 1'b0;
            ev_tx_rejected <= 1'b0;
            ev_tx_underrun <= 1'b0;

            // Reset by any transmitted octet, so the count only ever measures
            // gap. Saturates rather than wrapping: a long idle must not look
            // like a short one.
            if (gm_dv) begin
                ifg_cnt <= 4'd0;
            end else if (!ifg_ok) begin
                ifg_cnt <= ifg_cnt + 4'd1;
            end

            case (state)
                ST_IDLE: begin
                    accept <= 1'b0;
                    invert <= 1'b0;
                    if (s_tvalid && ifg_ok) begin
                        // R2: the header is a per-frame input, sampled here
                        // and held, so the user is free to change it for the
                        // next frame the moment this one starts.
                        hdr     <= s_tuser;
                        sub_cnt <= 4'd0;
                        state   <= ST_PRE;
                    end
                end

                ST_PRE: begin
                    if (sub_cnt == P_PREAMBLE_BYTES) begin
                        sub_cnt <= 4'd0;
                        state   <= ST_HDR;
                    end else begin
                        sub_cnt <= sub_cnt + 4'd1;
                    end
                end

                ST_HDR: begin
                    // Two cycles before the payload phase, because tready is
                    // registered and the ingress needs a cycle to fill: the
                    // first payload octet has to be sitting in the ingress on
                    // the first payload cycle, not arriving during it.
                    //
                    // Written against the header length rather than as a bare
                    // 11, because that is what it means: the last header cycle
                    // is HEADER_BYTES-1, and the round trip out through tready
                    // and back in through tvalid is two of them.
                    if (sub_cnt == (P_HEADER_BYTES - 4'd3)) begin
                        accept <= 1'b1;
                    end

                    if (sub_cnt == (P_HEADER_BYTES - 4'd1)) begin
                        sub_cnt <= 4'd0;
                        dat_cnt <= 11'd0;
                        state   <= ST_PAY;
                    end else begin
                        sub_cnt <= sub_cnt + 4'd1;
                    end
                end

                ST_PAY: begin
                    if (underrun_now) begin
                        invert         <= 1'b1;
                        fcs_idx        <= 2'd1;   // octet 0 went out this cycle
                        ev_tx_underrun <= 1'b1;
                        state          <= ST_FCS;
                    end else if (oversize_now) begin
                        invert         <= 1'b1;
                        fcs_idx        <= 2'd1;
                        ev_tx_rejected <= 1'b1;
                        state          <= ST_FCS;
                    end else begin
                        dat_cnt <= dat_cnt + 11'd1;
                        if (beat_last) begin
                            if ((dat_cnt + 11'd1) < P_MIN_PAYLOAD) begin
                                state <= ST_PAD;
                            end else begin
                                fcs_idx <= 2'd0;
                                state   <= ST_FCS;
                            end
                        end
                    end
                end

                ST_PAD: begin
                    dat_cnt <= dat_cnt + 11'd1;
                    if ((dat_cnt + 11'd1) >= P_MIN_PAYLOAD) begin
                        fcs_idx <= 2'd0;
                        state   <= ST_FCS;
                    end
                end

                ST_FCS: begin
                    fcs_idx <= fcs_idx + 2'd1;
                    if (fcs_idx == 2'd3) begin
                        if (invert) begin
                            state <= ST_DRAIN;
                        end else begin
                            ev_tx_ok <= 1'b1;
                            state    <= ST_IDLE;
                        end
                    end
                end

                ST_DRAIN: begin
                    if (beat_valid && beat_last) begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
