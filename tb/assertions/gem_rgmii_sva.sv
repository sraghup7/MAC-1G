//----------------------------------------------------------------------------
// gem_rgmii_sva -- wire-level legality on the transmit side.
//
// Checked at the pins, on every cycle of every scenario, because these are the
// properties that no functional test naturally covers: a design can emit every
// octet of every frame correctly and still be non-compliant on the gap.
//
// Sampling: RGMII carries two nibbles and two control bits per cycle, so the
// module reconstructs the whole cycle from both clock edges before asserting
// anything -- see the note above the reconstruction. Properties are then
// written against TX_EN, TX_ER and the complete octet, which is what Clause
// 4.2 actually talks about; the inter-frame gap is defined in byte times, not
// edges.
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

    localparam logic [7:0] PREAMBLE_OCTET = `GEM_PREAMBLE_OCTET;

    //------------------------------------------------------------------
    // Reconstruct the RGMII cycle before asserting anything about it
    //------------------------------------------------------------------
    //
    // These pins are double-data-rate: TXD carries the low nibble on the
    // rising edge and the high nibble on the falling one, and TX_CTL carries
    // TX_EN on the rising edge and TX_EN XOR TX_ER on the falling. A property
    // written directly against the pin and clocked on one edge therefore does
    // not see TX_EN at all -- SVA samples in the preponed region, so a posedge
    // reads whatever the pin held through the preceding low phase, which is
    // the XOR term.
    //
    // `wire tx_en = tx_ctl` was exactly that mistake. It is benign for clean
    // traffic, where TX_ER is low and the two happen to agree, and wrong
    // precisely during a B.4b abort tail: TX_ER rides the four inverted-FCS
    // octets, so the sampled signal reads low while TX_EN is genuinely high,
    // and a design leaving only 8 idle cycles afterwards would sample as
    // 4 + 8 = 12 and pass having emitted an illegal gap.
    //
    // The same flaw made a_frame_starts_with_preamble pass for the wrong
    // reason: it compared one ambiguously-sampled nibble against 0x5, which
    // succeeds whichever phase it caught, because both nibbles of 0x55 are 5.
    // It could not have detected a frame starting with any other octet.
    //
    // So rebuild the cycle the way rgmii_monitor does -- rising half latched
    // at the negedge, falling half read at the posedge that completes it --
    // and asserts against TX_EN, TX_ER and the whole octet as separate,
    // unambiguous things.
    reg [3:0] d_rise    = 4'b0;
    reg       ctl_rise  = 1'b0;

    always @(negedge clk) begin
        if (rst_n) begin
            d_rise   <= txd;
            ctl_rise <= tx_ctl;
        end
    end

    wire [7:0] octet = {txd, d_rise};   // {high nibble, low nibble}
    wire       tx_en = ctl_rise;
    wire       tx_er = ctl_rise ^ tx_ctl;

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
    // TX_EN here is the reconstructed rising-edge bit, so this stays correct
    // through a B.4b abort tail where TX_ER is asserted but TX_EN is not.
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
    // Checked on the whole reconstructed octet, so an X on either nibble is
    // caught rather than only the half this edge happened to expose.
    a_no_x_when_enabled: assert property (@(posedge clk) disable iff (!rst_n)
        tx_en |-> !$isunknown(octet))
        else $error("rgmii_tx: X or Z on TXD while TX_EN is asserted");

    // TX_ER may only be asserted inside a frame. Asserting it during idle is
    // the RGMII carrier-extend encoding, which is a 1000BASE-X notion with no
    // meaning here (B.7 lists half duplex as a non-goal) and would confuse a
    // link partner that does implement it.
    a_no_error_while_idle: assert property (@(posedge clk) disable iff (!rst_n)
        !tx_en |-> !tx_er)
        else $error("rgmii_tx: TX_ER asserted while TX_EN is low");

    //------------------------------------------------------------------
    // Clause 4.2.5 -- a frame begins with preamble, never with data.
    //------------------------------------------------------------------
    //
    // The first octet after TX_EN rises must be the full preamble octet. A
    // transmitter that starts a frame at the SFD, or at DA, is legal for a
    // receiver to accept (R8 requires our own RX to tolerate it) but is not
    // something a compliant transmitter may emit.
    //
    // Compared as a whole octet against 0x55, not as a nibble: a nibble
    // comparison passes on either DDR phase purely because both halves of 0x55
    // are 5, so it would have accepted a frame beginning with any octet whose
    // sampled nibble happened to be 5 -- 0x5D, say, or the 0xD5 SFD itself on
    // the other phase.
    a_frame_starts_with_preamble: assert property (@(posedge clk) disable iff (!rst_n)
        $rose(tx_en) |-> (octet == PREAMBLE_OCTET))
        else $error("rgmii_tx: frame did not begin with the preamble octet 0x%02h (R1)",
                    PREAMBLE_OCTET);

endmodule


bind gem_mac gem_rgmii_sva u_rgmii_tx_sva (
    .clk    (tx_clk),
    .rst_n  (tx_rst_n),
    .txd    (rgmii_txd),
    .tx_ctl (rgmii_tx_ctl)
);

`endif
