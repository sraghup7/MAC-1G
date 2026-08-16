//----------------------------------------------------------------------------
// gem_mac_params.vh -- single source of truth for every sized constant in the
// design (fpga_project_flow.md Stage 2: "parameter/include file, Stage 1's
// arithmetic made executable"; Stage 4: "parameterise everything sized, from
// the parameter file, never literals").
//
// Every value here traces to spec/PROJECT_SPEC.md B.3a or to a clause of
// IEEE 802.3-2022 (see Documents/IEEE802.3-2022_notes_for_1G_MAC.md). The
// derivation is in the comment, not in someone's memory.
//
// The MATLAB golden model reads this same file (model/+gem/params.m parses
// it) so the model and the RTL cannot silently disagree about a constant --
// checked by model/tests/tParams.m.
//
// Verilog-2001 has no module-external localparam, so these are `define. All
// are prefixed GEM_ to keep the global macro namespace clean.
//----------------------------------------------------------------------------

`ifndef GEM_MAC_PARAMS_VH
`define GEM_MAC_PARAMS_VH

//---------------------------------------------------------------------------
// Frame geometry -- IEEE 802.3-2022 Clause 3, Table 4-2
//---------------------------------------------------------------------------

// 7 octets of 0x55 (Clause 3.2.1), then the SFD (Clause 3.2.2).
`define GEM_PREAMBLE_BYTES      7
`define GEM_PREAMBLE_OCTET      8'h55
`define GEM_SFD_OCTET           8'hD5

// DA(6) + SA(6) + Length/Type(2). Clause 3.2.3 / 3.2.6.
`define GEM_DA_BYTES            6
`define GEM_SA_BYTES            6
`define GEM_ETHERTYPE_BYTES     2
`define GEM_HEADER_BYTES        14

// Frame Check Sequence, Clause 3.2.9.
`define GEM_FCS_BYTES           4

// minFrameSize = 512 bits = 64 octets, DA..FCS inclusive (Table 4-2). This is
// where the 64-byte minimum and hence the TX pad requirement (R3) come from.
`define GEM_MIN_FRAME_BYTES     64
// maxBasicFrameSize (Table 4-2). Jumbo is an explicit non-goal (B.7).
`define GEM_MAX_FRAME_BYTES     1518

// Payload bounds follow from the two above minus header+FCS:
//   46   = 64   - 14 - 4   (below this, TX pads -- R3)
//   1500 = 1518 - 14 - 4   (above this, TX rejects -- R6)
`define GEM_MIN_PAYLOAD_BYTES   46
`define GEM_MAX_PAYLOAD_BYTES   1500

//---------------------------------------------------------------------------
// Inter-frame gap -- and the asymmetry between TX and RX
//---------------------------------------------------------------------------

// What TX must emit: interPacketGap = 96 bit times = 12 byte times, all speeds
// (Table 4-2, R5). Full duplex times this from our own `transmitting` going
// false (Clause 4.2.3.2.6) -- no carrier sense involved.
`define GEM_IFG_BYTES           12

// What RX must survive: Table 4-2 Note 3 permits the gap *measured at the GMII
// receive signals* to shrink to 64 bit times = 8 byte times through network
// delay and clock tolerance, and R8 permits the preamble to be absent
// entirely. So RX recovery gets 8 cycles, not 20.
// See Documents/"Why RX Recovery Gets 8 Cycles, Not 20.md".
`define GEM_IFG_RX_MIN_BYTES    8

//---------------------------------------------------------------------------
// CRC-32 / FCS -- IEEE 802.3-2022 Clause 3.2.9
//---------------------------------------------------------------------------

