//----------------------------------------------------------------------------
// gem_crc32 -- byte-parallel IEEE 802.3 CRC-32 accumulator (R4, R9).
//
// One instance on each path. TX reads the register to build the FCS; RX lets
// the register keep running straight through the received FCS and compares the
// result against the residue constant, which is the form spec B.3a and
// gem.fcsResidue both specify: one comparator, no delay line, no "freeze the
// accumulator four octets early" special case at end of frame.
//
// BYTE-PARALLEL, NOT BIT-SERIAL, and it is not a style choice (B.7 item 2).
// B.3's cycles-per-byte is exactly 1.0, so a bit-serial CRC needing 8 cycles
// per octet cannot keep up with R7's back-to-back line rate. The eight-step
// loop below is unrolled by synthesis into a combinational XOR tree -- the same
// function gem.crc32Table tabulates in MATLAB, arrived at from the same
// polynomial rather than from a copy of the table.
//
// The reflected polynomial is DERIVED from GEM_CRC32_POLY at elaboration, not
// written down a second time. 0xEDB88320 appears in a comment here and nowhere
// in the logic: the params header holds the one copy of 0x04C11DB7, and
// tb_gem_crc32 checks the derivation lands where the standard says it should.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_crc32 (
    input  wire        clk,
    input  wire        rst_n,

    // Synchronous re-seed. Held asserted while the path has no frame in
    // flight, which is what makes gem_internal_sva's a_crc_reseeded a real
    // check rather than a race: the accumulator is provably at its seed value
    // on the cycle a new frame may start, so no frame can be poisoned by the
    // previous one's remainder.
    input  wire        init,
    input  wire        en,
    input  wire [7:0]  data,

    // The raw register, pre-final-XOR. Exposed rather than the finished CRC
    // because both users want the register:
    //   TX  good FCS octet i = ~crc[8i +: 8]; the B.4b abort's inverted FCS is
    //       the same octet without the complement -- literally one XOR, which
    //       is what B.4b item 4 promises the RTL costs.
    //   RX  residue_ok below.
    output wire [31:0] crc,
    output wire        residue_ok
);

    //------------------------------------------------------------------
    // reflect(0x04C11DB7) = 0xEDB88320
    //------------------------------------------------------------------
    //
    // Clause 3.3 ships each octet least-significant-bit first, which is the
    // "reflected input" convention; the standard implementation of it is a
    // right-shifting register against the bit-reversed polynomial rather than
    // reversing every octet on the way in. gem.crc32Table does exactly this,
    // and says so.
    function [31:0] reflect32;
        input [31:0] value;
        integer i;
        begin
            reflect32 = 32'd0;
            for (i = 0; i < 32; i = i + 1) begin
                reflect32[31-i] = value[i];
            end
        end
    endfunction

    localparam [31:0] POLY_REFLECTED = reflect32(`GEM_CRC32_POLY);

    // One octet of CRC update. Eight conditional shift-XOR steps, which is the
    // same arithmetic as one table lookup and is what synthesis flattens into
    // the XOR tree B.7 item 2 calls for.
    function [31:0] crc_step;
        input [31:0] state;
        input [7:0]  octet;
        integer i;
        reg [31:0] acc;
        begin
            acc = state ^ {24'd0, octet};
            for (i = 0; i < 8; i = i + 1) begin
                acc = acc[0] ? ((acc >> 1) ^ POLY_REFLECTED) : (acc >> 1);
            end
            crc_step = acc;
        end
    endfunction

    reg [31:0] crc_reg;

    // The update is a wire rather than a call inside the sequential block, so
    // that the function's blocking assignments (which a Verilog function has no
    // choice about) sit in combinational context where they belong. Same
    // circuit, and it reads as what it is: a register with an XOR tree in front.
    wire [31:0] crc_next = crc_step(crc_reg, data);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_reg <= `GEM_CRC32_INIT;
        end else if (init) begin
            crc_reg <= `GEM_CRC32_INIT;
        end else if (en) begin
            crc_reg <= crc_next;
        end
    end

    assign crc = crc_reg;

    // R9's verdict. The residue constant is the value *after* the final XOR --
    // the convention GEM_CRC32_RESIDUE documents, and the reason it documents
    // it is that the other convention's constant (0xDEBB20E3) is its bitwise
    // complement and using the wrong one fails every frame.
    assign residue_ok = ((crc_reg ^ `GEM_CRC32_XOROUT) == `GEM_CRC32_RESIDUE);

endmodule
