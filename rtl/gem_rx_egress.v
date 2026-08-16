//----------------------------------------------------------------------------
// gem_rx_egress -- the registered AXI-Stream egress stage (R15).
//
// One flop between the FIFO and the pins of the user interface, which is the
// last cycle of B.1b's thirteen. R15 asks for a registered handshake with no
// combinational path through it, and that is what this is: tvalid, tdata,
// tlast and tuser all come out of flops, and tready only ever gates their
// enable.
//
// The FIFO read strobe is combinational from tready, and it has to be -- a
// sink that cannot advance its source in the cycle it accepts a beat runs at
// half rate. The distinction R15 draws is about the *port*, not about internal
// paths: nothing here lets a user's tready ripple out to another module or a
// pin in the same cycle.
//
// R18's no-stall contract means tready is tied high in every testbench today,
// so the "hold the beat" branch below is exercised only if a future user
// stalls. gem_axis_sva measures and reports that rather than assuming it --
// see the vacuity note in that file.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rx_egress (
    input  wire       clk,
    input  wire       rst_n,

    // ---- FIFO read side: {user, last, data} ----
    input  wire       fifo_empty,
    input  wire [9:0] fifo_dout,
    output wire       fifo_rd,

    // ---- user port (R15) ----
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    input  wire       m_tready,
    output reg        m_tlast,
    output reg        m_tuser
);

    wire accept_next = !m_tvalid || m_tready;

    assign fifo_rd = accept_next && !fifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata  <= 8'd0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
            m_tuser  <= 1'b0;
        end else if (accept_next) begin
            // tlast and tuser are cleared when nothing is loaded, not merely
            // left alone. Holding the last beat's tlast high through the idle
            // that follows it violates gem_axis_sva's a_tlast_needs_tvalid --
            // correctly, because a frame delimiter asserted with no beat under
            // it is exactly the end-of-frame-from-a-counter mistake that
            // assertion exists to catch. It costs nothing to be unambiguous.
            m_tvalid <= !fifo_empty;
            m_tdata  <= fifo_empty ? 8'd0 : fifo_dout[7:0];
            m_tlast  <= !fifo_empty && fifo_dout[8];
            m_tuser  <= !fifo_empty && fifo_dout[9];
        end
    end

endmodule
