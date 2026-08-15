//----------------------------------------------------------------------------
// tb_axis_tx_driver -- a self-test of the stimulus driver's stall behaviour.
//
// The tx_underrun scenario is only a test of B.4b if the driver actually
// starves the MAC where the stimulus file says it does. If it stalls a cycle
// early, a cycle late, or for the wrong duration, the design will be blamed
// for a mismatch the harness created -- and against the stub, where tready
// never rises, there is nothing to notice the difference.
//
// So this ties tready high (a perfect consumer), plays the stimulus, and
// checks the handshake the driver produces against what the file asked for:
//
//   1. tvalid drops after exactly `stallAt` octets have been accepted
//   2. it stays down for exactly `stallCycles`
//   3. it does not drop mid-frame at all when stallAt is -1
//   4. every frame delivers its full octet count and exactly one tlast
//
// (3) matters as much as (1). A driver that stalled spuriously would make
// every clean TX scenario fail once real RTL exists, and the failure would
// look like a design that cannot sustain line rate.
//
// Like tb_rgmii_bfm, this has no DUT in it and therefore passes today.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_axis_tx_driver;

    import gem_tb_pkg::*;

    localparam time CLK_PERIOD = 8ns;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
    end

    wire [7:0]   tdata;
    wire         tvalid;
    wire         tlast;
    wire [111:0] tuser;
    logic        tready = 1'b1;      // a perfect consumer: never our stall

    axis_tx_driver u_drv (
        .clk    (clk),
        .rst_n  (rst_n),
        .tdata  (tdata),
        .tvalid (tvalid),
        .tready (tready),
        .tlast  (tlast),
        .tuser  (tuser)
    );

    //------------------------------------------------------------------
    // Observe the handshake
    //------------------------------------------------------------------
    int  frame        = 0;   // frame index currently being observed
    int  accepted     = 0;   // octets accepted so far in this frame
    int  lasts        = 0;   // tlast pulses seen in this frame
    bit  in_frame     = 1'b0;
    int  stall_start  = -1;  // accepted-count when tvalid went low
    int  stall_len    = 0;
    int  stalls_seen  = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (tvalid && tready) begin
                if (!in_frame) begin
                    in_frame = 1'b1;
                    accepted = 0;
                    lasts    = 0;
                end

                // A stall that just ended: check where it was and how long.
                if (stall_start >= 0) begin
                    stalls_seen++;
                    note_check();
                    if (stall_start != u_drv.f_stallAt[frame]) begin
                        report_fail($sformatf("frame %0d", frame), $sformatf(
                            "stalled after %0d octets, stimulus asked for %0d",
                            stall_start, u_drv.f_stallAt[frame]));
                    end
                    note_check();
                    if (stall_len != u_drv.f_stallCyc[frame]) begin
                        report_fail($sformatf("frame %0d", frame), $sformatf(
                            "stall lasted %0d cycles, stimulus asked for %0d",
                            stall_len, u_drv.f_stallCyc[frame]));
                    end
                    stall_start = -1;
                end

                accepted++;
                if (tlast) begin
                    lasts++;
                    note_check();
                    if (accepted != u_drv.f_len[frame]) begin
                        report_fail($sformatf("frame %0d", frame), $sformatf(
                            "delivered %0d octets, payload is %0d",
                            accepted, u_drv.f_len[frame]));
                    end
                    note_check();
                    if (lasts != 1) begin
                        report_fail($sformatf("frame %0d", frame),
                            $sformatf("saw %0d tlast pulses, expected 1", lasts));
                    end
                    in_frame = 1'b0;
                    frame++;
                end
            end else if (in_frame && !tvalid) begin
                // Mid-frame stall in progress.
                if (stall_start < 0) begin
                    stall_start = accepted;
                    stall_len   = 0;
                    note_check();
                    if (u_drv.f_stallAt[frame] < 0) begin
                        report_fail($sformatf("frame %0d", frame), $sformatf(
                            "tvalid dropped after %0d octets on a frame the stimulus said to send without interruption",
                            accepted));
                    end
                end
                stall_len++;
            end
        end
    end

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    string scenario, vecdir;

    initial begin
        bit ok;
        int expected_stalls, i;

        get_scenario(scenario, vecdir);
        begin_scenario("axis_tx_driver_selftest");
        $display("[gem_tb] driving %s/tx_stim.txt into a perfect consumer", vecdir);

        wait (rst_n);
        repeat (2) @(posedge clk);

        u_drv.play({vecdir, "/tx_stim.txt"});
        repeat (8) @(posedge clk);

        // Every frame the stimulus marked must actually have stalled. Without
        // this the checks above are all vacuously satisfiable by a driver that
        // simply never stalls.
        expected_stalls = 0;
        for (i = 0; i < u_drv.frames_sent; i++) begin
            if (u_drv.f_stallAt[i] >= 0) expected_stalls++;
        end

        $display("[gem_tb] %0d frames, %0d stalls seen, %0d expected",
                 u_drv.frames_sent, stalls_seen, expected_stalls);

        note_check();
        if (stalls_seen != expected_stalls) begin
            report_fail("axis_tx_driver", $sformatf(
                "stimulus asked for %0d mid-frame stalls, driver produced %0d",
                expected_stalls, stalls_seen));
        end

        note_check();
        if (frame != u_drv.frames_sent) begin
            report_fail("axis_tx_driver", $sformatf(
                "driver sent %0d frames, %0d completed on the handshake",
                u_drv.frames_sent, frame));
        end

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] axis_tx_driver self-test FAILED");
        $finish;
    end

    initial begin
        #40ms;
        $fatal(1, "[gem_tb] axis_tx_driver self-test TIMED OUT");
    end

endmodule
