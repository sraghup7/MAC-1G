//----------------------------------------------------------------------------
// gem_mmcm -- the board's 50 MHz oscillator turned into the two 125 MHz clocks
// spec B.1b's table names, and nothing else.
//
// It exists as its own file for the reason gem_oddr and gem_iddr do: the
// coding standard keeps vendor primitives out of logic modules, so every
// MMCME2_BASE/BUFG in this design is here and a reviewer looking for "what
// does this project instantiate?" has one place to look. Same two-branch
// shape, same define, same direction of default:
//
//   default (no define)   MMCME2_BASE plus a BUFG per output. This is what
//                         synthesis, implementation and the bitstream use.
//   GEM_BEHAVIORAL_IO     a plain-Verilog clock source, for XSim and Verilator,
//                         neither of which has the primitive's source here.
//
// THE TWO OUTPUTS, AND WHY THE SECOND ONE IS NOT A LUXURY (R14, B.1b):
//
//   clk_out0  125 MHz, phase 0. This is tx_clk -- the TX datapath, the
//             register block, and sys_clk (= tx_clk, B.7 item 3).
//   clk_out1  125 MHz, advanced 1.5556 ns ahead of clk_out0 -- see the
//             correction below for why "advanced" and not "delayed" this
//             time, and why the number is not B.1b's 1.2222 ns any more.
//             Drives exactly one thing: the ODDR that forwards GTX_CLK to
//             the PHY.
//
// SECOND CORRECTION (B.5 bring-up, 2026-08-27, from a hardware sweep):
// CLKOUT1_PHASE IS +60.000, NOT +70.000. The +70.000 derivation below is
// sound about the FPGA-internal asymmetry it cancels, and still wrong,
// because that asymmetry is not the only skew in the path -- the board's
// own TXD-vs-GTX_CLK trace skew is, and no FPGA-side derivation can see it.
// constrs/rgmii_timing.xdc says so in its own words: "board trace
// length/skew is not in this budget because B.1b never had trace-length
// data to put there."
//
// Swept on the real board, uniform SLEW FAST / DRIVE 16, echo payload
// mismatches per frames sent:
//
//   phase    errors / frames    WNS        note
//   55.0       0 / 4000       +0.019 ns    gate 2 nearly refuses
//   60.0       0 / 12000      +0.130 ns    <-- committed
//   65.0       3 / 4000       +0.241 ns
//   70.0      11 / 1000       +0.322 ns    the old value
//   80.0    3626 / 2000       +0.574 ns    ~27% of frames corrupt
//
// READ THAT WNS COLUMN AGAIN. It rises monotonically as the hardware gets
// WORSE. Setup slack against the TX output-delay constraint is ANTI-
// CORRELATED with whether the link actually works, because the constraint
// models FPGA-internal skew only and the real limit is board skew it cannot
// see. +70.000 was partly chosen by having more margin than +60.000 had.
// Optimising that number optimises the wrong thing, and on this interface
// it optimises it in the wrong direction. Do not retune this phase by
// looking at WNS; retune it with gem_host.py echo and thousands of frames.
//
// The lower edge of the working window was never found: gate 2 refuses below
// about 55 degrees, so 60.000 is confirmed clean but NOT confirmed centred.
// It sits one 5-degree grid step (111 ps) above 55.0 which is also clean, and
// one step below 65.0 which is not. If this ever drifts -- a different board,
// a temperature corner -- 55.0 is the direction to move, and the constraint
// is what stands in the way of going further.
//
// FIRST CORRECTION (B.5 bring-up, 2026-08-27): CLKOUT1_PHASE was +70.000
// (+1.5556 ns), NOT -55.000 (-1.2222 ns). Everything from here through "HOW
// THE OLD -55.000 VALUE WAS ARRIVED AT" describes Stage 6's derivation, now
// known to have solved the wrong problem, and the correct one it should have
// been solving -- kept as history plus the real fix, not two designs.
//
// B.1b assumed a KSZ9031RNX that "does not delay its own GTX_CLK input and
// expects the MAC to provide the skew," so Stage 6 spent two sub-projects
// finding a phase shift the FPGA could generate to hit the PHY's TsetupT/
// TholdT window (1.2-2.0 ns) itself. B.5 found the physical chip is a JLSemi
// JL2121(D) (spec/PROJECT_SPEC.md A.2's correction), and the real AX7035B
// manual (Manuals/AX7035B_UG.pdf Table 8-1) confirms its TXDLY strap is
// populated: "1: add 2ns delay to rgmii TX_CLK" (JL2121(D) datasheet Table
// 16, "Hardware Config"). TX_CLK/TXC is an INPUT to the PHY, so that is the
// PHY delaying its OWN internal use of the TXC it receives before latching
// TXD with it -- industry-standard "RGMII-ID" convention -- not a launch
// requirement on the FPGA. The FPGA-side target is therefore the OTHER
// table in the same datasheet chapter (4.7.3 "RGMII Timing", not "...With
// Delay Integrated At Transmitter"): TskewT, data-to-clock output skew at
// the launching device, -500 to +500 ps -- a much looser target than the
// old 1.2-2.0 ns one, aimed at the FPGA's own pins rather than the PHY's.
//
// THE FIRST ATTEMPT AT THIS CORRECTION WAS CLKOUT1_PHASE = 0.000 (launch
// GTX_CLK and TXD/TX_CTL from the identical clock phase, on the reasoning
// that TskewT needs no deliberate shift at all if both are launched
// together). Vivado's own post-route measurement (not simulated, not
// estimated -- gem_top built and routed with this change) showed that
// reasoning incomplete: at 0 degrees, TX hold failed by -1.278 ns
// (worst of five data/control outputs). The cause is a real, FPGA-internal
// asymmetry TskewT's ±500 ps target does not itself explain away: GTX_CLK is
// itself forwarded through an ODDR+OBUF (gem_rgmii_tx.v's u_oddr_gtx) to
// reach its pin, while TXD/TX_CTL's *launch reference* is clk_out0 only as
// far as their own ODDRs' clock pins -- an extra IOB hop that the reference
// clock's own timing does not carry. Measured post-route at 0 degrees:
// GTX_CLK's clock-network delay to its pin (destination clock delay) was
// 5.117 ns; TXD's clock-network delay to its launching flop (source clock
// delay) was 2.616 ns -- a native ~1.1 ns lag of GTX_CLK behind TXD that
// exists independent of any deliberate phase shift, and that TskewT's
// ±500 ps window cannot absorb on its own.
//
// THE FIX: a phase shift sized to cancel that native lag, not to hit the
// PHY's window -- a smaller, differently-motivated number that happens to
// land in a similar range. Setup and hold slack trade off perfectly
// linearly against CLKOUT1_PHASE (confirmed by sweeping the grid post-route:
// setup+hold slack sums to a constant ~1.502 ns at every phase tried), so
// the sweep is a search for the point that clears both, not a single
// closed-form phase. +70.000 degrees (1.5556 ns, advancing GTX_CLK earlier
// -- positive phase advances on this MMCM, the opposite sign convention
// from the old -55.000, which delayed) is the swept, measured result:
//
//   phase    TX setup slack   TX hold slack
//   0.000     +2.780 ns        -1.278 ns  (hold fails)
//   +35.000   -0.442 ns        +1.945 ns  (setup fails)
//   +50.000   -0.109 ns        +1.611 to +1.617 ns  (setup fails, thin)
//   +55.000   +0.003 ns        +1.500 ns  (both pass, setup too thin to trust)
//   +70.000   +0.336 ns        +1.167 ns  (both pass, comfortable)
//
// +70.000 was chosen over +55.000 for margin, not because it is a cleaner
// number -- 3 ps of measured setup slack is not a value to build a board
// bring-up on. Full path-by-path numbers for the +70.000 build are in
// Documents/RGMII I-O Timing Derivation.md's TX section.
//
// THE ARITHMETIC FOR THE CURRENT VCO/DIVIDER CHOICE (kept from the -55 deg
// era because nothing about the VCO or the output frequencies changed, only
// the phase):
//
//   VCO       = 50 MHz x CLKFBOUT_MULT_F(22.500) / DIVCLK_DIVIDE(1)
//             = 1125 MHz, inside the Artix-7 MMCM's 600-1200 MHz range.
//   clk_out0  = 1125 MHz / CLKOUT0_DIVIDE_F(9.000) = 125 MHz.
//   clk_out1  = 1125 MHz / CLKOUT1_DIVIDE(9)       = 125 MHz.
//   the shift = +70.000 degrees of the 8 ns period = +1.5556 ns; positive is
//               an advance on this MMCM (the old -55.000 delayed; sign
//               matters, see the correction above). 70/5 = 14 whole steps
//               of the 45/CLKOUT1_DIVIDE = 5 degree grid, exactly achievable.
//
//   BOTH OUTPUT FREQUENCIES ARE UNCHANGED from every configuration this
//   parameter has carried. tx_clk and gtx_clk_shifted are 125 MHz here
//   exactly as before, so nothing downstream sees any change from this
//   correction -- not the TX datapath, not sys_clk, not the UART's baud
//   divisor, not MDC's. Only CLKOUT1_PHASE moved, from -55.000 to +70.000.
//
// WHY A SECOND MMCM OUTPUT AND BUFG STILL EXIST -- unchanged from before this
// correction. `gem_rgmii_tx.v`'s header explains why GTX_CLK is forwarded
// through its own ODDR rather than driven from fabric logic: the same
// launch path as the data is what makes any skew claim meaningful. A second
// MMCM output (clk_out1) driving its own BUFG (u_bufg_gtx) keeps the GTX_CLK
// path structurally independent of the TX datapath's own clock tree, and is
// exactly what makes a phase shift between the two possible at all.
//
// HOW THE OLD -55.000 VALUE WAS ARRIVED AT, kept as history now that it no
// longer describes the design, because it took two sub-projects to reach and
// a future reader should not have to rediscover why it once looked right:
//
//   -72.000 -- B.1b's original intent, assuming the FPGA had to generate the
//   whole KSZ9031RNX TsetupT/TholdT skew itself: 1.6 ns, the centre of that
//   window. Never achievable on the then-current 1000 MHz VCO's 45/8 = 5.625
//   degree grid; write_bitstream's DRC (AVAL-139) refused it outright
//   (Stage 6 part 1).
//
//   -73.125 -- Stage 6 part 1's fix, the nearest legal grid point. Stage 6
//   part 2 measured it and found it violates TX setup on all five data
//   outputs by about 0.35 ns post-route (task-2-report.md). Sweeping the
//   whole grid inside the assumed PHY window found exactly one point that is
//   not violated -- 1.250 ns, clearing by 24 ps (task-2b-report.md).
//
//   -55.000 -- moved the VCO to change the phase grid itself rather than
//   accept the 5.625 degree grid's one thin survivor; measured the best
//   post-route margin (task-2d/2e-report.md) of the configurations the
//   assumed PHY window allowed. Per-configuration numbers are still in the
//   table in Documents/RGMII I-O Timing Derivation.md, kept as the historical
//   record of that sub-project, not as a live derivation.
//
//   All three values were solving a problem -- generating a full 1.2-2.0 ns
//   of TsetupT/TholdT skew on the FPGA side -- that the real chip's TXDLY
//   strap already solves on the PHY side. None of that measurement is wrong
//   about the FPGA's own clock-network behaviour, and in fact the same
//   measurement discipline is exactly what caught the 0-degree attempt's
//   hold failure above; it was answering a question this board does not ask.
//
// DO NOT REACH FOR CLKOUT1_USE_FINE_PS. This still applies at +70.000
// degrees: fine phase shift is a runtime interface (PSEN-driven), not a
// static one, and setting the parameter on MMCME2_ADV silences the DRC that
// would otherwise catch an off-grid CLKOUT1_PHASE (task-2d-report.md).
// MMCME2_BASE, the primitive below, does not accept the parameter at all.
//
// FEEDBACK IS INTERNAL: CLKFBOUT wires straight back to CLKFBIN with no BUFG.
// A BUFG in the feedback path exists to align the output clocks to the *input*
// clock, and nothing here needs that -- no external device is timed against
// the 50 MHz oscillator. What does matter is the phase relationship between
// CLKOUT0 and CLKOUT1, which is internal to the MMCM and identical either way.
// Internal feedback also has lower jitter, and saves a global buffer.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_mmcm (
    input  wire clk_in,     // 50 MHz board oscillator
    input  wire rst,        // active high, asynchronous
    output wire clk_out0,   // 125 MHz, phase 0 -> tx_clk
    output wire clk_out1,   // 125 MHz, +1.5556 ns ahead -> GTX_CLK forwarding
    output wire locked
);

