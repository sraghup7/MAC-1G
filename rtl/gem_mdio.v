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
//                     write, on demand -- including the pad-skew registers
//                     B.1b names as the fallback if RGMII timing needs help on
//                     the bench, which no fixed poll list could reach.
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
// changes on the falling edge of MDC and is sampled on the rising edge, which
// gives half a period of setup either side.
//
// WHAT CANNOT BE CONFIRMED WITHOUT THE BOARD, stated rather than assumed:
//
//   * PHY_ADDR. The strap-determined address on the AX7035B is not in the
//     pinout notes in this repository. The default of 0 is the common case and
//     is a parameter precisely because it is a guess. It is also now
//     answerable on the bench without a rebuild: sweep the address over the
//     request port and watch phy_id stop reading as all-ones.
//   * The speed encoding in register 0x1F. The KSZ9031RNX publishes resolved
//     speed and duplex there, and the mapping below follows the datasheet as
//     read online; A.2 flags that datasheet as unverified against the physical
//     part. link_up comes from BMSR bit 2, which is Clause 22 and
//     vendor-independent, so the important half does not depend on the
//     uncertain half.
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
    localparam [4:0] REG_PHYC    = 5'd31;   // KSZ9031RNX: resolved speed/duplex

    localparam [1:0] SPEED_10   = 2'b00,
                     SPEED_100  = 2'b01,
                     SPEED_1000 = 2'b10;

    // The poll cycle. PHY ID first, because it is the one that proves the bus
    // and the part are alive at all -- if it reads as all-ones or all-zeros,
    // nothing below it means anything.
    localparam [2:0] POLL_ID_HI = 3'd0,
                     POLL_ID_LO = 3'd1,
                     POLL_BMSR1 = 3'd2,
                     POLL_BMSR2 = 3'd3,
                     POLL_PHYC  = 3'd4;

    //------------------------------------------------------------------
    // MDC generation
    //------------------------------------------------------------------
    reg [15:0] div;
    reg        fall_en, rise_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div     <= 16'd0;
            mdc     <= 1'b0;
            fall_en <= 1'b0;
            rise_en <= 1'b0;
        end else begin
            fall_en <= 1'b0;
            rise_en <= 1'b0;
            if (div == (MDC_HALF[15:0] - 16'd1)) begin
                div <= 16'd0;
                mdc <= ~mdc;
                if (mdc) fall_en <= 1'b1;   // mdc is about to go low
                else     rise_en <= 1'b1;
            end else begin
                div <= div + 16'd1;
            end
        end
    end

    //------------------------------------------------------------------
    // Transaction state
    //------------------------------------------------------------------
    reg  [5:0]  bit_cnt;         // 0..63 within the frame
    reg         active;
    reg  [15:0] shift_in;
    reg  [2:0]  poll_step;
    reg  [15:0] poll_wait;

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

    // Requests are taken only between transactions. ready is a function of
    // `active` alone, so nothing of the requester's reaches the pins in the
    // same cycle.
    assign req_ready = !active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt      <= 6'd0;
            active       <= 1'b0;
            shift_in     <= 16'd0;
            poll_step    <= POLL_ID_HI;
            poll_wait    <= 16'd0;
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
                if (req_valid) begin
                    // A waiting request goes first. The poll it displaces comes
                    // round again on its own.
                    bit_cnt    <= 6'd0;
                    active     <= 1'b1;
                    cur_write  <= req_write;
                    cur_is_req <= 1'b1;
                    cur_phyad  <= req_phyad;
                    cur_regad  <= req_regad;
                    cur_wdata  <= req_wdata;
                end else if (poll_wait == POLL_GAP[15:0]) begin
                    poll_wait  <= 16'd0;
                    bit_cnt    <= 6'd0;
                    active     <= 1'b1;
                    cur_write  <= 1'b0;          // the sequencer only reads
                    cur_is_req <= 1'b0;
                    cur_phyad  <= PHY_ADDR;
                    case (poll_step)
                        POLL_ID_HI:             cur_regad <= REG_PHYIDR1;
                        POLL_ID_LO:             cur_regad <= REG_PHYIDR2;
                        POLL_BMSR1, POLL_BMSR2: cur_regad <= REG_BMSR;
                        POLL_PHYC:              cur_regad <= REG_PHYC;
                        default:                cur_regad <= REG_BMSR;
                    endcase
                end else begin
                    poll_wait <= poll_wait + 16'd1;
                end
            end else begin
                if (rise_en && data_phase && !cur_write) begin
                    shift_in <= {shift_in[14:0], mdio_i};
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
                                POLL_PHYC: begin
                                    case (shift_in[6:4])
                                        3'b001:  link_speed <= SPEED_10;
                                        3'b010:  link_speed <= SPEED_100;
                                        3'b100:  link_speed <= SPEED_1000;
                                        default: link_speed <= link_speed;
                                    endcase
                                end
                                default: ;
                            endcase

                            poll_step <= (poll_step == POLL_PHYC) ?
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
