//----------------------------------------------------------------------------
// gem_echo -- turn every good frame the MAC receives into a frame it transmits
// back to whoever sent it. B.5 step 6's echo mode, and the reason the board can
// be tested with nothing but a PC and Scapy.
//
// This is application logic, not MAC logic: it sits above gem_mac's two
// AXI-Stream ports in the top level, and gem_mac neither knows nor cares that
// it is there.
//
// STORE AND FORWARD, WHICH B.4b REJECTED -- AND WHY THAT IS NOT A CONTRADICTION.
// The MAC transmits cut-through because buffering a maximum frame before
// starting costs 12.14 us of latency and a BRAM the B.2 table does not carry,
// in a design whose premise is latency. None of that argument applies here. An
// echo cannot be cut-through in any case: the verdict on a received frame
// arrives with its last octet (B.4a), so a cut-through echo would have to start
// retransmitting a frame before knowing whether it was worth retransmitting.
// Buffering is what lets this module say something true instead -- only good
// frames are echoed -- and it costs one BRAM out of the four B.2 budgets and
// zero the design currently uses.
//
// THE DA/SA SWAP. A received frame's DA is this board and its SA is the host.
// Echoing the header verbatim would send the frame back to the board's own
// address, which most NICs drop and no host would see. So the two are
// exchanged: what comes back is addressed to whoever sent it, from the board,
// which is what makes B.5 step 6's round-trip work with no static ARP entry on
// the PC. `tx_axis_tuser` is {DA, SA, EtherType} most-significant-octet-first
// (gem_tx_engine), so the exchange is a field swap and nothing reorders inside
// an address.
//
// WHAT COMES BACK IS PADDED. `rx_axis_tdata` carries DA through pad (B.4a) --
// the pad is not stripped, because with a Type-interpreted Length/Type field
// there is no length in the frame to strip against. So the payload this module
// echoes includes whatever pad the sender's frame carried, and a 20-octet
// request comes back as a 46-octet reply. That is correct and it will look
// wrong to anyone comparing lengths in Wireshark without knowing it.
//
// FRAMES ARE DROPPED UNDER LOAD, ON PURPOSE. One frame fits in the buffer at a
// time, so a frame arriving while another is still being transmitted is
// dropped rather than queued, and `dropped` pulses to say so. This is not a
// defect to fix with a deeper buffer: echo at line rate is receive and transmit
// each running at one octet per cycle, so the transmit side can never catch up
// once it is behind by an inter-frame gap. A host script that expects every
// frame back at line rate is asking for something arithmetically impossible;
// B.5 step 6 round-trips frames it has sent, which works because it waits for
// each one.
//----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "gem_mac_params.vh"

