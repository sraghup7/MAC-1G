//----------------------------------------------------------------------------
// tb_gem_rx_fifo -- the async FIFO on its own, across two genuinely unrelated
// clocks.
//
// This is the design's only multi-bit clock domain crossing (R19), so it is
// the one module where "it worked in the integrated test" is the weakest
// possible evidence. In the scenario regression both clocks are 125 MHz and
// R18's no-stall contract keeps the FIFO nearly empty for the whole run, which
// means the integrated tests exercise one narrow operating point of a structure
// whose failures all live at the edges: full, empty, and pointers wrapping.
//
// So the clocks here are deliberately mismatched -- 8 ns against 11 ns, sharing
// no useful edge relationship -- because a Gray-code pointer bug is invisible
// while the two sides move in step.
//
// WHAT IS BEING CHECKED:
//   * nothing is lost, duplicated or reordered, with the writer ahead and with
//     the reader ahead
//   * full is reported at exactly GEM_RX_FIFO_DEPTH entries, not one either side
//   * level never exceeds the depth -- the same invariant gem_internal_sva
//     asserts inside the design, checked here where it can actually be provoked
//   * OVERFLOW IS REFUSED, NOT ABSORBED. The writer deliberately keeps pushing
//     against a full FIFO, and what must survive is the data already in it. A
//     FIFO that silently accepts a write while full corrupts the oldest entry
//     and reorders everything after it, which downstream looks like a CDC
//     failure and is not one.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_rx_fifo;

    import gem_tb_pkg::*;

    localparam int DEPTH = `GEM_RX_FIFO_DEPTH;
    localparam int WIDTH = 10;

    logic wr_clk = 1'b0, rd_clk = 1'b0;
    logic wr_rst_n = 1'b0, rd_rst_n = 1'b0;

    logic             wr_en = 1'b0;
    logic [WIDTH-1:0] wr_data = '0;
    wire              full;

    logic             rd_en = 1'b0;
    wire  [WIDTH-1:0] rd_data;
    wire              empty;

    gem_rx_fifo #(.WIDTH (WIDTH)) u_dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .full     (full),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .empty    (empty)
    );

    always #4.0ns wr_clk = ~wr_clk;
    always #5.5ns rd_clk = ~rd_clk;

    int  next_write = 0;
    int  next_read  = 0;
    int  n_written  = 0;
    int  n_read     = 0;
    int  n_refused  = 0;
    bit  reading    = 1'b0;

    // The level invariant, watched on every write cycle rather than sampled at
    // the end of the test.
    always @(posedge wr_clk) begin
        if (wr_rst_n) begin
            if (u_dut.level > DEPTH[`GEM_RX_FIFO_ADDR_W:0]) begin
                report_fail("gem_rx_fifo", $sformatf(
                    "level reached %0d, past the depth of %0d", u_dut.level, DEPTH));
            end
            if (wr_en && full) n_refused++;
        end
    end

    // Read side. Qualified by !empty and not by rd_en alone, because that is
    // exactly the condition under which the FIFO advances its pointer: rd_en is
    // registered from an `empty` sampled a cycle earlier, so on the cycle after
    // the last entry is taken it is still high while the FIFO is now empty. The
    // FIFO correctly refuses to pop; a checker watching rd_en alone counts a
    // read that never happened and then reports every later entry as shifted by
    // one.
    always @(posedge rd_clk) begin
        rd_en <= 1'b0;
        if (rd_rst_n && reading && !empty) begin
            rd_en <= 1'b1;
        end
        if (rd_rst_n && rd_en && !empty) begin
            note_check();
            if (rd_data !== WIDTH'(next_read)) begin
                report_fail("gem_rx_fifo", $sformatf(
                    "read entry %0d as 0x%03h, expected 0x%03h -- order or contents lost across the crossing",
                    n_read, rd_data, WIDTH'(next_read)));
            end
            next_read = (next_read + 1) % (1 << WIDTH);
            n_read++;
        end
    end

    // Offer COUNT entries. wr_en is offered regardless of `full` on purpose --
    // that is what makes the refusal path real -- and an entry only counts as
    // written when the FIFO would have taken it, using the same expression the
    // FIFO itself uses.
    task automatic write_burst(input int count);
        int accepted;
        begin
            accepted = 0;
            wr_data  <= WIDTH'(next_write);
            wr_en    <= 1'b1;
            while (accepted < count) begin
                @(posedge wr_clk);
                if (wr_en && !full) begin
                    accepted++;
                    n_written++;
                    next_write = (next_write + 1) % (1 << WIDTH);
                    // Dropped on the same edge as the last accepted write, not
                    // one edge later. Holding it up for one more cycle offers a
                    // further entry, and against a FIFO with room that entry is
                    // taken -- an extra write the burst never counted, which
                    // then reads back as a duplicate and looks exactly like a
                    // pointer bug in the design.
                    if (accepted == count) wr_en   <= 1'b0;
                    else                   wr_data <= WIDTH'(next_write);
                end
            end
        end
    endtask

    initial begin
        bit ok;
        int i;

        begin_scenario("gem_rx_fifo");

        repeat (4) @(posedge wr_clk);
        wr_rst_n = 1'b1;
        repeat (4) @(posedge rd_clk);
        rd_rst_n = 1'b1;
        repeat (4) @(posedge rd_clk);

        //--------------------------------------------------------------
        // 1. Fill exactly to the depth with the reader idle
        //--------------------------------------------------------------
        reading = 1'b0;
        write_burst(DEPTH);
        repeat (8) @(posedge wr_clk);

        note_check();
        if (!full) begin
            report_fail("gem_rx_fifo", $sformatf(
                "not full after %0d writes into a %0d-entry FIFO", DEPTH, DEPTH));
        end
        note_check();
        if (u_dut.level !== DEPTH[`GEM_RX_FIFO_ADDR_W:0]) begin
            report_fail("gem_rx_fifo", $sformatf(
                "level is %0d after %0d writes", u_dut.level, DEPTH));
        end

        //--------------------------------------------------------------
        // 2. Keep pushing at a full FIFO. Every one of these must bounce.
        //--------------------------------------------------------------
        wr_data <= WIDTH'(next_write);
        wr_en   <= 1'b1;
        repeat (16) @(posedge wr_clk);
        wr_en   <= 1'b0;
        @(posedge wr_clk);

        note_check();
        if (n_refused < 16) begin
            report_fail("gem_rx_fifo", $sformatf(
                "only %0d of 16 writes were offered against a full FIFO -- the overflow path was not exercised",
                n_refused));
        end
        note_check();
        if (u_dut.level !== DEPTH[`GEM_RX_FIFO_ADDR_W:0]) begin
            report_fail("gem_rx_fifo", $sformatf(
                "level is %0d after writing at a full FIFO -- entries were taken that could not fit",
                u_dut.level));
        end

        //--------------------------------------------------------------
        // 3. Drain it. The order check on the read side proves the refused
        //    writes disturbed nothing that was already stored.
        //--------------------------------------------------------------
        reading = 1'b1;
        wait (n_read == DEPTH);
        repeat (8) @(posedge rd_clk);

        note_check();
        if (!empty) begin
            report_fail("gem_rx_fifo", "not empty after every entry was read back");
        end

        //--------------------------------------------------------------
        // 4. Streaming, writer faster than reader: pointers wrap several times
        //    and back-pressure is continuous
        //--------------------------------------------------------------
        write_burst(DEPTH * 5);
        wait (n_read == n_written);

        //--------------------------------------------------------------
        // 5. Streaming with the reader ahead, so the FIFO sits near empty --
        //    the other side of the same pointer comparison
        //--------------------------------------------------------------
        for (i = 0; i < DEPTH * 2; i++) begin
            write_burst(1);
            repeat (3) @(posedge wr_clk);
        end
        wait (n_read == n_written);
        repeat (16) @(posedge rd_clk);

        note_check();
        if (n_read != n_written) begin
            report_fail("gem_rx_fifo", $sformatf(
                "wrote %0d entries, read %0d", n_written, n_read));
        end

        $display("[gem_tb] gem_rx_fifo: %0d entries across the crossing, %0d writes refused while full",
                 n_written, n_refused);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_rx_fifo FAILED");
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "[gem_tb] gem_rx_fifo TIMED OUT");
    end

endmodule
