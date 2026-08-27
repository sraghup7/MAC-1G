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
    // WHICH HALF LANDS ON Q1 IS NOT A PER-PHY CHOICE. RGMII v2.0 fixes it:
    // RXD[3:0] carries the LOW nibble on the rising edge and the HIGH nibble
    // on the falling one, on every compliant PHY. So Q1 = LOW, Q2 = HIGH, and
    // gem_rgmii_rx.v's mapping is {d_fall, d_rise} = {Q2, Q1} = {high, low}.
    // What a PHY's RX_CLK delay strap changes is WHERE IN THE EYE the capture
    // edge lands -- never which nibble of which octet the pair belongs to.
    //
    // COMMIT da81e24 GOT THIS WRONG AND WAS REVERTED (B.5 bring-up,
    // 2026-08-27). Its reasoning was that the JL2121(D)'s +2.000 ns RXDLY
    // strap is half of the 4 ns unit interval, so the rising edge "aligns
    // with the PHY's falling-edge launch" and Q1 becomes the HIGH nibble.
    // Half a UI of clock delay CENTRES the rising edge in the nibble that
    // same rising edge launched; it does not advance the edge into the next
    // one. A whole UI would. The commit also never re-ran the RX simulation,
    // which fails on the swapped mapping and passes 1469 checks on this one.
    //
    // AND IF THE CAPTURE EDGE REALLY IS A WHOLE NIBBLE AWAY, NO NIBBLE ORDER
    // HERE CAN REPAIR IT. The pair (Q1, Q2) then straddles an octet boundary
    // -- Q1 holding one octet's high nibble, Q2 the NEXT octet's low nibble
    // -- so {Q1,Q2} and {Q2,Q1} are both wrong, and wrong in a way that hides
    // itself: every octet whose two nibbles are equal (the 0x55 preamble) or
    // whose high nibble repeats its predecessor's (a 0x00-0x0f payload run)
    // still decodes clean, so the damage reads as sporadic corruption at
    // high-transition bytes rather than as the systematic re-framing it is.
    // That is what the bring-up ILA captured, and the lever is the capture
    // clock's phase in rtl/gem_rx_mmcm.v -- not this mapping.
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
