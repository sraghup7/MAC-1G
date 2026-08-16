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
//   2. Nothing here models clock-to-out, setup or hold. R14's 1.6 ns GTX_CLK
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
    // WHICH HALF LANDS ON Q1, which an earlier revision of this file claimed
    // could not be settled from a datasheet. It can, and the datasheet is
    // B.1b's own citation: the KSZ9031RNX adds 1.2 ns to RX_CLK relative to
    // RXD by default, which walks the clock into the middle of the data eye.
    // The rising edge therefore samples the nibble the PHY launched on ITS
    // rising edge -- the low nibble -- so Q1 is the low nibble and Q2 the high
    // one. The same mapping is what reference/verilog-ethernet's
    // rgmii_phy_if.v uses in the field (Q1 -> rxd[3:0], rx_dv = ctl_1).
    //
    // This was wrong once, and wrong in the direction that costs a bring-up
    // session: the mapping was carried over from the behavioural model above,
    // whose phase convention is correct for the testbench's clock-aligned
    // launch and NOT for a PHY that delays the clock. Every received octet
    // would have arrived nibble-swapped -- an SFD of 0xD5 reading as 0x5D, so
    // the hunter would never find a frame -- and gm_dv would have been carrying
    // DV ^ RX_ER. Simulation cannot see it, because simulation runs the branch
    // above. What is genuinely left for the bench is confirming the PHY's delay
    // is present at all (V-2), not deciding which wire goes where.
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
