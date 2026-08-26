//----------------------------------------------------------------------------
// gem_rx_abort -- close a frame the link took away, in band (V-25, B.4a).
//
// gem_rx_egress is reset by rx_path_rst_n, asynchronously, the instant a link
// event lands -- and its own registers are exactly what would have to carry a
// closing beat, so by the time anything could react they are already zero.
// This module sits downstream of gem_rx_egress instead, in tx_clk, watching
// what happened rather than trying to make gem_rx_egress do one more thing on
// its way into reset.
//
// A NECESSARY ASYMMETRY. This module's own reset is tx_rst_n, not
// rx_path_rst_n: it has to survive exactly the reset event it exists to
// observe, so link_rst_n arrives as an ordinary input, deliberately not this
// module's reset pin. Wiring it the other way compiles and elaborates cleanly
// -- it just makes the module permanently unable to see a link event, since
// its own bookkeeping would be cleared by the same edge it is watching for.
//
// LEVEL, BUT LATCHED, NOT SAMPLED LIVE. link_rst_n asserts asynchronously by
// construction (Documents/RX Clock Deskew Design.md Step 3b: a reset that
// waits for an edge cannot fire on a domain whose clock just died), so this
// module edge-detects it explicitly -- one flop of delay, compared against
// the live value -- rather than gating the abort decision directly off the
// current level every cycle. Both the delayed sample and frame_open below
// answer only to tx_rst_n, so the edge is caught exactly once per event.
//
// FRAME-OPEN IS TRACKED AT THE PORT, ON PURPOSE. The condition this module
// acts on is "a beat left gem_rx_egress with tlast=0 and nothing has closed
// it since" -- observed on the actual handshake (e_tvalid && m_tready), not
// inferred from FIFO occupancy or any other upstream state. Deriving it
// upstream can synthesise a closing beat for a frame the AXI-S port itself
// never actually started, which is a different and worse lie than the one
// this module exists to prevent.
//
// tdata is 0 on the synthetic beat, the same choice gem_rx_egress itself
// makes when nothing is loaded (see that module's header: "it costs nothing
// to be unambiguous") -- a stale octet would be indistinguishable from real
// data in a waveform, and gem_axis_sva's a_no_x requires a defined value on
// every valid beat regardless.
//
// tuser is 0. B.4a's base rule already makes this the single good/bad bit
// (1 = FCS good, R9); an abort beat with tuser=1 would not merely be an
// inconsistent choice of encoding, it would be a live bug -- gem_echo commits
// a frame on `if (rx_tuser && ...)`, so tuser=1 here would make the echo path
// transmit the truncated fragment as a good frame.
//
// This module changes nothing for the frozen scenario regression: none of it
// ever drives link_rst_n low, so `injecting` never asserts and the pass-
// through below is the identity function on every existing vector.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rx_abort (
    input  wire       clk,          // tx_clk
    input  wire       rst_n,        // tx_rst_n -- board reset ONLY
    input  wire       link_rst_n,   // rx_path_rst_n, read as data, never as
                                     // this module's own reset (see header)

    // ---- from gem_rx_egress, the real stream ----
    input  wire [7:0] e_tdata,
    input  wire       e_tvalid,
    input  wire       e_tlast,
    input  wire       e_tuser,

    // ---- to the AXI-S port: real beats pass straight through; one
    //      synthetic beat closes a frame the link took away ----
    output wire [7:0] m_tdata,
    output wire       m_tvalid,
    output wire       m_tlast,
    output wire       m_tuser,
    input  wire       m_tready
);

    reg link_rst_n_d;   // one cycle of delay, for edge detection only
    reg frame_open;      // a beat left with tlast=0 and nothing has closed it
    reg injecting;       // presenting the synthetic closing beat this cycle

    wire link_reset_edge = link_rst_n_d && !link_rst_n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_rst_n_d <= 1'b1;
            frame_open   <= 1'b0;
            injecting    <= 1'b0;
        end else begin
            link_rst_n_d <= link_rst_n;

            if (e_tvalid && m_tready) begin
                frame_open <= !e_tlast;
            end

            if (frame_open && link_reset_edge && !injecting) begin
                injecting <= 1'b1;
            end else if (injecting && m_tready) begin
                injecting  <= 1'b0;
                frame_open <= 1'b0;
            end
        end
    end

    assign m_tdata  = injecting ? 8'd0 : e_tdata;
    assign m_tvalid = injecting ? 1'b1 : e_tvalid;
    assign m_tlast  = injecting ? 1'b1 : e_tlast;
    assign m_tuser  = injecting ? 1'b0 : e_tuser;

endmodule
