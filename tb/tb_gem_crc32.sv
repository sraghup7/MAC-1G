//----------------------------------------------------------------------------
// tb_gem_crc32 -- the CRC accumulator on its own, against numbers that come
// from outside this project.
//
// The scenario regression already compares the whole design against the golden
// model, so what does a unit test add? Independence of the reference. Every
// frozen vector traces back to gem.crc32, and if that were wrong the model and
// the RTL could agree perfectly with each other and disagree with every
// Ethernet device on earth. So the checks here are the ones the MATLAB model
// validates itself against (model/tests/tCrc32.m), asked of the hardware
// directly:
//
//   1. the published check value for "123456789", which is a property of
//      CRC-32 itself and appears in every reference implementation
//   2. the residue: a frame followed by its own FCS lands on one fixed
//      constant, which is how the RX path decides R9's verdict
//   3. the reflected polynomial the RTL derives at elaboration is the one the
//      standard's polynomial reflects to
//   4. corruption is actually caught -- flipping one bit must break the
//      residue, or check 2 is passing for the wrong reason
//
// Check 4 is there because 2 alone is satisfiable by a broken comparator that
// says yes to everything, and "the FCS checker always passes" is exactly the
// bug that would let the whole regression go green while the design accepts
// corrupted frames.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_crc32;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        init = 1'b1;
    logic        en = 1'b0;
    logic [7:0]  data = 8'h00;
    wire  [31:0] crc;
    wire         residue_ok;

    always #(CLK_PERIOD/2) clk = ~clk;

    gem_crc32 u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (init),
        .en         (en),
        .data       (data),
        .crc        (crc),
        .residue_ok (residue_ok)
    );

    // The finished CRC, after the final complement (GEM_CRC32_XOROUT).
    function automatic logic [31:0] final_crc();
        return crc ^ `GEM_CRC32_XOROUT;
    endfunction

    task automatic seed();
        begin
            init <= 1'b1;
            en   <= 1'b0;
            @(posedge clk);
            init <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic feed(input logic [7:0] octets [], input int n);
        int i;
        begin
            for (i = 0; i < n; i++) begin
                data <= octets[i];
                en   <= 1'b1;
                @(posedge clk);
            end
            en <= 1'b0;
            @(posedge clk);
        end
    endtask

    logic [7:0] buf_a [];
    logic [7:0] buf_b [];

    initial begin
        bit ok;
        int i;
        logic [31:0] value;

        begin_scenario("gem_crc32");

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //--------------------------------------------------------------
        // 3. The derived polynomial
        //--------------------------------------------------------------
        // reflect(0x04C11DB7) = 0xEDB88320. The RTL computes this at
        // elaboration from the one copy of the polynomial in the params
        // header; this is the check that the derivation is right, so that
        // nobody is tempted to paste the reflected constant in "to be safe".
        note_check();
        if (u_dut.POLY_REFLECTED !== 32'hEDB88320) begin
            report_fail("gem_crc32", $sformatf(
                "reflected polynomial is 0x%08h, expected 0xEDB88320",
                u_dut.POLY_REFLECTED));
        end

        //--------------------------------------------------------------
        // The seed value
        //--------------------------------------------------------------
        seed();
        note_check();
        if (crc !== `GEM_CRC32_INIT) begin
            report_fail("gem_crc32", $sformatf(
                "accumulator seeds to 0x%08h, expected 0x%08h",
                crc, `GEM_CRC32_INIT));
        end

        //--------------------------------------------------------------
        // 1. The published check value
        //--------------------------------------------------------------
        buf_a = new [9];
        for (i = 0; i < 9; i++) buf_a[i] = 8'h31 + 8'(i);   // "123456789"

        seed();
        feed(buf_a, 9);

        value = final_crc();
        note_check();
        if (value !== 32'hCBF43926) begin
            report_fail("gem_crc32", $sformatf(
                "CRC-32 of \"123456789\" is 0x%08h, expected the published check value 0xCBF43926",
                value));
        end

        //--------------------------------------------------------------
        // 2. The residue, over a frame plus its own FCS
        //--------------------------------------------------------------
        // The FCS octets are the complement of the accumulator, least
        // significant octet first (R4). Building them here from the RTL's own
        // register and feeding them straight back is exactly what the TX path
        // does and then what the RX path sees, so a byte-order error shows up
        // as a residue failure rather than as a mystery on the wire.
        buf_a = new [20];
        for (i = 0; i < 20; i++) buf_a[i] = 8'((i * 37) + 11);

        seed();
        feed(buf_a, 20);

        buf_b = new [4];
        buf_b[0] = ~crc[7:0];
        buf_b[1] = ~crc[15:8];
        buf_b[2] = ~crc[23:16];
        buf_b[3] = ~crc[31:24];

        feed(buf_b, 4);

        note_check();
        if (!residue_ok) begin
            report_fail("gem_crc32", $sformatf(
                "residue over frame+FCS is 0x%08h, expected 0x%08h -- R9's verdict would reject every good frame",
                final_crc(), `GEM_CRC32_RESIDUE));
        end

        //--------------------------------------------------------------
        // 4. ... and corruption breaks it
        //--------------------------------------------------------------
        buf_a[7] = buf_a[7] ^ 8'h01;

        seed();
        feed(buf_a, 20);
        feed(buf_b, 4);        // the FCS of the *uncorrupted* frame

        note_check();
        if (residue_ok) begin
            report_fail("gem_crc32",
                "one flipped bit still satisfies the residue check -- the FCS verdict is not checking anything");
        end

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_crc32 FAILED");
        $finish;
    end

    initial begin
        #1ms;
        $fatal(1, "[gem_tb] gem_crc32 TIMED OUT");
    end

endmodule
