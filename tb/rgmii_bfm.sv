//----------------------------------------------------------------------------
// rgmii_bfm -- the PHY side of the RGMII bus, in two halves.
//
//   rgmii_driver   plays a vector file at the DUT's RX pins, at real DDR
//   rgmii_monitor  captures the DUT's TX pins back into 12-bit cycle words
//
// Both use the same word layout as gem.rgmiiEncode:
//
//     bit  9   : CTL on the falling edge  (DV XOR ER)
//     bit  8   : CTL on the rising edge   (DV)
//     bits 7:4 : data on the falling edge (high nibble)
//     bits 3:0 : data on the rising edge  (low nibble)
//
// so a captured stream diffs straight against a generated one without either
// side re-deriving the encoding. The mapping is written down once in MATLAB
// and once here; tRgmii.m and the loopback testbench check they agree.
//
// The driver models real DDR rather than shortcutting to a byte per cycle.
// Driving whole bytes would exercise the deframer and never the input stage --
// and the input stage is where RGMII designs actually break.
//
// Both modules keep their vector arrays internal and expose them by
// hierarchical reference (u_drv.n_words, u_mon.words[i]). Dynamic arrays
// cannot be module ports, and large unpacked array ports are the shakiest
// corner of XSim's elaborator -- a bus functional model that will not
// elaborate is worth nothing.
//----------------------------------------------------------------------------

`ifndef RGMII_BFM_SV
`define RGMII_BFM_SV

