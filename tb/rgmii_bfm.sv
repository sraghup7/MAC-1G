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

    // Both edges are driven from registers selected by clk, so each pin has a
    // single driver. Two always blocks writing the same variable would work in
    // simulation and mislead anyone reading it.
    reg [3:0] d_rise, d_fall;
    reg       ctl_rise, ctl_fall;

    assign rgmii_d   = clk ? d_rise   : d_fall;
    assign rgmii_ctl = clk ? ctl_rise : ctl_fall;

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

    always @(posedge clk) begin
        if (rst_n && enable) begin
            d_rise   <= rgmii_d;
            ctl_rise <= rgmii_ctl;
        end
    end

    // The falling edge completes a word, so that is where it is committed.
    always @(negedge clk) begin
        if (rst_n && enable) begin
            if (ctl_rise) started <= 1'b1;
            if ((started || ctl_rise) && n_words < MAX_WORDS) begin
                words[n_words] <= {rgmii_ctl, ctl_rise, rgmii_d, d_rise};
                n_words        <= n_words + 1;
            end
        end
    end

endmodule

`endif
