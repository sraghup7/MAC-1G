//----------------------------------------------------------------------------
// gem_mdio -- R16's Clause 22 management interface, driven by a hardware
// sequencer rather than by a register-level request port.
//
// R16 allows either ("bring-up software (or a hardware sequencer) uses it"),
// and the top-level interface frozen in Stage 3 settles it: gem_mac has mdc,
// mdio_i/o/t, link_up and link_speed, and no request channel. So this block
// polls on its own and publishes what it finds. That is also the behaviour
// bring-up step 3 actually needs -- a MAC that cannot confirm the link is up
// without software attached is a MAC you cannot debug with a scope and a
// blinking LED.
//
// Clause 22 read frame, 64 MDC periods:
//   32 x 1   preamble
//   01       start
//   10       read opcode
//   5 bits   PHY address
//   5 bits   register address
//   2 bits   turnaround -- the STA releases the bus and the PHY drives a 0
//   16 bits  data, driven by the PHY
//
// MDC is 125 MHz / (2 x MDC_HALF). At the default MDC_HALF = 32 that is
// 1.95 MHz, inside R16's 2.5 MHz ceiling with margin rather than at it. MDIO
// is driven on the falling edge of MDC and sampled on the rising edge, which
// is what gives the PHY a full half period of setup either side.
//
// WHAT CANNOT BE CONFIRMED WITHOUT THE BOARD, stated rather than assumed:
//
//   * PHY_ADDR. The strap-determined address on the AX7035B is not in the
//     pinout notes in this repository. The default of 0 is the common case and
//     is a parameter precisely because it is a guess -- bring-up step 3 reads
//     the PHY ID registers to find the real one.
//   * The speed encoding in register 0x1F. The KSZ9031RNX publishes resolved
//     speed and duplex there, and the mapping below follows the datasheet as
//     read online; A.2 already flags that the datasheet has not been checked
//     against the physical part. link_up comes from BMSR bit 2, which is
//     Clause 22 and vendor-independent, so the important half of this does not
//     depend on the uncertain half.
//
// BMSR's link status is latching-low: it reports a link that has gone down
// since the last read, and only a second read shows the current state. So the
// poll reads it twice and believes the second, which is a real bug avoided
// rather than a ritual -- a MAC that reports the link down forever after one
// glitch is worse than one that does not report at all.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_mdio #(
    parameter [4:0]   PHY_ADDR = 5'd0,
    parameter integer MDC_HALF = 32,       // tx_clk cycles per MDC half period
    parameter integer POLL_GAP = 4096      // tx_clk cycles between transactions
) (
    input  wire       clk,
    input  wire       rst_n,

    output reg        mdc,
    input  wire       mdio_i,
    output wire       mdio_o,
    output wire       mdio_t,              // 1 = released

    output reg        link_up,
    output reg [1:0]  link_speed           // 00=10, 01=100, 10=1000 (Clause 22)
);

    localparam [4:0] REG_BMSR = 5'd1;      // Clause 22, basic status
    localparam [4:0] REG_PHYC = 5'd31;     // KSZ9031RNX PHY control: speed/duplex

    localparam [1:0] SPEED_10   = 2'b00,
                     SPEED_100  = 2'b01,
                     SPEED_1000 = 2'b10;

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
    // Transaction sequencer
    //------------------------------------------------------------------
    reg  [5:0]  bit_cnt;         // 0..63 within the frame
    reg         active;
    /* verilator lint_off UNUSEDSIGNAL */
    // Justified suppression (R22): a Clause 22 read always shifts in all 16
    // bits, and this block acts on three of them -- BMSR's link-status bit and
    // the three speed bits of the vendor status register. Masking the rest
    // would mean two shift registers, or a read that is not a read.
    reg  [15:0] shift_in;
    /* verilator lint_on UNUSEDSIGNAL */
    reg  [1:0]  poll_step;       // 0,1 = BMSR twice; 2 = PHY control
    reg  [15:0] poll_wait;
    reg  [4:0]  reg_addr;

    wire [13:0] cmd = {2'b01, 2'b10, PHY_ADDR, reg_addr};

    // Preamble, then command, then the bus is released for turnaround and
    // data. Releasing at bit 46 -- the first turnaround bit -- is what Clause
    // 22 requires of a reader; holding the bus one bit longer collides with
    // the PHY.
    wire cmd_phase  = (bit_cnt >= 6'd32) && (bit_cnt < 6'd46);
    wire data_phase = (bit_cnt >= 6'd46);

    // bit_cnt-32 runs 0..13 across the command phase; cmd is shifted out most
    // significant bit first. Across 32..45 the top two bits of bit_cnt are
    // constant, so the low nibble is the offset -- no subtractor.
    wire [3:0] cmd_pos = bit_cnt[3:0];
    wire       cmd_bit = cmd[4'd13 - cmd_pos];

    assign mdio_o = cmd_phase ? cmd_bit : 1'b1;
    assign mdio_t = (!active) ? 1'b1 : (data_phase ? 1'b1 : 1'b0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt    <= 6'd0;
            active     <= 1'b0;
            shift_in   <= 16'd0;
            poll_step  <= 2'd0;
            poll_wait  <= 16'd0;
            reg_addr   <= REG_BMSR;
            link_up    <= 1'b0;
            link_speed <= SPEED_1000;
        end else if (!active) begin
            if (poll_wait == POLL_GAP[15:0]) begin
                poll_wait <= 16'd0;
                bit_cnt   <= 6'd0;
                active    <= 1'b1;
                reg_addr  <= (poll_step == 2'd2) ? REG_PHYC : REG_BMSR;
            end else begin
                poll_wait <= poll_wait + 16'd1;
            end
        end else begin
            if (rise_en && data_phase) begin
                shift_in <= {shift_in[14:0], mdio_i};
            end

            if (fall_en) begin
                if (bit_cnt == 6'd63) begin
                    active <= 1'b0;

                    // The second BMSR read is the one that means anything.
                    if (poll_step == 2'd1) begin
                        link_up <= shift_in[2];
                    end

                    if (poll_step == 2'd2) begin
                        case (shift_in[6:4])
                            3'b001:  link_speed <= SPEED_10;
                            3'b010:  link_speed <= SPEED_100;
                            3'b100:  link_speed <= SPEED_1000;
                            default: link_speed <= link_speed;
                        endcase
                    end

                    poll_step <= (poll_step == 2'd2) ? 2'd0 : (poll_step + 2'd1);
                end else begin
                    bit_cnt <= bit_cnt + 6'd1;
                end
            end
        end
    end

endmodule
