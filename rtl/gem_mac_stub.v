//----------------------------------------------------------------------------
// gem_mac_stub -- the gem_mac port list, and nothing else.
//
// Stage 3 deliverable, not a placeholder to be deleted. Two jobs:
//
//   1. It fixes the top-level interface now. Stage 4's per-module loop opens
//      with "define the interface precisely" (fpga_project_flow.md), and an
//      interface argued over while RTL is being written is an interface that
//      changes under the testbench. Every signal here is traceable to a
//      requirement, listed against it below.
//
//   2. It lets the whole verification apparatus -- vector files, RGMII bus
//      functional model, scoreboard, assertions -- elaborate and run before a
//      single line of design logic exists. The testbenches are expected to
//      FAIL against this module. What is being checked is that they fail
//      loudly, in the right place, with a message naming the frame and the
//      corruption. That is much cheaper to fix now than when a real failure is
//      competing for the blame.
//
// Outputs are driven to constants rather than left floating, so the failures
// are deterministic rather than X-propagation noise.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

/* verilator lint_off UNUSED */
// Justified suppression (R22 allows one with a reason): every input is
// deliberately unconnected -- that is what makes this a stub. The suppression
// is removed along with the file when Stage 4 replaces it with real logic.

module gem_mac (
    // ---- Clocks and resets (R19, B.1b) ------------------------------------
    // sys_clk = tx_clk for v1 (B.7 item 3), so there is no separate sys_clk
    // port. rx_clk is not a port either: it is the buffered rgmii_rx_clk pin.
    input  wire         tx_clk,             // 125 MHz from the MMCM
    input  wire         tx_rst_n,           // async assert, sync deassert
    input  wire         rx_rst_n,           // ditto, in the rx_clk domain

    // ---- RGMII to the KSZ9031RNX (R13, R14) -------------------------------
    output wire [3:0]   rgmii_txd,
    output wire         rgmii_tx_ctl,       // rise = TX_EN, fall = TX_EN ^ TX_ER
    output wire         rgmii_gtx_clk,      // MMCM output phase-shifted ~1.6 ns
    input  wire [3:0]   rgmii_rxd,
    input  wire         rgmii_rx_ctl,       // rise = RX_DV, fall = RX_DV ^ RX_ER
    input  wire         rgmii_rx_clk,       // recovered by the PHY's CDR

    // ---- PHY management (R16) ---------------------------------------------
    output wire         mdc,                // <= 2.5 MHz
    input  wire         mdio_i,
    output wire         mdio_o,
    output wire         mdio_t,             // 1 = release the bus

    // ---- TX user interface, AXI-Stream (R15), tx_clk domain ---------------
    // tuser carries the per-frame header at SOF (R2): DA, SA, EtherType are
    // per-frame inputs, not compile-time constants.
    input  wire [7:0]   tx_axis_tdata,
    input  wire         tx_axis_tvalid,
    output wire         tx_axis_tready,
    input  wire         tx_axis_tlast,
    input  wire [111:0] tx_axis_tuser,      // {DA[47:0], SA[47:0], EtherType[15:0]}

    // ---- RX user interface, AXI-Stream (R15), sys_clk (= tx_clk) domain ----
    // Decided in Stage 3 while writing the golden model:
    //   * tdata carries DA through pad -- the whole frame except preamble,
    //     SFD and FCS. There is no RX header sideband, so R15's "tuser: RX
    //     good/bad at EOF" stays literally true at one bit wide.
    //   * every frame ends with exactly one tlast at the natural end of its
    //     DV burst, whatever went wrong. Errors detectable mid-frame do not
    //     cut the stream short, so there is one tlast timing rather than two.
    output wire [7:0]   rx_axis_tdata,
    output wire         rx_axis_tvalid,
    input  wire         rx_axis_tready,
    output wire         rx_axis_tlast,
    output wire         rx_axis_tuser,      // 1 = FCS good (R9)

    // ---- Status and counters (R17) ----------------------------------------
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_rejected,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_badfcs,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_runt,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_rxer,
    input  wire         stat_clear,
    output wire         link_up,
    output wire [1:0]   link_speed          // 00=10, 01=100, 10=1000 (Clause 22)
);

    // No logic. Outputs held at constants so that a failing comparison is a
    // real mismatch rather than X propagation, which reads the same in a log
    // and is not the same thing at all.

    assign rgmii_txd        = 4'b0;
    assign rgmii_tx_ctl     = 1'b0;
    assign rgmii_gtx_clk    = 1'b0;

    assign mdc              = 1'b0;
    assign mdio_o           = 1'b0;
    assign mdio_t           = 1'b1;         // released

    assign tx_axis_tready   = 1'b0;         // never accepts

    assign rx_axis_tdata    = 8'b0;
    assign rx_axis_tvalid   = 1'b0;         // never delivers
    assign rx_axis_tlast    = 1'b0;
    assign rx_axis_tuser    = 1'b0;

    assign stat_tx_ok       = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_tx_rejected = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_rx_ok       = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_rx_badfcs   = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_rx_runt     = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_rx_oversize = {`GEM_COUNTER_WIDTH{1'b0}};
    assign stat_rx_rxer     = {`GEM_COUNTER_WIDTH{1'b0}};

    assign link_up          = 1'b0;
    assign link_speed       = 2'b10;

endmodule

/* verilator lint_on UNUSED */
