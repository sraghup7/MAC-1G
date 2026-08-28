//----------------------------------------------------------------------------
// gem_stats -- R17's counter block, entirely in the sys_clk (= tx_clk) domain.
//
// The RX counters count events that happen in the rx_clk domain, and there are
// two ways to do that. Counting in rx_clk and synchronising nine 32-bit values
// across means nine multi-bit crossings, each needing its own handshake or
// Gray coding; carrying one event per class across and counting on this side
// means nine single-bit crossings through a structure whose safety argument
// fits in a paragraph. The second is what this does. R19's "zero undeclared CDC
// paths" is much easier to hold to when there is almost nothing crossing.
//
// WRAP IS EXPECTED BEHAVIOUR, not an error. 32 bits at B.3a's worst-case
// 1.488 Mframe/s wraps in about 48 minutes, and B.5 step 8's soak runs at least
// four hours -- so any comparison of these against a model has to be modular,
// and nothing here saturates or flags.
//
// stat_clear is synchronous and clears everything at once, so a reader can zero
// the block and know that every counter it then reads covers the same window.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_stats (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire        ev_tx_ok,
    input  wire        ev_tx_rejected,
    input  wire        ev_tx_underrun,
    input  wire        ev_rx_ok,
    input  wire        ev_rx_badfcs,
    input  wire        ev_rx_runt,
    input  wire        ev_rx_oversize,
    input  wire        ev_rx_rxer,
    input  wire        ev_rx_fifo_drop,

    output reg [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_tx_rejected,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_tx_underrun,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_badfcs,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_runt,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_rxer,
    output reg [`GEM_COUNTER_WIDTH-1:0] stat_rx_fifo_drop
);

    localparam [`GEM_COUNTER_WIDTH-1:0] ONE  = {{(`GEM_COUNTER_WIDTH-1){1'b0}}, 1'b1};
    localparam [`GEM_COUNTER_WIDTH-1:0] ZERO = {`GEM_COUNTER_WIDTH{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_tx_ok        <= ZERO;
            stat_tx_rejected  <= ZERO;
            stat_tx_underrun  <= ZERO;
            stat_rx_ok        <= ZERO;
            stat_rx_badfcs    <= ZERO;
            stat_rx_runt      <= ZERO;
            stat_rx_oversize  <= ZERO;
            stat_rx_rxer      <= ZERO;
            stat_rx_fifo_drop <= ZERO;
        end else if (clear) begin
            stat_tx_ok        <= ZERO;
            stat_tx_rejected  <= ZERO;
            stat_tx_underrun  <= ZERO;
            stat_rx_ok        <= ZERO;
            stat_rx_badfcs    <= ZERO;
            stat_rx_runt      <= ZERO;
            stat_rx_oversize  <= ZERO;
            stat_rx_rxer      <= ZERO;
            stat_rx_fifo_drop <= ZERO;
        end else begin
            if (ev_tx_ok)         stat_tx_ok        <= stat_tx_ok        + ONE;
            if (ev_tx_rejected)   stat_tx_rejected  <= stat_tx_rejected  + ONE;
            if (ev_tx_underrun)   stat_tx_underrun  <= stat_tx_underrun  + ONE;
            if (ev_rx_ok)         stat_rx_ok        <= stat_rx_ok        + ONE;
            if (ev_rx_badfcs)     stat_rx_badfcs    <= stat_rx_badfcs    + ONE;
            if (ev_rx_runt)       stat_rx_runt      <= stat_rx_runt      + ONE;
            if (ev_rx_oversize)   stat_rx_oversize  <= stat_rx_oversize  + ONE;
            if (ev_rx_rxer)       stat_rx_rxer      <= stat_rx_rxer      + ONE;
            if (ev_rx_fifo_drop)  stat_rx_fifo_drop <= stat_rx_fifo_drop + ONE;
        end
    end

endmodule
