# `gem_mac` — RTL coding standard

Document status: v1.0 — written at the close of Stage 4, from the RTL rather than
before it. Versioned alongside the design.

Every rule below is one this repository already follows, and each names what
enforces it. That order matters: a standard written in advance describes
intentions, and a standard written from the code describes the code. Where the
design deviates from the flow doc's advice, the deviation is at the bottom under
its own heading rather than quietly absent.

**The rule behind the rules:** every entry here has a failure it prevents. If you
cannot state the failure, it is a preference, and preferences do not belong in a
document that refuses builds.

---

## Language and files

| Rule | Why | Enforced by |
|---|---|---|
| Synthesisable RTL is **Verilog-2001**; SystemVerilog appears only in `tb/` | Keeps the design portable across tools that disagree about SystemVerilog, and keeps the verification language out of anything that becomes a circuit | review |
| **One module per file**, file named for the module | A module you cannot find by its name is a module nobody reviews | Verilator `DECLFILENAME` |
| Assertions live in bound files, never in design modules | No property language in synthesisable source | `tb/assertions/`, bound |

## Naming

- Modules are `gem_*`; instances are `u_*`; generate blocks are `g_*`.
- Active-low signals end in `_n` (`tx_rst_n`). Nothing else does.
- One-cycle event pulses are `ev_*` — the name says it is an event, not a level,
  because a level that should have been a pulse counts every cycle it is high.
- FSM states are `ST_*`; sized copies of shared macros are `P_*` (see Constants).
- Signals that exist only for a bound assertion to watch are named and their
  purpose stated at the declaration (`frame_active` in `gem_rx_deframe`). A
  linter will call them unused, and they are — by the design, not by accident.

## Sequential and combinational logic

- Sequential blocks are `always @(posedge clk or negedge rst_n)` with
  **nonblocking** assignments only. Resets arrive already synchronised to their
  own domain (asynchronous assert, synchronous deassert, B.1b).
- **Memory arrays are written in their own block, with no reset.** A RAM's
  contents cannot be reset — no silicon clears an array on a signal — so an
  array written inside a reset block is not a RAM, and the tool will say so and
  build flip-flops instead. `gem_rx_fifo` did this: 64×10 bits became 648
  registers and a multiplexer tree while the specification claimed distributed
  RAM. Pointers keep their resets; contents do not get one.
- Combinational blocks are `always @(*)` and **assign every output a default
  before the case**. An incomplete combinational assignment is an inferred latch,
  and R23 refuses the build over one whether or not it survives optimisation.
- **Blocking assignments appear only inside functions, combinational blocks and
  `initial` blocks** — never in a clocked process.
- **Functions are called from continuous assignments, not from clocked blocks.**
  A Verilog function has no choice but to assign with `=`; calling one inside an
  `always @(posedge)` puts blocking assignments in a sequential context, which is
  legal, confusing, and flagged. `gem_crc32` computes `crc_next` as a wire for
  exactly this reason.

## Constants

- **No sized constant is written twice.** Everything traceable to frame geometry,
  the CRC polynomial, the FIFO depth or the latency ceiling comes from
  `rtl/gem_mac_params.vh`, which the MATLAB model parses rather than restates.
