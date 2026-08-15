//----------------------------------------------------------------------------
// gem_rgmii_sva -- wire-level legality on the transmit side.
//
// Checked at the pins, on every cycle of every scenario, because these are the
// properties that no functional test naturally covers: a design can emit every
// octet of every frame correctly and still be non-compliant on the gap.
//
// Sampling note: RGMII carries two nibbles per cycle, but TX_EN is the rising-
// edge half of TX_CTL, so the properties below are written against the value
// sampled at posedge. That is exactly what the PHY latches, and the inter-frame
// gap in Clause 4.2.3.2.2 is defined in byte times, not edges.
//----------------------------------------------------------------------------

`ifndef GEM_RGMII_SVA_SV
`define GEM_RGMII_SVA_SV

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_rgmii_sva (
    input wire       clk,          // tx_clk
    input wire       rst_n,
    input wire [3:0] txd,
    input wire       tx_ctl
);

    // The reset guard is repeated per property rather than written once as
    // `default disable iff (!rst_n)`, which XSim 2024.2 rejects outright.

    // TX_EN as the PHY sees it.
    wire tx_en = tx_ctl;

    // A sized constant, because a bit-select cannot be applied directly to a
    // macro that expands to a literal (`8'h55[3:0]` is a syntax error).
    localparam logic [7:0] PREAMBLE_OCTET = `GEM_PREAMBLE_OCTET;

    //------------------------------------------------------------------
    // R5 -- inter-frame gap, 96 bit times = 12 byte times (Table 4-2).
    //------------------------------------------------------------------
    //
    // The transmitter is the one that produces this gap, so unlike the receive
    // side there is no shrinkage to tolerate: 12 is a hard floor and anything
    // less is non-compliant. A link partner is entitled to drop the frame that
    // arrives too early, and the symptom is intermittent loss under load that
    // no amount of staring at frame contents explains.
    //
    // Written as: on the cycle TX_EN falls, it must stay low for GEM_IFG_BYTES
    // cycles before it may rise again.
    //
    // SAMPLING CAVEAT, to be resolved in Stage 4 when real pin timing exists.
    // SVA samples in the preponed region, before the clock edge. Combined with
    // the driver's clock-to-out, what a posedge sees on a DDR control pin is
    // the value it held through the *previous* low phase -- which for RGMII is
    // TX_EN XOR TX_ER, not TX_EN. For clean traffic the two agree, because
    // TX_ER is low throughout, so every scenario in the current suite is
    // unaffected.
    //
    // They diverge exactly during a B.4b abort tail, where TX_ER is asserted
    // across the four inverted-FCS octets: the sampled signal reads low for
    // those four cycles while TX_EN is still genuinely high. A design that
    // then left only 8 idle cycles would sample as 4 + 8 = 12 and pass, having
    // actually emitted an illegal gap.
    //
    // Not fixed here because the fix depends on how the RTL brings TX_EN out --
    // once there is an internal tx_en to bind to, this property should watch
    // that rather than reconstruct it from the pin. Recorded so the gap in
    // coverage is known rather than discovered later.
    a_ifg_respected: assert property (@(posedge clk) disable iff (!rst_n)
        $fell(tx_en) |-> (!tx_en)[*`GEM_IFG_BYTES])
        else $error("rgmii_tx: inter-frame gap shorter than %0d byte times (R5)",
                    `GEM_IFG_BYTES);

    //------------------------------------------------------------------
    // Table 35-1 -- control encoding legality.
    //------------------------------------------------------------------
    //
    // Nothing on the data lines may be X while the PHY is being told the data
    // is valid. Driving X here is the one failure the PHY cannot report back.
    a_no_x_when_enabled: assert property (@(posedge clk) disable iff (!rst_n)
        tx_en |-> !$isunknown(txd))
        else $error("rgmii_tx: X or Z on TXD while TX_EN is asserted");

    //------------------------------------------------------------------
    // Clause 4.2.5 -- a frame begins with preamble, never with data.
    //------------------------------------------------------------------
    //
    // The first nibble after TX_EN rises must be the low nibble of 0x55.
    // A transmitter that starts a frame at the SFD, or at DA, is legal for a
    // receiver to accept (R8 requires our own RX to tolerate it) but is not
    // something a compliant transmitter may emit.
    a_frame_starts_with_preamble: assert property (@(posedge clk) disable iff (!rst_n)
        $rose(tx_en) |-> (txd == PREAMBLE_OCTET[3:0]))
        else $error("rgmii_tx: frame did not begin with a preamble nibble (R1)");

endmodule


bind gem_mac gem_rgmii_sva u_rgmii_tx_sva (
    .clk    (tx_clk),
    .rst_n  (tx_rst_n),
    .txd    (rgmii_txd),
    .tx_ctl (rgmii_tx_ctl)
);

`endif
