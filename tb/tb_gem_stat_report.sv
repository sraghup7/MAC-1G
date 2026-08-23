//----------------------------------------------------------------------------
// tb_gem_stat_report -- the formatter and the transmitter together, decoded
// back into text and compared against the line they were supposed to produce.
//
// This is the testbench B.7 item 5 asks for in as many words: one that decodes
// its own transmitter's output. The counters themselves are already proven --
// sixteen frozen scenarios check them against the golden model -- so the
// obligation here is narrow and specific: that what is printed is what the
// ports held, and that the framing carrying it is right.
//
// THE COMPARISON IS AGAINST A WHOLE LINE, built with $sformatf from the values
// the testbench drove. One string compare covers the field names, their order,
// the separators, the hexadecimal formatting and every value, and when it fails
// it prints both lines, which is the difference between "field 7 mismatched"
// and seeing that a name is misspelled.
//
// THE SNAPSHOT IS THE PROPERTY WORTH THE TROUBLE. Every counter is changed to a
// different value the moment the first record starts transmitting, while about
// a hundred and ninety characters are still queued behind it. The record must
// come out carrying the old values throughout -- all thirteen fields from one
// instant -- and the next record must carry the new ones. Without the snapshot
// this test fails in the most confusing way available: the first few fields are
// right and the rest are not.
//
// BAUD IS NOT CHECKED HERE. tb_gem_uart_tx checks it at the shipped divisor,
// against a receiver that derives its timing from the baud rate in nanoseconds.
// This testbench overrides CLKS_PER_BIT to 8, because a record at 115200 baud
// is 16.5 ms -- two million clock cycles to re-prove a bit period that is
// already covered, in a test whose subject is text.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module tb_gem_stat_report;

    import gem_tb_pkg::*;

    localparam real CLK_HALF_NS = 4.0;

    // Short enough to simulate, and the receiver below is timed from the same
    // number: what this test checks is the text, not the rate.
    localparam int  CLKS_PER_BIT_TB = 8;
    localparam real BIT_NS = CLKS_PER_BIT_TB * 2.0 * CLK_HALF_NS;

    // A record is ~190 characters, so ~122 us at this bit period. The interval
    // has to clear that with room, or a trigger lands inside a record.
    localparam int  CLKS_PER_REPORT_TB = 40_000;   // 320 us

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [`GEM_COUNTER_WIDTH-1:0] tx_ok, tx_rej, tx_urun, rx_ok, rx_bad, rx_runt, rx_over, rx_rxer;
    logic        link_up;
    logic [1:0]  link_speed;
    logic [31:0] phy_id;
    logic        phy_id_valid;
    logic        rx_mmcm_locked;

    wire [7:0] uart_data;
    wire       uart_valid;
    wire       uart_ready;
    wire       serial;

    gem_stat_report #(
        .CLKS_PER_REPORT (CLKS_PER_REPORT_TB)
    ) u_report (
        .clk              (clk),
        .rst_n            (rst_n),
        .stat_tx_ok       (tx_ok),
        .stat_tx_rejected (tx_rej),
        .stat_tx_underrun (tx_urun),
        .stat_rx_ok       (rx_ok),
        .stat_rx_badfcs   (rx_bad),
        .stat_rx_runt     (rx_runt),
        .stat_rx_oversize (rx_over),
        .stat_rx_rxer     (rx_rxer),
        .link_up          (link_up),
        .link_speed       (link_speed),
        .phy_id           (phy_id),
        .phy_id_valid     (phy_id_valid),
        .rx_mmcm_locked   (rx_mmcm_locked),
        .uart_data        (uart_data),
        .uart_valid       (uart_valid),
        .uart_ready       (uart_ready)
    );

    gem_uart_tx #(
        .CLKS_PER_BIT (CLKS_PER_BIT_TB)
    ) u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (uart_data),
        .valid (uart_valid),
        .ready (uart_ready),
        .tx    (serial)
    );

    always #(CLK_HALF_NS * 1ns) clk = ~clk;

    //----------------------------------------------------------------------
    // Receiver: mid-bit sampling, lines split on newline.
    //----------------------------------------------------------------------
    string lines [$];
    string current = "";
    int    stray_control = 0;

    task automatic receive_forever();
        logic [7:0] octet;
        int k;
        forever begin
            @(negedge serial);
            #(0.5 * BIT_NS * 1ns);
            if (serial !== 1'b0) continue;      // not a frame
            for (k = 0; k < 8; k++) begin
                #(BIT_NS * 1ns);
                octet[k] = serial;
            end
            #(BIT_NS * 1ns);
            note_check();
            if (serial !== 1'b1) begin
                report_fail("gem_stat_report", $sformatf(
                    "stop bit low on character 0x%02h", octet));
            end

            if (octet == 8'h0A) begin
                lines.push_back(current);
                current = "";
            end else if (octet < 8'h20 || octet > 8'h7E) begin
                // Anything outside printable ASCII would break a host parser
                // and is worth naming rather than silently accumulating.
                stray_control++;
            end else begin
                current = {current, string'(octet)};
            end
        end
    endtask

    //----------------------------------------------------------------------
    // The line the design is supposed to produce, from the values driven.
    //----------------------------------------------------------------------
    function automatic string expected_line(
        input logic [31:0] a_tx_ok, a_tx_rej, a_tx_urun, a_rx_ok,
        input logic [31:0] a_rx_bad, a_rx_runt, a_rx_over, a_rx_rxer,
        input logic        a_link,
        input logic [1:0]  a_speed,
        input logic [31:0] a_phyid,
        input logic        a_phyok,
        input logic        a_rxlock);
        return $sformatf(
            "gem tx_ok=%08x tx_rej=%08x tx_urun=%08x rx_ok=%08x rx_bad=%08x rx_runt=%08x rx_over=%08x rx_rxer=%08x link=%08x speed=%08x phyid=%08x phyok=%08x rxlock=%08x",
            a_tx_ok, a_tx_rej, a_tx_urun, a_rx_ok, a_rx_bad, a_rx_runt, a_rx_over, a_rx_rxer,
            32'(a_link), 32'(a_speed), a_phyid, 32'(a_phyok), 32'(a_rxlock));
    endfunction

    task automatic drive_set_a();
        tx_ok        = 32'h0000002a;
        tx_rej       = 32'h00000000;
        tx_urun      = 32'h00000003;
        rx_ok        = 32'h000001f4;
        rx_bad       = 32'h00000002;
        rx_runt      = 32'h00000000;
        rx_over      = 32'h0000000b;
        rx_rxer      = 32'h00000000;
        link_up      = 1'b1;
        link_speed   = 2'b10;            // 1000 Mbps, Clause 22
        phy_id       = 32'h00221622;     // KSZ9031RNX
        phy_id_valid = 1'b1;
        rx_mmcm_locked = 1'b1;
    endtask

    // Deliberately different in every field, including the ones that are a
    // single bit: a snapshot that leaked would show it somewhere.
    task automatic drive_set_b();
        tx_ok        = 32'hdeadbeef;
        tx_rej       = 32'h00000001;
        tx_urun      = 32'hffffffff;
        rx_ok        = 32'h12345678;
        rx_bad       = 32'h000000ff;
        rx_runt      = 32'h00000009;
        rx_over      = 32'h00000000;
        rx_rxer      = 32'h0000abcd;
        link_up      = 1'b0;
        link_speed   = 2'b01;
        phy_id       = 32'hffffffff;
        phy_id_valid = 1'b0;
        rx_mmcm_locked = 1'b0;
    endtask

    string want_a, want_b;
    bit    ok;

    initial begin
        begin_scenario("gem_stat_report");

        drive_set_a();
        want_a = expected_line(32'h0000002a, 32'h00000000, 32'h00000003, 32'h000001f4,
                               32'h00000002, 32'h00000000, 32'h0000000b, 32'h00000000,
                               1'b1, 2'b10, 32'h00221622, 1'b1, 1'b1);
        want_b = expected_line(32'hdeadbeef, 32'h00000001, 32'hffffffff, 32'h12345678,
                               32'h000000ff, 32'h00000009, 32'h00000000, 32'h0000abcd,
                               1'b0, 2'b01, 32'hffffffff, 1'b0, 1'b0);

        fork
            receive_forever();
        join_none

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // The instant the first character is offered to the UART, move every
        // input. The record already in flight must not notice.
        wait (uart_valid === 1'b1);
        @(posedge clk);
        drive_set_b();

        wait (lines.size() >= 2);

        note_check();
        if (lines[0] != want_a) begin
            report_fail("gem_stat_report", $sformatf(
                "the first record does not match the values held when it started.\n     got: %s\n    want: %s",
                lines[0], want_a));
        end

        note_check();
        if (lines[1] != want_b) begin
            report_fail("gem_stat_report", $sformatf(
                "the second record does not match the values changed to.\n     got: %s\n    want: %s",
                lines[1], want_b));
        end

        note_check();
        if (stray_control != 0) begin
            report_fail("gem_stat_report", $sformatf(
                "%0d character(s) outside printable ASCII were transmitted", stray_control));
        end

        $display("[gem_tb] gem_stat_report: %0d records, %0d characters each", lines.size(), lines[0].len());
        $display("[gem_tb]   %s", lines[0]);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_stat_report FAILED");
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "[gem_tb] gem_stat_report TIMED OUT");
    end

endmodule
