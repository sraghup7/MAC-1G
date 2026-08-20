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
//   clk_out1  125 MHz, the same clock deliberately delayed ~1.6 ns. It drives
//             exactly one thing: the ODDR that forwards GTX_CLK to the PHY.
//
// The KSZ9031RNX does not delay its own GTX_CLK input and expects the MAC to
// provide the skew (B.1b quotes the datasheet). 1.6 ns is the numeric centre
// of the datasheet's 1.2-2.0 ns TsetupT/TholdT window, chosen over the obvious
// 90 degrees / 2.0 ns precisely because 2.0 ns is the window's edge and would
// leave zero margin before place-and-route had even run.
//
// THE ARITHMETIC, spelled out because it is the kind that is easy to get
// plausibly wrong:
//
//   VCO       = 50 MHz x CLKFBOUT_MULT_F(20) / DIVCLK_DIVIDE(1) = 1000 MHz,
//               inside the Artix-7 MMCM's 600-1200 MHz range.
//   outputs   = 1000 MHz / 8 = 125 MHz on both CLKOUT0 and CLKOUT1.
//   the shift = 1.6 ns of an 8 ns period is 72 degrees, and the MMCM delays
//               rather than advances at a negative phase, hence -72.
//
//   BUT -72 IS NOT ACHIEVABLE. Static phase resolution is 45/CLKOUT_DIVIDE =
//   45/8 = 5.625 degrees, so -72 (12.8 steps) rounds to -73.125 (13 steps) =
//   1.625 ns -- which is the value CLKOUT1_PHASE actually carries below, not
//   -72. That is 25 ps from the intent and still 0.375 ns clear of both edges
//   of the 1.2-2.0 ns window, so the rounding is harmless. It is not silent,
//   either: write_bitstream's DRC (AVAL-139) refuses outright on a
//   CLKOUT1_PHASE that is not an exact multiple of 5.625 with
//   CLKOUT1_USE_FINE_PS false, which is how the -72 literal that used to sit
//   below was found -- nothing had run write_bitstream against gem_top before
//   Stage 6 retargeted the build onto it. Stage 6's timing report is where
//   the achieved number gets confirmed rather than assumed; V-2 is the open
//   item that closes with a scope on GTX_CLK/TXD0.
//
//   STAGE 6 PART 2 FOUND THE ROUNDING IS NOT HARMLESS, AND THE VALUE BELOW
//   IS KNOWN NOT TO MEET TIMING. Post-route, against constrs/rgmii_timing.xdc,
//   -73.125 violates the TX setup check on all five data outputs by about
//   0.35 ns (task-2-report.md). Sweeping the whole 5.625 grid inside the PHY's
//   window found exactly one point that is not violated -- 1.250 ns, clearing
//   by 24 ps (task-2b-report.md) -- and placement cannot help, because 99.939%
//   of the path is ODDR C-to-Q and OBUF I-to-O cell delay in sites those cells
//   cannot leave (task-2c-report.md). The value below is left as it is pending
//   a decision, not because it passes.
//
//   DO NOT REACH FOR CLKOUT1_USE_FINE_PS TO BUY FINER RESOLUTION. Fine phase
//   shift is a runtime interface, not a static one: Xilinx's own MMCME2_ADV
//   model starts its fine-shift counter at zero and moves it only on PSEN, and
//   the Clocking Wizard reaches an awkward phase by retuning the VCO rather
//   than by setting this parameter. What the parameter does do here is switch
//   AVAL-139 off -- so an unachievable CLKOUT1_PHASE stops being refused and
//   starts being silently analysed as though the silicon produced it, which is
//   worse than the error it replaces (task-2d-report.md). MMCME2_BASE, the
//   primitive below, does not accept the parameter at all.
//
//   What does move the grid is the VCO: achievable shifts are k * VCO_period/8,
//   so putting a wanted shift on the grid means picking the VCO to suit it.
//   Measured post-route across every configuration the PHY's window allows,
//   the best that buys is 58 ps of setup -- at 1.2222 ns, a 1125 MHz VCO and
//   CLKOUT1_DIVIDE 9. Better than the grid's 24 ps, still not the hundreds
//   this direction was hoped to yield, and not free: CLKOUT0's divider moves
//   with it. Note that the smallest shift is NOT the best one -- 1.200 ns
//   needs a 625 MHz VCO, whose extra clock uncertainty costs more than the
//   shorter shift returns. Per-configuration numbers live in the table in
//   Documents/RGMII I-O Timing Derivation.md; add to that table rather than
//   restating its numbers here, which is how this paragraph first got the
//   1.200 ns configuration and the 58 ps figure attached to each other.
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
    output wire clk_out0,   // 125 MHz, phase 0        -> tx_clk
    output wire clk_out1,   // 125 MHz, ~1.6 ns later  -> GTX_CLK forwarding
    output wire locked
);

`ifdef GEM_BEHAVIORAL_IO

    //------------------------------------------------------------------
    // Simulation model.
    //
    // WHAT IT REPRODUCES: two 125 MHz clocks whose phase relationship is the
    // 1.6 ns the real MMCM is asked for, held low while RST is asserted, and a
    // LOCKED that arrives some time after RST releases rather than instantly.
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
    // The two forever loops are one construct, offset. Both toggle on a fixed
    // 4 ns grid; clk1's grid starts 1.6 ns later and stays there for the whole
    // simulation, so the phase relationship survives RST gating the toggles
    // off and on again. Deriving clk1 from clk0 with a delayed assignment
    // would have been the obvious alternative and is worse: it makes the
    // shifted clock an event-driven consequence of the unshifted one, which
    // lint reads as combinational logic on a clock. (Note for the next person
    // wrapping a comment here: a line whose text starts with the word
    // "verilator" is read as a metacomment, not as prose, and the lint fails
    // with "Unknown verilator comment". This one did.)
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
        #1.6;                           // the phase shift, applied once
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
        .CLKFBOUT_MULT_F    (20.000),    // VCO = 1000 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (8.000),     // 125 MHz, tx_clk
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (8),         // 125 MHz, GTX_CLK copy
        .CLKOUT1_PHASE      (-73.125),   // 1.625 ns; -72 rounded to the nearest achievable step
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
