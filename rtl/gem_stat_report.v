//----------------------------------------------------------------------------
// gem_stat_report -- R17's counters as one line of text per second, out of
// gem_uart_tx and into a file on the host.
//
// This is the half of B.7 item 5 that makes the UART decision worth anything.
// The counters were correct and verified in all sixteen frozen scenarios
// before this module existed (V-20); what was missing was any way to read them
// on hardware, and what B.5 step 8's four-hour soak actually needs is not a
// number on a screen but a record a script can timestamp and diff.
//
// THE RECORD, which is a contract with sw/host and should be changed with the
// same care as a register map:
//
//   gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000000 rx_ok=000001f4 \
//       rx_bad=00000002 rx_runt=00000000 rx_over=00000000 rx_rxer=00000000 \
//       link=00000001 speed=00000002 phyid=00221622 phyok=00000001 \
//       rxlock=00000001 rx_drop=00000000\n
//
// (one line, no wrapping; broken here only to fit in a comment.)
//
// Three decisions in that format, each with a reason:
//
//   NAMED FIELDS, EVERY LINE. B.7 item 5 asks for this specifically. The
//   alternative -- a header once, then columns -- is smaller and is how logs
//   become unreadable: add a counter and every historical column silently
//   shifts, so a diff of two runs from different builds compares tx_ok against
//   rx_ok and reports nonsense rather than an error.
//
//   HEXADECIMAL, and no 0x prefix. Decimal would need a binary-to-BCD
//   conversion -- double dabble, 32 bits, a shift-add-3 per digit -- to make a
//   number a human reads once a second marginally nicer. A nibble is four bits
//   and an ASCII digit, which is a lookup with no state at all.
//
//   EVERY FIELD EIGHT NIBBLES, including the one-bit ones. `link=00000001` is
//   silly to read and it means the parser has exactly one rule instead of a
//   width per field, at a cost of thirty characters a line on a link that
//   sends fewer than two hundred a second.
//
// THE SNAPSHOT, which is the one part of this module that is not obvious.
// Every field is captured into a register bank the instant a record starts,
// and the record is formatted from those registers rather than from the live
// counter ports. A record takes about 17 ms to clock out at 115200 baud, and
// without the snapshot its fields would each be true at a different instant --
// so a line could show more frames received than the same line's transmit
// count when both were captured from the same steady stream, and a soak whose
// whole purpose is finding divergence would have manufactured some. The cost
// is 14 x 32 flip-flops, stated here rather than discovered in a utilisation
// report, and it buys the property that every line is a true instantaneous
// state of the MAC.
//
// A record cannot collide with the next trigger at the shipped settings: 17 ms
// of transmission against a 1 s interval. If an override ever made it possible,
// the trigger is simply ignored while a record is in flight -- a dropped sample
// rather than a corrupted line.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_stat_report #(
    // sys_clk cycles between records. Default: one second.
    parameter integer CLKS_PER_REPORT = (`GEM_SYS_CLK_HZ / 1000) * `GEM_STAT_REPORT_MS
) (
    input  wire        clk,
    input  wire        rst_n,

    // R17's counters, straight off gem_mac's status ports.
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_rejected,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_underrun,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_badfcs,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_runt,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize,
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_rxer,
    // Receive frames that lost at least one octet to a full RX FIFO --
    // frames, not octets. gem_mac collapses the FIFO's per-octet drop into
    // one event per frame before it crosses into this clock domain.
    input  wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_fifo_drop,

    // ... and what the MDIO sequencer found (R16).
    input  wire        link_up,
    input  wire [1:0]  link_speed,
    input  wire [31:0] phy_id,
    input  wire        phy_id_valid,

    // The RX deskew MMCM's lock (design doc Step 3f). On the record because
    // it is the one field that explains a link that is up while nothing is
    // received: the MMCM on the recovered clock never locked. One wire, and
    // the four-hour soak can tell "cable problem" from "clocking problem"
    // from a log file.
    input  wire        rx_mmcm_locked,

    // To gem_uart_tx.
    output wire [7:0]  uart_data,
    output wire        uart_valid,
    input  wire        uart_ready
);

    localparam integer N_FIELDS   = 14;
    localparam [3:0]   LAST_FIELD = 4'd13;

    localparam [2:0] ST_IDLE = 3'd0,
                     ST_TAG  = 3'd1,
                     ST_NAME = 3'd2,
                     ST_EQ   = 3'd3,
                     ST_VAL  = 3'd4,
                     ST_SEP  = 3'd5;

    //======================================================================
    // The interval trigger
    //======================================================================
    reg [31:0] interval_cnt;
    wire       trig = (interval_cnt == (CLKS_PER_REPORT[31:0] - 32'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interval_cnt <= 32'd0;
        end else if (trig) begin
            interval_cnt <= 32'd0;
        end else begin
            interval_cnt <= interval_cnt + 32'd1;
        end
    end

    //======================================================================
    // The snapshot
    //======================================================================
    reg [31:0] snap [0:N_FIELDS-1];

    reg [2:0]  state;
    reg [3:0]  field;
    reg [2:0]  name_idx;
    reg [2:0]  tag_idx;
    reg [2:0]  nibble_idx;

    wire start_record = trig && (state == ST_IDLE);

    integer j;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < N_FIELDS; j = j + 1) begin
                snap[j] <= 32'd0;
            end
        end else if (start_record) begin
            snap[0]  <= stat_tx_ok;
            snap[1]  <= stat_tx_rejected;
            snap[2]  <= stat_tx_underrun;
            snap[3]  <= stat_rx_ok;
            snap[4]  <= stat_rx_badfcs;
            snap[5]  <= stat_rx_runt;
            snap[6]  <= stat_rx_oversize;
            snap[7]  <= stat_rx_rxer;
            snap[8]  <= {31'd0, link_up};
            snap[9]  <= {30'd0, link_speed};
            snap[10] <= phy_id;
            snap[11] <= {31'd0, phy_id_valid};
            snap[12] <= {31'd0, rx_mmcm_locked};
            snap[13] <= stat_rx_fifo_drop;
        end
    end

    //======================================================================
    // Character sources
    //======================================================================
    //
    // Names are packed into 56 bits -- seven characters, the longest name here
    // -- with explicit zero padding rather than a shorter string literal, so
    // that every entry is exactly the declared width and no assignment silently
    // extends. The formatter walks bytes 6 down to 0 and skips the zeros,
    // which costs a cycle each and nothing on the wire.
    function [55:0] name_of(input [3:0] f);
        case (f)
            4'd0:    name_of = {16'd0, "tx_ok"};
            4'd1:    name_of = {8'd0,  "tx_rej"};
            4'd2:    name_of =         "tx_urun";
            4'd3:    name_of = {16'd0, "rx_ok"};
            4'd4:    name_of = {8'd0,  "rx_bad"};
            4'd5:    name_of =         "rx_runt";
            4'd6:    name_of =         "rx_over";
            4'd7:    name_of =         "rx_rxer";
            4'd8:    name_of = {24'd0, "link"};
            4'd9:    name_of = {16'd0, "speed"};
            4'd10:   name_of = {16'd0, "phyid"};
            4'd11:   name_of = {16'd0, "phyok"};
            4'd12:   name_of = {8'd0,  "rxlock"};
            // Appended rather than filed with the other receive counters:
            // the names make position irrelevant to a parser, and keeping
            // every existing field at its old offset means a soak log from
            // before this field and one from after still line up to a human
            // reading them side by side.
            4'd13:   name_of =         "rx_drop";
            default: name_of = {48'd0, "?"};
        endcase
    endfunction

    // "gem " -- a fixed anchor so a host script can pick these lines out of a
    // log that has anything else in it.
    function [7:0] tag_of(input [2:0] i);
        case (i)
            3'd3:    tag_of = "g";
            3'd2:    tag_of = "e";
            3'd1:    tag_of = "m";
            default: tag_of = " ";
        endcase
    endfunction

    function [7:0] hex_char(input [3:0] n);
        hex_char = (n < 4'd10) ? (8'h30 + {4'd0, n})           // '0'..'9'
                               : (8'h61 + {4'd0, n} - 8'd10);  // 'a'..'f'
    endfunction

    wire [55:0] name_word = name_of(field);

    // Byte `name_idx` of the packed name, counted from the top.
    reg [7:0] name_byte;
    always @(*) begin
        name_byte = 8'd0;
        case (name_idx)
            3'd6:    name_byte = name_word[55:48];
            3'd5:    name_byte = name_word[47:40];
            3'd4:    name_byte = name_word[39:32];
            3'd3:    name_byte = name_word[31:24];
            3'd2:    name_byte = name_word[23:16];
            3'd1:    name_byte = name_word[15:8];
            3'd0:    name_byte = name_word[7:0];
            default: name_byte = 8'd0;
        endcase
    end

    wire [31:0] value_word = snap[field];

    reg [3:0] value_nibble;
    always @(*) begin
        value_nibble = 4'd0;
        case (nibble_idx)
            3'd7:    value_nibble = value_word[31:28];
            3'd6:    value_nibble = value_word[27:24];
            3'd5:    value_nibble = value_word[23:20];
            3'd4:    value_nibble = value_word[19:16];
            3'd3:    value_nibble = value_word[15:12];
            3'd2:    value_nibble = value_word[11:8];
            3'd1:    value_nibble = value_word[7:4];
            3'd0:    value_nibble = value_word[3:0];
            default: value_nibble = 4'd0;
        endcase
    end

    reg [7:0] char_out;
    always @(*) begin
        char_out = 8'h20;                       // space, and the default
        case (state)
            ST_TAG:  char_out = tag_of(tag_idx);
            ST_NAME: char_out = name_byte;
            ST_EQ:   char_out = "=";
            ST_VAL:  char_out = hex_char(value_nibble);
            ST_SEP:  char_out = (field == LAST_FIELD) ? 8'h0A : 8'h20;
            default: char_out = 8'h20;
        endcase
    end

    // A zero byte inside a name is padding: skipped without being offered to
    // the UART, which is why it costs a cycle rather than a character.
    wire name_pad = (state == ST_NAME) && (name_byte == 8'd0);
    wire emitting = (state != ST_IDLE) && !name_pad;
    wire accepted = emitting && uart_ready;

    //======================================================================
    // The formatter
    //======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            field      <= 4'd0;
            name_idx   <= 3'd6;
            tag_idx    <= 3'd3;
            nibble_idx <= 3'd7;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start_record) begin
                        state      <= ST_TAG;
                        field      <= 4'd0;
                        tag_idx    <= 3'd3;
                        name_idx   <= 3'd6;
                        nibble_idx <= 3'd7;
                    end
                end

                ST_TAG: begin
                    if (accepted) begin
                        if (tag_idx == 3'd0) begin
                            state    <= ST_NAME;
                            name_idx <= 3'd6;
                        end else begin
                            tag_idx <= tag_idx - 3'd1;
                        end
                    end
                end

                ST_NAME: begin
                    // Padding is consumed with no handshake; a real character
                    // waits for the UART to take it.
                    if (name_pad) begin
                        name_idx <= name_idx - 3'd1;
                    end else if (accepted) begin
                        if (name_idx == 3'd0) begin
                            state <= ST_EQ;
                        end else begin
                            name_idx <= name_idx - 3'd1;
                        end
                    end
                end

                ST_EQ: begin
                    if (accepted) begin
                        state      <= ST_VAL;
                        nibble_idx <= 3'd7;
                    end
                end

                ST_VAL: begin
                    if (accepted) begin
                        if (nibble_idx == 3'd0) begin
                            state <= ST_SEP;
                        end else begin
                            nibble_idx <= nibble_idx - 3'd1;
                        end
                    end
                end

                ST_SEP: begin
                    if (accepted) begin
                        if (field == LAST_FIELD) begin
                            state <= ST_IDLE;
                        end else begin
                            field    <= field + 4'd1;
                            name_idx <= 3'd6;
                            state    <= ST_NAME;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    assign uart_data  = char_out;
    assign uart_valid = emitting;

endmodule
