//----------------------------------------------------------------------------
// gem_clk_rst -- the clock and reset block spec B.1a names and Stage 4
// deliberately did not build: the MMCM, one reset synchroniser per domain, and
// the PHY's power-on reset hold.
//
// It is board-level integration rather than MAC logic, which is why gem_mac
// takes tx_clk, gtx_clk_shifted, tx_rst_n and rx_rst_n as inputs and contains
// no reset synchroniser of its own. Everything that turns a bare 50 MHz pin
// and a button into those four signals lives here.
//
// WHAT COMES OUT, AND WHAT EACH ONE IS GATED ON (B.1b's reset strategy):
//
//   tx_clk / gtx_clk_shifted   the MMCM's two outputs. See gem_mmcm for the
//                              1.6 ns and the arithmetic behind it.
//
//   tx_rst_n   released only once the MMCM reports LOCKED. Never let logic
//              out of reset onto an unlocked MMCM: the output clock during
//              acquisition is not a 125 MHz clock, it is whatever the VCO is
//              doing on the way there, and a state machine clocked by that
//              comes out of reset in a state nobody designed.
//
//   rx_rst_n   released on rx_clk alone, with no reference to the MMCM. This
//              is B.1b's rule that no domain's reset release depends on
//              another domain's clock running, and it is not academic here:
//              rx_clk is recovered by the PHY's CDR and simply does not exist
//              until the PHY is out of reset with a link. Gating it on LOCKED
//              would work on the bench and be wrong in principle; gating the
//              MMCM's domain on rx_clk would deadlock the whole design
//              whenever the cable is unplugged.
//
//   phy_rst_n  held low for >= 10 ms after the board reset releases
//              (KSZ9031RNX tSR, B.1b). Counted on clk50 because that is the
//              only clock guaranteed to be running at that point -- counting
//              it on tx_clk would mean the PHY's reset hold depends on the
//              MMCM, which is the coupling this block exists to avoid.
//
// A DELIBERATE NON-COUPLING, stated because its consequence is visible on the
// bench: tx_rst_n is not gated on phy_rst_n, so the MAC starts polling MDIO
// several milliseconds before the PHY answers. That is intentional -- the two
// have nothing to do with each other, and gem_mdio's phy_id_valid already
// distinguishes a real ID from the all-ones a bus with nothing driving it
// returns. If a top level ever wants the MAC to wait for the PHY, that is a
// decision to write down there, in one AND gate, rather than to bury here.
//
// POWER-UP WITH ext_rst_n TIED HIGH. If the board's reset key turns out to be
// unreachable (its pin is one of the things the ALINX manual's text extraction
// never captured), tying ext_rst_n high still works on hardware: the FPGA's
// global set/reset clears every flop in the synchroniser chains at
// configuration, so each one walks itself out of reset STAGES clocks later.
// Simulation has no GSR, so a testbench must assert ext_rst_n explicitly --
// which is the difference tb_gem_clk_rst's first check exists to pin down.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_clk_rst #(
    // Cycles of clk50 that phy_rst_n stays low after the board reset releases.
    // The default is the KSZ9031RNX's 10 ms from the parameter header, in
    // exact integer arithmetic: (50e6 / 1e6) * 10000 us = 500,000 cycles.
    // A testbench overrides it to check the sequencing without simulating
    // 10 ms of it; nothing else should.
    parameter integer PHY_RST_CYCLES = (`GEM_CLK50_HZ / 1000000) * `GEM_PHY_RESET_HOLD_US
) (
    input  wire clk50,      // board oscillator, free-running, never gated
    input  wire ext_rst_n,  // board reset key: asynchronous, active low
    input  wire rx_clk,     // recovered by the PHY; may not be running yet

    output wire tx_clk,
    output wire gtx_clk_shifted,
    output wire tx_rst_n,
    output wire rx_rst_n,
    output wire mmcm_locked,
    output wire phy_rst_n
);

    //======================================================================
    // Clock generation
    //======================================================================
    gem_mmcm u_mmcm (
        .clk_in   (clk50),
        .rst      (~ext_rst_n),
        .clk_out0 (tx_clk),
        .clk_out1 (gtx_clk_shifted),
        .locked   (mmcm_locked)
    );

    //======================================================================
    // One reset synchroniser per domain
    //======================================================================
    //
    // Three domains, three chains, three different asynchronous sources -- and
    // the differences between those sources are the whole design:
    //
    //   clk50   the button alone. This domain has to be alive before anything
    //           else is, because it is what times the PHY's reset.
    //   tx_clk  the button AND lock. Losing lock re-asserts reset immediately
    //           and asynchronously, which is correct and necessary: when the
    //           MMCM unlocks, tx_clk stops, and a synchronous path could not
    //           deliver the reset at all.
    //   rx_clk  the button alone, again -- see the header on why LOCKED must
    //           not appear in this expression.
    wire ref_rst_n;

    gem_reset_sync u_ref_rst (
        .clk    (clk50),
        .arst_n (ext_rst_n),
        .rst_n  (ref_rst_n)
    );

    gem_reset_sync u_tx_rst (
        .clk    (tx_clk),
        .arst_n (ext_rst_n & mmcm_locked),
        .rst_n  (tx_rst_n)
    );

    gem_reset_sync u_rx_rst (
        .clk    (rx_clk),
        .arst_n (ext_rst_n),
        .rst_n  (rx_rst_n)
    );

    //======================================================================
    // PHY reset hold (KSZ9031RNX tSR >= 10 ms)
    //======================================================================
    //
    // The counter stops at its terminal value rather than wrapping, so
    // phy_rst_n rises once and stays up until the next board reset. A counter
    // that wrapped would re-assert the PHY's reset every 21 ms, which is the
    // sort of fault that presents as a link that negotiates and then dies.
    //
    // 20 bits holds 1,048,575 -- twice the 500,000 the default needs, and the
    // ceiling on any override: 21 ms at 50 MHz. Sized here rather than derived
    // from the parameter because Verilog-2001 has no $clog2 and the repository
    // has no other place that pretends otherwise.
    localparam [19:0] PHY_RST_TERMINAL = PHY_RST_CYCLES[19:0];

    reg [19:0] phy_rst_cnt;
    reg        phy_rst_n_r;

    always @(posedge clk50 or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            phy_rst_cnt <= 20'd0;
            phy_rst_n_r <= 1'b0;
        end else if (phy_rst_cnt != PHY_RST_TERMINAL) begin
            phy_rst_cnt <= phy_rst_cnt + 20'd1;
            phy_rst_n_r <= 1'b0;
        end else begin
            phy_rst_n_r <= 1'b1;
        end
    end

    assign phy_rst_n = phy_rst_n_r;

endmodule
