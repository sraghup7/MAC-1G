//----------------------------------------------------------------------------
// gem_rx_fifo -- B.1a module 9: the rx_clk -> sys_clk crossing.
//
// This is the design's only multi-bit clock domain crossing, and R19 requires
// there to be no others: everything else that crosses is a single event,
// carried by gem_pulse_sync. Multi-bit data through per-bit synchronisers is
// the number-one cause of "worked in simulation, fails on hardware", and the
// reason is not subtle -- two bits of the same word can land on opposite sides
// of a clock edge and produce a value that was never written.
//
// Gray-coded pointers, dual-flop synchronised, which is the standard structure
// for exactly one reason: adjacent Gray codes differ in one bit, so a pointer
// sampled mid-update is either the old value or the new one and never a third
// thing. Everything else here follows from that.
//
// DEPTH IS DERIVED, NOT CHOSEN (B.3a). This FIFO exists to cross clock
// domains, not to absorb a rate mismatch -- both sides run at line rate. Its
// required depth is therefore the clock-drift term (2 x 100 ppm over one
// maximum-length frame, about 0.3 octets) plus the pointer synchroniser's
// visibility latency (about 4 octets), so roughly 4.3. GEM_RX_FIFO_DEPTH is
// 64: fifteen times that, at no extra cost, because the smallest thing the
// device can build here holds far more than 64 octets anyway.
//
// `level`, `wr_en` and `full` are named for gem_internal_sva, which binds to
// them. A fill level buried in an unnamed expression is one whose overflow
// cannot be asserted on -- which is why the assertion was written before this
// module existed, and why this module exposes what it asks for.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_rx_fifo #(
    parameter integer WIDTH = 10        // {user, last, data}
) (
    // ---- write side, rx_clk ----
    input  wire             wr_clk,
    input  wire             wr_rst_n,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,

    // ---- read side, sys_clk (= tx_clk, B.7 item 3) ----
    input  wire             rd_clk,
    input  wire             rd_rst_n,
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty
);

    localparam integer AW    = `GEM_RX_FIFO_ADDR_W;
    localparam integer DEPTH = `GEM_RX_FIFO_DEPTH;

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wr_bin,  wr_gray;
    reg  [AW:0] rd_bin,  rd_gray;
    reg  [AW:0] rd_gray_s1, rd_gray_s2;   // read pointer, seen from write side
    reg  [AW:0] wr_gray_s1, wr_gray_s2;   // write pointer, seen from read side

    function [AW:0] bin2gray;
        input [AW:0] value;
        begin
            bin2gray = value ^ (value >> 1);
        end
    endfunction

    function [AW:0] gray2bin;
        input [AW:0] value;
        integer i;
        begin
            gray2bin[AW] = value[AW];
            for (i = AW - 1; i >= 0; i = i - 1) begin
                gray2bin[i] = gray2bin[i+1] ^ value[i];
            end
        end
    endfunction

    wire [AW:0] rd_bin_wrdom = gray2bin(rd_gray_s2);
    wire [AW:0] wr_bin_next  = wr_bin + {{AW{1'b0}}, (wr_en && !full)};

    // Write-side view of occupancy. Conservative by construction: the read
    // pointer it subtracts is two flops old, so this can only ever over-state
    // how full the FIFO is, never under-state it. That is the right direction
    // for a signal whose job is to withhold writes.
    wire [AW:0] level = wr_bin - rd_bin_wrdom;

    assign full  = (level == DEPTH[AW:0]);
    assign empty = (rd_gray == wr_gray_s2);

    assign rd_data = mem[rd_bin[AW-1:0]];

    //------------------------------------------------------------------
    // Write side
    //------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else begin
            if (wr_en && !full) begin
                mem[wr_bin[AW-1:0]] <= wr_data;
            end
            wr_bin  <= wr_bin_next;
            wr_gray <= bin2gray(wr_bin_next);
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_s1 <= {(AW+1){1'b0}};
            rd_gray_s2 <= {(AW+1){1'b0}};
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
        end
    end

    //------------------------------------------------------------------
    // Read side
    //------------------------------------------------------------------
    wire [AW:0] rd_bin_next = rd_bin + {{AW{1'b0}}, (rd_en && !empty)};

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= bin2gray(rd_bin_next);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_s1 <= {(AW+1){1'b0}};
            wr_gray_s2 <= {(AW+1){1'b0}};
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end
    end

endmodule
