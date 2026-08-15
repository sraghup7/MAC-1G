#!/usr/bin/env python3
"""Run scripts/build.tcl under Vivado, from anywhere.

Exists for the same reason lint.py and clean.py do: the Makefile cannot assume
the tool is on PATH. `make regress` worked because run_sim.py locates Vivado
itself, while `make synth` invoked a bare `vivado` and died with "The system
cannot find the file specified" -- so the four build targets had never actually
been runnable through make, and nothing said so.

The locator is imported from run_sim.py rather than copied. Two searches for
the same executable would drift the first time one of them learned about a new
install path, and the symptom would be `make regress` working while
`make synth` claimed Vivado was missing.

Usage:
    python scripts/build.py synth
    python scripts/build.py impl
    python scripts/build.py bitstream
    python scripts/build.py program build/skeleton_top.bit
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_sim import vivado_bin          # noqa: E402  (path set above)

REPO = Path(__file__).resolve().parent.parent

TARGETS = {
    "synth":     "scripts/build.tcl",
    "impl":      "scripts/build.tcl",
    "bitstream": "scripts/build.tcl",
    "program":   "scripts/program.tcl",
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in TARGETS:
        sys.exit(f"usage: {Path(__file__).name} {'|'.join(TARGETS)} [extra tclargs]")

    target = sys.argv[1]
    script = TARGETS[target]
    tclargs = sys.argv[2:] if target == "program" else [target]

    vivado = vivado_bin("vivado")
    cmd = [vivado, "-mode", "batch", "-source", script, "-tclargs", *tclargs]

    print(f"==> {target}: {' '.join(cmd)}")
    # Streamed, not captured: synthesis takes minutes and a silent terminal
    # for that long is indistinguishable from a hang.
    result = subprocess.run(cmd, cwd=REPO)

    if result.returncode != 0:
        print(f"\n{target} FAILED (exit {result.returncode}).")
        print("If a gate refused the build, the reason is in the output above;")
        print("Vivado's own log is in vivado.log.")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
