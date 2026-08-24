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
// RESET COORDINATION ACROSS THE BOUNDARY. The two sides take independent
// resets -- rx_rst_n here, tx_rst_n there -- and nothing stops one side from
// resetting while the other keeps running. Without help that desynchronises
// the pointers: a write side snapped back to zero under a read side that is
// mid-frame makes `empty` compare a live read pointer against a reset write
// pointer, and the read side pulls garbage until the counts realign mod 128.
// So each side's reset is carried into the other domain through two flops,
// and every register on a side is held under the AND of its own reset and
// the other side's synchronised copy. Neither side operates unless BOTH
// domains were seen out of reset, and whichever side releases first finds
// the safe arrangement: a writer ahead of its reader is ordinary FIFO
// operation; a reader ahead of its writer sees `empty` and reads nothing.
// The synchronised copies sit on the asynchronous reset pins as ordinary
// fabric nets -- the path to each reset pin is a timed synchronous path,
// which is exactly how a per-domain reset deassertion is supposed to arrive
// (B.1b).
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

    // A write refused because the FIFO was full: one wr_clk cycle per lost
    // beat. Under B.3a's derivation this never fires -- the FIFO exists to
    // cross domains, not to absorb rate mismatch, and R18's no-stall contract
    // keeps the read side draining. That is exactly why it must be observable
    // rather than silent: if it ever fires, the premise is wrong somewhere,
    // and a condition nobody can see is one nobody fixes. gem_internal_sva
    // asserts the same condition in simulation; this pin is its hardware
    // counterpart.
    output wire             drop,

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
     // ASYNC_REG on both pointer-synchroniser chains, matching
     // gem_reset_sync.v/gem_pulse_sync.v: keeps each pair in one slice and
     // marks them for report_cdc (gate 4 counts unmarked synchroniser
     // endpoints as findings).
     (* ASYNC_REG = "TRUE" *) reg  [AW:0] rd_gray_s1, rd_gray_s2;   // read pointer, seen from write side
     (* ASYNC_REG = "TRUE" *) reg  [AW:0] wr_gray_s1, wr_gray_s2;   // write pointer, seen from read side

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

    //------------------------------------------------------------------
    // The other side's reset, seen from here. Two flops: the first is the
    // metastability catcher, the second gives a clean signal to hold state
    // with. Held at zero by this side's own raw reset, so a side that is
    // itself resetting never believes the other side was out of reset.
    //
    // Justified suppression (R22 permits one with a reason): SYNCASYNCNET
    // fires because these flops sample the raw resets synchronously -- as
    // data -- while the same nets drive asynchronous reset pins elsewhere,
    // which is not an accident but the definition of a reset synchroniser.
    // gem_reset_sync does the identical thing at board level and is linted
    // clean only because its input is a dedicated port rather than a shared
    // domain reset.
    //------------------------------------------------------------------
    /* verilator lint_off SYNCASYNCNET */
    // ASYNC_REG: reset synchroniser, same class as wr_rst_n_r1/r2 below.
    (* ASYNC_REG = "TRUE" *) reg rd_rst_n_w1, rd_rst_n_w2;     // read side's reset, in wr_clk
    // ASYNC_REG: these are reset synchronisers (the other domain's reset,
    // re-synchronised), same class as gem_reset_sync.v -- placement plus CDC
    // visibility to report_cdc (gate 4).
    (* ASYNC_REG = "TRUE" *) reg wr_rst_n_r1, wr_rst_n_r2;     // write side's reset, in rd_clk

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_rst_n_w1 <= 1'b0;
            rd_rst_n_w2 <= 1'b0;
        end else begin
            rd_rst_n_w1 <= rd_rst_n;
            rd_rst_n_w2 <= rd_rst_n_w1;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_rst_n_r1 <= 1'b0;
            wr_rst_n_r2 <= 1'b0;
        end else begin
            wr_rst_n_r1 <= wr_rst_n;
            wr_rst_n_r2 <= wr_rst_n_r1;
        end
    end
    /* verilator lint_on SYNCASYNCNET */

    // Effective per-side resets: own domain's reset AND the other side's
    // synchronised copy. Both must have been seen high before this side
    // runs at all.
    wire wr_rst_eff_n = wr_rst_n && rd_rst_n_w2;
    wire rd_rst_eff_n = rd_rst_n && wr_rst_n_r2;

    wire [AW:0] rd_bin_wrdom = gray2bin(rd_gray_s2);
    wire [AW:0] wr_bin_next  = wr_bin + {{AW{1'b0}}, (wr_en && !full)};

    // Write-side view of occupancy. Conservative by construction: the read
    // pointer it subtracts is two flops old, so this can only ever over-state
    // how full the FIFO is, never under-state it. That is the right direction
    // for a signal whose job is to withhold writes.
    wire [AW:0] level = wr_bin - rd_bin_wrdom;

    assign full  = (level == DEPTH[AW:0]);
    assign empty = (rd_gray == wr_gray_s2);
    assign drop  = wr_en && full;

    assign rd_data = mem[rd_bin[AW-1:0]];

    //------------------------------------------------------------------
    // Write side
    //------------------------------------------------------------------
    // THE MEMORY HAS NO RESET, and that is the whole reason it is a separate
    // block from the pointers. A RAM's contents cannot be reset -- there is no
    // silicon that clears a whole array on a signal -- so an array written
    // inside a block with an asynchronous reset cannot be a RAM, and Vivado
    // says so plainly and then builds it out of flip-flops:
    //
    //   [Synth 8-4767] Trying to implement RAM 'mem_reg' in registers.
    //                  RAM is sensitive to asynchronous reset signal.
    //   RAM "mem_reg" dissolved into registers
    //
    // That is exactly what this module did until it was read: 64 x 10 bits
    // became 648 flip-flops and a MUXF7/MUXF8 read tree, roughly half the
    // design's registers, while the specification claimed distributed RAM. The
    // pointers keep their reset, because pointers must start at zero; the
    // contents do not need one, because `empty` makes them unreadable until
    // something has been written.
    //
    // The warning was in the log from the first synthesis run. Printing a
    // report is not reading it.
    //
    // The write is additionally gated on the read side's synchronised reset:
    // while the read side is held, this side must neither advance nor write,
    // or slot 0 would take a beat the pointers never count.
    always @(posedge wr_clk) begin
        if (wr_en && !full && rd_rst_n_w2) begin
            mem[wr_bin[AW-1:0]] <= wr_data;
        end
    end

    always @(posedge wr_clk or negedge wr_rst_eff_n) begin
        if (!wr_rst_eff_n) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else begin
            wr_bin  <= wr_bin_next;
            wr_gray <= bin2gray(wr_bin_next);
        end
    end

    always @(posedge wr_clk or negedge wr_rst_eff_n) begin
        if (!wr_rst_eff_n) begin
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
    wire [AW:0] rd_bin_next = rd_bin + {{AW{1'b0}}, (rd_en && !empty && wr_rst_n_r2)};

    always @(posedge rd_clk or negedge rd_rst_eff_n) begin
        if (!rd_rst_eff_n) begin
            rd_bin  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= bin2gray(rd_bin_next);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_eff_n) begin
        if (!rd_rst_eff_n) begin
            wr_gray_s1 <= {(AW+1){1'b0}};
            wr_gray_s2 <= {(AW+1){1'b0}};
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end
    end

endmodule