`timescale 1ns / 1ps

//----------------------------------------------------------------------------
// Driver: reads its own vector file, plays it at the pins.
//----------------------------------------------------------------------------
module rgmii_driver (
    input  wire        clk,          // 125 MHz, standing in for the PHY's RXC
    input  wire        rst_n,
    input  wire        start,
    output reg         busy,
    output reg         done,
    output wire [3:0]  rgmii_d,
    output wire        rgmii_ctl
);

    logic [11:0] words [];
    int          n_words = 0;
    int          idx     = 0;

    // Simulation time at which cycle 0 was launched. With a fixed clock period
    // this is all that is needed to date any cycle in the file -- launch time
    // of cycle N is t0 + N * period -- which is how tb_gem_mac_rx converts the
    // golden model's sfdCycle into an R21 latency measurement without the
    // driver storing a timestamp per cycle.
    time t0 = 0;

    // Both edges are driven from registers selected by clk, so each pin has a
    // single driver. Two always blocks writing the same variable would work in
    // simulation and mislead anyone reading it.
    reg [3:0] d_rise, d_fall;
    reg       ctl_rise, ctl_fall;

    // Clock-to-out. Without it the pins change at exactly the clock edges, so
    // anything sampling on an edge -- the monitor, or a real IDDR in the DUT --
    // races the mux and may read either the old nibble or the new one
    // depending on scheduling order. That is not a subtle inaccuracy: it makes
    // the captured stream nondeterministic.
    //
    // A real PHY has a clock-to-out too, so this is the honest model rather
    // than a simulation trick. It shifts each nibble's window a little past
    // its launching edge, which puts every edge-triggered sampler safely
    // inside the previous nibble's window.
    localparam time TCO = 1ns;

    assign #TCO rgmii_d   = clk ? d_rise   : d_fall;
    assign #TCO rgmii_ctl = clk ? ctl_rise : ctl_fall;

    task automatic load(input string path);
        n_words = gem_tb_pkg::read_cycles(path, words);
        $display("[rgmii_driver] loaded %0d cycles from %s", n_words, path);
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx      <= 0;
            busy     <= 1'b0;
            done     <= 1'b0;
            d_rise   <= 4'b0;
            d_fall   <= 4'b0;
            ctl_rise <= 1'b0;
            ctl_fall <= 1'b0;
        end else if (busy) begin
            if (idx >= n_words) begin
                busy     <= 1'b0;
                done     <= 1'b1;
                d_rise   <= 4'b0;
                d_fall   <= 4'b0;
                ctl_rise <= 1'b0;
                ctl_fall <= 1'b0;
            end else begin
                // Dating cycle 0 here, at the edge that actually launches it,
                // rather than at the edge that set `start` -- those are one
                // period apart, and an R21 measurement that is one cycle out
                // is worse than none.
                if (idx == 0) t0 <= $time;

                d_rise   <= words[idx][3:0];
                d_fall   <= words[idx][7:4];
                ctl_rise <= words[idx][8];
                ctl_fall <= words[idx][9];
                idx      <= idx + 1;
            end
        end else if (start && !done) begin
            busy <= 1'b1;
            idx  <= 0;
        end
    end

endmodule


//----------------------------------------------------------------------------
// Monitor: pins in, cycle words out. Capture starts on the first cycle with
// CTL asserted, so leading idle does not have to be modelled or skipped.
//----------------------------------------------------------------------------
module rgmii_monitor #(
    parameter int MAX_WORDS = 1 << 21
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [3:0]  rgmii_d,
    input  wire        rgmii_ctl
);

    logic [11:0] words [MAX_WORDS];
    int          n_words = 0;
    bit          started = 1'b0;

    reg [3:0] d_rise   = 4'b0;
    reg       ctl_rise = 1'b0;

    // Sampling phases, which are NOT the ones they intuitively ought to be.
    //
    // With the driver's clock-to-out, cycle N occupies the pins like this:
    //
    //     posedge T ......... negedge T+P/2 ....... posedge T+P
    //        |  +TCO             |  +TCO              |  +TCO
    //        |   [--- d_rise(N) ---][--- d_fall(N) ---][-- d_rise(N+1) --
    //
    // so the rising-edge nibble is stable across the NEGEDGE, and the
    // falling-edge nibble across the following POSEDGE. Each half is therefore
    // sampled one edge after it was launched, and the word is committed at the
    // posedge that completes it.
    //
    // Sampling d_rise at the posedge instead reads the value from before that
    // edge -- the previous cycle's falling nibble. That bug produced a capture
    // whose rising nibble came from cycle N and whose falling nibble came from
    // cycle N+1: every octet's high half taken from the next octet. It was
    // invisible until tb_rgmii_bfm diffed the BFM against itself, and it would
    // have made every TX scenario report the design as broken.

    always @(negedge clk) begin
        if (rst_n && enable) begin
            d_rise   <= rgmii_d;
            ctl_rise <= rgmii_ctl;
        end
    end

    always @(posedge clk) begin
        if (rst_n && enable) begin
            if (ctl_rise) started <= 1'b1;
            if ((started || ctl_rise) && n_words < MAX_WORDS) begin
                words[n_words] <= {rgmii_ctl, ctl_rise, rgmii_d, d_rise};
                n_words        <= n_words + 1;
            end
        end
    end

endmodule

//----------------------------------------------------------------------------
// Loopback: the MAC's own transmit pins fed back to its receive pins, the way
// a link partner (or a PHY in loopback mode) would return them.
//
// It is not a wire. A wire would put the receive path on the transmit clock,
// and the single most valuable thing an integrated loopback can exercise is
// the rx_clk -> sys_clk crossing -- the async FIFO whose depth B.3a derives,
// and the number-one cause of "worked in simulation, fails on hardware". So
// this behaves like the real thing: capture the frame on the transmit clock,
// then re-emit it on an independent receive clock, regenerating the gap.
//
// Only frame cycles are carried across. Idle is not queued; the receive side
// generates GEM_IFG_BYTES of it after each frame and emits idle whenever the
// queue is empty. That keeps the queue bounded no matter how long the test
// runs and no matter how the two clocks drift -- which is exactly how a real
// link absorbs clock tolerance, in the gap rather than in a buffer.
//----------------------------------------------------------------------------

module rgmii_loopback (
    input  wire        tx_clk,
    input  wire        rx_clk,
    input  wire        rst_n,

    // From the MAC's transmit pins
    input  wire [3:0]  tx_d,
    input  wire        tx_ctl,

    // To the MAC's receive pins
    output wire [3:0]  rx_d,
    output wire        rx_ctl
);

    localparam time TCO = 1ns;

    logic [11:0] fifo [$];

    //------------------------------------------------------------------
    // Capture, on the transmit clock. Same sampling phases as rgmii_monitor.
    //------------------------------------------------------------------
    reg [3:0] cap_rise   = 4'b0;
    reg       cap_ctl_r  = 1'b0;
    reg       was_active = 1'b0;

    always @(negedge tx_clk) begin
        if (rst_n) begin
            cap_rise  <= tx_d;
            cap_ctl_r <= tx_ctl;
        end
    end

    always @(posedge tx_clk) begin
        if (!rst_n) begin
            fifo.delete();
            was_active <= 1'b0;
        end else begin
            if (cap_ctl_r) begin
                fifo.push_back({tx_ctl, cap_ctl_r, tx_d, cap_rise});
                was_active <= 1'b1;
            end else if (was_active) begin
                // Frame just ended: hand the receive side a legal gap. The
                // receiver is entitled to see this shrink to 8 byte times on a
                // real link (Table 4-2 Note 3), but a compliant transmitter --
                // which this loopback is standing in for -- emits the full 12.
                repeat (`GEM_IFG_BYTES) fifo.push_back(12'h000);
                was_active <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------
    // Replay, on the receive clock.
    //------------------------------------------------------------------
    reg [3:0] rep_rise = 4'b0, rep_fall = 4'b0;
    reg       rep_ctl_r = 1'b0, rep_ctl_f = 1'b0;

    assign #TCO rx_d   = rx_clk ? rep_rise  : rep_fall;
    assign #TCO rx_ctl = rx_clk ? rep_ctl_r : rep_ctl_f;

    always @(posedge rx_clk) begin
        if (!rst_n) begin
            rep_rise  <= 4'b0;
            rep_fall  <= 4'b0;
            rep_ctl_r <= 1'b0;
            rep_ctl_f <= 1'b0;
        end else if (fifo.size() > 0) begin
            automatic logic [11:0] w = fifo.pop_front();
            rep_rise  <= w[3:0];
            rep_fall  <= w[7:4];
            rep_ctl_r <= w[8];
            rep_ctl_f <= w[9];
        end else begin
            // Nothing to send: idle. This is where clock drift is absorbed.
            rep_rise  <= 4'b0;
            rep_fall  <= 4'b0;
            rep_ctl_r <= 1'b0;
            rep_ctl_f <= 1'b0;
        end
    end

endmodule

`endif
