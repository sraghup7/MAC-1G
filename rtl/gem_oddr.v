//----------------------------------------------------------------------------
// gem_oddr -- the double-data-rate output cell the RGMII transmit pins need.
//
// It exists in two forms, and which one you get is decided by a define:
//
//   default (no define)   the Xilinx primitive. This is what
//                         synthesis, implementation and the bitstream use.
//                         A DDR pin at 125 MHz has to be registered in the
//                         IOB, and UG901 is explicit that these primitives are
//                         instantiated, never inferred -- so an "inferrable"
//                         version would not be the same circuit, it would be a
//                         clock feeding a LUT.
//
//   GEM_BEHAVIORAL_IO     a plain Verilog model, for XSim and Verilator.
//
// THE DEFAULT IS DELIBERATELY THE SYNTHESISABLE ONE. If the define is
// forgotten in a simulation flow the failure is loud (`ODDR` is not a module
// anyone can find); if it were the other way round, a forgotten define during
// synthesis would quietly build a clock-muxed LUT that behaves in simulation
// and fails on the bench -- exactly the class of bug this project's I/O
// constraints exist to prevent.
//
// WHAT THE BEHAVIOURAL MODEL IS FOR, AND WHAT IT IS NOT. It reproduces
// the pairing and the phase relationship of the primitives, not their timing.
// Two consequences worth writing down rather than discovering:
//
//   1. The behavioural output cell is one clock later than a real ODDR. Every
//      octet is shifted by the same amount, and every consumer (the RGMII
//      monitor, the loopback, the golden comparison after burst segmentation)
//      measures relative to the frame, so this is invisible -- but it is a
//      difference, and pretending otherwise is how sim/hardware divergence
//      gets missed.
//   2. Nothing here models clock-to-out, setup or hold. R14's GTX_CLK
//      shift and the PHY's 1.2 ns RX delay cannot be checked by simulation at
//      all; that is open item V-2, and it closes with static timing analysis
//      and a scope, not here.
//
// The nonblocking assignments in the output cell are not stylistic. Both this
// design and the frozen rgmii_monitor sample on clock edges, so a continuous
// assignment muxed by the clock would update in the same region the monitor
// reads and the captured stream would depend on scheduling order -- which is
// the exact bug (nondeterministic capture) that the BFM's clock-to-out delay
// exists to avoid on the driver side. Nonblocking assignment gives every
// edge-triggered reader the pre-edge value by construction, on any simulator.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps


//----------------------------------------------------------------------------
// Output cell: one pin, two nibbles' worth of one bit per clock.
//
//   d_rise  the value the pin carries across the high phase (RGMII: the low
//           nibble of the octet, and TX_EN on TX_CTL)
//   d_fall  the value it carries across the low phase (the high nibble, and
//           TX_EN ^ TX_ER)
//----------------------------------------------------------------------------
module gem_oddr (
    input  wire clk,
    input  wire d_rise,
    input  wire d_fall,
    output wire q
);

`ifdef GEM_BEHAVIORAL_IO

    // Both halves of one cycle have to leave together, so they are staged to
    // the same depth: d_rise is read one edge before it is presented and
    // d_fall one edge after, which without the extra register would pair the
    // low nibble of one octet with the high nibble of the next. That is not a
    // hypothetical -- it is the bug the Stage 3 review found in the monitor,
    // seen from the other side of the same pin.
    reg rise_q, fall_q, fall_d;
    reg pin;

    initial begin
        rise_q = 1'b0;
        fall_q = 1'b0;
        fall_d = 1'b0;
        pin    = 1'b0;
    end

    always @(posedge clk) begin
        rise_q <= d_rise;
        fall_d <= fall_q;
        fall_q <= d_fall;
    end

    /* verilator lint_off COMBDLY */
    // Justified suppression (R22 permits one with a reason). This block is
    // sensitive to both edges of the clock, which Verilator reads as
    // combinational and therefore objects to the nonblocking assignment. The
    // nonblocking assignment is the entire point: see the header note on why a
    // clock-muxed continuous assignment would make the captured wire stream
    // depend on simulator scheduling order. Simulation-only code -- the
    // synthesis path below instantiates a real ODDR and never reaches here.
    always @(clk) begin
        if (clk) begin
            pin <= rise_q;
        end else begin
            pin <= fall_d;
        end
    end
    /* verilator lint_on COMBDLY */

    assign q = pin;

`else

    // SAME_EDGE: both inputs are captured on the rising edge, D1 is presented
    // across the high phase and D2 across the low phase. That is the RGMII
    // mapping directly, with no extra alignment register.
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr (
        .Q  (q),
        .C  (clk),
        .CE (1'b1),
        .D1 (d_rise),
        .D2 (d_fall),
        .R  (1'b0),
        .S  (1'b0)
    );

`endif

endmodule
