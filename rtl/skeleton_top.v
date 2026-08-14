// Stage 2 Tier A skeleton (fpga_project_flow.md, Stage 2): a near-empty top
// module with zero design logic. Its only job is to prove the toolchain,
// part string, constraint reading, and board connection before any real
// gem_mac RTL exists. Not part of the MAC design - do not build on this file.
//
// Bring-up checklist step 1 (spec/PROJECT_SPEC.md B.5): "Board alive: power,
// JTAG enumerates, blinky bitstream from the Stage-2 skeleton."

module skeleton_top (
    input  wire       clk50,   // 50 MHz Sitime active oscillator, pin Y18 (bank 14)
    output wire [3:0] led      // LED1-LED4, pins F19/E21/D20/C20 (bank 16), active-low
);

    // 2^26 / 50,000,000 Hz ~= 1.34 s per half-period on the MSB - slow enough
    // to see by eye. No reset: on power-up the counter starts at 0 anyway,
    // and a blink pattern that starts one phase off from another doesn't
    // matter for a "does the clock reach the fabric" test.
    localparam DIV_WIDTH = 26;

    reg [DIV_WIDTH-1:0] counter = {DIV_WIDTH{1'b0}};

    always @(posedge clk50) begin
        counter <= counter + 1'b1;
    end

    // Active-low (ALINX AX7035B manual, Part 21: driving the pin LOW lights
    // the LED). Blink LED1 only; leave LED2-4 off so a single clean blink is
    // unambiguous on the bench.
    assign led[0]   = ~counter[DIV_WIDTH-1];
    assign led[3:1] = 3'b111;

endmodule