`ifdef GEM_BEHAVIORAL_IO

    //------------------------------------------------------------------
    // Simulation model.
    //
    // WHAT IT REPRODUCES: two 125 MHz clocks whose phase relationship is the
    // 1.5556 ns clk1 leads clk0 by (CLKOUT1_PHASE = +70.000, see the
    // correction in the file header), held low while RST is asserted, and a
    // LOCKED that arrives some time after RST releases rather than
    // instantly.
    //
    // WHAT IT DOES NOT: jitter, the real ~100 us lock time, the input clock's
    // frequency (the outputs here are 125 MHz because the model says so, not
    // because 50 MHz was multiplied), and the fact that a real MMCM's outputs
    // are unstable-but-present before LOCKED rather than absent. None of that
    // is checkable in simulation, and pretending otherwise is how sim and
    // hardware quietly diverge -- the same warning gem_oddr's header carries
    // about its own model.
    //
    // LOCKED arriving late is the one behaviour worth modelling exactly,
    // because it is the thing gem_clk_rst is built around: tx_rst_n must not
    // release onto an unlocked MMCM (B.1b). A model that locked instantly
    // would let that logic pass without ever having been exercised.
    //
    // The two forever loops are one construct, offset. Both toggle on a
    // fixed 4 ns grid; clk1's grid starts 6.4444 ns after clk0's -- the same
    // phase relationship as leading by 1.5556 ns, since the two are
    // equivalent modulo the 8 ns period and simulation time cannot run
    // negative -- and stays there for the whole simulation, so the phase
    // relationship survives RST gating the toggles off and on again.
    // Deriving clk1 from clk0 with a delayed assignment would have been the
    // obvious alternative and is worse: it makes the shifted clock an
    // event-driven consequence of the unshifted one, which lint reads as
    // combinational logic on a clock. (Note for the next person wrapping a
    // comment here: a comment line starting with the tool's own name, lower
    // case, is read as a metacomment rather than prose, and the lint fails
    // with "Unknown [tool name] comment" -- do not start a line with that
    // word even inside an illustrative quote, as this comment itself once
    // did.)
    //------------------------------------------------------------------

    reg clk0;
    reg clk1;
    reg [7:0] lock_cnt;
    reg       locked_r;

    initial begin
        clk0 = 1'b0;
        forever begin
            #4.0;                       // half of the 8 ns period
            clk0 = rst ? 1'b0 : ~clk0;
        end
    end

    initial begin
        clk1 = 1'b0;
        #6.4444;                        // the phase shift, applied once (see above)
        forever begin
            #4.0;
            clk1 = rst ? 1'b0 : ~clk1;
        end
    end

    // 128 input clocks (2.56 us at 50 MHz) is not the datasheet's lock time --
    // it is long enough that reset gating is genuinely exercised and short
    // enough that a unit test does not spend its life waiting.
    localparam [7:0] LOCK_CYCLES = 8'd128;

    always @(posedge clk_in or posedge rst) begin
        if (rst) begin
            lock_cnt <= 8'd0;
            locked_r <= 1'b0;
        end else if (lock_cnt != LOCK_CYCLES) begin
            lock_cnt <= lock_cnt + 8'd1;
            locked_r <= 1'b0;
        end else begin
            locked_r <= 1'b1;
        end
    end

    assign clk_out0 = clk0;
    assign clk_out1 = clk1;
    assign locked   = locked_r;

`else

    wire clk_fb;
    wire clk0_raw;
    wire clk1_raw;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (20.000),    // 50 MHz
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (22.500),    // VCO = 1125 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (9.000),     // 125 MHz, tx_clk
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (9),         // 125 MHz, GTX_CLK copy
        .CLKOUT1_PHASE      (60.000),    // +1.3333 ns; measured on hardware, see header
        .CLKOUT1_DUTY_CYCLE (0.500),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1    (clk_in),
        .CLKFBIN   (clk_fb),
        .CLKFBOUT  (clk_fb),
        .CLKFBOUTB (),
        .CLKOUT0   (clk0_raw),
        .CLKOUT0B  (),
        .CLKOUT1   (clk1_raw),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .LOCKED    (locked),
        .PWRDWN    (1'b0),
        .RST       (rst)
    );

    // Both outputs are clocks that drive flip-flops across the die, so both
    // take a global buffer. Vivado will often infer these; instantiating them
    // means the netlist does not depend on it noticing.
    BUFG u_bufg_tx  (.I (clk0_raw), .O (clk_out0));
    BUFG u_bufg_gtx (.I (clk1_raw), .O (clk_out1));

`endif

endmodule
