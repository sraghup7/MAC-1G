//----------------------------------------------------------------------------
// gem_iddr -- the double-data-rate input cell the RGMII receive pins need.
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
// Input cell: one pin, back to the two halves of one cycle.
//
// Sampling phases, which are not the ones they look like they should be. With
// the PHY's clock-to-out, the value launched on the rising edge is stable
// across the following FALLING edge, and the value launched on the falling
// edge across the following RISING edge. So each half is captured one edge
// after it was launched, and the pair is complete at the rising edge that ends
// the cycle. This is the same reasoning -- and the same phases -- as
// rgmii_monitor, which was written first and got it wrong first.
//----------------------------------------------------------------------------
module gem_iddr (
    input  wire clk,
    input  wire d,
    output reg  q_rise,     // what the pin carried across the high phase
    output reg  q_fall      // ... and across the low phase
);

`ifdef GEM_BEHAVIORAL_IO

    reg rise_cap;

    initial begin
        rise_cap = 1'b0;
        q_rise   = 1'b0;
        q_fall   = 1'b0;
    end

    always @(negedge clk) begin
        rise_cap <= d;
    end

    always @(posedge clk) begin
        q_rise <= rise_cap;
        q_fall <= d;
    end

`else

    // SAME_EDGE_PIPELINED presents both halves of one cycle together on the
    // rising edge, one cycle later. Q1 is the rising-edge capture and Q2 the
    // falling-edge one.
    //
    // WHICH HALF LANDS ON Q1: the board's PHY is a JLSemi JL2121(D)
    // (spec/PROJECT_SPEC.md A.2), whose RXDLY strap is populated for +2.000 ns
    // (Manuals/AX7035B_UG.pdf Table 8-1). On an 8 ns RGMII period, 2 ns is
    // exactly half a unit interval (4 ns), so the delayed RX_CLK rising edge
    // aligns with the PHY's FALLING-edge launch -- the HIGH nibble. Thus Q1
    // (rising-edge capture) = HIGH nibble, Q2 (falling-edge capture) = LOW
    // nibble. This is the OPPOSITE of the KSZ9031RNX's 1.2 ns default, and
    // the mapping in gem_rgmii_rx.v is {d_rise, d_fall} = {Q1, Q2} = {high, low}.
    //
    // An earlier revision (for KSZ9031RNX) had the opposite mapping and was
    // wrong for this board: every received octet would arrive nibble-swapped
    // (SFD 0xD5 reading as 0x5D), and the SFD hunter would never find a frame.
    // Simulation cannot see this (V-2) because it runs the behavioural branch.
    wire q1, q2;

    IDDR #(
        .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
        .INIT_Q1      (1'b0),
        .INIT_Q2      (1'b0),
        .SRTYPE       ("SYNC")
    ) u_iddr (
        .Q1 (q1),
        .Q2 (q2),
        .C  (clk),
        .CE (1'b1),
        .D  (d),
        .R  (1'b0),
        .S  (1'b0)
    );

    always @(*) begin
        q_rise = q1;    // rising-edge capture: the value across the high phase
        q_fall = q2;    // falling-edge capture: the value across the low phase
    end

`endif

endmodule
