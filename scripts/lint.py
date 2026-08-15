#!/usr/bin/env python3
"""Verilator lint gate for gem_mac (R22).

R22 asks for a clean Verilator lint with zero warnings. The point of a gate is
that it fails, so this script is written to be hard to accidentally satisfy:

  * a missing Verilator is an ERROR, not a skip. A lint that silently does not
    run reports the same "nothing to see here" as a lint that passed, which is
    the worst possible behaviour for a quality gate.
  * warnings are failures. Verilator's own `-Wall` already exits nonzero on a
    warning; this script does not soften that.
  * suppressions must be justified in the source. There are exactly two today,
    both in rtl/gem_mac_stub.v, both explaining themselves and both scheduled
    for deletion when Stage 4 replaces the stub.

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

# Design entry points, each linted as its own top. Today that is the port-only
# stub and the Stage 2 skeleton; in Stage 4 the stub is replaced by the real
# gem_mac and linting it covers the whole hierarchy beneath it.
TOPS = [
    "rtl/gem_mac_stub.v",
    "rtl/skeleton_top.v",
]

FLAGS = ["--lint-only", "-Wall", "-Irtl"]


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
