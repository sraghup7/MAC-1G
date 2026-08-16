//----------------------------------------------------------------------------
// gem_top -- the board. Everything below this file is portable Verilog that
// knows nothing about an ALINX AX7035B; everything specific to one PCB is
// here or in constrs/.
//
// FIVE BLOCKS AND NOTHING ELSE OF SUBSTANCE:
//
//   u_clk_rst    the MMCM, three reset synchronisers and the PHY's 10 ms reset
//                hold (B.1b). Turns clk50 and a button into every clock and
//                reset the rest of the design expects to be handed.
//   u_mac        the MAC itself, unchanged and unaware of any of this.
//   u_echo       B.5 step 6's echo mode: good frames come back to their sender
//                with the addresses exchanged. Application logic, above the MAC.
//   u_report     R17's counters formatted as one line of text per second...
//   u_uart       ... and clocked out of a serial pin at 115200 (B.7 item 5).
//
// WHAT DRIVES THE TRANSMIT PORT, AND WHY IT IS ECHO RATHER THAN NOTHING. A bare
// board has no user logic, so the MAC's transmit side would have nothing
// offering it frames and would never be exercised on hardware at all. Echo is
// what B.5 step 6 asks for and it makes steps 5 to 7 performable with a PC and
// Scapy: the host sends a frame, the board sends it back, and everything in
// between -- RGMII in, deframe, CRC check, FIFO, egress, ingress, assembly,
// CRC generation, RGMII out -- has been proven by one round trip.
//
// THE LEDs, which are the only diagnostic before a serial cable is attached and
// are therefore chosen for the questions asked in that order (B.5 steps 1-4):
//
//   led[0]  MMCM locked          "are the clocks alive?"          (step 2)
//   led[1]  link up              "did the PHY negotiate?"         (step 3)
//   led[2]  heartbeat, ~1.9 Hz   "is anything running at all?"    (step 1)
//   led[3]  sticky RX error      "has any bad frame been seen?"   (step 7)
//
// They are active low: the manual is explicit that a user LED lights when its
// pin is driven low, so the assignment at the bottom inverts once, in one place.
//
// The heartbeat earns its LED. A design whose clock has stopped and a design
// whose logic is wedged look identical on every other indicator, and both look
// like a dead board.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_top #(
    // Three numbers a testbench shortens and nothing else may touch. Each
    // defaults to what the board ships with; each exists because simulating
    // the real one means simulating milliseconds to observe something already
    // checked at its true value in that block's own testbench -- the PHY's
    // 10 ms reset hold (gem_clk_rst), 115200 baud (gem_uart_tx) and one record
    // per second (gem_stat_report).
    parameter integer PHY_RST_CYCLES       = (`GEM_CLK50_HZ / 1000000) * `GEM_PHY_RESET_HOLD_US,
    parameter integer UART_CLKS_PER_BIT    = `GEM_SYS_CLK_HZ / `GEM_UART_BAUD,
    parameter integer STAT_CLKS_PER_REPORT = (`GEM_SYS_CLK_HZ / 1000) * `GEM_STAT_REPORT_MS
) (
    input  wire       clk50,          // 50 MHz board oscillator (Y18)
    input  wire       rst_key_n,      // reset key, active low (F20)

    // RGMII to the KSZ9031RNX
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_gtx_clk,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    input  wire       rgmii_rx_clk,

    // PHY management and reset
    output wire       mdc,
    inout  wire       mdio,
    output wire       phy_rst_n,

    // R17's status readout (B.7 item 5)
    output wire       uart_tx,

    // Board furniture
    input  wire       key_clear_n,    // KEY1, active low: clear the counters
    output wire [3:0] led             // active low
);

    //======================================================================
    // Clocks and resets
    //======================================================================
    wire tx_clk, gtx_clk_shifted, tx_rst_n, rx_rst_n, mmcm_locked;

    gem_clk_rst #(
        .PHY_RST_CYCLES (PHY_RST_CYCLES)
    ) u_clk_rst (
        .clk50           (clk50),
        .ext_rst_n       (rst_key_n),
        .rx_clk          (rgmii_rx_clk),
        .tx_clk          (tx_clk),
        .gtx_clk_shifted (gtx_clk_shifted),
        .tx_rst_n        (tx_rst_n),
        .rx_rst_n        (rx_rst_n),
        .mmcm_locked     (mmcm_locked),
        .phy_rst_n       (phy_rst_n)
    );

    //======================================================================
    // MDIO's bidirectional pin
    //======================================================================
    //
    // The one tristate in the design, and it is inferred rather than
    // instantiated. That is not a violation of the rule keeping vendor
    // primitives in their own modules: a conditional assignment to `z` is
    // ordinary Verilog that every tool turns into the same IOBUF, unlike the
    // DDR cells and the MMCM, which UG901 is explicit are instantiated and
    // never inferred. gem_mac drives the three signals a tristate needs and
    // contains no `z` of its own.
    wire mdio_o, mdio_t;
    wire mdio_i = mdio;

    assign mdio = mdio_t ? 1'bz : mdio_o;

    //======================================================================
    // The MAC
    //======================================================================
    wire [7:0]   rx_tdata;
    wire         rx_tvalid, rx_tlast, rx_tuser, rx_tready;
    wire [7:0]   tx_tdata;
    wire         tx_tvalid, tx_tlast, tx_tready;
    wire [111:0] tx_tuser;

    wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok, stat_tx_rejected, stat_tx_underrun;
    wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok, stat_rx_badfcs, stat_rx_runt;
    wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize, stat_rx_rxer;
    wire [31:0]  phy_id;
    wire         phy_id_valid, link_up;
    wire [1:0]   link_speed;

    wire         mdio_req_ready;
    wire [15:0]  mdio_rsp_data;
    wire         mdio_rsp_valid;
    wire         stat_clear;

    gem_mac u_mac (
        .tx_clk           (tx_clk),
        .tx_rst_n         (tx_rst_n),
        .rx_rst_n         (rx_rst_n),
        .gtx_clk_shifted  (gtx_clk_shifted),

        .rgmii_txd        (rgmii_txd),
        .rgmii_tx_ctl     (rgmii_tx_ctl),
        .rgmii_gtx_clk    (rgmii_gtx_clk),
        .rgmii_rxd        (rgmii_rxd),
        .rgmii_rx_ctl     (rgmii_rx_ctl),
        .rgmii_rx_clk     (rgmii_rx_clk),

        .mdc              (mdc),
        .mdio_i           (mdio_i),
        .mdio_o           (mdio_o),
        .mdio_t           (mdio_t),

        // R16's on-demand request port is unused on a bare board: the
        // sequencer inside gem_mdio already polls the PHY ID, link status and
        // speed and publishes them on the pins below, which is what B.5 steps
        // 2 and 3 need. The port exists for software that is not written yet.
        .mdio_req_valid   (1'b0),
        .mdio_req_ready   (mdio_req_ready),
        .mdio_req_write   (1'b0),
        .mdio_req_phyad   (5'd0),
        .mdio_req_regad   (5'd0),
        .mdio_req_wdata   (16'd0),
        .mdio_rsp_data    (mdio_rsp_data),
        .mdio_rsp_valid   (mdio_rsp_valid),

        .tx_axis_tdata    (tx_tdata),
        .tx_axis_tvalid   (tx_tvalid),
        .tx_axis_tready   (tx_tready),
        .tx_axis_tlast    (tx_tlast),
        .tx_axis_tuser    (tx_tuser),

        .rx_axis_tdata    (rx_tdata),
        .rx_axis_tvalid   (rx_tvalid),
        .rx_axis_tready   (rx_tready),
        .rx_axis_tlast    (rx_tlast),
        .rx_axis_tuser    (rx_tuser),

        .stat_tx_ok       (stat_tx_ok),
        .stat_tx_rejected (stat_tx_rejected),
        .stat_tx_underrun (stat_tx_underrun),
        .stat_rx_ok       (stat_rx_ok),
        .stat_rx_badfcs   (stat_rx_badfcs),
        .stat_rx_runt     (stat_rx_runt),
        .stat_rx_oversize (stat_rx_oversize),
        .stat_rx_rxer     (stat_rx_rxer),
        .stat_clear       (stat_clear),
        .phy_id           (phy_id),
        .phy_id_valid     (phy_id_valid),
        .link_up          (link_up),
        .link_speed       (link_speed)
    );

    //======================================================================
    // Echo (B.5 step 6)
    //======================================================================
    wire echo_dropped;

    gem_echo u_echo (
        .clk       (tx_clk),        // sys_clk = tx_clk (B.7 item 3)
        .rst_n     (tx_rst_n),
        .rx_tdata  (rx_tdata),
        .rx_tvalid (rx_tvalid),
        .rx_tlast  (rx_tlast),
        .rx_tuser  (rx_tuser),
        .rx_tready (rx_tready),
        .tx_tdata  (tx_tdata),
        .tx_tvalid (tx_tvalid),
        .tx_tready (tx_tready),
        .tx_tlast  (tx_tlast),
        .tx_tuser  (tx_tuser),
        .dropped   (echo_dropped)
    );

    //======================================================================
    // R17's readout
    //======================================================================
    wire [7:0] uart_data;
    wire       uart_valid, uart_ready;

    gem_stat_report #(
        .CLKS_PER_REPORT (STAT_CLKS_PER_REPORT)
    ) u_report (
        .clk              (tx_clk),
        .rst_n            (tx_rst_n),
        .stat_tx_ok       (stat_tx_ok),
        .stat_tx_rejected (stat_tx_rejected),
        .stat_tx_underrun (stat_tx_underrun),
        .stat_rx_ok       (stat_rx_ok),
        .stat_rx_badfcs   (stat_rx_badfcs),
        .stat_rx_runt     (stat_rx_runt),
        .stat_rx_oversize (stat_rx_oversize),
        .stat_rx_rxer     (stat_rx_rxer),
        .link_up          (link_up),
        .link_speed       (link_speed),
        .phy_id           (phy_id),
        .phy_id_valid     (phy_id_valid),
        .uart_data        (uart_data),
        .uart_valid       (uart_valid),
        .uart_ready       (uart_ready)
    );

    gem_uart_tx #(
        .CLKS_PER_BIT (UART_CLKS_PER_BIT)
    ) u_uart (
        .clk   (tx_clk),
        .rst_n (tx_rst_n),
        .data  (uart_data),
        .valid (uart_valid),
        .ready (uart_ready),
        .tx    (uart_tx)
    );

    //======================================================================
    // The key, the heartbeat and the LEDs
    //======================================================================
    //
    // The key is synchronised and edge-detected, and deliberately not
    // debounced. A bouncing contact produces several clear pulses instead of
    // one, and clearing counters twice is clearing them once -- the debouncer
    // would be logic guarding against an outcome identical to the intended
    // one. (`gem_stats` clears synchronously, so there is no window where a
    // second pulse could catch it half done.)
    reg  key_sync1, key_sync2, key_sync3;

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            key_sync1 <= 1'b1;
            key_sync2 <= 1'b1;
            key_sync3 <= 1'b1;
        end else begin
            key_sync1 <= key_clear_n;
            key_sync2 <= key_sync1;
            key_sync3 <= key_sync2;
        end
    end

    // Pressed is low, so the clear is the falling edge.
    assign stat_clear = key_sync3 && !key_sync2;

    // ~1.9 Hz at 125 MHz: 2^25 cycles is 0.268 s per half period.
    reg [24:0] heartbeat_cnt;

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            heartbeat_cnt <= 25'd0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 25'd1;
        end
    end

    // Sticky, because an error counted once at three in the morning is the
    // thing a soak needs to have noticed. Cleared with the counters it
    // reflects, by the same key.
    reg err_seen;

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            err_seen <= 1'b0;
        end else if (stat_clear) begin
            err_seen <= 1'b0;
        end else if ((|stat_rx_badfcs) || (|stat_rx_runt) ||
                     (|stat_rx_oversize) || (|stat_rx_rxer)) begin
            err_seen <= 1'b1;
        end
    end

    assign led = ~{err_seen, heartbeat_cnt[24], link_up, mmcm_locked};

    //======================================================================
    // Deliberately unread, gathered here rather than scattered (R22)
    //======================================================================
    /* verilator lint_off UNUSED */
    // Justified suppression. Each of these is an output of a block whose other
    // outputs are used, and each exists for something this top level does not
    // do: the MDIO request port is tied off above and so its ready and its
    // response can have no reader, and `echo_dropped` reports a condition the
    // echo path's own header explains is expected under load and is not an
    // R17 counter -- putting it on the one remaining LED would mean a soak
    // ends with a light on that says nothing went wrong.
    wire _unused_ok = &{1'b0, mdio_req_ready, mdio_rsp_valid, mdio_rsp_data,
                        echo_dropped, 1'b0};
    /* verilator lint_on UNUSED */

endmodule
