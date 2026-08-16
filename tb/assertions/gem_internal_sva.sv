//----------------------------------------------------------------------------
// gem_internal_sva -- invariants on gem_mac's internal state.
//
// STATUS: active as of Stage 4. Every property below was written in Stage 3,
// before the modules it refers to existed, and none of them was changed to suit
// the RTL when the RTL arrived.
//
// That order is the point. Writing these first forced the question "what would
// I have to be able to observe to check this?" while the module boundaries were
// still free to move -- a FIFO whose fill level is buried in an unnamed
// expression is one whose overflow cannot be asserted on. So gem_rx_fifo
// exposes `level`, gem_rx_deframe exposes `state` and `frame_active`, and
// gem_crc32 keeps its accumulator in a register called `crc_reg`, because these
// properties asked for them. Writing assertions after the RTL means asserting
// whatever the implementation happened to expose, which is how a design ends up
// with assertions that restate the code instead of the spec.
//
// One of them did real work immediately. a_crc_reseeded fails if the
// accumulator still holds the previous frame's remainder on the first hunting
// cycle, which is exactly what the obvious implementation does -- re-seed when
// the hunt begins. The RX deframer asserts init one cycle earlier, on the
// end-of-frame cycle, and the comment there says why.
//----------------------------------------------------------------------------

`ifndef GEM_INTERNAL_SVA_SV
`define GEM_INTERNAL_SVA_SV

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_internal_sva (
    input wire        rx_clk,
    input wire        rx_rst_n,
    input wire        sys_clk,
    input wire        sys_rst_n,

    // From the RX async FIFO (B.3a, depth 64)
    input wire [`GEM_RX_FIFO_ADDR_W:0] fifo_level,
    input wire                         fifo_wr_en,
    input wire                         fifo_full,

    // From the RX control FSM
    input wire [2:0]  rx_state,
    input wire        rx_frame_active,

    // From the CRC accumulator
    input wire [31:0] rx_crc_reg
);

    //------------------------------------------------------------------
    // The FIFO must never overflow (B.3a's whole derivation says it cannot)
    //------------------------------------------------------------------
    //
    // B.3a derives the required depth as ~4.3 bytes and chooses 64, about 15x
    // headroom. If this ever fires, the derivation's premise is wrong -- most
    // likely the no-stall user contract (R18) is being violated somewhere --
    // and the fix belongs back in Stage 1, not in a bigger FIFO.
    a_fifo_never_overflows: assert property (@(posedge rx_clk) disable iff (!rx_rst_n)
        !(fifo_wr_en && fifo_full))
        else $error("rx_fifo: write while full -- B.3a's depth derivation is wrong");

    a_fifo_within_depth: assert property (@(posedge rx_clk) disable iff (!rx_rst_n)
        fifo_level <= `GEM_RX_FIFO_DEPTH)
        else $error("rx_fifo: level %0d exceeds depth %0d", fifo_level, `GEM_RX_FIFO_DEPTH);

    //------------------------------------------------------------------
    // The RX FSM must never reach an unencoded state
    //------------------------------------------------------------------
    a_rx_state_legal: assert property (@(posedge rx_clk) disable iff (!rx_rst_n)
        rx_state inside {3'd0, 3'd1, 3'd2, 3'd3, 3'd4})
        else $error("rx_fsm: illegal state 0x%0h", rx_state);

    //------------------------------------------------------------------
    // R10 -- recovery inside the 8-cycle budget
    //------------------------------------------------------------------
    //
    // The single most valuable property in this file, and the reason it was
    // written before the RTL. Documents/"Why RX Recovery Gets 8 Cycles, Not
    // 20.md" derives that a compliant link may present the next SFD only 8
    // byte times after the last frame ended. So from any end of frame --
    // clean or aborted -- the FSM must be back to hunting within 8 cycles,
    // with the CRC accumulator re-seeded.
    //
    // A design that silently needs 15 cycles passes every functional test that
    // uses a nominal gap, and fails on real hardware against a switch. This
    // assertion catches it in whichever scenario happens to run, rather than
    // relying on someone remembering to write the tight-gap test.
    a_rx_recovers_in_budget: assert property (@(posedge rx_clk) disable iff (!rx_rst_n)
        $fell(rx_frame_active) |-> ##[1:`GEM_IFG_RX_MIN_BYTES] (rx_state == 3'd0))
        else $error("rx_fsm: not back to hunting within %0d cycles of end of frame (R10)",
                    `GEM_IFG_RX_MIN_BYTES);

    a_crc_reseeded: assert property (@(posedge rx_clk) disable iff (!rx_rst_n)
        (rx_state == 3'd0) |-> (rx_crc_reg == `GEM_CRC32_INIT))
        else $error("rx_crc: accumulator not re-seeded while hunting -- the next frame is poisoned");

endmodule


bind gem_mac gem_internal_sva u_internal_sva (
    .rx_clk          (rgmii_rx_clk),
    .rx_rst_n        (rx_rst_n),
    .sys_clk         (tx_clk),
    .sys_rst_n       (tx_rst_n),
    .fifo_level      (u_rx_fifo.level),
    .fifo_wr_en      (u_rx_fifo.wr_en),
    .fifo_full       (u_rx_fifo.full),
    .rx_state        (u_rx_ctrl.state),
    .rx_frame_active (u_rx_ctrl.frame_active),
    .rx_crc_reg      (u_rx_crc.crc_reg)
);

`endif
