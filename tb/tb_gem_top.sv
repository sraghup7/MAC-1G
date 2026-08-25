//----------------------------------------------------------------------------
// tb_gem_top -- the whole board, driven only at its pins.
//
// Every other testbench in this repository reaches inside: it drives an
// AXI-Stream port, or a module's inputs, or hands a block a clock the design
// would have had to make for itself. This one drives what an ALINX AX7035B
// drives -- a 50 MHz oscillator, a reset key, and the PHY's RGMII pins -- and
// reads what a PC would read: four LEDs, a serial line, and frames coming back
// on the wire.
//
// That is the point of Stage 5. The pieces have all passed on their own; what
// has never been tested is whether they were wired together correctly, and
// interface mistakes are invisible from inside a module by construction.
//
// THE ROUND TRIP IS THE TEST. A frame goes in on RGMII and, if it was good, has
// to come back out on RGMII with its addresses exchanged. Getting one frame
// back proves the whole chain in one observation: the MMCM produced a usable
// clock, the resets released in an order that let logic start, the IDDR
// captured real nibbles, the deframer found the SFD, the CRC agreed, the FIFO
// crossed the domain, the egress port handed the frame to the echo path, the
// echo path swapped the addresses, the ingress port took it back, the assembler
// rebuilt it, a new CRC was computed and the ODDR put it on the pins. A failure
// anywhere in that list produces silence, which is why the checks below say
// which stage they were watching when the silence started.
//
// WHAT IS SHORTENED, AND WHAT IS NOT. Three parameters are overridden -- the
// PHY's 10 ms reset hold, the UART's baud divisor and the record interval --
// because each is a duration already checked at its true value in its own
// block's testbench, and simulating them here would mean milliseconds of
// simulation to re-observe a number. Nothing about the datapath is scaled: the
// frames are the committed rx_clean_sweep vector, at line rate, through the
// real design.
//
// MDIO has a pull-up and no PHY on it, exactly as an unpopulated bus behaves.
// The sequencer therefore reads all-ones, reports `phy_id_valid` low and
// `link_up` low, and the record says so -- which is itself worth checking,
// because a design that claimed a link with no PHY attached would be lying
// about the one thing bring-up step 3 asks it.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_top;

    import gem_tb_pkg::*;

    localparam real CLK50_HALF_NS = 10.0;   // 50 MHz board oscillator
    localparam real RXCLK_HALF_NS = 4.0;    // 125 MHz recovered receive clock

    localparam int  PHY_RST_TEST   = 20;
    localparam int  UART_BIT_CLKS  = 8;
    localparam int  REPORT_CLKS    = 20_000;   // 160 us
    localparam real UART_BIT_NS    = UART_BIT_CLKS * 2.0 * 4.0;

    // Relative to sim/, which is where run_sim.py runs xsim from. Scenario
    // testbenches are handed an absolute path in run.cfg; a per-module
    // testbench gets no run.cfg, so this one names its own stimulus.
    localparam string VEC_DIR = "../model/vectors/rx_clean_sweep";

    logic clk50 = 1'b0;
    logic rx_clk = 1'b0;
    logic rst_key_n = 1'b0;
    logic key_clear_n = 1'b1;

    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl, rgmii_gtx_clk;
    wire [3:0] rgmii_rxd;
    wire       rgmii_rx_ctl;
    wire       mdc, phy_rst_n, uart_tx;
    wire [3:0] led;
    wire       mdio;

    // The board's MDIO pull-up, with nothing on the far end.
    pullup (mdio);

    gem_top #(
        .PHY_RST_CYCLES       (PHY_RST_TEST),
        .UART_CLKS_PER_BIT    (UART_BIT_CLKS),
        .STAT_CLKS_PER_REPORT (REPORT_CLKS)
    ) u_dut (
        .clk50         (clk50),
        .rst_key_n     (rst_key_n),
        .rgmii_txd     (rgmii_txd),
        .rgmii_tx_ctl  (rgmii_tx_ctl),
        .rgmii_gtx_clk (rgmii_gtx_clk),
        .rgmii_rxd     (rgmii_rxd),
        .rgmii_rx_ctl  (rgmii_rx_ctl),
        .rgmii_rx_clk  (rx_clk),
        .mdc           (mdc),
        .mdio          (mdio),
        .phy_rst_n     (phy_rst_n),
        .uart_tx       (uart_tx),
        .key_clear_n   (key_clear_n),
        .led           (led)
    );

    always #(CLK50_HALF_NS * 1ns) clk50 = ~clk50;

    // The recovered receive clock, and the switch that takes it away.
    //
    // A LINK DROP IS NOT A RESET, and the difference is the whole point of
    // criteria D6 and D7. Pressing the reset key stops both domains; pulling
    // the cable stops only this clock. tx_clk keeps running, the deskew MMCM
    // loses lock, rx_rst_n asserts and tx_rst_n does not -- the one case in
    // which the async FIFO's two halves can reset asymmetrically, which is
    // exactly the window the Stage 6 part 2 review found could drain FIFO
    // memory onto the AXI-S port as a well-formed frame. Section 4 above
    // cannot reach it: a board reset takes both halves down together.
    //
    // Gated rather than free-running so that window is reachable here. It
    // parks low, which is what an unplugged cable leaves on the pin.
    logic rx_clk_en = 1'b1;
    always #(RXCLK_HALF_NS * 1ns) begin
        if (rx_clk_en) rx_clk = ~rx_clk;
        else           rx_clk = 1'b0;
    end

    //----------------------------------------------------------------------
    // Stimulus and capture, both at the pins
    //----------------------------------------------------------------------
    logic drv_start = 1'b0;
    // The driver's reset is deliberately NOT the board's. It stands in for the
    // PHY, and a PHY does not stop driving because the FPGA was reset -- which
    // is the entire point of the mid-operation reset check below.
    logic drv_rst_n = 1'b0;
    wire  drv_busy, drv_done;

    rgmii_driver u_drv (
        .clk       (rx_clk),
        .rst_n     (drv_rst_n),
        .start     (drv_start),
        .busy      (drv_busy),
        .done      (drv_done),
        .rgmii_d   (rgmii_rxd),
        .rgmii_ctl (rgmii_rx_ctl)
    );

    // Sampled on the design's own transmit clock. That is a hierarchical
    // reference into the DUT and it is deliberate: a testbench-generated
    // 125 MHz clock would have no defined phase relationship to the MMCM's,
    // and every captured nibble would be a coin toss.
    rgmii_monitor u_mon (
        .clk       (u_dut.tx_clk),
        .rst_n     (u_dut.tx_rst_n),
        .enable    (1'b1),
        .rgmii_d   (rgmii_txd),
        .rgmii_ctl (rgmii_tx_ctl)
    );

    //----------------------------------------------------------------------
    // A UART receiver, decoding the status line into whole records
    //----------------------------------------------------------------------
    string uart_lines [$];
    string uart_current = "";

    task automatic uart_receive_forever();
        logic [7:0] octet;
        int k;
        forever begin
            @(negedge uart_tx);
            #(0.5 * UART_BIT_NS * 1ns);
            if (uart_tx !== 1'b0) continue;
            for (k = 0; k < 8; k++) begin
                #(UART_BIT_NS * 1ns);
                octet[k] = uart_tx;
            end
            #(UART_BIT_NS * 1ns);
            if (octet == 8'h0A) begin
                uart_lines.push_back(uart_current);
                uart_current = "";
            end else if (octet >= 8'h20 && octet <= 8'h7E) begin
                uart_current = {uart_current, string'(octet)};
            end
        end
    endtask

    // Pull one named field out of a record. Written as a search rather than
    // one $sscanf over the whole line because the assignment-suppression flag
    // (%*x) is not portable -- xsim returns a failed conversion for it -- and a
    // format string that has to list every field in order would need editing
    // whenever the record gains one, which is the coupling the named-field
    // format exists to avoid.
    function automatic int field_value(input string line, input string name);
        string key = {name, "="};
        int i, j, v;
        bit found;
        for (i = 0; i + key.len() + 8 <= line.len(); i++) begin
            found = 1'b1;
            for (j = 0; j < key.len(); j++) begin
                if (line.getc(i + j) != key.getc(j)) found = 1'b0;
            end
            if (found) begin
                if ($sscanf(line.substr(i + key.len(), i + key.len() + 7), "%h", v) == 1) begin
                    return v;
                end
                return -1;
            end
        end
        return -1;
    endfunction

    //----------------------------------------------------------------------
    // CRC-32, so the testbench can judge a frame's FCS without asking the
    // design whether it is happy with its own arithmetic.
    //----------------------------------------------------------------------
    function automatic logic [31:0] crc32(ref logic [7:0] data [$], input int n);
        logic [31:0] crc = 32'hFFFFFFFF;
        int i, b;
        for (i = 0; i < n; i++) begin
            crc = crc ^ {24'd0, data[i]};
            for (b = 0; b < 8; b++) begin
                crc = crc[0] ? ((crc >> 1) ^ 32'hEDB88320) : (crc >> 1);
            end
        end
        return ~crc;
    endfunction

    //----------------------------------------------------------------------
    // What went in
    //----------------------------------------------------------------------
    beat_t in_beats [];
    int    n_in_beats;

    typedef struct {
        logic [47:0] da;
        logic [47:0] sa;
        logic [15:0] etype;
        logic [7:0]  payload [$];
        bit          good;
    } frame_t;

    frame_t in_frames [$];
    int     n_good_in = 0;

    function automatic void build_input_frames();
        int i, idx;
        frame_t f;
        idx = 0;
        f.payload = {};
        for (i = 0; i < n_in_beats; i++) begin
            if (idx < 6)       f.da    = {f.da[39:0],    in_beats[i].data};
            else if (idx < 12) f.sa    = {f.sa[39:0],    in_beats[i].data};
            else if (idx < 14) f.etype = {f.etype[7:0],  in_beats[i].data};
            else               f.payload.push_back(in_beats[i].data);
            idx++;
            if (in_beats[i].last) begin
                f.good = in_beats[i].user;
                if (f.good) n_good_in++;
                in_frames.push_back(f);
                f.payload = {};
                idx = 0;
            end
        end
    endfunction

    //----------------------------------------------------------------------
    // What came back
    //----------------------------------------------------------------------
    burst_t bursts [];
    int     n_bursts;

    // rgmii_monitor stores into a fixed-size array and split_bursts takes a
    // dynamic one, so the populated prefix is copied across -- the same hop
    // tb_gem_mac_tx makes for the same reason.
    logic [11:0] captured [];

    int echoes_seen = 0;
    int matched     = 0;

    task automatic check_transmitted(input int from_word = 0);
        int b, i, len, pay_len;
        logic [7:0] octets [$];
        logic [7:0] body   [$];
        logic [47:0] da, sa;
        logic [15:0] et;
        logic [31:0] want_fcs, got_fcs;
        bit found;

        captured = new [u_mon.n_words];
        for (i = 0; i < u_mon.n_words; i++) captured[i] = u_mon.words[i];
        n_bursts = split_bursts(captured, u_mon.n_words, bursts);

        for (b = 0; b < n_bursts; b++) begin
            if (bursts[b].startIdx < from_word) continue;   // captured before the mark
            octets = {};
            for (i = 0; i < bursts[b].len; i++) begin
                octets.push_back(u_mon.words[bursts[b].startIdx + i][7:0]);
            end
            len = octets.size();
            echoes_seen++;

            // Preamble, SFD, then at least a header and an FCS.
            note_check();
            if (len < 8 + 14 + 4) begin
                report_fail("gem_top", $sformatf(
                    "transmitted burst %0d is only %0d octets -- too short to be a frame", b, len));
                continue;
            end

            note_check();
            if (octets[7] !== 8'hD5) begin
                report_fail("gem_top", $sformatf(
                    "transmitted burst %0d has 0x%02h where the SFD should be", b, octets[7]));
            end

            // Strip preamble and SFD; keep DA through pad; hold back the FCS.
            body = {};
            for (i = 8; i < len - 4; i++) body.push_back(octets[i]);

            got_fcs = {octets[len-1], octets[len-2], octets[len-3], octets[len-4]};
            want_fcs = crc32(body, body.size());

            note_check();
            if (got_fcs !== want_fcs) begin
                report_fail("gem_top", $sformatf(
                    "frame %0d came off the wire with FCS %08h, computed %08h -- the transmit CRC is wrong or the frame is corrupt",
                    b, got_fcs, want_fcs));
            end

            da = {body[0], body[1], body[2], body[3], body[4], body[5]};
            sa = {body[6], body[7], body[8], body[9], body[10], body[11]};
            et = {body[12], body[13]};
            pay_len = body.size() - 14;

            // Find the frame this is an echo of: same payload, addresses the
            // other way round.
            found = 1'b0;
            foreach (in_frames[k]) begin
                if (!in_frames[k].good) continue;
                if (in_frames[k].payload.size() != pay_len) continue;
                if (in_frames[k].da !== sa || in_frames[k].sa !== da) continue;
                if (in_frames[k].etype !== et) continue;
                found = 1'b1;
                for (i = 0; i < pay_len; i++) begin
                    if (in_frames[k].payload[i] !== body[14 + i]) found = 1'b0;
                end
                if (found) break;
            end

            note_check();
            if (!found) begin
                report_fail("gem_top", $sformatf(
                    "frame %0d (DA %012h SA %012h, %0d payload octets) matches no good frame that was sent -- the echo is not echoing, or the addresses are not exchanged",
                    b, da, sa, pay_len));
            end else begin
                matched++;
            end
        end
    endtask

    //----------------------------------------------------------------------
    // Criterion D6's instrument: beats accepted on the RX AXI-S port
    //
    // Counted on u_dut.tx_clk, and that is not an arbitrary choice. The RX
    // AXI-S port is the async FIFO's READ side (gem_mac.v: rd_clk = tx_clk),
    // and tx_clk keeps running through a link drop. That is precisely why the
    // defect is reachable at all: a read side still clocked, holding stale
    // Gray pointers against a write side whose pointers were zeroed, sees
    // empty deassert and drains FIFO memory -- which has no reset, because it
    // infers as RAM -- onto this port. It arrives as well-formed AXI-S, so
    // nothing downstream can tell it from a real frame. Counting handshakes
    // here, on the read side's own clock, is the only place it is visible.
    //
    // tready is included in the condition rather than assumed: a beat is a
    // beat only when both sides agree, and counting tvalid alone would report
    // stalled cycles as delivered octets.
    //----------------------------------------------------------------------
    int  rx_axis_beats = 0;
    bit  rx_axis_watch = 1'b0;

    always @(posedge u_dut.tx_clk) begin
        if (rx_axis_watch && u_dut.rx_tvalid === 1'b1 && u_dut.rx_tready === 1'b1) begin
            rx_axis_beats++;
        end
    end

    // Criterion D8's instrument: is the RX port mid-frame, and did the frame
    // it was carrying ever get terminated?
    //
    // "Mid-frame" means a beat has been accepted and it was not the last one.
    // d8_saw_tlast latches any terminating beat while armed, so section 8 can
    // ask the only question that distinguishes the two abort behaviours the
    // design doc offered: when the link vanishes underneath a frame, does the
    // port close it in band or simply stop talking?
    bit rx_in_frame   = 1'b0;
    bit d8_watch      = 1'b0;
    bit d8_saw_tlast  = 1'b0;

    always @(posedge u_dut.tx_clk) begin
        if (u_dut.rx_path_rst_n !== 1'b1) begin
            rx_in_frame <= 1'b0;
        end else if (u_dut.rx_tvalid === 1'b1 && u_dut.rx_tready === 1'b1) begin
            rx_in_frame <= (u_dut.rx_tlast !== 1'b1);
        end

        if (d8_watch && u_dut.rx_tvalid === 1'b1 && u_dut.rx_tready === 1'b1 &&
            u_dut.rx_tlast === 1'b1) begin
            d8_saw_tlast <= 1'b1;
        end
    end

    //----------------------------------------------------------------------
    // The run
    //----------------------------------------------------------------------
    int  rx_ok_reported;
    // Counter snapshots for criteria D6 and D7. Sized from the design's own
    // counter width rather than int, so a comparison can never be a
    // truncation artifact.
    logic [`GEM_COUNTER_WIDTH-1:0] rx_ok_before, rx_badfcs_before;
    logic [`GEM_COUNTER_WIDTH-1:0] rx_runt_before, rx_oversize_before, rx_rxer_before;
    int  mark_words, mark_records;
    bit  reset_hit_tx;
    bit  ok;
    int  i;

    initial begin
        begin_scenario("gem_top");

        n_in_beats = read_beats({VEC_DIR, "/rx_expected.txt"}, in_beats);
        build_input_frames();
        u_drv.load({VEC_DIR, "/rx_rgmii.hex"});

        fork
            uart_receive_forever();
        join_none

        //--------------------------------------------------------------
        // 1. Out of reset: the board comes up in the order B.5 expects
        //--------------------------------------------------------------
        repeat (10) @(posedge clk50);

        note_check();
        if (led[0] !== 1'b1) begin
            report_fail("gem_top", "the lock LED is lit while the board is still in reset");
        end

        rst_key_n = 1'b1;
        drv_rst_n = 1'b1;

        wait (u_dut.mmcm_locked === 1'b1);
        // The lock LED is now "all clocks locked" -- the RX deskew MMCM's
        // lock arrives after its supervisor's first retry pulse clears and
        // 128 input clocks count, so give it its own wait rather than hoping
        // 20 clk50 cycles cover it.
        wait (u_dut.rx_mmcm_locked === 1'b1);
        repeat (20) @(posedge clk50);

        note_check();
        if (led[0] !== 1'b0) begin      // active low
            report_fail("gem_top", "the MMCM locked and the lock LED did not light");
        end

        note_check();
        if (phy_rst_n !== 1'b1) begin
            report_fail("gem_top", $sformatf(
                "the PHY is still in reset %0d clk50 cycles after release", PHY_RST_TEST + 20));
        end

        note_check();
        if (led[1] !== 1'b1) begin
            report_fail("gem_top",
                "the link LED is lit with no PHY on the MDIO bus -- the design is claiming a link it cannot have");
        end

        //--------------------------------------------------------------
        // 2. Frames in, frames back
        //--------------------------------------------------------------
        @(posedge rx_clk);
        drv_start = 1'b1;
        wait (drv_done === 1'b1);

        // Let the last echo drain: a maximum frame plus its gap, generously.
        repeat (4000) @(posedge rx_clk);

        check_transmitted();

        note_check();
        if (echoes_seen == 0) begin
            report_fail("gem_top",
                "nothing was transmitted at all -- no frame completed the round trip");
        end

        //--------------------------------------------------------------
        // 3. The counters, read the way a bring-up session reads them
        //--------------------------------------------------------------
        wait (uart_lines.size() >= 1);

        note_check();
        if (uart_lines[0].substr(0, 2) != "gem") begin
            report_fail("gem_top", $sformatf(
                "the status line does not start with its tag: '%s'", uart_lines[0]));
        end

        rx_ok_reported = field_value(uart_lines[0], "rx_ok");

        note_check();
        if (rx_ok_reported != n_good_in) begin
            report_fail("gem_top", $sformatf(
                "the readout reports rx_ok=%0d and %0d good frames were sent -- the counters and the record disagree, or frames were lost before being counted",
                rx_ok_reported, n_good_in));
        end

        //--------------------------------------------------------------
        // 4. Reset asserted mid-frame, with the link partner still sending
        //
        //    The flow doc lists this under what system testing must reach and
        //    unit testing structurally cannot, and it matters here more than it
        //    would in most designs, because of what the reset architecture
        //    deliberately does: tx_rst_n waits for MMCM lock and rx_rst_n does
        //    not (B.1b -- rx_clk may not exist yet), so the two domains always
        //    release at different moments. gem_rx_fifo straddles that boundary
        //    with a reset from each side. Resetting one side of an async FIFO
        //    while the other keeps its pointers is a classic way to corrupt the
        //    level calculation, and this design's reset strategy guarantees a
        //    window where exactly that is true.
        //--------------------------------------------------------------
        drv_start = 1'b0;
        drv_rst_n = 1'b0;
        repeat (4) @(posedge rx_clk);
        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;

        // The strongest moment is with a frame arriving AND a frame leaving:
        // both domains busy, the async FIFO in use, the echo buffer holding a
        // frame it has not finished sending. Hunt for that, bounded, because
        // it depends on where the echo path happens to be -- and fall back to
        // mid-receive, which is the case that straddles the FIFO and is the
        // one this check exists for. Which of the two happened is printed, so
        // a run cannot quietly claim the stronger one.
        for (i = 0; i < 4000 && !reset_hit_tx; i++) begin
            @(posedge rx_clk);
            if (rgmii_rx_ctl === 1'b1 && rgmii_tx_ctl === 1'b1) reset_hit_tx = 1'b1;
        end

        if (!reset_hit_tx) begin
            wait (rgmii_rx_ctl === 1'b1);
            repeat (30) @(posedge rx_clk);
        end

        note_check();
        if (rgmii_rx_ctl !== 1'b1) begin
            report_fail("gem_top",
                "meant to reset mid-frame and the frame had already ended -- this run proved nothing about recovery");
        end
        rst_key_n = 1'b0;

        // The PHY keeps sending into a chip in reset, which is what really
        // happens. Then quiesce it, so that what the counters show afterwards
        // is the replay and nothing else.
        repeat (200) @(posedge rx_clk);
        drv_start = 1'b0;
        drv_rst_n = 1'b0;
        repeat (50) @(posedge clk50);

        note_check();
        if (led[0] !== 1'b1) begin
            report_fail("gem_top", "the lock LED is still lit while the board is held in reset");
        end

        //--------------------------------------------------------------
        // 5. ... and it comes back
        //--------------------------------------------------------------
        rst_key_n = 1'b1;
        wait (u_dut.mmcm_locked === 1'b1);
        // Same reasoning as section 1: both MMCMs must report lock before the
        // "all clocks locked" LED is meaningful.
        wait (u_dut.rx_mmcm_locked === 1'b1);
        wait (phy_rst_n === 1'b1);
        repeat (50) @(posedge clk50);

        note_check();
        if (led[0] !== 1'b0) begin
            report_fail("gem_top", "the MMCM did not lock again after the reset was released");
        end

        // Everything from here is post-reset, judged on its own.
        mark_words   = u_mon.n_words;
        mark_records = uart_lines.size();
        echoes_seen  = 0;
        matched      = 0;

        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;
        wait (drv_done === 1'b1);
        repeat (4000) @(posedge rx_clk);

        check_transmitted(mark_words);

        note_check();
        if (echoes_seen == 0) begin
            report_fail("gem_top",
                "nothing was echoed after the reset -- the design received frames before it and none after, which is a recovery failure rather than a receive one");
        end

        // The counters restarted, so a record taken now must account for the
        // replay exactly. Anything else means state survived the reset.
        wait (uart_lines.size() > mark_records + 1);

        rx_ok_reported = field_value(uart_lines[mark_records + 1], "rx_ok");

        note_check();
        if (rx_ok_reported != n_good_in) begin
            report_fail("gem_top", $sformatf(
                "after the reset the readout reports rx_ok=%0d for a replay of %0d good frames -- the counters did not restart from zero, or the receive path did not fully recover",
                rx_ok_reported, n_good_in));
        end

        $display("[gem_tb] gem_top: reset asserted mid-frame%s, %0d frames echoed after recovery",
                 reset_hit_tx ? " (and mid-transmission)" : "", echoes_seen);

        //--------------------------------------------------------------
        // 6. Criterion D6: FIFO integrity across a link drop
        //
        //    The defect this exists to catch produces WELL-FORMED AXI-S
        //    output, which is what makes it invisible to every other check
        //    in this file: frames still arrive, the echo path still works,
        //    the counters still move. Only the fact that octets appear on
        //    the read side while the write side is held in reset gives it
        //    away, and only if something is watching that port on tx_clk.
        //
        //    Sequence: get a frame in flight so the FIFO holds octets, pull
        //    the clock mid-frame, and assert that nothing at all is handed
        //    to the AXI-S port until the link is back and a real frame
        //    arrives. rx_path_rst_n is what makes that true -- it takes the
        //    read half down with the write half. Remove it from gem_mac.v
        //    and this check is the one that fails.
        //--------------------------------------------------------------
        drv_rst_n = 1'b0;
        repeat (4) @(posedge rx_clk);
        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;

        // Drop mid-frame: the FIFO must hold octets for there to be debris
        // to drain. Bounded hunt, then assert we actually caught a frame --
        // dropping the link in the inter-frame gap would prove nothing.
        for (i = 0; i < 4000 && rgmii_rx_ctl !== 1'b1; i++) begin
            @(posedge rx_clk);
        end

        note_check();
        if (rgmii_rx_ctl !== 1'b1) begin
            report_fail("gem_top",
                "meant to drop the link mid-frame and no frame was in flight -- this run proved nothing about FIFO integrity");
        end

        // Let a few octets land in the FIFO before the clock goes away.
        repeat (8) @(posedge rx_clk);

        rx_axis_beats = 0;
        rx_axis_watch = 1'b1;
        rx_clk_en     = 1'b0;      // the cable comes out

        // The PHY stops driving with it. Everything from here is judged on
        // tx_clk, which is still running -- that is the point.
        drv_start = 1'b0;

        // Long enough for the read side to have drained the whole FIFO if it
        // were free to: the pointer range is 2**(AW+1) = 128 entries, so 500
        // tx_clk cycles is comfortably more than the defect would need.
        repeat (500) @(posedge u_dut.tx_clk);

        note_check();
        if (u_dut.rx_mmcm_locked !== 1'b0) begin
            report_fail("gem_top",
                "the deskew MMCM still reports lock with its input clock stopped -- the link-drop event never reached it, so nothing below is testing what it claims");
        end

        note_check();
        if (u_dut.rx_path_rst_n !== 1'b0) begin
            report_fail("gem_top",
                "the link dropped and rx_path_rst_n stayed high -- the FIFO's read half is still live against a reset write half, which is the corruption window itself");
        end

        note_check();
        if (rx_axis_beats != 0) begin
            report_fail("gem_top", $sformatf(
                "%0d octet(s) were handed to the RX AXI-S port while the link was down -- FIFO memory is being drained onto the port as a fabricated frame (criterion D6)",
                rx_axis_beats));
        end

        // The cable goes back in.
        rx_clk_en = 1'b1;
        wait (u_dut.rx_mmcm_locked === 1'b1);
        wait (u_dut.rx_path_rst_n === 1'b1);
        repeat (20) @(posedge u_dut.tx_clk);

        // ... and the next genuine frame must arrive intact. Judged on the
        // counters, which survive a link drop (gem_stats runs on tx_clk with
        // tx_rst_n, and tx_rst_n does not assert here), so a clean advance of
        // exactly the good-frame count with no error counter moving is the
        // whole statement: received, classified and counted correctly.
        rx_axis_watch = 1'b0;

        rx_ok_before       = u_dut.stat_rx_ok;
        rx_badfcs_before   = u_dut.stat_rx_badfcs;
        rx_runt_before     = u_dut.stat_rx_runt;
        rx_oversize_before = u_dut.stat_rx_oversize;
        rx_rxer_before     = u_dut.stat_rx_rxer;

        drv_rst_n = 1'b0;
        repeat (4) @(posedge rx_clk);
        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;
        wait (drv_done === 1'b1);
        repeat (4000) @(posedge rx_clk);

        note_check();
        if (u_dut.stat_rx_ok - rx_ok_before != n_good_in) begin
            report_fail("gem_top", $sformatf(
                "after the link came back rx_ok advanced by %0d for a replay of %0d good frames -- the receive path did not recover cleanly from the drop (criterion D6)",
                u_dut.stat_rx_ok - rx_ok_before, n_good_in));
        end

        note_check();
        if (u_dut.stat_rx_badfcs   != rx_badfcs_before   ||
            u_dut.stat_rx_runt     != rx_runt_before     ||
            u_dut.stat_rx_oversize != rx_oversize_before ||
            u_dut.stat_rx_rxer     != rx_rxer_before) begin
            report_fail("gem_top",
                "an RX error counter moved while replaying known-good frames after a link drop -- the recovered path is mis-classifying (criterion D6)");
        end

        // The measured count, not a hardcoded zero: on a failing run this line
        // prints beside the failure and must not contradict it.
        $display("[gem_tb] gem_top: link dropped mid-frame, %0d octet(s) leaked to the AXI-S port, %0d good frames replayed clean",
                 rx_axis_beats, n_good_in);

        //--------------------------------------------------------------
        // 7. Criterion D7: no phantom statistics events
        //
        //    gem_pulse_sync carries each RX event across to tx_clk as a
        //    toggle. Reset the source half and not the destination half and
        //    the toggle returns to 0 underneath a destination chain still
        //    holding 1 -- the edge detector sees a transition that no event
        //    caused and counts it. Five synchronisers, so up to five
        //    fabricated counter increments per link flap, on a design whose
        //    entire bring-up story is reading those counters over UART.
        //
        //    Drop the link with NOTHING in flight, so any movement at all is
        //    fabricated by definition.
        //
        //    PARITY IS THE WHOLE TEST, and it is easy to get wrong in a way
        //    that makes this check decoration. `toggle` flips once per event
        //    and resets to 0, so a phantom edge exists only when it is
        //    sitting at 1 -- i.e. after an ODD number of events. Dropping the
        //    link after the 12-frame replay above would leave every toggle at
        //    0, the defect would produce nothing, and this check would pass
        //    against broken RTL. So one further good frame is driven first,
        //    deliberately, to make rx_ok's toggle odd before the drop.
        //    Measured: with dst_rst_n reverted to tx_rst_n and an even count
        //    this check passes; with an odd count it fails.
        //--------------------------------------------------------------
        rx_ok_before = u_dut.stat_rx_ok;

        drv_rst_n = 1'b0;
        repeat (4) @(posedge rx_clk);
        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;

        // Exactly one more good frame, then stop the PHY mid-stream.
        for (i = 0; i < 20000 && u_dut.stat_rx_ok == rx_ok_before; i++) begin
            @(posedge u_dut.tx_clk);
        end

        note_check();
        if (u_dut.stat_rx_ok - rx_ok_before != 1) begin
            report_fail("gem_top", $sformatf(
                "meant to leave the event toggles at odd parity and rx_ok advanced by %0d -- this run cannot expose a phantom event (criterion D7)",
                u_dut.stat_rx_ok - rx_ok_before));
        end

        drv_start = 1'b0;
        drv_rst_n = 1'b0;
        repeat (200) @(posedge rx_clk);     // let the path go fully idle

        note_check();
        if (u_dut.rx_tvalid === 1'b1) begin
            report_fail("gem_top",
                "meant to drop the link with nothing in flight and the RX port is still handing over octets -- this run cannot attribute a counter move to a phantom event");
        end

        rx_ok_before       = u_dut.stat_rx_ok;
        rx_badfcs_before   = u_dut.stat_rx_badfcs;
        rx_runt_before     = u_dut.stat_rx_runt;
        rx_oversize_before = u_dut.stat_rx_oversize;
        rx_rxer_before     = u_dut.stat_rx_rxer;

        rx_clk_en = 1'b0;
        repeat (200) @(posedge u_dut.tx_clk);
        rx_clk_en = 1'b1;
        wait (u_dut.rx_mmcm_locked === 1'b1);
        wait (u_dut.rx_path_rst_n === 1'b1);
        repeat (200) @(posedge u_dut.tx_clk);

        note_check();
        if (u_dut.stat_rx_ok       != rx_ok_before       ||
            u_dut.stat_rx_badfcs   != rx_badfcs_before   ||
            u_dut.stat_rx_runt     != rx_runt_before     ||
            u_dut.stat_rx_oversize != rx_oversize_before ||
            u_dut.stat_rx_rxer     != rx_rxer_before) begin
            report_fail("gem_top", $sformatf(
                "an RX counter moved across a link drop with nothing in flight -- phantom statistics event (criterion D7). ok %0d->%0d badfcs %0d->%0d runt %0d->%0d over %0d->%0d rxer %0d->%0d",
                rx_ok_before, u_dut.stat_rx_ok,
                rx_badfcs_before, u_dut.stat_rx_badfcs,
                rx_runt_before, u_dut.stat_rx_runt,
                rx_oversize_before, u_dut.stat_rx_oversize,
                rx_rxer_before, u_dut.stat_rx_rxer));
        end

        $display("[gem_tb] gem_top: link flapped idle, all five RX counters unmoved");

        //--------------------------------------------------------------
        // 8. Criterion D8: what a link event does to a frame in flight
        //
        //    THIS TEST PINS BEHAVIOUR THAT IS ACCEPTED, NOT BEHAVIOUR THAT
        //    IS DESIRABLE, and the distinction matters to whoever trips it
        //    next. Step 3b of the deskew design offered two ways for the RX
        //    port to end a frame the link took away underneath it:
        //
        //      (a) stop mid-frame -- tvalid simply drops, no terminating
        //          beat, the consumer sees a frame that never ends
        //      (b) close it in band -- a final beat with tlast=1 and
        //          tuser=1, so the consumer is told the frame is bad
        //
        //    The owner chose (a) for v1 (V-25, B.4a's amendment): it is what
        //    falls out of resetting gem_rx_egress, and resetting it was
        //    itself the lesser evil -- leaving it out let egress stall on
        //    fifo_empty and then resume the old frame using the NEXT frame's
        //    octets, splicing two frames into one well-formed lie.
        //
        //    So this asserts (a) happens, and (a) is the weaker option. If
        //    someone implements (b), THIS CHECK IS SUPPOSED TO FAIL: that is
        //    the whole point of pinning it. Update B.4a and V-25 and invert
        //    the check -- do not quietly widen it to accept both, which
        //    would leave the port's contract undefined again.
        //--------------------------------------------------------------
        drv_rst_n = 1'b0;
        repeat (4) @(posedge rx_clk);
        drv_rst_n = 1'b1;
        @(posedge rx_clk);
        drv_start = 1'b1;

        // FIRST, PROVE THE INSTRUMENT. The check below passes when no tlast
        // is seen -- which is also exactly what a broken watcher does. A
        // mistyped hierarchical name or a watcher that never arms would sail
        // through and report the abort behaviour confirmed without having
        // observed anything. So arm it against ordinary traffic, where tlast
        // certainly occurs, and require it to latch before trusting its
        // silence later. This repository already measures SVA vacuity for
        // the same reason: a property with nothing to evaluate is not a
        // passing property.
        d8_saw_tlast = 1'b0;
        d8_watch     = 1'b1;
        for (i = 0; i < 20000 && !d8_saw_tlast; i++) begin
            @(posedge u_dut.tx_clk);
        end

        note_check();
        if (!d8_saw_tlast) begin
            report_fail("gem_top",
                "the tlast watcher never fired on ordinary traffic -- it cannot be trusted to stay silent during the abort, so criterion D8's result below would be vacuous");
        end

        // Wait for the AXI-S port itself to be mid-frame. Section 6 timed its
        // drop on rgmii_rx_ctl -- the wire -- which is a different instant:
        // the RX pipeline is 13 cycles deep and the FIFO adds more, so a
        // frame on the pins is not yet a frame on the port.
        d8_watch     = 1'b0;
        d8_saw_tlast = 1'b0;
        for (i = 0; i < 20000 && !rx_in_frame; i++) begin
            @(posedge u_dut.tx_clk);
        end

        note_check();
        if (!rx_in_frame) begin
            report_fail("gem_top",
                "meant to drop the link with a frame in flight on the RX AXI-S port and the port was never mid-frame -- this run proved nothing about the abort behaviour (criterion D8)");
        end

        d8_watch  = 1'b1;
        rx_clk_en = 1'b0;               // the cable comes out mid-frame
        drv_start = 1'b0;

        repeat (200) @(posedge u_dut.tx_clk);

        note_check();
        if (u_dut.rx_tvalid === 1'b1) begin
            report_fail("gem_top",
                "the RX port is still asserting tvalid after the link went away -- it is offering octets no PHY delivered (criterion D8)");
        end

        note_check();
        if (d8_saw_tlast) begin
            report_fail("gem_top",
                "the RX port terminated the interrupted frame with tlast -- that is Step 3b option (b), the clean in-band abort, and this design is documented as option (a). If option (b) was implemented deliberately, this check is the one that is out of date: update B.4a and V-25 and invert it (criterion D8)");
        end

        // Put the link back so the run ends with the board in a working
        // state rather than a torn one.
        rx_clk_en = 1'b1;
        wait (u_dut.rx_mmcm_locked === 1'b1);
        wait (u_dut.rx_path_rst_n === 1'b1);
        repeat (20) @(posedge u_dut.tx_clk);
        d8_watch = 1'b0;

        $display("[gem_tb] gem_top: frame in flight on the RX port aborted without tlast (option (a), as documented)");

        $display("[gem_tb] gem_top: %0d good frames in, %0d frames echoed back, %0d matched",
                 n_good_in, echoes_seen, matched);
        $display("[gem_tb]   %s", uart_lines[0]);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_top FAILED");
        $finish;
    end

    initial begin
        #50ms;
        $fatal(1, "[gem_tb] gem_top TIMED OUT");
    end

endmodule
