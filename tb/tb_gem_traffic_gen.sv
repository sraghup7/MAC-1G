//----------------------------------------------------------------------------
// tb_gem_traffic_gen -- the transmit-side traffic generator on its own.
//
// gem_traffic_gen turns a level (enable) and a payload length into an endless
// stream of AXI-stream frames. Its defining property -- and the reason it
// exists -- is that the frames go out back to back with NO idle cycle:
// m_tvalid stays high across a frame boundary, because the engine's
// start-of-frame condition is a level, not an edge. A testbench that expects a
// gap between frames fails against correct RTL, so none of the checks here
// assumes one.
//
// WHAT IS BEING CHECKED:
//   * m_tvalid never falls between a frame's first octet and its m_tlast while
//     the sink holds m_tready high (check 1). This is why the DUT exists.
//   * with m_tready toggled pseudo-randomly, no octet is lost or duplicated:
//     the accepted stream must still be octet i == i[7:0] and every frame must
//     still be exactly payload_len beats (check 2)
//   * exactly payload_len accepted beats per frame, m_tlast on the last octet
//     and nowhere else (check 3)
//   * octet i of a frame is i[7:0], beat by beat (check 4)
//   * payload_len is clamped to 46..1500 (check 5)
//   * enable dropped mid-frame lets the frame finish, then m_tvalid goes low
//     and stays low (check 6)
//   * reset mid-frame drops m_tvalid and the next frame after release starts at
//     octet 0 (check 7)
//   * m_tuser is constant {DA, SA, ETHERTYPE} on every valid cycle (assertion)
//
// The one AXI-stream rule every sampler obeys: a beat moves only on
// m_tvalid && m_tready, so m_tdata is sampled there and nowhere else.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_gem_traffic_gen;

    import gem_tb_pkg::*;

    localparam [47:0] DA        = 48'h02_00_00_00_00_02;
    localparam [47:0] SA        = 48'h02_00_00_00_00_01;
    localparam [15:0] ETHERTYPE = 16'h88B5;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        enable = 1'b0;
    logic [10:0] payload_len = '0;
    logic        m_tready = 1'b1;

    wire [7:0]   m_tdata;
    wire         m_tvalid;
    wire         m_tlast;
    wire [111:0] m_tuser;

    // Pseudo-random m_tready source (maximal-length 16-bit LFSR). Backpressure
    // is applied only while backpressure_on is set; otherwise the sink is
    // always ready.
    logic [15:0] prng = 16'hACE1;
    bit  backpressure_on = 1'b0;

    // Beat-level monitor state, shared by every scenario.
    int octet_in_frame = 0;   // octet index within the current frame, per beat
    int beats_in_frame = 0;   // accepted beats so far in the current frame
    int frames_done    = 0;   // completed frames (accepted m_tlast beats)
    int beats_total    = 0;   // accepted beats in total
    int data_mismatch  = 0;   // beats where m_tdata != octet index
    int len_mismatch   = 0;   // beats where length or m_tlast placement broke
    bit chk_data = 1'b0;      // scenario gate: run the per-beat data check
    bit chk_len  = 1'b0;      // scenario gate: run the length / m_tlast checks
    int exp_len  = 0;         // what a frame must measure in this scenario
    bit bubble_on    = 1'b0;  // scenario gate: arm the check-1 monitor
    bit bubble_armed = 1'b0;  // check 1: armed after the first accepted beat
    int bubble_seen  = 0;     // check 1: cycles where a bubble was observed

    gem_traffic_gen #(
        .DA        (DA),
        .SA        (SA),
        .ETHERTYPE (ETHERTYPE)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (enable),
        .payload_len (payload_len),
        .m_tdata     (m_tdata),
        .m_tvalid    (m_tvalid),
        .m_tready    (m_tready),
        .m_tlast     (m_tlast),
        .m_tuser     (m_tuser)
    );

    always #4.0ns clk = ~clk;

    //--------------------------------------------------------------
    // m_tready driver. Random backpressure only while backpressure_on.
    //--------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1'b1;
            prng     <= 16'hACE1;
        end else if (backpressure_on) begin
            prng     <= {prng[14:0], prng[15] ^ prng[13] ^ prng[12] ^ prng[10]};
            m_tready <= prng[15];
        end else begin
            m_tready <= 1'b1;
        end
    end

    //--------------------------------------------------------------
    // CHECK 1 -- no mid-frame bubble. This is why the DUT exists.
    //
    // What turns this red, confirmed by construction: m_tready is held high
    // for the entire armed window, so backpressure can never be the cause of a
    // low m_tvalid. The condition `!m_tvalid && m_tready` therefore reduces to
    // "the DUT itself dropped m_tvalid", and that has exactly two possible
    // shapes -- a mid-frame stall, or an idle inserted at a frame boundary --
    // both of which violate the no-stall / no-idle contract this module exists
    // to provide. Correct RTL keeps m_tvalid high from the first octet of the
    // first frame, across every back-to-back boundary, to the last octet of the
    // final frame, so the check is green exactly when the module is correct and
    // red exactly when it is not. The `m_tready` term is the discriminator that
    // keeps the backpressure-caused lows of check 2 out of this verdict: a low
    // that coincides with the sink's m_tready low never satisfies it.
    //--------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && bubble_on && bubble_armed) begin
            note_check();
            if (!m_tvalid && m_tready) bubble_seen++;
        end
    end

    //--------------------------------------------------------------
    // Frame tracker. Counters reset with the DUT. Scenario gates select which
    // named checks are live during a run; every check samples only on beats
    // (m_tvalid && m_tready).
    //--------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            octet_in_frame = 0;
            beats_in_frame = 0;
            frames_done    = 0;
            beats_total    = 0;
            data_mismatch  = 0;
            len_mismatch   = 0;
            bubble_armed   = 1'b0;
            bubble_seen    = 0;
        end else if (m_tvalid && m_tready) begin
            if (bubble_on && !bubble_armed) bubble_armed = 1'b1;
            beats_total++;
            if (chk_data) begin
                note_check();
                if (m_tdata !== octet_in_frame[7:0]) data_mismatch++;
            end
            if (chk_len) begin
                note_check();
                if (m_tlast !== (octet_in_frame == exp_len - 1)) len_mismatch++;
                if (octet_in_frame >= exp_len) len_mismatch++;
            end
            if (m_tlast) begin
                frames_done++;
                if (chk_len) begin
                    note_check();
                    if (beats_in_frame + 1 !== exp_len) len_mismatch++;
                end
                octet_in_frame = 0;
                beats_in_frame = 0;
            end else begin
                octet_in_frame++;
                beats_in_frame++;
            end
        end
    end

    //--------------------------------------------------------------
    // m_tuser assertion: {DA, SA, ETHERTYPE}, stable on every valid cycle.
    //--------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && m_tvalid) begin
            note_check();
            if (m_tuser !== {DA, SA, ETHERTYPE}) begin
                report_fail("gem_traffic_gen", $sformatf(
                    "m_tuser is %h, expected %h", m_tuser, {DA, SA, ETHERTYPE}));
            end
        end
    end

    task automatic reset_dut();
        begin
            enable      <= 1'b0;
            payload_len <= '0;
            rst_n       <= 1'b0;
            repeat (4) @(posedge clk);
            rst_n       <= 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        bit ok;
        int target;

        begin_scenario("gem_traffic_gen");

        //--------------------------------------------------------------
        // Check 1: no mid-frame bubble. m_tready is held high throughout.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 46;
        chk_data = 1'b0;
        chk_len  = 1'b0;
        bubble_on = 1'b1;
        enable <= 1'b1;
        target = frames_done + 5;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        bubble_on = 1'b0;
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (bubble_seen != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 1: m_tvalid fell %0d cycle(s) with m_tready held high -- a mid-frame bubble or an inter-frame idle",
                bubble_seen));
        end
        $display("[gem_tb] gem_traffic_gen: check 1 no-mid-frame-bubble, %0d frames of %0d octets, %0d bubbles",
                 frames_done, 46, bubble_seen);

        //--------------------------------------------------------------
        // Check 2: backpressure honoured. m_tready toggled pseudo-randomly; the
        // accepted stream must stay octet i == i[7:0] and every frame must
        // still be exactly payload_len beats -- so nothing is lost or
        // duplicated. A bubble (valid low while ready high) is a check-1
        // concern and, with ready low, cannot move a beat, so it is out of
        // scope here.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 300;
        chk_data = 1'b1;
        chk_len  = 1'b1;
        exp_len  = 300;
        backpressure_on = 1'b1;
        enable <= 1'b1;
        target = frames_done + 5;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        backpressure_on = 1'b0;
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (data_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 2: %0d accepted octet(s) off the i == i[7:0] pattern under backpressure",
                data_mismatch));
        end
        note_check();
        if (len_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 2: %0d frame-length violation(s) under backpressure",
                len_mismatch));
        end
        $display("[gem_tb] gem_traffic_gen: check 2 backpressure, %0d octets over %0d frames with random m_tready, %0d pattern / %0d length mismatches",
                 beats_total, frames_done, data_mismatch, len_mismatch);

        //--------------------------------------------------------------
        // Check 3: frame length. Exactly payload_len accepted beats per frame,
        // m_tlast on the last octet and nowhere else.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 300;
        chk_data = 1'b0;
        chk_len  = 1'b1;
        exp_len  = 300;
        enable <= 1'b1;
        target = frames_done + 4;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (len_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 3: %0d length / m_tlast violation(s), expected exactly %0d beats per frame",
                len_mismatch, 300));
        end
        $display("[gem_tb] gem_traffic_gen: check 3 frame-length, %0d frames of %0d octets", frames_done, 300);

        //--------------------------------------------------------------
        // Check 4: payload pattern. Octet i is i[7:0], beat by beat. 257 octets
        // makes the frame wrap the 8-bit counter, so octet 256 must be 0.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 257;
        chk_data = 1'b1;
        chk_len  = 1'b0;
        enable <= 1'b1;
        target = frames_done + 4;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (data_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 4: %0d octet(s) off the i == i[7:0] pattern",
                data_mismatch));
        end
        $display("[gem_tb] gem_traffic_gen: check 4 payload-pattern, %0d frames of %0d octets", frames_done, 257);

        //--------------------------------------------------------------
        // Check 5: clamping. payload_len 10 -> 46-octet frames, 2000 -> 1500.
        // payload_len is an 11-bit signal (max 2047); a value like 9000 would
        // silently truncate rather than exercise the clamp.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 10;
        chk_data = 1'b0;
        chk_len  = 1'b1;
        exp_len  = 46;
        enable <= 1'b1;
        target = frames_done + 3;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (len_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 5a: payload_len=10 did not clamp to 46-octet frames (%0d violation(s))",
                len_mismatch));
        end
        $display("[gem_tb] gem_traffic_gen: check 5 clamp payload_len=10 -> %0d-octet frames", 46);

        reset_dut();
        payload_len <= 2000;
        chk_len  = 1'b1;
        exp_len  = 1500;
        enable <= 1'b1;
        target = frames_done + 3;
        wait (frames_done >= target);
        repeat (2) @(posedge clk);
        enable <= 1'b0;
        wait (m_tvalid === 1'b0);
        note_check();
        if (len_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 5b: payload_len=2000 did not clamp to 1500-octet frames (%0d violation(s))",
                len_mismatch));
        end
        $display("[gem_tb] gem_traffic_gen: check 5 clamp payload_len=2000 -> %0d-octet frames", 1500);

        //--------------------------------------------------------------
        // Check 6: enable dropped mid-frame lets the frame finish, then
        // m_tvalid goes low and stays low.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 300;
        chk_data = 1'b0;
        chk_len  = 1'b1;
        exp_len  = 300;
        enable <= 1'b1;
        wait (beats_total >= 100);          // mid-frame of the 300-octet first frame
        repeat (2) @(posedge clk);
        enable <= 1'b0;                     // dropped mid-frame
        wait (m_tvalid === 1'b0);
        note_check();
        if (frames_done != 1) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 6: %0d frame(s) completed after enable was dropped mid-frame -- the one in flight must finish and nothing more",
                frames_done));
        end
        note_check();
        if (len_mismatch != 0) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 6: the interrupted frame was not full length (%0d violation(s))",
                len_mismatch));
        end
        repeat (32) @(posedge clk);
        note_check();
        if (m_tvalid !== 1'b0) begin
            report_fail("gem_traffic_gen", "check 6: m_tvalid rose again after enable was dropped");
        end
        $display("[gem_tb] gem_traffic_gen: check 6 enable-dropped-mid-frame, in-flight frame finished, m_tvalid stayed low");

        //--------------------------------------------------------------
        // Check 7: reset mid-frame drops m_tvalid; the next frame after release
        // starts at octet 0.
        //--------------------------------------------------------------
        reset_dut();
        payload_len <= 300;
        chk_data = 1'b0;
        chk_len  = 1'b0;
        enable <= 1'b1;
        wait (beats_total >= 100);          // mid-frame again
        repeat (2) @(posedge clk);
        rst_n <= 1'b0;                      // async reset mid-frame
        repeat (2) @(posedge clk);
        note_check();
        if (m_tvalid !== 1'b0) begin
            report_fail("gem_traffic_gen", "check 7: m_tvalid did not drop on reset");
        end
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;                      // release
        @(posedge clk);                     // the DUT's first post-release edge: idle + enable high
                                             // starts the next frame here (count <= 0). Sample now --
                                             // m_tready is held high in this scenario (no backpressure),
                                             // so count advances every subsequent cycle once active;
                                             // waiting any longer here skips past octet 0.
        note_check();
        if (m_tdata !== 8'h00) begin
            report_fail("gem_traffic_gen", $sformatf(
                "check 7: first octet after reset is %02h, expected 00", m_tdata));
        end
        note_check();
        if (m_tlast !== 1'b0) begin
            report_fail("gem_traffic_gen", "check 7: first octet after reset carried m_tlast");
        end
        $display("[gem_tb] gem_traffic_gen: check 7 reset-mid-frame, next frame restarted at octet 0");

        $display("[gem_tb] gem_traffic_gen: %0d frames, %0d accepted octets in total", frames_done, beats_total);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_traffic_gen FAILED");
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "[gem_tb] gem_traffic_gen TIMED OUT");
    end

endmodule
