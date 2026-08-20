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
//   clk_out1  125 MHz, the same clock deliberately delayed 1.2222 ns. It
//             drives exactly one thing: the ODDR that forwards GTX_CLK to the
//             PHY.
//
// The KSZ9031RNX does not delay its own GTX_CLK input and expects the MAC to
// provide the skew (B.1b quotes the datasheet). Whatever delay this file
// chooses has to land inside the datasheet's 1.2-2.0 ns TsetupT/TholdT window.
// B.1b's original pick was 1.6 ns, the numeric centre of that window, on the
// reasoning that the centre leaves the most margin against both of the PHY's
// edges. That reasoning is still sound about the PHY and turned out to be
// incomplete about the FPGA: Stage 6 part 2 measured this design's own TX
// setup check and found its slack improves monotonically as the shift shrinks.
// So the value below sits near the window's 1.2 ns floor rather than at its
// centre. The window is still honoured; the choice inside it is no longer the
// middle. The ordered history is further down.
//
// THE ARITHMETIC, spelled out because it is the kind that is easy to get
// plausibly wrong:
//
//   VCO       = 50 MHz x CLKFBOUT_MULT_F(22.500) / DIVCLK_DIVIDE(1)
//             = 1125 MHz, inside the Artix-7 MMCM's 600-1200 MHz range.
//   clk_out0  = 1125 MHz / CLKOUT0_DIVIDE_F(9.000) = 125 MHz.
//   clk_out1  = 1125 MHz / CLKOUT1_DIVIDE(9)       = 125 MHz.
//   the shift = 1.2222 ns of the 8 ns output period is 55 degrees, and the
//               MMCM delays rather than advances at a negative phase, hence
//               the -55.000 below.
//
//   -55.000 IS EXACTLY ACHIEVABLE, NOT ROUNDED. Static phase resolution is
//   45/CLKOUT1_DIVIDE = 45/9 = 5 degrees, and -55 is 11 whole steps of it.
//   Equivalently, achievable shift magnitudes are k * VCO_period/8 =
//   k * 0.11111 ns, and 1.2222 ns is k = 11. write_bitstream's DRC (AVAL-139)
//   is silent on this value because the value is legal -- which is a different
//   thing from the check having been switched off, see the warning below.
//
//   BOTH OUTPUT FREQUENCIES ARE UNCHANGED from the configuration this replaced
//   (1000 MHz VCO, both dividers 8). The VCO and both dividers moved together,
//   which is the standard way to move the phase grid without moving the
//   outputs. tx_clk and gtx_clk_shifted are 125 MHz here exactly as they were,
//   so nothing downstream sees any change -- not the TX datapath, not sys_clk,
//   not the UART's baud divisor, not MDC's. Only the MMCM's internal VCO
//   frequency and the grid it implies are different.
//
// HOW THIS VALUE WAS ARRIVED AT, in order, because three values have now sat
// in this parameter and each was replaced for a reason worth not having to
// rediscover:
//
//   -72.000 -- B.1b's intent. 1.6 ns, the centre of the PHY window. Never
//   achievable: on the then-current 1000 MHz VCO the grid was 45/8 = 5.625
//   degrees, and -72 is 12.8 steps of it. Stage 6 part 1 found it, because
//   write_bitstream's DRC (AVAL-139) refuses outright on a CLKOUT1_PHASE that
//   is not an exact multiple of the step with CLKOUT1_USE_FINE_PS false --
//   and nothing had run write_bitstream against gem_top before Stage 6
//   retargeted the build onto it.
//
//   -73.125 -- Stage 6 part 1's fix. 1.625 ns, -72 rounded to the nearest of
//   those 5.625 degree steps, believed harmless at the time: 25 ps from the
//   intent and still 0.375 ns clear of both window edges. Stage 6 part 2
//   measured it and it is not harmless. Post-route against
//   constrs/rgmii_timing.xdc it violates TX setup on all five data outputs by
//   about 0.35 ns (task-2-report.md). Sweeping the whole 5.625 degree grid
//   inside the PHY window found exactly one point that is not violated --
//   1.250 ns, clearing by 24 ps (task-2b-report.md) -- and placement cannot
//   help, because 99.939% of the path is ODDR C-to-Q and OBUF I-to-O cell
//   delay in sites those cells cannot leave (task-2c-report.md).
//
//   -55.000 -- the value below. The grid itself was the problem, so the grid
//   was moved rather than the phase alone: achievable shifts are
//   k * VCO_period/8, so choosing the VCO chooses which shifts exist at all.
//   task-2d-report.md built and post-route-measured every configuration the
//   PHY's window allows and found this one best; task-2e-report.md committed
//   it and re-measured it on the committed tree rather than inheriting that
//   number. Per-configuration numbers live in the table in
//   Documents/RGMII I-O Timing Derivation.md. Add to that table rather than
//   restating its numbers here -- restating them here is exactly how an
//   earlier revision of this header got a configuration and a margin attached
//   to each other wrongly.
//
//   WHAT IT BUYS IS THIN, AND IS NOT CLAIMED TO BE MORE. Worst-case TX setup
//   margin goes from violated to positive, and positive by tens of ps, not by
//   the few hundred this chain of tasks went looking for. It is a real,
//   measured, Vivado-verifiable improvement on a check that previously failed
//   outright, and it is the ceiling of what phase shift alone reaches here:
//   the remaining deficit is the irreducible cell delay above plus a 0.264 ns
//   clock-network insertion asymmetry between the launch and forwarded clocks,
//   and neither of those is a phase choice. If the bench shows it is not
//   enough, the next lever is the PHY's own GTX_CLK pad-skew register over
//   MDIO, not this parameter -- the procedure is written out in
//   Documents/RGMII I-O Timing Derivation.md and is gated on V-2 / B.5 step 5,
//   because it can only be validated with a board in hand.
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
    output wire clk_out1,   // 125 MHz, 1.2222 ns later -> GTX_CLK forwarding
    output wire locked
);

`ifdef GEM_BEHAVIORAL_IO

    //------------------------------------------------------------------
    // Simulation model.
    //
    // WHAT IT REPRODUCES: two 125 MHz clocks whose phase relationship is the
    // 1.2222 ns the real MMCM is asked for, held low while RST is asserted, and a
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
    // 4 ns grid; clk1's grid starts 1.2222 ns later and stays there for the whole
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
        #1.2222;                        // the phase shift, applied once
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
        .CLKOUT1_PHASE      (-55.000),   // 1.2222 ns; 11 whole steps of the 5 deg grid
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