- The macros there are **unsized**, because the model's parser reads them as plain
  numbers. Verilog cannot part-select or width-match an unsized literal
  (`` `GEM_IFG_BYTES[3:0] `` is a syntax error), so each module gives the ones it
  needs a width exactly once, as a `localparam [W:0] P_*`.
- Derived constants are **derived**, not pasted. `gem_crc32` reflects the
  polynomial at elaboration; `0xEDB88320` appears in a comment and nowhere in the
  logic, and `tb_gem_crc32` checks the derivation lands where the standard says.

## Vendor primitives

- Logic modules contain **no vendor primitives**. The DDR I/O cells are isolated
  in `gem_oddr` and `gem_iddr`, and the MMCM and its two global buffers in
  `gem_mmcm` — each with a Xilinx primitive and a plain-Verilog model behind
  `GEM_BEHAVIORAL_IO`. `gem_clk_rst` instantiates `gem_mmcm` and stays primitive-free
  itself, which is what lets it be read as a reset policy rather than as a
  clocking datasheet.
- **The synthesisable path is the default**; simulation and lint must ask for the
  model. A forgotten define in a simulation flow fails loudly (`ODDR` is not a
  module anyone can find); the other way round, a forgotten define in synthesis
  would quietly build a clock-muxed LUT that simulates fine and fails on the
  bench.

## Clock domain crossing

- Multi-bit data crosses **only** through `gem_rx_fifo`. Single events cross
  **only** through `gem_pulse_sync`. Nothing else crosses, which is what makes
  R19's "zero undeclared CDC paths" checkable rather than aspirational.
- A synchroniser's safety argument is written at the synchroniser, in terms of the
  event rate it is safe at. `gem_pulse_sync` is safe because B.3a's worst-case
  frame rate puts events 84 cycles apart against a requirement of three.
- **Resets cross domains only through `gem_reset_sync`**, one instance per domain,
  asynchronous assert and synchronous deassert (B.1b). Its flops carry
  `ASYNC_REG` so the placer keeps the chain together; a synchroniser spread across
  the die still simulates perfectly and buys none of the settling time it exists
  for. Which asynchronous source feeds each instance is a design decision with a
  stated reason, not a wiring detail — see `gem_clk_rst`, where `tx_rst_n` is
  gated on MMCM lock and `rx_rst_n` deliberately is not.

## Comments

- Module headers state **which requirement the module implements** and which of
  its decisions would be plausible-looking bugs if reversed.
- Comments explain **why**, not what. The exception is arithmetic that is easy to
  get off by one — the IFG counter's accounting, the DDR sampling phases, the FCS
  holdback's indices — where the what is the hard part and is spelled out.
- When a defect was found and fixed, the comment says so. "This was wrong once"
  is the most useful thing a comment can tell the next reader.

## Lint

- **Zero warnings** under `verilator --lint-only -Wall --timing` (R22). `--timing`
  is not a relaxation: Verilator 5 refuses to read a file containing a delay at
  all until told how to treat one, and `gem_mmcm`'s simulation model cannot avoid
  delays, because generating a clock from nothing is what a clock source does.
  No warning class is disabled by it. The alternative, `--no-timing`, ignores the
  delays and then reports the clock generator as circular combinational logic —
  a warning about a construct the tool has misunderstood, which is worse than no
  warning at all.
- Suppressions are inline, scoped to the narrowest region that needs them, and
  carry a stated reason. There are three: the nonblocking assignment in
  `gem_oddr`'s simulation model, `frame_active` in `gem_rx_deframe` (driven for a
  bound assertion, not for logic), and the three deliberately unread outputs
  gathered in one place at the bottom of `gem_mac`.
- A blanket `-Wno-` flag is never the answer: it hides a class, and the one that
  matters will be in it.

---

## Deliberate deviations

**Blanket reset.** The flow doc advises resetting control state and leaving
pipeline registers alone. This design resets everything in the datapath,
including the FCS holdback — but not the FIFO's memory (see the rule above) and
not the DDR cells, which carry `INIT` on the primitive and an `initial` in the
model rather than a reset. The cost is real in principle and measured at zero
here — 745 LUTs and 788 FFs against budgets of 2000 and 3000, WNS +2.262 ns —
and the benefit is that every register has a defined value at time zero, so a
simulation that starts mid-frame cannot produce X-propagation that reads like a
data bug. Revisit if timing ever gets tight; it is not tight.

**Per-module testbenches for three modules, not thirteen.** Stage 4's loop asks
for one per module. `gem_crc32`, `gem_rx_fifo` and `gem_mdio` have them, because
each checks something the integrated regression structurally cannot: numbers from
outside this project, FIFO behaviour at full and empty, and a protocol with no
golden-model counterpart. The rest are covered bit-exactly through the scenario
regression, and a unit test for `gem_stats` would restate it.

---

## What actually enforces this

Rules nobody checks are decoration. These do the checking:

| Gate | Command | Catches |
|---|---|---|
| Verilator lint | `make lint` | widths, latches, unused signals, filename/module mismatch |
| Latch inference | `make synth`, `make oocsynth` | latches, including ones optimisation removes |
| Memory inference | `make oocsynth` | arrays that dissolved into flip-flops instead of becoming RAM |
| Timing and area | `make oocsynth` | 125 MHz, and the B.2 resource budget |
| Model, vectors, regression | `make check` | everything the design is supposed to do |

Every one of them has been made to fail on purpose. See the table in
[`README.md`](README.md) for what each canary was.