// G(x) = x^32+x^26+x^23+x^22+x^16+x^12+x^11+x^10+x^8+x^7+x^5+x^4+x^2+x+1
`define GEM_CRC32_POLY          32'h04C11DB7
// "Complement the first 32 bits of the frame" == seed the register all-ones.
`define GEM_CRC32_INIT          32'hFFFFFFFF
// Step (e): complement the remainder.
`define GEM_CRC32_XOROUT        32'hFFFFFFFF

// Residue: run the identical CRC across frame-plus-its-own-FCS and this is
// what falls out, for any frame. This -- not a recompute-and-compare -- is how
// the RX path checks the FCS (R9), because it costs one comparator and no
// extra state. Verified empirically, both here and by model/tests/tCrc32.m,
// rather than quoted from memory.
//   0x2144DF1C is the value *after* the final XOR (the convention this design
//   uses, since GEM_CRC32_XOROUT is applied).
//   0xDEBB20E3 is the same constant *before* the final XOR -- the number most
//   often quoted elsewhere. They are bitwise complements; using the wrong one
//   fails every frame, which is at least a loud failure.
`define GEM_CRC32_RESIDUE       32'h2144DF1C

//---------------------------------------------------------------------------
// Datapath and buffering -- spec B.3 / B.3a
//---------------------------------------------------------------------------

// 125 MB/s at 125 MHz = exactly 1 byte/cycle. There is no spare cycle during
// a frame; see B.3 for what that forbids.
`define GEM_DATA_WIDTH          8

// Derived in B.3a: clock-drift term (~0.3 B over a max-length frame at
// 2x100 ppm) + CDC pointer-sync term (~4 B) ~= 4.3 B minimum. 64 is ~15x that
// at zero extra cost, since one BRAM18 holds far more than 64 bytes anyway.
`define GEM_RX_FIFO_DEPTH       64
`define GEM_RX_FIFO_ADDR_W      6

// R17 status counters. 32 bits at the worst-case frame rate of 1.488 Mframe/s
// (B.3a) wraps in ~48 minutes; the soak test (B.5 step 8) runs >= 4 hours, so
// the regression must treat wrap as expected behaviour, not as divergence.
`define GEM_COUNTER_WIDTH       32

// R21: MAC-added RX latency ceiling, SFD on the wire to the first byte out of
// the user interface. B.1b's bottom-up pipeline sum is 13 cycles against this
// (IDDR 1 + deframe 2 + FCS holdback 4 + verdict 1 + FIFO CDC 4 + egress 1),
// so there is 2.5x margin. Lives here rather than only in the spec because
// tb_gem_mac_rx measures against it on every scenario -- a latency budget
// nothing checks is a wish.
`define GEM_RX_LATENCY_MAX_CYCLES 32

//---------------------------------------------------------------------------
// Board clocking and PHY reset -- spec B.1b, built by Stage 5's clock/reset
// block (rtl/gem_clk_rst.v)
//---------------------------------------------------------------------------

// The board's only oscillator, and the MMCM's input (A.2 / ALINX AX7035B
// manual Part 5, pin Y18). Everything the reset sequencer counts is counted
// in these cycles, because it is the one clock running before the MMCM locks.
`define GEM_CLK50_HZ            50000000

// KSZ9031RNX tSR: RST_N must be held low at least 10 ms after the supplies are
// stable, and MDIO is not to be trusted until it releases (B.1b's reset
// strategy, bring-up step 2). Stated in microseconds rather than milliseconds
// so that cycles = (CLK50_HZ / 1e6) * HOLD_US stays exact integer arithmetic
// -- a reset hold that is short by a rounding error is a PHY that comes up
// unreliably, on some boards, at some temperatures.
`define GEM_PHY_RESET_HOLD_US   10000

//---------------------------------------------------------------------------
// Simulation scaling
//---------------------------------------------------------------------------

// Stage 3's strategy decision: the RTL is parameterised from day one so the
// slow full-scale tests can be scaled down for fast iteration
// (fpga_project_flow.md, Stage 3 "Strategy decisions made here").
// GEM_SIM_SCALE caps the payload length the generator and testbenches sweep
// to, so a smoke run is seconds and the full run is the real 1500. It must
// never change synthesised geometry -- only how much traffic a test drives.
`ifndef GEM_SIM_SCALE
  `define GEM_SIM_SCALE         `GEM_MAX_PAYLOAD_BYTES
`endif

`endif // GEM_MAC_PARAMS_VH
