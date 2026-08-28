//----------------------------------------------------------------------------
// gem_rx_drop_episode -- collapse the RX FIFO's per-octet drop into one pulse
// per frame that lost anything.
//
// gem_rx_fifo's `drop` is `wr_en && full`: one pulse per refused octet. That is
// the honest signal at the FIFO, and it is the wrong signal to count. A FIFO
// that is full stays full for many consecutive beats, and the counters live in
// tx_clk, so the event has to cross a domain -- through gem_pulse_sync, which
// is a toggle synchroniser and needs several destination clocks between source
// pulses to carry them all. Both clocks run at 125 MHz here. Counting the raw
// pulse would therefore undercount by a factor nobody can predict and nobody
// can measure, which is worse than not counting it: a number that is wrong in
// an unknown direction gets believed.
//
// So the episode is what is counted. A sticky bit remembers that this frame
// lost at least one octet, and one pulse is emitted when the deframer says the
// frame ended. Consecutive pulses are then at least a minimum frame apart --
// 64 octets plus the gap -- which the synchroniser carries without loss. The
// field on the UART record is `rx_drop`, and it counts FRAMES, not octets.
//
// A drop landing on the very cycle the frame ends still counts: the emit term
// reads the live `drop` as well as the sticky bit, so an episode one cycle long
// at exactly the wrong moment is not lost.
//
// KNOWN LIMITATION. If octets are dropped and the link then goes down with no
// further frame end, that episode is never emitted. The alternative was the
// unknown undercount above, so this is the better trade -- and `rst_n` clears
// the sticky bit, so a remembered episode cannot survive a link flap and be
// attributed to the frames after it.
//
// This is a module rather than a dozen lines inside gem_mac because of where it
// has to be placed, not because of what it does. constrs/pins.xdc confines
// every cell the deskewed receive clock touches to one clock region -- a BUFH
// reaches no further -- and does it by naming whole hierarchies, on the stated
// grounds that constraining individual flops is bookkeeping. A bare flop in
// gem_mac's own scope could only be pinned by its inferred synthesis name.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rx_drop_episode (
    input  wire clk,        // rx_clk, the deskewed receive clock
    input  wire rst_n,      // rx_rst_n

    // gem_rx_fifo's drop: one cycle per octet refused because the FIFO was full.
    input  wire drop,
    // Any of the deframer's five end-of-frame events.
    input  wire frame_end,

    // One cycle per frame that lost at least one octet.
    output wire episode
);

    reg seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seen <= 1'b0;
        end else if (frame_end) begin
            seen <= 1'b0;       // emitted here, or the frame ended clean
        end else if (drop) begin
            seen <= 1'b1;
        end
    end

    assign episode = frame_end && (seen || drop);

endmodule
