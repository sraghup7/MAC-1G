//----------------------------------------------------------------------------
// gem_mac -- a full-duplex 1000BASE-T Ethernet MAC, RGMII to the PHY and
// AXI-Stream to user logic. Stage 4's design, replacing rtl/gem_mac_stub.v.
//
// The port list is the stub's, plus two additions, and both were forced by a
// requirement the frozen interface had no way to express. Fixing the interface
// early was the stub's whole job and it did it -- every signal the datapath
// needs was already there, and every Stage 3 testbench still elaborates
// unchanged against this module. What it could not anticipate was the two
// requirements that need a port to exist at all:
//
//   gtx_clk_shifted   R14's GTX_CLK skew mechanism has to clock the GTX_CLK
//                     forwarding cell from somewhere. See the clocking note.
//   mdio_req_* / phy_id
//                     R16 asks for "a register-level request interface" and
//                     for reading the PHY ID. With neither a request channel
//                     nor an ID output, R16 was half-implementable and B.5
//                     bring-up step 3 was not performable at all.
//
// Both are additive: existing testbenches leave them unconnected or tied off,
// and no behaviour they check changes.
//
// STRUCTURE (spec B.1a's nine modules, and where each of them went):
//
//   tx_clk domain
//     u_tx_ingress   1  AXI-S ingress register, two octets deep
//     u_tx_engine    2  frame assembler, padder
//     u_tx_crc       3  byte-parallel CRC-32, shared code with RX
//                    4  TX arbiter and IFG counter -- inside u_tx_engine,
//                       because the gap and the frame are one sequence and
//                       splitting them would mean two state machines agreeing
//                       about who owns the wire
//     u_rgmii_tx     5  ODDR output stage and GTX_CLK forwarding
//
//   rx_clk domain
//     u_rgmii_rx     6  IDDR input stage
//     u_rx_ctrl      7  SFD hunter, deframer, FCS holdback
//                    8  classifier -- inside u_rx_ctrl, for the same reason:
//                       the class is decided from the same counters the
//                       deframer already keeps
//     u_rx_crc       8  the RX CRC accumulator, same module as TX's
//     u_rx_fifo      9  async FIFO, the design's only multi-bit CDC
//
//   sys_clk = tx_clk (B.7 item 3)
//     u_rx_egress    9  registered AXI-S egress
//     u_rx_abort        additive, V-25: closes a frame the link took away in
//                       band, rather than leaving the port to just go quiet
//     u_ev_*            one toggle synchroniser per RX counter event
//     u_stats           R17's counters
//     u_mdio            R16's management interface
//
// CLOCKING (B.1b). tx_clk is the 125 MHz MMCM output; rx_clk is the receive
// domain's clock -- deskewed from the raw pin by gem_clk_rst's second MMCM,
// which is why this port is named rx_clk and no longer rgmii_rx_clk: it has
// not carried the pin since Stage 6 part 2. It is asynchronous to tx_clk. The
// resets are per-domain and are expected to arrive already synchronised to
// their own clock -- asynchronous assert, synchronous deassert -- which is why
// this module uses them directly rather than re-synchronising: the clock/reset
// module that owns both MMCMs is where B.1b puts that job, and doing it twice
// would just add a cycle.
//
// rx_path_rst_n (Stage 6 part 2) covers the destination halves of every
// crossing OUT of the RX domain, so that an RX-only reset cannot leave one
// half of a crossing stale while the other re-zeroes. See
// Documents/RX Clock Deskew Design.md Step 3b for what happens without it:
// up to 127 octets of fabricated frame data per link drop.
//
// gtx_clk_shifted is the second MMCM output, phase shifted +70 deg = 1.5556 ns
// ahead of tx_clk (re-derived for the JL2121(D), rtl/gem_mmcm.v's header and
// docs/reports/stage9/rgmii-jl2121-retiming-report.md), and it exists as a
// port because the shift cannot be made anywhere else. R14's mechanism is
// that GTX_CLK leaves the chip a deliberate 1.5556 ns ahead of the data it
// clocks; the cell that forwards it therefore needs a clock this module does
// not otherwise have. It is an
// additive port -- every Stage 3 testbench elaborates unchanged, leaving it
// unconnected, and the only consequence is that rgmii_gtx_clk does not toggle
// in simulations that never look at it.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_mac (
    // ---- Clocks and resets (R19, B.1b) ------------------------------------
    input  wire         tx_clk,             // 125 MHz from the MMCM
    input  wire         tx_rst_n,           // async assert, sync deassert
    input  wire         rx_rst_n,           // ditto, in the rx_clk domain
    // tx_clk-domain reset for the destination half of every RX-domain
    // crossing. Asserts with rx_rst_n; releases after it.
    input  wire         rx_path_rst_n,

    // Second MMCM output, phase-shifted +70 deg (1.5556 ns advance) from tx_clk
    // (B.1b/R14, re-derived for the JL2121(D)). Drives only the GTX_CLK
    // forwarding cell.
    input  wire         gtx_clk_shifted,

    // ---- RGMII to the KSZ9031RNX (R13, R14) -------------------------------
    output wire [3:0]   rgmii_txd,
    output wire         rgmii_tx_ctl,       // rise = TX_EN, fall = TX_EN ^ TX_ER
    output wire         rgmii_gtx_clk,
    input  wire [3:0]   rgmii_rxd,
    input  wire         rgmii_rx_ctl,       // rise = RX_DV, fall = RX_DV ^ RX_ER
    input  wire         rx_clk,             // the DESKEWED receive clock from
                                            // gem_clk_rst -- no longer the raw
                                            // pin, see the CLOCKING paragraph

    // ---- PHY management (R16) ---------------------------------------------
    output wire         mdc,                // <= 2.5 MHz
    input  wire         mdio_i,
    output wire         mdio_o,
    output wire         mdio_t,             // 1 = release the bus

    // R16's register-level request interface: any PHY register, read or write,
    // on demand. Accepted when valid and ready are both high; one transaction
    // at a time. Tie req_valid low and this side of the block disappears,
    // which is what every Stage 3 testbench does.
    input  wire         mdio_req_valid,
    output wire         mdio_req_ready,
    input  wire         mdio_req_write,
    input  wire [4:0]   mdio_req_phyad,
    input  wire [4:0]   mdio_req_regad,
    input  wire [15:0]  mdio_req_wdata,
    output wire [15:0]  mdio_rsp_data,
    output wire         mdio_rsp_valid,     // one cycle, when a read lands

    // ---- TX user interface, AXI-Stream (R15), tx_clk domain ---------------
    input  wire [7:0]   tx_axis_tdata,
    input  wire         tx_axis_tvalid,
    output wire         tx_axis_tready,
    input  wire         tx_axis_tlast,
    input  wire [111:0] tx_axis_tuser,      // {DA[47:0], SA[47:0], EtherType[15:0]}

    // ---- RX user interface, AXI-Stream (R15), sys_clk (= tx_clk) domain ----
    output wire [7:0]   rx_axis_tdata,
    output wire         rx_axis_tvalid,
    input  wire         rx_axis_tready,
    output wire         rx_axis_tlast,
    output wire         rx_axis_tuser,      // 1 = FCS good (R9)

    // ---- Status and counters (R17) ----------------------------------------
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_ok,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_rejected,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_tx_underrun,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_ok,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_badfcs,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_runt,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_oversize,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_rxer,
    output wire [`GEM_COUNTER_WIDTH-1:0] stat_rx_fifo_drop,
    input  wire         stat_clear,
    // One tx_clk pulse per receive frame that lost at least one octet to a
    // full async FIFO. It is the per-frame collapse of gem_rx_fifo's
    // per-octet `drop`, synchronised in this module: the raw per-octet pulse
    // is too dense for a toggle synchroniser to carry without an unknown,
    // load-dependent undercount. B.3a says this cannot happen, which is why
    // the premise must be observable (and now countable) if it does. Additive
    // port -- existing testbenches leave it unconnected.
    output wire         rx_fifo_drop,
    // What the MDIO sequencer found, live on pins so an ILA or VIO can read the
    // link state with no software attached -- which is the situation B.5's
    // bring-up steps 2 and 3 are actually conducted in.
    output wire [31:0]  phy_id,             // {PHYIDR1, PHYIDR2}
    output wire         phy_id_valid,       // ... and it was not all-ones/zeros
    output wire         link_up,
    output wire [1:0]   link_speed          // 00=10, 01=100, 10=1000 (Clause 22)
);

    //======================================================================
    // Transmit path
    //======================================================================
    wire       ing_accept, ing_pop;
    wire       beat_valid, beat_last;
    wire [7:0] beat_data;

    gem_tx_ingress u_tx_ingress (
        .clk        (tx_clk),
        .rst_n      (tx_rst_n),
        .s_tdata    (tx_axis_tdata),
        .s_tvalid   (tx_axis_tvalid),
        .s_tready   (tx_axis_tready),
        .s_tlast    (tx_axis_tlast),
        .accept     (ing_accept),
        .pop        (ing_pop),
        .beat_valid (beat_valid),
        .beat_data  (beat_data),
        .beat_last  (beat_last)
    );

    wire        tx_residue_unused;
    wire        tx_crc_init, tx_crc_en;
    wire [7:0]  tx_crc_data;
    wire [31:0] tx_crc;
    wire [7:0]  tx_gm_byte;
    wire        tx_gm_dv, tx_gm_er;
    wire        ev_tx_ok, ev_tx_rejected, ev_tx_underrun;

    gem_tx_engine u_tx_engine (
        .clk            (tx_clk),
        .rst_n          (tx_rst_n),
        .beat_valid     (beat_valid),
        .beat_data      (beat_data),
        .beat_last      (beat_last),
        .accept         (ing_accept),
        .pop            (ing_pop),
        .s_tvalid       (tx_axis_tvalid),
        .s_tuser        (tx_axis_tuser),
        .crc_init       (tx_crc_init),
        .crc_en         (tx_crc_en),
        .crc_data       (tx_crc_data),
        .crc            (tx_crc),
        .gm_byte        (tx_gm_byte),
        .gm_dv          (tx_gm_dv),
        .gm_er          (tx_gm_er),
        .ev_tx_ok       (ev_tx_ok),
        .ev_tx_rejected (ev_tx_rejected),
        .ev_tx_underrun (ev_tx_underrun)
    );

    gem_crc32 u_tx_crc (
        .clk        (tx_clk),
        .rst_n      (tx_rst_n),
        .init       (tx_crc_init),
        .en         (tx_crc_en),
        .data       (tx_crc_data),
        .crc        (tx_crc),
        .residue_ok (tx_residue_unused) // TX never checks a residue
    );

    gem_rgmii_tx u_rgmii_tx (
        .tx_clk          (tx_clk),
        .gtx_clk_shifted (gtx_clk_shifted),
        .gm_byte         (tx_gm_byte),
        .gm_dv           (tx_gm_dv),
        .gm_er           (tx_gm_er),
        .rgmii_txd       (rgmii_txd),
        .rgmii_tx_ctl    (rgmii_tx_ctl),
        .rgmii_gtx_clk   (rgmii_gtx_clk)
    );

    //======================================================================
    // Receive path -- rx_clk domain up to the FIFO
    //======================================================================
    wire [7:0] rx_gm_byte;
    wire       rx_gm_dv, rx_gm_er;

    gem_rgmii_rx u_rgmii_rx (
        .rx_clk       (rx_clk),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl),
        .gm_byte      (rx_gm_byte),
        .gm_dv        (rx_gm_dv),
        .gm_er        (rx_gm_er)
    );

    wire [31:0] rx_crc_unused;
    wire       rx_crc_init, rx_crc_en, rx_crc_residue_ok;
    wire [7:0] rx_crc_data;
    wire       fifo_wr, fifo_full, fifo_empty, fifo_rd, fifo_drop;
    wire [9:0] fifo_din, fifo_dout;
    wire       ev_rx_ok_r, ev_rx_badfcs_r, ev_rx_runt_r;
    wire       ev_rx_oversize_r, ev_rx_rxer_r;

    gem_rx_deframe u_rx_ctrl (
        .clk            (rx_clk),
        .rst_n          (rx_rst_n),
        .gm_byte        (rx_gm_byte),
        .gm_dv          (rx_gm_dv),
        .gm_er          (rx_gm_er),
        .crc_init       (rx_crc_init),
        .crc_en         (rx_crc_en),
        .crc_data       (rx_crc_data),
        .crc_residue_ok (rx_crc_residue_ok),
        .fifo_wr        (fifo_wr),
        .fifo_din       (fifo_din),
        .ev_rx_ok       (ev_rx_ok_r),
        .ev_rx_badfcs   (ev_rx_badfcs_r),
        .ev_rx_runt     (ev_rx_runt_r),
        .ev_rx_oversize (ev_rx_oversize_r),
        .ev_rx_rxer     (ev_rx_rxer_r)
    );

    gem_crc32 u_rx_crc (
        .clk        (rx_clk),
        .rst_n      (rx_rst_n),
        .init       (rx_crc_init),
        .en         (rx_crc_en),
        .data       (rx_crc_data),
        .crc        (rx_crc_unused),    // RX wants the verdict, not the value
        .residue_ok (rx_crc_residue_ok)
    );

    gem_rx_fifo #(
        .WIDTH (10)
    ) u_rx_fifo (
        .wr_clk   (rx_clk),
        .wr_rst_n (rx_rst_n),
        .wr_en    (fifo_wr),
        .wr_data  (fifo_din),
        .full     (fifo_full),
        .drop     (fifo_drop),
        .rd_clk   (tx_clk),
        // rx_path_rst_n, not tx_rst_n: the read half must never outlive the
        // write half's pointers. On an RX-only reset the write side zeroes
        // while mem -- which has no reset, so it infers as RAM -- keeps the
        // last frames; a read side still running on stale Gray samples would
        // see empty deassert and drain up to 127 octets of that debris onto
        // the AXI-S port as if it were a received frame. Design doc Step 3b.
        .rd_rst_n (rx_path_rst_n),
        .rd_en    (fifo_rd),
        .rd_data  (fifo_dout),
        .empty    (fifo_empty)
    );

    // The FIFO's per-octet drop, collapsed to one event per frame that lost
    // anything, so that it survives the crossing below. gem_rx_drop_episode's
    // header explains why the raw pulse cannot: a toggle synchroniser cannot
    // carry a burst of consecutive cycles, and an undercount nobody can
    // measure would be worse than no counter at all.
    //
    // It is a module rather than two flops here so that constrs/pins.xdc can
    // confine it to the RX clock region by hierarchy, the way it confines
    // every other cell the deskewed clock touches.
    wire ev_rx_frame_end = ev_rx_ok_r | ev_rx_badfcs_r | ev_rx_runt_r |
                           ev_rx_oversize_r | ev_rx_rxer_r;
    wire fifo_drop_frame;

    gem_rx_drop_episode u_rx_drop_episode (
        .clk       (rx_clk),
        .rst_n     (rx_rst_n),
        .drop      (fifo_drop),
        .frame_end (ev_rx_frame_end),
        .episode   (fifo_drop_frame)
    );

    // Takes rx_path_rst_n rather than tx_rst_n. Leaving it out of the RX
    // reset was traced worse than resetting it: egress would stall mid-frame
    // on fifo_empty and then resume the old frame with the new frame's
    // octets, emitting a well-formed frame spliced from two different ones.
    // Resetting instead makes the failure visible at this boundary -- and
    // gem_rx_abort below turns that into a proper closing beat before it
    // reaches the port, rather than leaving the port itself to just go quiet
    // (B.4a, V-25).
    wire [7:0] egress_tdata;
    wire       egress_tvalid, egress_tlast, egress_tuser;

    gem_rx_egress u_rx_egress (
        .clk        (tx_clk),
        .rst_n      (rx_path_rst_n),
        .fifo_empty (fifo_empty),
        .fifo_dout  (fifo_dout),
        .fifo_rd    (fifo_rd),
        .m_tdata    (egress_tdata),
        .m_tvalid   (egress_tvalid),
        .m_tready   (rx_axis_tready),
        .m_tlast    (egress_tlast),
        .m_tuser    (egress_tuser)
    );

    // Closes a frame the link took away in band, instead of leaving the port
    // to just go quiet mid-frame (B.4a's amendment, V-25). rx_path_rst_n
    // arrives as an ordinary input here, not this module's reset -- see
    // gem_rx_abort's header for why that asymmetry is required rather than
    // incidental.
    gem_rx_abort u_rx_abort (
        .clk        (tx_clk),
        .rst_n      (tx_rst_n),
        .link_rst_n (rx_path_rst_n),
        .e_tdata    (egress_tdata),
        .e_tvalid   (egress_tvalid),
        .e_tlast    (egress_tlast),
        .e_tuser    (egress_tuser),
        .m_tdata    (rx_axis_tdata),
        .m_tvalid   (rx_axis_tvalid),
        .m_tlast    (rx_axis_tlast),
        .m_tuser    (rx_axis_tuser),
        .m_tready   (rx_axis_tready)
    );

    //======================================================================
    // Counter events across the domain boundary (R17, R19)
    //======================================================================
    wire ev_rx_ok_s, ev_rx_badfcs_s, ev_rx_runt_s;
    wire ev_rx_oversize_s, ev_rx_rxer_s;
    wire ev_rx_fifo_drop_s;

    // Destination halves take rx_path_rst_n so a link drop cannot manufacture
    // phantom counter events: if the source toggle resets while the
    // destination chain keeps its old value, the edge detector fires once and
    // the counters lie about a link that delivered nothing.
    gem_pulse_sync u_ev_rx_ok (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (ev_rx_ok_r),
        .dst_clk (tx_clk),       .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_ok_s));

    gem_pulse_sync u_ev_rx_badfcs (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (ev_rx_badfcs_r),
        .dst_clk (tx_clk),       .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_badfcs_s));

    gem_pulse_sync u_ev_rx_runt (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (ev_rx_runt_r),
        .dst_clk (tx_clk),       .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_runt_s));

    gem_pulse_sync u_ev_rx_oversize (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (ev_rx_oversize_r),
        .dst_clk (tx_clk),       .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_oversize_s));

    gem_pulse_sync u_ev_rx_rxer (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (ev_rx_rxer_r),
        .dst_clk (tx_clk),       .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_rxer_s));

    // The FIFO-drop event crosses with the five above, and for the same
    // reason the destination takes rx_path_rst_n: leaving it on tx_rst_n
    // would manufacture one phantom drop per link flap. The source is the
    // per-frame R1 pulse (fifo_drop_frame), not gem_rx_fifo's per-octet
    // drop, which is far too dense for a toggle synchroniser to carry.
    gem_pulse_sync u_ev_rx_fifo_drop (
        .src_clk (rx_clk), .src_rst_n (rx_rst_n), .src_pulse (fifo_drop_frame),
        .dst_clk (tx_clk), .dst_rst_n (rx_path_rst_n), .dst_pulse (ev_rx_fifo_drop_s));

    // Deliberately tx_rst_n, NOT rx_path_rst_n. The counters must survive a
    // link flap -- a statistics block that zeroed itself whenever the cable
    // moved would destroy the evidence at exactly the moment it is wanted.
    // This is safe only because the pulse synchronisers above reset both
    // halves together: no phantom event reaches these counters across a flap,
    // so they stay truthful without being reset. The two changes are one
    // change; "fixing" either alone breaks both.
    gem_stats u_stats (
        .clk              (tx_clk),
        .rst_n            (tx_rst_n),
        .clear            (stat_clear),
        .ev_tx_ok         (ev_tx_ok),
        .ev_tx_rejected   (ev_tx_rejected),
        .ev_tx_underrun   (ev_tx_underrun),
        .ev_rx_ok         (ev_rx_ok_s),
        .ev_rx_badfcs     (ev_rx_badfcs_s),
        .ev_rx_runt       (ev_rx_runt_s),
        .ev_rx_oversize   (ev_rx_oversize_s),
        .ev_rx_rxer       (ev_rx_rxer_s),
        .ev_rx_fifo_drop  (ev_rx_fifo_drop_s),
        .stat_tx_ok       (stat_tx_ok),
        .stat_tx_rejected (stat_tx_rejected),
        .stat_tx_underrun (stat_tx_underrun),
        .stat_rx_ok       (stat_rx_ok),
        .stat_rx_badfcs   (stat_rx_badfcs),
        .stat_rx_runt     (stat_rx_runt),
        .stat_rx_oversize (stat_rx_oversize),
        .stat_rx_rxer     (stat_rx_rxer),
        .stat_rx_fifo_drop(stat_rx_fifo_drop)
    );

    //======================================================================
    // Management (R16)
    //======================================================================
    gem_mdio u_mdio (
        .clk          (tx_clk),
        .rst_n        (tx_rst_n),
        .mdc          (mdc),
        .mdio_i       (mdio_i),
        .mdio_o       (mdio_o),
        .mdio_t       (mdio_t),
        .req_valid    (mdio_req_valid),
        .req_ready    (mdio_req_ready),
        .req_write    (mdio_req_write),
        .req_phyad    (mdio_req_phyad),
        .req_regad    (mdio_req_regad),
        .req_wdata    (mdio_req_wdata),
        .rsp_data     (mdio_rsp_data),
        .rsp_valid    (mdio_rsp_valid),
        .phy_id       (phy_id),
        .phy_id_valid (phy_id_valid),
        .link_up      (link_up),
        .link_speed   (link_speed)
    );

    // Deliberately unread outputs, gathered in one place so that "nothing
    // uses this" is a statement rather than an oversight:
    //   fifo_full          B.3a derives that this FIFO cannot fill under R18's
    //                      no-stall contract, and the write side already
    //                      withholds writes when it is full. It is exposed for
    //                      gem_internal_sva to assert on, which is the honest
    //                      way to treat a condition that should be impossible:
    //                      check it, do not quietly depend on it.
    //   tx_residue_unused  a residue check means nothing on the transmit side.
    //   rx_crc_unused      the receive side wants the verdict, not the value.
    /* verilator lint_off UNUSED */
    wire _unused_ok = &{1'b0, fifo_full, tx_residue_unused, rx_crc_unused};
    /* verilator lint_on UNUSED */

    // The FIFO's drop leaves as a port, but as the synchronised per-frame
    // pulse in tx_clk -- the same event the rx_drop counter counts -- not the
    // raw per-octet pulse. B.3a says it can never fire, which is why it must
    // be observable (and now countable) if it does.
    assign rx_fifo_drop = ev_rx_fifo_drop_s;

endmodule
