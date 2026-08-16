//----------------------------------------------------------------------------
// tb_gem_mdio -- the management interface against a PHY register-file model.
//
// This closes open item V-3, which had a plan and no test: "add tb_mdio.sv with
// a PHY register-file BFM when the module is written (Stage 4), checking the
// 64-cycle Clause 22 transaction and the <= 2.5 MHz MDC bound."
//
// The BFM is a PHY, not a decoder of what this MAC happens to emit: it waits
// for the start bit, decodes the address and opcode fields the way Clause 22
// says to, answers only transactions addressed to it, and applies writes to its
// own register file. So a MAC that shifted its fields in the wrong order gets
// silence rather than accommodation, and a MAC whose writes land in the wrong
// register is caught by reading that register back.
//
// FOUR THINGS ARE CHECKED, and the first two are the ones R16 actually asks for:
//
//   1. the register-level request port -- an on-demand read of a register the
//      sequencer never touches, and a write whose effect is confirmed by
//      reading it back through the same port
//   2. the sequencer's poll order: PHY ID high, PHY ID low, BMSR, BMSR, vendor
//      status. BMSR twice because its link bit latches low, and PHY ID first
//      because it is what proves the bus is alive at all (B.5 step 3)
//   3. framing: preamble, start, opcode, field order, and bus turnaround --
//      released on a read, held for all 64 periods on a write
//   4. the MDC period, measured rather than derived from the divider's
//      arithmetic, because a divider off by a factor of two is exactly the bug
//      a calculation cannot catch
//
// WHAT THIS CANNOT CHECK, and it is most of what will go wrong on the bench:
// whether PHY_ADDR is the address the AX7035B straps, and whether register
// 0x1F carries the speed bits where the KSZ9031RNX datasheet says. Both are
// read from a datasheet A.2 flags as unverified against the physical part, and
// both are bring-up step 3's job -- which the request port now makes doable:
// sweep the address and watch phy_id stop reading all-ones.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_gem_mdio;

    import gem_tb_pkg::*;

    localparam time    CLK_PERIOD = 8ns;
    localparam [4:0]   PHY_ADDR   = 5'd3;
    localparam integer MDC_HALF   = 32;

    // R16's ceiling.
    localparam time MDC_MIN_PERIOD = 400ns;   // 2.5 MHz

    // A recognisable identifier, and deliberately neither all-ones nor
    // all-zeros -- those are what a floating or stuck bus reads as, and
    // phy_id_valid exists to tell them apart from a real part answering.
    localparam [15:0] ID_HI = 16'h0022;
    localparam [15:0] ID_LO = 16'h1622;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire  mdc, mdio_o, mdio_t;
    logic mdio_i = 1'b1;

    logic        req_valid = 1'b0;
    wire         req_ready;
    logic        req_write = 1'b0;
    logic [4:0]  req_phyad = 5'd0;
    logic [4:0]  req_regad = 5'd0;
    logic [15:0] req_wdata = 16'd0;
    wire  [15:0] rsp_data;
    wire         rsp_valid;

    wire [31:0] phy_id;
    wire        phy_id_valid;
    wire        link_up;
    wire [1:0]  link_speed;

    gem_mdio #(
        .PHY_ADDR (PHY_ADDR),
        .MDC_HALF (MDC_HALF),
        .POLL_GAP (64)               // shortened; the bit timing is unaffected
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .mdc          (mdc),
        .mdio_i       (mdio_i),
        .mdio_o       (mdio_o),
        .mdio_t       (mdio_t),
        .req_valid    (req_valid),
        .req_ready    (req_ready),
        .req_write    (req_write),
        .req_phyad    (req_phyad),
        .req_regad    (req_regad),
        .req_wdata    (req_wdata),
        .rsp_data     (rsp_data),
        .rsp_valid    (rsp_valid),
        .phy_id       (phy_id),
        .phy_id_valid (phy_id_valid),
        .link_up      (link_up),
        .link_speed   (link_speed)
    );

    //------------------------------------------------------------------
    // The PHY's register file
    //------------------------------------------------------------------
    logic [15:0] phy_reg [0:31];
    int          n_transactions = 0;
    int          n_writes       = 0;

    // What the sequencer asked for, in order, so the poll cycle is checked as
    // a sequence rather than by its effects alone.
    int seen_reg [0:31];
    int n_seen = 0;

    initial begin
        int i;
        for (i = 0; i < 32; i++) phy_reg[i] = 16'h0000;
        phy_reg[1]  = 16'h0004;      // BMSR: link up
        phy_reg[2]  = ID_HI;         // PHYIDR1
        phy_reg[3]  = ID_LO;         // PHYIDR2
        phy_reg[5]  = 16'hBEEF;      // a register the sequencer never reads
        phy_reg[31] = 16'h0040;      // vendor status: speed bits = 3'b100
    end

    //------------------------------------------------------------------
    // MDC period
    //------------------------------------------------------------------
    time last_rise = 0;

    always @(posedge mdc) begin
        if (last_rise != 0) begin
            note_check();
            if (($time - last_rise) < MDC_MIN_PERIOD) begin
                report_fail("gem_mdio", $sformatf(
                    "MDC period is %0t, faster than R16's 2.5 MHz ceiling (%0t)",
                    $time - last_rise, MDC_MIN_PERIOD));
            end
        end
        last_rise = $time;
    end

    //------------------------------------------------------------------
    // The PHY side of a Clause 22 transaction
    //------------------------------------------------------------------
    int          bit_idx = -1;      // -1 = waiting for the start bit
    logic [1:0]  got_st, got_op;
    logic [4:0]  got_phy, got_reg;
    logic [15:0] answer;
    logic [15:0] wr_capture;
    bit          addressed = 1'b0;
    bit          is_write  = 1'b0;

    // Clause 22 wants 32 preamble ones before the start bit, and the station
    // must have driven every one of them. Counted here because nothing else
    // could: a BFM that hunts for the first zero never notices that only 31
    // rising edges preceded it, which is what a frame begun mid-MDC-period
    // produces. That defect existed and this is the check that would have
    // caught it.
    int preamble_ones = 0;

    always @(posedge mdc) begin
        if (rst_n) begin
            if (bit_idx < 0) begin
                // Clause 22 preamble is all ones; the frame starts at the
                // first zero the station drives.
                if (mdio_t) begin
                    preamble_ones = 0;          // bus idle, nothing driven yet
                end else if (mdio_o === 1'b1) begin
                    preamble_ones = preamble_ones + 1;
                end else if (mdio_o === 1'b0) begin
                    note_check();
                    if (preamble_ones < 32) begin
                        report_fail("gem_mdio", $sformatf(
                            "only %0d preamble ones were driven before the start bit, Clause 22 requires 32",
                            preamble_ones));
                    end
                    preamble_ones = 0;
                    bit_idx   = 32;
                    got_st[1] = 1'b0;
                end
            end else begin
                // Increment first: the start bit was sampled on the edge that
                // set bit_idx to 32, so this edge already carries the next bit.
                // Counting after the case instead reads every field one
                // position early -- which is how this testbench first reported
                // the opcode as 00.
                bit_idx = bit_idx + 1;
                case (bit_idx)
                    33: got_st[0]  = mdio_o;
                    34: got_op[1]  = mdio_o;
                    35: got_op[0]  = mdio_o;
                    36, 37, 38, 39, 40: got_phy = {got_phy[3:0], mdio_o};
                    41, 42, 43, 44, 45: got_reg = {got_reg[3:0], mdio_o};
                    default: ;
                endcase

                if (bit_idx == 45) begin
                    is_write  = (got_op == 2'b01);
                    addressed = (got_phy == PHY_ADDR);

                    note_check();
                    if (got_st !== 2'b01) begin
                        report_fail("gem_mdio", $sformatf(
                            "start field was %b, expected 01", got_st));
                    end
                    note_check();
                    if ((got_op !== 2'b10) && (got_op !== 2'b01)) begin
                        report_fail("gem_mdio", $sformatf(
                            "opcode was %b, which is neither a Clause 22 read (10) nor a write (01)",
                            got_op));
                    end
                    note_check();
                    if (!addressed) begin
                        report_fail("gem_mdio", $sformatf(
                            "transaction addressed PHY %0d, not %0d", got_phy, PHY_ADDR));
                    end

                    answer     = addressed ? phy_reg[got_reg] : 16'hFFFF;
                    wr_capture = 16'h0000;
                end

                // Turnaround and data: on a read the station must have let go
                // of the bus; on a write it must not have.
                if (bit_idx >= 46) begin
                    note_check();
                    if (is_write) begin
                        if (mdio_t !== 1'b0) begin
                            report_fail("gem_mdio", $sformatf(
                                "station released MDIO at bit %0d of a write -- nobody is driving the data",
                                bit_idx));
                        end
                    end else begin
                        if (mdio_t !== 1'b1) begin
                            report_fail("gem_mdio", $sformatf(
                                "station still driving MDIO at bit %0d of a read -- it collides with the PHY",
                                bit_idx));
                        end
                    end
                end

                if (is_write && (bit_idx >= 48)) begin
                    wr_capture = {wr_capture[14:0], mdio_o};
                end

                if (bit_idx == 63) begin
                    if (addressed) begin
                        if (is_write) begin
                            phy_reg[got_reg] = wr_capture;
                            n_writes++;
                        end else if (n_seen < 32) begin
                            seen_reg[n_seen] = int'(got_reg);
                            n_seen++;
                        end
                    end
                    n_transactions++;
                    bit_idx = -1;
                end
            end
        end
    end

    // The PHY drives the second turnaround bit and the 16 data bits of a read,
    // changing on the falling edge so each value is stable across the station's
    // sample. Driving one bit ahead of the counter: at bit_idx == N the next
    // rising edge is the station's sample of bit N+1.
    always @(negedge mdc) begin
        if (rst_n && addressed && !is_write &&
            (bit_idx >= 46) && (bit_idx <= 62)) begin
            if (bit_idx == 46) mdio_i <= 1'b0;                    // TA
            else               mdio_i <= answer[62 - bit_idx];    // 15 downto 0
        end else begin
            mdio_i <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Issuing a request
    //------------------------------------------------------------------
    // `taken` samples (valid && ready) on the clock edge, which is exactly the
    // condition the master accepts on. Waiting on `ready` falling instead would
    // also fire when a poll happened to start on that edge, and the request
    // would sit unserved.
    bit taken = 1'b0;

    always @(posedge clk) begin
        if (rst_n && req_valid && req_ready) taken <= 1'b1;
    end

    task automatic mdio_request(input bit is_wr,
                                input logic [4:0]  regad,
                                input logic [15:0] wdata);
        begin
            taken     = 1'b0;
            req_write <= is_wr;
            req_phyad <= PHY_ADDR;
            req_regad <= regad;
            req_wdata <= wdata;
            req_valid <= 1'b1;
            wait (taken);
            @(posedge clk);
            req_valid <= 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    initial begin
        bit ok;
        int i;
        int expect_reg [0:4];

        begin_scenario("gem_mdio");

        expect_reg[0] = 2;    // PHYIDR1 -- B.5 step 3 reads this first
        expect_reg[1] = 3;    // PHYIDR2
        expect_reg[2] = 1;    // BMSR
        expect_reg[3] = 1;    // BMSR again: the link bit latches low
        expect_reg[4] = 31;   // vendor speed/duplex

        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        //--------------------------------------------------------------
        // 1. One full poll cycle
        //--------------------------------------------------------------
        wait (n_transactions >= 5);
        repeat (100) @(posedge clk);

        for (i = 0; i < 5; i++) begin
            note_check();
            if (seen_reg[i] != expect_reg[i]) begin
                report_fail("gem_mdio", $sformatf(
                    "poll %0d read register %0d, expected %0d",
                    i, seen_reg[i], expect_reg[i]));
            end
        end

        note_check();
        if (phy_id !== {ID_HI, ID_LO}) begin
            report_fail("gem_mdio", $sformatf(
                "phy_id is 0x%08h, expected 0x%08h -- B.5 step 3 cannot prove the PHY is alive",
                phy_id, {ID_HI, ID_LO}));
        end
        note_check();
        if (!phy_id_valid) begin
            report_fail("gem_mdio",
                "phy_id_valid is low after a plausible identifier was returned");
        end
        note_check();
        if (!link_up) begin
            report_fail("gem_mdio",
                "BMSR reported link up and link_up stayed low -- the read never reached the status output");
        end
        note_check();
        if (link_speed !== 2'b10) begin
            report_fail("gem_mdio", $sformatf(
                "link_speed is %b after a 1000 Mbps indication, expected 10", link_speed));
        end

        //--------------------------------------------------------------
        // 2. A read over the request port, of a register no poll touches
        //--------------------------------------------------------------
        mdio_request(1'b0, 5'd5, 16'h0000);
        wait (rsp_valid);

        note_check();
        if (rsp_data !== 16'hBEEF) begin
            report_fail("gem_mdio", $sformatf(
                "requested read of register 5 returned 0x%04h, expected 0xBEEF",
                rsp_data));
        end

        //--------------------------------------------------------------
        // 3. A write, confirmed by reading it back the same way
        //--------------------------------------------------------------
        // Register 5 again, so the read-back cannot be satisfied by the value
        // that was already there -- 0x1234 has to have displaced 0xBEEF.
        mdio_request(1'b1, 5'd5, 16'h1234);
        wait (req_ready);
        repeat (4) @(posedge clk);

        note_check();
        if (n_writes != 1) begin
            report_fail("gem_mdio", $sformatf(
                "the PHY saw %0d write transactions, expected 1", n_writes));
        end
        note_check();
        if (phy_reg[5] !== 16'h1234) begin
            report_fail("gem_mdio", $sformatf(
                "register 5 holds 0x%04h after a write of 0x1234", phy_reg[5]));
        end

        mdio_request(1'b0, 5'd5, 16'h0000);
        wait (rsp_valid);

        note_check();
        if (rsp_data !== 16'h1234) begin
            report_fail("gem_mdio", $sformatf(
                "read back 0x%04h after writing 0x1234 -- the write reached the PHY but not this register, or the read is stale",
                rsp_data));
        end

        $display("[gem_tb] gem_mdio: %0d transactions (%0d writes), poll order %0d %0d %0d %0d %0d, phy_id 0x%08h",
                 n_transactions, n_writes,
                 seen_reg[0], seen_reg[1], seen_reg[2], seen_reg[3], seen_reg[4],
                 phy_id);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_mdio FAILED");
        $finish;
    end

    initial begin
        #10ms;
        $fatal(1, "[gem_tb] gem_mdio TIMED OUT");
    end

endmodule
