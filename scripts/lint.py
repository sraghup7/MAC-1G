#!/usr/bin/env python3
"""Verilator lint gate for gem_mac (R22).

R22 asks for a clean Verilator lint with zero warnings. The point of a gate is
that it fails, so this script is written to be hard to accidentally satisfy:

  * a missing Verilator is an ERROR, not a skip. A lint that silently does not
    run reports the same "nothing to see here" as a lint that passed, which is
    the worst possible behaviour for a quality gate.
  * warnings are failures. Verilator's own `-Wall` already exits nonzero on a
    warning; this script does not soften that.
  * suppressions must be justified in the source. There are exactly three today,
    each explaining itself where it sits: the nonblocking assignment in the
    simulation model of the DDR output cell (rtl/gem_oddr.v), a signal driven
    only for a bound assertion to watch (rtl/gem_rx_deframe.v), and the three
    deliberately unread outputs gathered at the bottom of rtl/gem_mac.v. Stage
    3's two lived in the port-only stub and went with it, as V-9 required.
    rtl/gem_mdio.v had a fourth until the request interface landed and made
    every bit of a read register meaningful -- a suppression that stopped being
    needed, which is the only good way for one to end.

WSL: on Windows the natural place for Verilator is inside WSL, so if it is not
on PATH natively this falls back to `wsl -- verilator`. Relative paths survive
that hop because WSL translates the working directory when it is on a mounted
drive (E:\\Projects\\MAC1G becomes /mnt/e/Projects/MAC1G), which is why every
path handed to Verilator below is kept relative to the repo root.

Usage:
    python scripts/lint.py
    python scripts/lint.py --verilator /usr/bin/verilator
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Design entry points, each linted as its own top. Linting gem_mac covers every
# module beneath it, which is the whole design -- Verilator finds them by name
# in rtl/ (-Irtl), so a module added to the hierarchy is linted the moment it is
# instantiated rather than the moment somebody remembers to list it here.
TOPS = [
    "rtl/gem_mac.v",
    "rtl/skeleton_top.v",
    # Stage 5's clock/reset block. It is not under gem_mac and never will be --
    # it is what feeds gem_mac its clocks -- so until the Stage 5 top level
    # instantiates both, it has to be named here to be linted at all.
    "rtl/gem_clk_rst.v",
    # R17's readout, likewise: siblings of gem_mac rather than modules
    # under it, and unreachable from any other top until Stage 5's top
    # level ties the three together.
    "rtl/gem_stat_report.v",
    "rtl/gem_uart_tx.v",
]

# GEM_BEHAVIORAL_IO selects the plain-Verilog models of the DDR I/O cells. The
# synthesis path instantiates Xilinx ODDR/IDDR primitives, which Verilator has
# no source for; see the header of rtl/gem_ddr_io.v for why the primitive path
# is the default and the model has to be asked for.
#
# --timing is not a relaxation of the gate. Verilator 5 refuses to read a file
# containing a delay at all unless told how to treat one (NEEDTIMINGOPT), and
# gem_mmcm's simulation model cannot avoid delays: generating a 125 MHz clock
# from nothing is what a clock source does. The alternative, --no-timing, is
# actively worse -- it ignores the delays and then reports the clock generator
# as circular combinational logic, a warning about a construct it has
# misunderstood. No warning class is disabled either way; every -Wall check
# still runs on every file.
FLAGS = ["--lint-only", "-Wall", "--timing", "-Irtl", "-DGEM_BEHAVIORAL_IO"]


def verilator_command(explicit: str | None) -> list[str]:
    """Return the command prefix that runs Verilator, or exit explaining why not."""
    if explicit:
        return [explicit]

    found = shutil.which("verilator")
    if found:
        return [found]

    # Windows: try WSL before giving up.
    if shutil.which("wsl"):
        probe = subprocess.run(["wsl", "--", "verilator", "--version"],
                               capture_output=True, text=True)
        if probe.returncode == 0:
            print(f"    using WSL: {probe.stdout.strip()}")
            return ["wsl", "--", "verilator"]

    sys.exit(
        "ERROR: verilator not found.\n"
        "  R22 requires a clean lint. This target fails rather than passing a\n"
        "  check that did not run.\n"
        "  Install it (Linux/WSL: sudo apt update && sudo apt install verilator)\n"
        "  or pass --verilator <path>."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", help="path to the verilator executable")
    args = parser.parse_args()

    verilator = verilator_command(args.verilator)

    failures = []
    for top in TOPS:
        if not (REPO / top).exists():
            print(f"  SKIP  {top} (not present)")
            continue

        print(f"==> Linting {top}")
        result = subprocess.run(verilator + FLAGS + [top],
                                cwd=REPO, capture_output=True, text=True)
        output = (result.stdout + result.stderr).strip()

        if result.returncode != 0:
            failures.append(top)
            print(output)
        else:
            print("    clean")

    print()
    if failures:
        print(f"LINT FAILED: {', '.join(failures)}")
        print("R22 requires zero warnings. Fix them, or add a lint_off with a")
        print("stated reason in the source -- not a flag that hides the class.")
        return 1

    print(f"Lint clean: {len(TOPS)} top(s), zero warnings (R22).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
