//----------------------------------------------------------------------------
// tb_gem_mdio -- the management interface against a PHY register-file model.
//
// This closes open item V-3, which had a plan and no test: "add tb_mdio.sv with
// a PHY register-file BFM when the module is written (Stage 4), checking the
// 64-cycle Clause 22 transaction and the <= 2.5 MHz MDC bound."
//
// The BFM is a PHY, not a decoder of what this MAC happens to emit: it waits
// for the start bit, decodes the address fields the way Clause 22 says to, and
// refuses to answer a transaction addressed to somebody else. So a MAC that
// shifted its fields in the wrong order would be answered by silence rather
// than accommodated.
//
// WHAT THIS CANNOT CHECK, and it is most of what will go wrong on the bench:
// whether PHY_ADDR is the address the AX7035B straps, and whether register
// 0x1F carries the speed bits in the position the KSZ9031RNX datasheet
// describes. Both are stated as unknowns in the module header, both are read
// from a datasheet that A.2 flags as unverified against the physical part, and
// both are bring-up step 3's job. What is checked here is everything that is
// decidable without the board: framing, field order, bus turnaround, the clock
// bound, and that a returned register value actually reaches link_up and
// link_speed.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_gem_mdio;

    import gem_tb_pkg::*;

    localparam time     CLK_PERIOD = 8ns;
    localparam [4:0]    PHY_ADDR   = 5'd3;
    localparam integer  MDC_HALF   = 32;

    // R16's ceiling. MDC's period must be at least this, measured rather than
    // asserted from the divider's arithmetic -- a divider off by a factor of
    // two is exactly the bug that a calculation cannot catch and a measurement
    // can.
    localparam time MDC_MIN_PERIOD = 400ns;   // 2.5 MHz

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    wire  mdc, mdio_o, mdio_t;
    logic mdio_i = 1'b1;
    wire  link_up;
    wire  [1:0] link_speed;

    gem_mdio #(
        .PHY_ADDR (PHY_ADDR),
        .MDC_HALF (MDC_HALF),
        .POLL_GAP (64)               // shortened; the bit timing is unaffected
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .mdc        (mdc),
        .mdio_i     (mdio_i),
        .mdio_o     (mdio_o),
        .mdio_t     (mdio_t),
        .link_up    (link_up),
        .link_speed (link_speed)
    );

    //------------------------------------------------------------------
    // The PHY's registers. BMSR bit 2 is link status; 0x1F bits [6:4] are the
    // KSZ9031RNX's resolved speed, set here to the 1000 Mbps encoding.
    //------------------------------------------------------------------
    logic [15:0] phy_reg [0:31];
    int          n_transactions = 0;
    int          n_addressed    = 0;

    initial begin
        int i;
        for (i = 0; i < 32; i++) phy_reg[i] = 16'h0000;
        phy_reg[1]  = 16'h0004;      // BMSR: link up
        phy_reg[31] = 16'h0040;      // PHY control: speed bits = 3'b100
    end

    //------------------------------------------------------------------
    // MDC period check
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
    // The PHY side of a Clause 22 read
    //------------------------------------------------------------------
    // Bit numbering matches the module: 0..31 preamble, 32.. start.
    int          bit_idx = -1;      // -1 = waiting for the start bit
    logic [1:0]  got_st, got_op;
    logic [4:0]  got_phy, got_reg;
    logic [15:0] answer;
    bit          addressed = 1'b0;

    always @(posedge mdc) begin
        if (rst_n) begin
            if (bit_idx < 0) begin
                // Clause 22 preamble is all ones; the frame starts at the
                // first zero the station drives.
                if (!mdio_t && (mdio_o === 1'b0)) begin
                    bit_idx = 32;
                    got_st  = {1'b0, 1'b0};
                    got_st[1] = 1'b0;
                end
            end else begin
                // Increment first: the start bit was sampled on the edge that
                // set bit_idx to 32, so this edge is already carrying the next
                // bit. Counting after the case instead reads every field one
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
                    note_check();
                    if ({got_st, got_op} !== 4'b0110) begin
                        report_fail("gem_mdio", $sformatf(
                            "start/opcode were %b/%b, expected 01/10 for a Clause 22 read",
                            got_st, got_op));
                    end
                    addressed = (got_phy == PHY_ADDR);
                    if (addressed) begin
                        n_addressed++;
                        answer = phy_reg[got_reg];
                    end else begin
                        answer = 16'hFFFF;   // not ours: leave the bus alone
                    end
                    note_check();
                    if (!addressed) begin
                        report_fail("gem_mdio", $sformatf(
                            "transaction addressed PHY %0d, not %0d", got_phy, PHY_ADDR));
                    end
                end

                // The station must have released the bus by the turnaround.
                if (bit_idx >= 46) begin
                    note_check();
                    if (mdio_t !== 1'b1) begin
                        report_fail("gem_mdio", $sformatf(
                            "station still driving MDIO at bit %0d -- it collides with the PHY",
                            bit_idx));
                    end
                end

                if (bit_idx == 63) begin
                    n_transactions++;
                    bit_idx = -1;
                end
            end
        end
    end

    // The PHY drives the second turnaround bit and the 16 data bits, changing
    // on the falling edge so the value is stable across the station's sample.
    always @(negedge mdc) begin
        // Driving one bit ahead of the counter: at bit_idx == N the next rising
        // edge is the station's sample of bit N+1. So the second turnaround bit
        // (47) is driven at 46, and data bit k (frame bit 48+k) at 47+k.
        if (rst_n && addressed && (bit_idx >= 46) && (bit_idx <= 62)) begin
            if (bit_idx == 46) mdio_i <= 1'b0;                    // TA
            else               mdio_i <= answer[62 - bit_idx];    // 15 downto 0
        end else begin
            mdio_i <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Sequence
    //------------------------------------------------------------------
    initial begin
        bit ok;

        begin_scenario("gem_mdio");

        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        // Three transactions: BMSR, BMSR again, then the vendor status
        // register -- one full poll cycle.
        wait (n_transactions >= 3);
        repeat (100) @(posedge clk);

        note_check();
        if (!link_up) begin
            report_fail("gem_mdio",
                "BMSR reported link up and link_up stayed low -- the read data never reached the status output");
        end

        note_check();
        if (link_speed !== 2'b10) begin
            report_fail("gem_mdio", $sformatf(
                "link_speed is %b after a 1000 Mbps indication, expected 10", link_speed));
        end

        $display("[gem_tb] gem_mdio: %0d transactions, %0d addressed this PHY",
                 n_transactions, n_addressed);

        ok = check_done();
        if (!ok) $fatal(1, "[gem_tb] gem_mdio FAILED");
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "[gem_tb] gem_mdio TIMED OUT");
    end

endmodule
