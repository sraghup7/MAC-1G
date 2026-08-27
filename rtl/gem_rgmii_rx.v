//----------------------------------------------------------------------------
// gem_rgmii_rx -- B.1a module 6: the receive input stage.
//
// RGMII pins in, one octet plus RX_DV and RX_ER per rx_clk cycle out. The
// inverse of gem_rgmii_tx, including the CTL encoding: RX_DV on the rising
// edge, RX_DV ^ RX_ER on the falling one, so an error shows up as the two
// edges disagreeing rather than as a separate signal.
//
// No IDELAY in v1 -- but the header this paragraph replaces claimed more than
// that, and the claim was retracted by measurement. It reasoned about the
// PHY's 1.2 ns RX_CLK delay at the PINS and omitted the FPGA's own clock
// insertion, which task-4a measured at 3.720 ns corner-to-corner on the raw
// BUFG network -- more than the entire guaranteed eye. What actually makes
// capture close is the deskew MMCM upstream (rtl/gem_rx_mmcm.v,
// Documents/RX Clock Deskew Design.md) plus its -45 degree capture trim;
// task-4e derived the margins and signed them off for bench confirmation.
// If the bench disagrees, the first lever is the PHY's own pad-skew register,
// not fabric delay lines. Simulation cannot check any of this (V-2).
//
// Everything downstream of this module runs on rx_clk and is asynchronous to
// tx_clk (R19). The only path out of this domain is the async FIFO and the
// counter pulse synchronisers -- there are no others, by construction.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module gem_rgmii_rx (
    input  wire       rx_clk,

    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,

    output wire [7:0] gm_byte,
    output wire       gm_dv,
    output wire       gm_er
);

    wire [3:0] d_rise, d_fall;
    wire       ctl_rise, ctl_fall;

    genvar i;

    generate
        for (i = 0; i < 4; i = i + 1) begin : g_rxd
            gem_iddr u_iddr (
                .clk    (rx_clk),
                .d      (rgmii_rxd[i]),
                .q_rise (d_rise[i]),
                .q_fall (d_fall[i])
            );
        end
    endgenerate

    gem_iddr u_iddr_ctl (
        .clk    (rx_clk),
        .d      (rgmii_rx_ctl),
        .q_rise (ctl_rise),
        .q_fall (ctl_fall)
    );

    assign gm_byte = {d_rise, d_fall};    // {high nibble, low nibble}: JL2121(D)
    assign gm_dv   = ctl_rise;
    assign gm_er   = ctl_rise ^ ctl_fall;

endmodule