module gem_echo (
    input  wire         clk,
    input  wire         rst_n,

    // From gem_mac's receive port (sys_clk domain). tready is tied high and
    // never falls: R18's contract is that the receive path does not stall, and
    // a frame this module cannot take is dropped at its head rather than
    // back-pressured half way through.
    input  wire [7:0]   rx_tdata,
    input  wire         rx_tvalid,
    input  wire         rx_tlast,
    input  wire         rx_tuser,       // 1 = FCS good (R9)
    output wire         rx_tready,

    // To gem_mac's transmit port.
    output wire [7:0]   tx_tdata,
    output wire         tx_tvalid,
    input  wire         tx_tready,
    output wire         tx_tlast,
    output wire [111:0] tx_tuser,       // {DA, SA, EtherType}, MSO first

    // One cycle per frame that could not be buffered. The top level makes this
    // visible; nothing here counts it, because R17's counter set is a frozen
    // contract with the host and this is not one of its members.
    output wire         dropped
);

    // 1518 octets is the largest frame, of which 14 are header held separately,
    // so 1504 is the most payload+pad that can arrive. 2048 is the next power
    // of two and exactly one BRAM18 at this width.
    localparam integer BUF_DEPTH = 2048;
    localparam integer ADDR_W    = 11;

    localparam [1:0] ST_IDLE = 2'd0,
                     ST_PRE  = 2'd1,   // first octet fetched, not yet offered
                     ST_SEND = 2'd2;

    //======================================================================
    // Receive side
    //======================================================================
    reg [ADDR_W-1:0] wr_idx;        // octets of this frame seen so far
    reg              in_frame;
    reg              drop_this;     // this frame is not being kept
    reg [111:0]      hdr;           // the first 14 octets, as they arrive
    // The committed frame's header, swapped, held apart from `hdr`. Without
    // this the two would be the same register, and a frame arriving while
    // another is being transmitted -- which is exactly the case this module
    // drops rather than queues -- would shift its own address into the header
    // of the frame already on the wire. The reply would leave with the right
    // payload and the wrong destination, intermittently, under load only.
    reg [111:0]      hdr_tx;
    reg [ADDR_W-1:0] pay_len;       // payload+pad octets of the committed frame
    reg              pending;       // a committed frame is waiting to go out
    reg              drop_pulse;

    reg [1:0]        state;

    wire busy       = pending || (state != ST_IDLE);
    wire first_beat = rx_tvalid && !in_frame;
    wire is_header  = (wr_idx < 11'd14);

    // Where this octet lands, once the 14 header octets are past.
    //
    // There is no range check on the address and none is needed: it is ADDR_W
    // bits and the buffer is exactly 2**ADDR_W deep, so every value it can hold
    // addresses a real location. A frame long enough to wrap it -- more than
    // 2062 octets delivered -- is by definition oversize, therefore classified
    // bad (B.4a), therefore never committed, so what it overwrites on its way
    // past is its own earlier octets in a frame nothing will transmit.
    wire [ADDR_W-1:0] wr_addr = wr_idx - 11'd14;
    wire mem_we = rx_tvalid && !is_header && !drop_this && !(first_beat && busy);

    //----------------------------------------------------------------------
    // The buffer itself, written in its own block with no reset. A RAM's
    // contents cannot be reset -- the lesson V-18 cost 648 flip-flops to
    // learn -- so the pointers below keep their resets and this does not.
    //----------------------------------------------------------------------
    reg [7:0] mem [0:BUF_DEPTH-1];

    always @(posedge clk) begin
        if (mem_we) begin
            mem[wr_addr] <= rx_tdata;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_idx     <= 11'd0;
            in_frame   <= 1'b0;
            drop_this  <= 1'b0;
            hdr        <= 112'd0;
            hdr_tx     <= 112'd0;
            pay_len    <= 11'd0;
            pending    <= 1'b0;
            drop_pulse <= 1'b0;
        end else begin
            drop_pulse <= 1'b0;

            if (rx_tvalid) begin
                if (first_beat) begin
                    // The decision to keep or drop is taken once, here, and
                    // holds for the whole frame. Deciding per octet would let
                    // a frame be half kept, which is worse than dropping it.
                    drop_this  <= busy;
                    drop_pulse <= busy;
                    in_frame   <= 1'b1;
                    wr_idx     <= 11'd1;
                    hdr        <= {hdr[103:0], rx_tdata};
                end else begin
                    wr_idx <= wr_idx + 11'd1;
                    if (is_header) begin
                        hdr <= {hdr[103:0], rx_tdata};
                    end
                end

                if (rx_tlast) begin
                    in_frame <= 1'b0;
                    wr_idx   <= 11'd0;
                    // Commit only a good frame that has a payload to send.
                    // The length test is not defensive padding: B.4c records
                    // that a zero-length payload cannot be expressed on the
                    // transmit port at all, since there would be no beat to
                    // carry tlast.
                    if (rx_tuser && !drop_this && !(first_beat && busy)
                        && (wr_idx >= 11'd14)) begin
                        pay_len <= wr_idx - 11'd13;   // this beat included
                        pending <= 1'b1;
                        hdr_tx  <= {hdr[63:16], hdr[111:64], hdr[15:0]};
                    end
                end
            end

            if ((state == ST_SEND) && tx_tready && tx_tlast) begin
                pending <= 1'b0;
            end
        end
    end

    // R18: the receive path is never stalled. See the header.
    assign rx_tready = 1'b1;
    assign dropped   = drop_pulse;

    //======================================================================
    // Transmit side
    //======================================================================
    reg [ADDR_W-1:0] rd_ptr;    // next address to fetch
    reg [ADDR_W-1:0] sent;      // index of the octet currently being offered
    reg [7:0]        dout;

    wire last_now = (state == ST_SEND) && (sent == (pay_len - 11'd1));
    wire mem_re   = (state == ST_PRE) ||
                    ((state == ST_SEND) && tx_tready && !last_now);

    // Same rule as the write port: no reset, so this stays a RAM.
    always @(posedge clk) begin
        if (mem_re) begin
            dout <= mem[rd_ptr];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= ST_IDLE;
            rd_ptr <= 11'd0;
            sent   <= 11'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (pending) begin
                        rd_ptr <= 11'd0;
                        sent   <= 11'd0;
                        state  <= ST_PRE;
                    end
                end

                // One cycle of fetch latency, spent once per frame rather than
                // once per octet: the read below is issued from rd_ptr and its
                // result lands in dout on the next edge.
                ST_PRE: begin
                    rd_ptr <= 11'd1;
                    state  <= ST_SEND;
                end

                ST_SEND: begin
                    if (tx_tready) begin
                        if (last_now) begin
                            state <= ST_IDLE;
                        end else begin
                            rd_ptr <= rd_ptr + 11'd1;
                            sent   <= sent + 11'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    assign tx_tdata  = dout;
    assign tx_tvalid = (state == ST_SEND);
    assign tx_tlast  = last_now;

    // The swap, and the whole point of the module: source and destination
    // exchanged, EtherType untouched. Taken from the header latched at commit,
    // never from the live capture register -- see hdr_tx's declaration.
    assign tx_tuser  = hdr_tx;

endmodule
