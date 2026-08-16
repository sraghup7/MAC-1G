//----------------------------------------------------------------------------
// gem_rgmii_rx -- B.1a module 6: the receive input stage.
//
// RGMII pins in, one octet plus RX_DV and RX_ER per rx_clk cycle out. The
// inverse of gem_rgmii_tx, including the CTL encoding: RX_DV on the rising
// edge, RX_DV ^ RX_ER on the falling one, so an error shows up as the two
// edges disagreeing rather than as a separate signal.
//
// No IDELAY, and that is a decision rather than an omission (R14, B.1b): the
// KSZ9031RNX adds 1.2 ns to RX_CLK relative to RXD by default, out of reset,
// with no MDIO write -- which sits inside the RGMII v2.0 receive window, so an
// IDDR clocked directly by the recovered clock is sufficient for v1. The
// fallback if the bench says otherwise is the PHY's own pad-skew register, not
// fabric delay lines. Simulation cannot check any of this (open item V-2).
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

    assign gm_byte = {d_fall, d_rise};    // {high nibble, low nibble}
    assign gm_dv   = ctl_rise;
    assign gm_er   = ctl_rise ^ ctl_fall;

endmodule
