//----------------------------------------------------------------------------
// gem_mdio -- R16's Clause 22 management interface: a register-level request
// port for software, and a sequencer that polls the PHY on its own.
//
// R16 asks for both halves and says so: "a register-level request interface;
// bring-up software (or a hardware sequencer) uses it to read PHY ID, link
// status, and resolved speed/duplex." The first draft of this module had only
// the sequencer, because the port list frozen in Stage 3 carried no request
// channel -- which made R16 half-implemented and B.5 bring-up step 3 ("MDIO
// reads PHY ID registers correctly, proving MDIO + PHY alive") impossible to
// perform. The ports were added rather than the requirement trimmed.
//
// WHY BOTH, when either alone looks sufficient:
//
//   the request port  is what "register-level" means. Any register, read or
//                     write, on demand -- including paged vendor registers a
//                     fixed poll list could not reach (see the JL2121(D) note
//                     below on how the poll sequencer itself now uses this
//                     same page-switch mechanism to read resolved speed).
//   the sequencer     is what makes the MAC debuggable with nothing attached.
//                     link_up, link_speed and phy_id are live on pins for an
//                     ILA or a VIO before any software exists, which is the
//                     situation bring-up steps 2 and 3 are actually conducted
//                     in.
//
// They share one state machine and cannot collide: a transaction runs to
// completion, and a request is accepted only while the master is idle. A
// pending request is served before the next poll, because a human waiting at a
// console beats a poll that will come round again in a few microseconds.
//
// Clause 22 frame, 64 MDC periods:
//   32 x 1   preamble
//   01       start
//   10 read / 01 write
//   5 bits   PHY address
//   5 bits   register address
//   2 bits   turnaround -- on a read the STA releases the bus and the PHY
//            drives 0; on a write the STA drives 1 then 0 and never releases
//   16 bits  data, from the PHY on a read and from the STA on a write
//
// MDC is 125 MHz / (2 x MDC_HALF). At the default MDC_HALF = 32 that is
// 1.95 MHz, inside R16's 2.5 MHz ceiling with margin rather than at it. MDIO
// changes on the falling edge of MDC, which gives half a period of setup
// against the PHY's sampling edge either way.
//
// WHERE READ DATA IS SAMPLED, and why it is not "on the rising edge". Clause
// 22 lets a PHY drive its read data anywhere from 0 to 300 ns after the MDC
// rising edge -- the pin may still be carrying the previous bit for the
// first third of the bit period. So the guaranteed-valid interval for bit N
// runs from roughly rising_N + 300 ns to rising_{N+1}, and the safe place to
// sample is the very end of it: the design captures MDIO on the last sys_clk
// before rising_{N+1}. Against the two transition regions that is >= 200 ns
// of margin on the old-bit side and >= 16 ns (the synchroniser's latency)
// on the new-bit side. An earlier revision sampled one sys_clk AFTER the
// rising edge instead -- inside the window where a fast PHY may already be
// changing the pin. The register-file testbench cannot discriminate the two
// points (it holds each bit a full period, so both read settled data),
// which is exactly why the choice is made here on the datasheet's
// arithmetic and recorded, rather than left to whichever arrangement
// happened to pass simulation.
//
// mdio_i passes through two synchroniser flops before anything samples it.
// It is timed against MDC, which this fabric generates, but the PHY's
// 0-300 ns skew makes the sampling instant asynchronous in fact; two flops
// turn that into an ordinary resolved signal, and cost 16 ns of visibility
// latency that the margins above already absorb.
//
// WHAT CANNOT BE CONFIRMED WITHOUT THE BOARD, stated rather than assumed:
//
//   * PHY_ADDR. The strap-determined address on the AX7035B is not in the
//     pinout notes in this repository. The default of 0 is the common case and
//     is a parameter precisely because it is a guess. It is also now
//     answerable on the bench without a rebuild: sweep the address over the
//     request port and watch phy_id stop reading as all-ones.
//
// THE PHY IS A JLSemi JL2121(D), NOT A KSZ9031RNX -- A.2's B.5 bring-up
// correction, and it changes register 0x1F's meaning, not just its bit
// layout. The board's Ethernet chip was assumed to be a Micrel/Microchip
// KSZ9031RNX (A.2); B.5 step 3 read phy_id back as 0x937c4032, which is not a
// KSZ9031RNX identifier at all. The JLSemi JL2121(D) datasheet
// (DS009-JL2121(D)-v1.09-Preliminary) confirms it exactly: PHYIDR1 defaults
// to 0x937c, and PHYIDR2's fixed OUI-LSB/model field is 0x402_, with the low
// nibble the silicon revision -- 0x4032 is revision 2. Both PHYIDR1 (0x2) and
// PHYIDR2 (0x3) are the standard Clause 22 addresses on this chip too, so the
// poll order below did not need to change to read them correctly.
//
// Register 0x1F did not survive the correction. On the KSZ9031RNX it was
// assumed to publish resolved speed and duplex directly. On the JL2121(D) it
// is the Page Select Register (PAGSR): the chip multiplexes several register
// banks (PHY Specific Control/Status at page 0xA43, LED control at 0xD04,
// SGMII registers at 0xD08/0xDC0, ...) onto the Clause 22 address space, and
// PAGSR picks which bank registers outside the Clause 22 basic set (0x0-0xF)
// currently mean. Reading 0x1F on this chip returns the page number, not a
// speed encoding -- treating it as one gave a case statement whose inputs
// never assert, silently freezing link_speed at its reset value forever.
// Resolved speed and duplex instead live in the PHY Specific Status Register
// (page 0xA43, register 0x1A): bits [5:4] are 00/01/10 for 10/100/1000 Mbps
// (11 reserved), bit 3 is duplex, bit 2 is a second, real-time link-up bit
// independent of BMSR's latch. This module reads only bits [5:4]; link_up
// still comes from BMSR, unchanged, because that is Clause 22 and does not
// depend on which vendor's PHY answers it.
//
// Reaching a paged register costs three transactions instead of one: write
// PAGSR = page, read (or write) the target register, write PAGSR back to the
// default page (0x0000) so the Clause 22 registers this module also polls --
// BMSR, PHYIDR1/2 -- read correctly again afterwards. The three are kept
// atomic against the request port below (see req_pending's guard) precisely
// because a request that landed while the vendor page was still selected
// would silently address the wrong register bank.
//
// WHAT THIS DOES NOT TOUCH: the RGMII clock-delay story. B.1b and the RX/TX
// timing documents assumed the KSZ9031RNX's MDIO-programmable MMD 2h/8h
// pad-skew registers as R14's escalation path if timing margin proves thin
// on the bench. The JL2121(D) datasheet has no MMD register-access chapter at
// all; RXDLY/TXDLY are hardware strap pins (board pins 25/24), each adding a
// fixed 0 or 2 ns and latched at reset, not written over MDIO. That escalation
// path does not exist on this chip -- see the note in `Documents/RGMII I-O
// Timing Derivation.md` and `docs/reports/stage9/known-issues.md`. Nothing in
// this module implements or assumes it either way; it only reads PHYSR.
//
// BMSR's link status is latching-low: it reports a link that has gone down
// since the last read, and only a second read shows the current state. So the
// poll reads it twice and believes the second -- a real bug avoided rather than
// a ritual, since a MAC that reports the link down forever after one glitch is
// worse than one that does not report at all.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_mdio #(
    parameter [4:0]   PHY_ADDR = 5'd0,
    parameter integer MDC_HALF = 32,       // tx_clk cycles per MDC half period
    parameter integer POLL_GAP = 4096      // tx_clk cycles between polls
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MDIO pins ----
    output reg         mdc,
    input  wire        mdio_i,
    output wire        mdio_o,
    output wire        mdio_t,              // 1 = released

    // ---- register-level request interface (R16) ----
    // Accepted on the cycle req_valid and req_ready are both high. One
    // transaction at a time; ready falls for the ~33 us the frame takes.
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,           // 1 = write, 0 = read
    input  wire [4:0]  req_phyad,
    input  wire [4:0]  req_regad,
    input  wire [15:0] req_wdata,
    output reg  [15:0] rsp_data,            // last completed read
    output reg         rsp_valid,           // one cycle, when that read landed

    // ---- what the sequencer found, live on pins for an ILA (B.5 steps 2-3) --
    output reg  [31:0] phy_id,              // {PHYIDR1, PHYIDR2}
    output reg         phy_id_valid,
    output reg         link_up,
    output reg [1:0]   link_speed           // 00=10, 01=100, 10=1000 (Clause 22)
);

    localparam [4:0] REG_BMSR    = 5'd1;    // Clause 22 basic status
    localparam [4:0] REG_PHYIDR1 = 5'd2;    // Clause 22 identifier, high
    localparam [4:0] REG_PHYIDR2 = 5'd3;    // Clause 22 identifier, low
    localparam [4:0] REG_PHYSR   = 5'd26;   // JL2121(D): page 0xA43, resolved speed/duplex
    localparam [4:0] REG_PAGSR   = 5'd31;   // JL2121(D): page select, every page

    localparam [15:0] PAGE_VENDOR  = 16'h0A43;  // where REG_PHYSR lives
    localparam [15:0] PAGE_DEFAULT = 16'h0000;  // where BMSR/PHYIDR1/2 live

    localparam [1:0] SPEED_10   = 2'b00,
                     SPEED_100  = 2'b01,
                     SPEED_1000 = 2'b10;

    // The poll cycle. PHY ID first, because it is the one that proves the bus
    // and the part are alive at all -- if it reads as all-ones or all-zeros,
    // nothing below it means anything. The last three steps are one paged
    // access to REG_PHYSR (see the header note): select the vendor page,
    // read the status register, then restore the default page so the next
    // POLL_ID_HI/BMSR reads land on the Clause 22 registers they expect.
    localparam [2:0] POLL_ID_HI       = 3'd0,
                     POLL_ID_LO       = 3'd1,
                     POLL_BMSR1       = 3'd2,
                     POLL_BMSR2       = 3'd3,
                     POLL_PAGE_SEL    = 3'd4,
                     POLL_PHYSR       = 3'd5,
                     POLL_PAGE_RESTORE = 3'd6;

    //------------------------------------------------------------------
    // MDC generation
    //------------------------------------------------------------------
    reg [15:0] div;
    reg        fall_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div     <= 16'd0;
            mdc     <= 1'b0;
            fall_en <= 1'b0;
        end else begin
            fall_en <= 1'b0;
            if (div == (MDC_HALF[15:0] - 16'd1)) begin
                div <= 16'd0;
                mdc <= ~mdc;
                if (mdc) fall_en <= 1'b1;   // mdc is about to go low
            end else begin
                div <= div + 16'd1;
            end
        end
    end

    // The read-sampling instant: the last sys_clk cycle of the MDC-low half
    // period, i.e. the sys_clk edge immediately before the rising edge. See
    // the header note -- this is the one point in the bit period Clause 22
    // guarantees the PHY's data stable.
    wire sample_now = (div == (MDC_HALF[15:0] - 16'd1)) && !mdc;

    // mdio_i synchronised into sys_clk before anything samples it. Held at
    // idle-high through reset, which is what a pulled-up MDIO reads as.
    // ASYNC_REG per gem_reset_sync.v/gem_pulse_sync.v: placement plus CDC
    // visibility to report_cdc (gate 4).
    (* ASYNC_REG = "TRUE" *) reg mdio_i_s1, mdio_i_s2;

    /* verilator lint_off SYNCASYNCNET */
    // Justified suppression (R22 permits one with a reason): these flops
    // deliberately sample an input asynchronously generated by the PHY --
    // that is what a signal synchroniser is. Same pattern as the reset
    // synchronisers in gem_rx_fifo.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdio_i_s1 <= 1'b1;
            mdio_i_s2 <= 1'b1;
        end else begin
            mdio_i_s1 <= mdio_i;
            mdio_i_s2 <= mdio_i_s1;
        end
    end
    /* verilator lint_on SYNCASYNCNET */

    //------------------------------------------------------------------
    // Transaction state
    //------------------------------------------------------------------
    reg  [5:0]  bit_cnt;         // 0..63 within the frame
    reg         active;
    reg  [15:0] shift_in;
    reg  [2:0]  poll_step;
    reg  [15:0] poll_wait;

    // A request is accepted immediately and started at the next MDC falling
    // edge -- see the note on req_ready below.
    reg         req_pending;
    reg         pend_write;
    reg  [4:0]  pend_phyad;
    reg  [4:0]  pend_regad;
    reg  [15:0] pend_wdata;

    // What the transaction in flight is doing, whichever source asked for it.
    reg         cur_write;
    reg         cur_is_req;      // came from the request port, not the poller
    reg  [4:0]  cur_phyad;
    reg  [4:0]  cur_regad;
    reg  [15:0] cur_wdata;

    wire [13:0] cmd = {2'b01, cur_write ? 2'b01 : 2'b10, cur_phyad, cur_regad};

    wire cmd_phase  = (bit_cnt >= 6'd32) && (bit_cnt < 6'd46);
    wire ta_phase   = (bit_cnt >= 6'd46) && (bit_cnt < 6'd48);
    wire data_phase = (bit_cnt >= 6'd48);

    // Across each phase the high bits of bit_cnt are constant, so the low
    // nibble is the offset into the field -- no subtractor.
    wire [3:0] cmd_pos  = bit_cnt[3:0];               // 32..45 -> 0..13
    wire       cmd_bit  = cmd[4'd13 - cmd_pos];
    wire [3:0] data_pos = bit_cnt[3:0];               // 48..63 -> 0..15
    wire       wdata_bit = cur_wdata[4'd15 - data_pos];

    // On a read the bus is released from the first turnaround bit -- Clause 22
    // requires it, and holding on one bit longer collides with the PHY driving
    // its zero. On a write the station owns the bus for all 64 periods.
    assign mdio_t = (!active)  ? 1'b1 :
                    (cur_write) ? 1'b0 :
                    ((ta_phase || data_phase) ? 1'b1 : 1'b0);

    assign mdio_o = cmd_phase              ? cmd_bit :
                    (cur_write && ta_phase)   ? (bit_cnt == 6'd46) :  // TA = 10
                    (cur_write && data_phase) ? wdata_bit :
                                                1'b1;

    // Requests are taken only between transactions, and only when none is
    // already waiting. ready is a function of registers alone, so nothing of
    // the requester's reaches the pins in the same cycle.
    assign req_ready = !active && !req_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt      <= 6'd0;
            active       <= 1'b0;
            shift_in     <= 16'd0;
            poll_step    <= POLL_ID_HI;
            poll_wait    <= 16'd0;
            req_pending  <= 1'b0;
            pend_write   <= 1'b0;
            pend_phyad   <= PHY_ADDR;
            pend_regad   <= 5'd0;
            pend_wdata   <= 16'd0;
            cur_write    <= 1'b0;
            cur_is_req   <= 1'b0;
            cur_phyad    <= PHY_ADDR;
            cur_regad    <= REG_PHYIDR1;
            cur_wdata    <= 16'd0;
            rsp_data     <= 16'd0;
            rsp_valid    <= 1'b0;
            phy_id       <= 32'd0;
            phy_id_valid <= 1'b0;
            link_up      <= 1'b0;
            link_speed   <= SPEED_1000;
        end else begin
            rsp_valid <= 1'b0;

            if (!active) begin
                if (poll_wait < POLL_GAP[15:0]) begin
                    poll_wait <= poll_wait + 16'd1;
                end

                if (req_valid && req_ready) begin
                    req_pending <= 1'b1;
                    pend_write  <= req_write;
                    pend_phyad  <= req_phyad;
                    pend_regad  <= req_regad;
                    pend_wdata  <= req_wdata;
                end

                // FRAMES START ON A FALLING EDGE, NOT ON AN ARBITRARY CYCLE.
                // bit_cnt advances on fall_en, so a frame begun while MDC is
                // high spends its first bit period with no rising edge in it --
                // and the PHY samples on rising edges. It would see 31 preamble
                // ones instead of 32. Most PHYs tolerate that; Clause 22 does
                // not promise they will, and a marginal preamble is exactly the
                // kind of thing a bring-up session loses a day to. Aligning
                // costs at most one MDC half period of latency on a request.
                if (fall_en) begin
                    // A pending request is deferred, not just delayed, while
                    // the poll sequencer has the vendor page selected -- see
                    // the header note on REG_PAGSR. POLL_PHYSR is the read
                    // taken with page 0xA43 live; POLL_PAGE_RESTORE is the
                    // write that takes it back to 0x0000 and has not landed
                    // yet. Letting a request in at either point would
                    // address whatever register it asked for inside the
                    // wrong page, silently. POLL_PAGE_SEL is safe to
                    // preempt: the page is still 0x0000 until that write
                    // completes, so displacing it changes nothing about
                    // which page is selected.
                    if (req_pending && (poll_step != POLL_PHYSR) &&
                                       (poll_step != POLL_PAGE_RESTORE)) begin
                        // A waiting request goes first. The poll it displaces
                        // comes round again on its own.
                        bit_cnt     <= 6'd0;
                        active      <= 1'b1;
                        req_pending <= 1'b0;
                        cur_write   <= pend_write;
                        cur_is_req  <= 1'b1;
                        cur_phyad   <= pend_phyad;
                        cur_regad   <= pend_regad;
                        cur_wdata   <= pend_wdata;
                    end else if (poll_wait >= POLL_GAP[15:0]) begin
                        poll_wait  <= 16'd0;
                        bit_cnt    <= 6'd0;
                        active     <= 1'b1;
                        cur_is_req <= 1'b0;
                        cur_phyad  <= PHY_ADDR;
                        case (poll_step)
                            POLL_ID_HI: begin
                                cur_write <= 1'b0;
                                cur_regad <= REG_PHYIDR1;
                            end
                            POLL_ID_LO: begin
                                cur_write <= 1'b0;
                                cur_regad <= REG_PHYIDR2;
                            end
                            POLL_BMSR1, POLL_BMSR2: begin
                                cur_write <= 1'b0;
                                cur_regad <= REG_BMSR;
                            end
                            POLL_PAGE_SEL: begin
                                // Select the vendor page before reading
                                // PHYSR -- see the header note.
                                cur_write <= 1'b1;
                                cur_regad <= REG_PAGSR;
                                cur_wdata <= PAGE_VENDOR;
                            end
                            POLL_PHYSR: begin
                                cur_write <= 1'b0;
                                cur_regad <= REG_PHYSR;
                            end
                            POLL_PAGE_RESTORE: begin
                                // Back to the default page so the next
                                // POLL_ID_HI/BMSR reads land on the Clause
                                // 22 registers they expect.
                                cur_write <= 1'b1;
                                cur_regad <= REG_PAGSR;
                                cur_wdata <= PAGE_DEFAULT;
                            end
                            default: begin
                                cur_write <= 1'b0;
                                cur_regad <= REG_BMSR;
                            end
                        endcase
                    end
                end
            end else begin
                // Sample just before the rising edge, through the
                // synchroniser: the one instant Clause 22 guarantees. The
                // bit being captured belongs to the current bit_cnt period,
                // exactly as before -- only the position within the period
                // moved, from its contested start to its guaranteed end.
                if (sample_now && data_phase && !cur_write) begin
                    shift_in <= {shift_in[14:0], mdio_i_s2};
                end

                if (fall_en) begin
                    if (bit_cnt == 6'd63) begin
                        active <= 1'b0;

                        if (cur_is_req) begin
                            // A write has nothing to return; rsp_valid marks a
                            // read landing, so a requester never mistakes a
                            // stale value for a fresh one.
                            if (!cur_write) begin
                                rsp_data  <= shift_in;
                                rsp_valid <= 1'b1;
                            end
                        end else begin
                            case (poll_step)
                                POLL_ID_HI: phy_id[31:16] <= shift_in;
                                POLL_ID_LO: begin
                                    phy_id[15:0] <= shift_in;
                                    // Only meaningful once both halves are in,
                                    // and only believable if the bus is not
                                    // simply floating high or stuck low.
                                    phy_id_valid <= !((phy_id[31:16] == 16'hFFFF) &&
                                                      (shift_in       == 16'hFFFF)) &&
                                                    !((phy_id[31:16] == 16'h0000) &&
                                                      (shift_in       == 16'h0000));
                                end
                                // The second BMSR read is the one that means
                                // anything -- see the note on latching-low.
                                POLL_BMSR2: link_up <= shift_in[2];
                                // JL2121(D) PHYSR bits [5:4]: 00/01/10 for
                                // 10/100/1000 Mbps, 11 reserved. Same
                                // 00/01/10 encoding SPEED_10/100/1000 already
                                // use, so no remapping is needed past the bit
                                // slice -- see the header note on REG_PHYSR.
                                POLL_PHYSR: begin
                                    case (shift_in[5:4])
                                        2'b00:   link_speed <= SPEED_10;
                                        2'b01:   link_speed <= SPEED_100;
                                        2'b10:   link_speed <= SPEED_1000;
                                        default: link_speed <= link_speed;
                                    endcase
                                end
                                default: ;
                            endcase

                            poll_step <= (poll_step == POLL_PAGE_RESTORE) ?
                                             POLL_ID_HI : (poll_step + 3'd1);
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 6'd1;
                    end
                end
            end
        end
    end

endmodule
