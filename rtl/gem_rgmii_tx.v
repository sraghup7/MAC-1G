//----------------------------------------------------------------------------
// gem_rgmii_tx -- B.1a module 5: the transmit output stage.
//
// One octet per cycle in, RGMII v2.0 out (R13): the low nibble and TX_EN on
// the rising edge, the high nibble and TX_EN ^ TX_ER on the falling one. That
// XOR is the whole of the RGMII error encoding -- there is no third pin -- and
// getting it backwards produces a MAC that transmits clean traffic perfectly
// and can never mark a frame bad, which survives every test that does not
// deliberately abort one.
//
// GTX_CLK is forwarded through an ODDR of its own rather than driven from
// fabric logic. A clock that leaves the chip through ordinary logic has an
// unpredictable, uncharacterisable delay relative to the data it clocks; one
// forwarded through an output register in the IOB has the same launch path as
// the data, which is what makes any skew claim about it meaningful.
//
// gtx_clk_shifted is a second MMCM output, kept structurally independent of
// tx_clk's own BUFG rather than sharing it, and now advanced 1.5556 ns ahead
// of tx_clk (rtl/gem_mmcm.v's header has the full correction and the
// post-route measurement behind that number). The JL2121(D)'s TXDLY strap
// delays the clock internally at the PHY, so this design no longer aims for
// the PHY's TsetupT/TholdT window the way B.1b's original -55 deg shift did
// -- the 1.5556 ns here exists to cancel a measured FPGA-internal asymmetry
// (GTX_CLK is itself forwarded through an extra ODDR+OBUF hop that tx_clk's
// own launch reference does not carry), landing TXC and TXD/TX_CTL close
// together at the FPGA's own pins, which is what the PHY's non-delay-mode
// TskewT spec (±500 ps) actually asks for.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rgmii_tx (
    input  wire       tx_clk,

    // The 125 MHz clock from the MMCM's second output, advanced 1.5556 ns
    // ahead of tx_clk (rtl/gem_mmcm.v). Only ever used to clock the GTX_CLK
    // forwarding cell below.
    input  wire       gtx_clk_shifted,

    // GMII-style stream, one octet per cycle
    input  wire [7:0] gm_byte,
    input  wire       gm_dv,
    input  wire       gm_er,

    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_gtx_clk
);

    genvar i;

    generate
        for (i = 0; i < 4; i = i + 1) begin : g_txd
            gem_oddr u_oddr (
                .clk    (tx_clk),
                .d_rise (gm_byte[i]),      // low nibble on the rising edge
                .d_fall (gm_byte[4+i]),    // high nibble on the falling edge
                .q      (rgmii_txd[i])
            );
        end
    endgenerate

    gem_oddr u_oddr_ctl (
        .clk    (tx_clk),
        .d_rise (gm_dv),
        .d_fall (gm_dv ^ gm_er),
        .q      (rgmii_tx_ctl)
    );

    // Clock forwarding: a constant 1/0 pattern through a DDR output cell is a
    // clock at the cell's own frequency, launched from the same kind of IOB
    // register as the data.
    gem_oddr u_oddr_gtx (
        .clk    (gtx_clk_shifted),
        .d_rise (1'b1),
        .d_fall (1'b0),
        .q      (rgmii_gtx_clk)
    );

endmodule
