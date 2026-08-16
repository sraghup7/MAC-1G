//----------------------------------------------------------------------------
// gem_reset_sync -- asynchronous assert, synchronous deassert (spec B.1b).
//
// The first reset synchroniser in this repository. Until Stage 5 there was
// none anywhere, and deliberately so: gem_mac takes tx_rst_n and rx_rst_n as
// inputs and states in its header that they arrive already synchronised, while
// every testbench simply supplied them that way. This module is what makes
// that claim true on hardware.
//
// WHY BOTH HALVES OF THE NAME MATTER -- each guards a different failure, and a
// design that gets one right and the other wrong looks fine until it does not:
//
//   asynchronous assert   a purely synchronous reset cannot take effect while
//                         its clock is stopped, and the two cases this design
//                         must survive are exactly those: power-up before the
//                         MMCM has locked, and an rx_clk the PHY has not
//                         started driving yet. Reset has to reach the flops
//                         with no edge available to carry it.
//
//   synchronous deassert  release, by contrast, must be aligned. Flops leaving
//                         reset on different edges of the same clock start from
//                         different states -- a recovery/removal violation,
//                         which does not fail every time and so gets blamed on
//                         everything except reset.
//
// The shift register is the whole mechanism. Reset drives the chain to zero
// from any state without a clock; releasing it walks a single 1 through STAGES
// flops, so nothing downstream sees the release until this domain's own clock
// has sampled it STAGES times. STAGES = 2 is the standard depth and the
// minimum this module accepts (STAGES = 1 does not elaborate -- the shift
// expression has no lower bits to select).
//
// ASYNC_REG tells the placer to keep the chain's flops in one slice, close
// together. Without it they can be spread across the die and the metastability
// settling time this structure buys gets eaten by routing -- which is not
// visible in simulation, in lint, or in a timing report, only in an MTBF
// nobody measured.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_reset_sync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire arst_n,   // asynchronous, from any domain or none
    output wire rst_n     // this domain's reset: async assert, sync deassert
);

    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            sync <= {STAGES{1'b0}};
        end else begin
            sync <= {sync[STAGES-2:0], 1'b1};
        end
    end

    assign rst_n = sync[STAGES-1];

endmodule
