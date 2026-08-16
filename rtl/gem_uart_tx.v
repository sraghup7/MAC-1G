//----------------------------------------------------------------------------
// gem_uart_tx -- 8N1 serial transmitter, one octet at a time.
//
// The whole of R17's readout mechanism rests on this module and it is
// deliberately the dullest thing in the repository: a divider, a shift
// register, and a bit counter. B.7 item 5 chose a UART over a VIO probe
// precisely because a UART produces a file a script can diff after the fact,
// and that argument is only worth anything if the octets on the wire are the
// octets that were asked for.
//
// FRAMING, in the order the wire sees it: the line idles high, one start bit
// (low), eight data bits least-significant first, one stop bit (high). No
// parity -- the 8N1 in B.7 item 5 -- and no receive path in v1.
//
// THE DIVIDER, and why it is a parameter with a derived default. At 125 MHz
// and 115200 baud the exact divisor is 1085.0694..., and the choice is which
// way to round:
//
//   truncate to 1085   each bit is 8.680 us against an ideal 8.6806 us, so the
//                      transmitter runs 0.0064% FAST. Over the ten bit periods
//                      of a frame the accumulated error is 0.06% of one bit --
//                      the receiver samples the stop bit 0.0006 of a bit period
//                      early, which is nothing.
//   round up to 1086   would run 0.086% slow, also fine.
//
// Either works; the reason to write the arithmetic down is that the failure
// mode when a divider IS wrong looks nothing like a divider problem. A UART a
// few percent off delivers most octets correctly and corrupts the occasional
// one, which reads as a flaky cable or a noisy ground rather than as integer
// division. tb_gem_uart_tx therefore decodes this module's output with a
// receiver whose bit period comes from the baud rate in nanoseconds and never
// from CLKS_PER_BIT, so a wrong divisor here cannot agree with itself there.
//
// HANDSHAKE: assert `valid` with `data`; the octet is taken on any cycle where
// `valid` and `ready` are both high. `ready` falls for the whole frame after
// that and rises again as the stop bit completes, so a producer that simply
// holds `valid` high streams octets back to back with no gap -- which is what
// gem_stat_report does for the ~190 characters of a record.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_uart_tx #(
    // sys_clk cycles per bit period. The default is the only one this project
    // ships; the parameter exists so a testbench can shorten a frame without
    // pretending the design has a different baud rate.
    parameter integer CLKS_PER_BIT = `GEM_SYS_CLK_HZ / `GEM_UART_BAUD
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,

    output wire       tx        // idles high
);

    localparam [1:0] ST_IDLE  = 2'd0,
                     ST_START = 2'd1,
                     ST_DATA  = 2'd2,
                     ST_STOP  = 2'd3;

    // 16 bits holds 65,535 -- sixty times the default divisor, so any baud
    // rate down to about 2000 at 125 MHz still fits. Verilog-2001 has no
    // $clog2, and the repository does not pretend otherwise anywhere else.
    localparam [15:0] LAST_TICK = CLKS_PER_BIT[15:0] - 16'd1;

    reg [1:0]  state;
    reg [15:0] tick;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;
    reg        tx_r;

    wire tick_done = (tick == LAST_TICK);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            tick    <= 16'd0;
            bit_idx <= 3'd0;
            shifter <= 8'd0;
            tx_r    <= 1'b1;        // idle high, from the first cycle
        end else begin
            case (state)
                ST_IDLE: begin
                    tx_r <= 1'b1;
                    tick <= 16'd0;
                    if (valid) begin
                        shifter <= data;
                        state   <= ST_START;
                        tx_r    <= 1'b0;   // start bit begins immediately
                    end
                end

                ST_START: begin
                    if (tick_done) begin
                        tick    <= 16'd0;
                        bit_idx <= 3'd0;
                        state   <= ST_DATA;
                        tx_r    <= shifter[0];
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                ST_DATA: begin
                    if (tick_done) begin
                        tick    <= 16'd0;
                        // LSB first: shift down, and the next bit is what
                        // lands in bit 0. On the eighth the frame is done.
                        shifter <= {1'b0, shifter[7:1]};
                        if (bit_idx == 3'd7) begin
                            state <= ST_STOP;
                            tx_r  <= 1'b1;      // stop bit
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                            tx_r    <= shifter[1];
                        end
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                ST_STOP: begin
                    tx_r <= 1'b1;
                    if (tick_done) begin
                        tick  <= 16'd0;
                        state <= ST_IDLE;
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // ready falls the moment an octet is accepted and does not rise until the
    // stop bit has been held for its full period. Deriving it from the state
    // rather than keeping a second flag means there is no way for the two to
    // disagree about whether the transmitter is busy.
    assign ready = (state == ST_IDLE);
    assign tx    = tx_r;

endmodule
