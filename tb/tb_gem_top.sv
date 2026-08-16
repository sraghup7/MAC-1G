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
    always #(RXCLK_HALF_NS * 1ns) rx_clk = ~rx_clk;

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
    // The run
    //----------------------------------------------------------------------
    int  rx_ok_reported;
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
