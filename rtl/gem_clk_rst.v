//----------------------------------------------------------------------------
// gem_clk_rst -- the clock and reset block spec B.1a names and Stage 4
// deliberately did not build: the MMCM, one reset synchroniser per domain, the
// PHY's power-on reset hold -- and, since Stage 6 part 2, the deskew MMCM for
// the recovered receive clock, its reset supervisor, and a second RX-domain
// crossing reset.
//
// It is board-level integration rather than MAC logic, which is why gem_mac
// takes tx_clk, gtx_clk_shifted, tx_rst_n, rx_rst_n and rx_path_rst_n as
// inputs and contains no reset synchroniser of its own. Everything that turns
// a bare 50 MHz pin and a button into those signals lives here.
//
// WHAT COMES OUT, AND WHAT EACH ONE IS GATED ON:
//
//   tx_clk / gtx_clk_shifted   the crystal MMCM's two outputs. See gem_mmcm
//                              for the phase shift and the arithmetic behind it.
//
//   tx_rst_n   released only once the crystal MMCM reports LOCKED. Never let
//              logic out of reset onto an unlocked MMCM: the output clock
//              during acquisition is not a 125 MHz clock, it is whatever the
//              VCO is doing on the way there, and a state machine clocked by
//              that comes out of reset in a state nobody designed.
//
//   rx_clk_deskew  rgmii_rx_clk deskewed through the second MMCM
//                  (u_rx_mmcm, gem_rx_mmcm). This -- not the raw pin -- clocks
//                  the receive domain: cancelling the clock network's
//                  insertion-delay spread is the whole point, see
//                  Documents/RX Clock Deskew Design.md.
//
//   rx_rst_n   released on the DESKEWED clock, gated on tx_rst_n AND the RX
//              MMCM's lock. The reasoning this file used to carry here --
//              that rx_rst_n must depend on nothing but rx_clk existing --
//              was correct about the design it described and is superseded by
//              the deskew design: an MMCM on a recovered clock does not
//              self-recover after its input stops (UG472 p.83/91, proven
//              structurally in the vendor model), so its domain's release has
//              to wait for the supervisor's re-lock. The full argument, the
//              B.1b exception it takes, and why it stays deadlock-free are in
//              Documents/RX Clock Deskew Design.md Steps 3a-3e and 5.
//
//   rx_path_rst_n  a SECOND reset, in the tx_clk domain, covering the
//              destination half of every clock-domain crossing OUT of the RX
//              domain (the FIFO's read side, the five counter-event
//              synchronisers inside gem_mac, the egress register, and the
//              FIFO-drop LED synchroniser in gem_top). Without it, resetting
//              the RX half alone leaves stale FIFO contents that get delivered
//              as fabricated frames, plus phantom counter events -- the
//              failure class Step 3b of the design document exists for. This
//              is the first mechanism in the project able to reset one side of
//              a crossing without the other, which is exactly why both halves
//              now assert together.
//
//   phy_rst_n  held low for >= 10 ms after the board reset releases
//              (JL2121(D) DS009 §4.7.1 t1/t3 >= 10 ms; KSZ9031RNX tSR was the
//               same 10 ms, so the value never moved — only its source did.
//               B.1b). Counted on clk50 because that is the
//              only clock guaranteed to be running at that point -- counting
//              it on tx_clk would mean the PHY's reset hold depends on the
//              MMCM, which is the coupling this block exists to avoid.
//
// THE RX MMCM RESET SUPERVISOR (Step 3c of the design document) runs on clk50,
// which never stops and gates nothing: while the RX MMCM reports unlocked it
// pulses RST for 80 ns every 327.68 us forever. The pulse exceeds
// MMCM_RSTMINPULSE (5 ns); the period exceeds three times MMCM_TLOCKMAX
// (100 us), so a retry cannot interrupt a lock acquisition that would have
// succeeded. Worst case from clock-return to locked is therefore retry period
// + lock time = ~428 us, NOT the 100 us lock figure alone. The registered
// output with asynchronous preset is deliberate: a combinational magnitude
// comparison driving a hard primitive's RST pin is a glitch away from
// resetting nothing at the wrong moment, and the async preset holds the MMCM
// in reset from configuration until ref_rst_n releases.
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
    // The default is the JL2121(D)'s 10 ms (DS009 §4.7.1 t1/t3, confirmed
    // against the real datasheet — the KSZ9031RNX tSR it was first sourced to
    // was the same 10 ms) from the parameter header, in
    // exact integer arithmetic: (50e6 / 1e6) * 10000 us = 500,000 cycles.
    // A testbench overrides it to check the sequencing without simulating
    // 10 ms of it; nothing else should.
    parameter integer PHY_RST_CYCLES = (`GEM_CLK50_HZ / 1000000) * `GEM_PHY_RESET_HOLD_US,
    // Cycles of clk50 between pulses of the RX MMCM's recovery reset while it
    // reports unlocked. Default: 16384 x 20 ns = 327.68 us > 3 x MMCM_TLOCKMAX.
    // Same justification as PHY_RST_CYCLES: a testbench overrides it to check
    // the sequencing without simulating 327 us of it; nothing else should.
    // 15 bits is the ceiling on any override: 655.34 us.
    parameter integer RX_MMCM_RETRY_CYCLES = 16384
) (
    input  wire clk50,      // board oscillator, free-running, never gated
    input  wire ext_rst_n,  // board reset key: asynchronous, active low
    input  wire rx_clk,     // RAW rgmii_rx_clk pin; may not be running yet

    output wire tx_clk,
    output wire gtx_clk_shifted,
    output wire rx_clk_deskew,   // the deskewed clock the RX domain runs on
    output wire tx_rst_n,
    output wire rx_rst_n,        // RX domain proper, lock-gated
    output wire rx_path_rst_n,   // destination halves of RX-domain crossings
    output wire mmcm_locked,     // crystal MMCM
    output wire rx_mmcm_locked,  // RX deskew MMCM
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

    // The RX deskew MMCM, fed the RAW pin -- no buffer between them, or its
    // compensation would be compensating a BUFG instead of the pin (UG472
    // p.89). Its reset comes from the clk50 supervisor below, never from
    // anything in the RX domain: when the recovered clock stops, nothing in
    // that domain can be trusted to run, let alone to recover it.
    wire rx_mmcm_rst;

    gem_rx_mmcm u_rx_mmcm (
        .clk_in (rx_clk),
        .rst    (rx_mmcm_rst),
        .clk_out(rx_clk_deskew),
        .locked (rx_mmcm_locked)
    );

    //======================================================================
    // The RX MMCM's reset supervisor, on clk50 (design doc Step 3c)
    //======================================================================
    //
    // UG472 p.83/p.91: LOCKED deasserts when the input clock stops, and a
    // RESET must be applied after it returns -- the primitive does not
    // self-recover (proven structurally in the vendor's own model; see design
    // doc Step 3a). Nothing in the RX domain can apply that reset, because the
    // RX domain is precisely what died. clk50 is free-running and gates
    // nothing, so the recovery mechanism sits on the root of the dependency
    // graph rather than on the branch that stopped.
    //
    // locked_s is a plain 2-flop data synchroniser, NOT gem_reset_sync: this
    // samples a level another domain drives, it does not distribute a reset.
    //
    // ref_rst_n is declared here rather than with the reset synchronisers
    // below because the supervisor's flops reset on it and Verilog-2001 has
    // no forward references.
    wire ref_rst_n;

    (* ASYNC_REG = "TRUE" *) reg locked_s1, locked_s2;

    always @(posedge clk50 or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            locked_s1 <= 1'b0;
            locked_s2 <= 1'b0;
        end else begin
            locked_s1 <= rx_mmcm_locked;
            locked_s2 <= locked_s1;
        end
    end

    wire locked_s = locked_s2;

    localparam [14:0] RX_MMCM_RETRY_TERMINAL = RX_MMCM_RETRY_CYCLES[14:0];
    localparam [14:0] RST_PULSE_CYCLES       = 15'd4;   // 80 ns >= MMCM_RSTMINPULSE

    reg [14:0] retry_cnt;
    reg        rx_mmcm_rst_r;

    always @(posedge clk50 or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            retry_cnt <= 15'd0;
        end else if (locked_s) begin
            // Held at zero for as long as lock holds, so the instant it is
            // lost the retry counter has not yet counted anywhere and the
            // comparison below is already true: RST asserts on the next
            // clk50 edge, not after a wait. Load-bearing -- do not "simplify".
            retry_cnt <= 15'd0;
        end else if (retry_cnt == RX_MMCM_RETRY_TERMINAL) begin
            retry_cnt <= 15'd0;
        end else begin
            retry_cnt <= retry_cnt + 15'd1;
        end
    end

    // Registered with an asynchronous PRESET: held asserting from
    // configuration until ref_rst_n releases, then a clean glitch-free level.
    always @(posedge clk50 or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            rx_mmcm_rst_r <= 1'b1;
        end else begin
            rx_mmcm_rst_r <= (!locked_s) && (retry_cnt < RST_PULSE_CYCLES);
        end
    end

    assign rx_mmcm_rst = rx_mmcm_rst_r;

    //======================================================================
    // One reset synchroniser per domain
    //======================================================================
    //
    // Four chains, four different asynchronous sources -- and the differences
    // between those sources are the whole design:
    //
    //   clk50      the button alone. This domain has to be alive before
    //              anything else is, because it times the PHY's reset and runs
    //              the RX MMCM's supervisor.
    //   tx_clk     the button AND crystal-MMCM lock. Losing lock re-asserts
    //              reset immediately and asynchronously, which is correct and
    //              necessary: when the MMCM unlocks, tx_clk stops, and a
    //              synchronous path could not deliver the reset at all.
    //   rx (deskew) tx_rst_n AND the RX MMCM's lock, released on the deskewed
    //              clock. The lock gate is UG472 p.83 ("the clock outputs
    //              should not be used prior to the assertion of LOCKED") plus
    //              the no-self-recovery finding; taking tx_rst_n rather than
    //              ext_rst_n means an asymmetric reset in EITHER direction is
    //              impossible, not just the one the deskew introduced. See
    //              Documents/RX Clock Deskew Design.md Steps 3b/3d/5.
    //   rx_path    the tx_clk-side half of every crossing out of the RX domain,
    //              gated on rx_rst_n as well as tx_rst_n so both halves of any
    //              crossing always assert together. Release order falls out:
    //              write side first (rx_rst_n), then read side two tx_clk
    //              edges later -- Step 3b property 2.
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
        .clk    (rx_clk_deskew),
        .arst_n (tx_rst_n & rx_mmcm_locked),
        .rst_n  (rx_rst_n)
    );

    gem_reset_sync u_rx_path_rst (
        .clk    (tx_clk),
        .arst_n (tx_rst_n & rx_rst_n),
        .rst_n  (rx_path_rst_n)
    );

    //======================================================================
    // PHY reset hold (JL2121(D) DS009 §4.7.1 t1/t3 >= 10 ms; KSZ9031RNX tSR
    // was the same 10 ms — value unchanged, source corrected)
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
