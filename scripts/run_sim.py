#!/usr/bin/env python3
"""XSim regression runner for gem_mac.

Compiles the RTL, the testbenches and the bound assertions once, then runs each
scenario in the catalogue and reports a pass/fail table. Exits nonzero if
anything failed, so `make regress` is a gate rather than a report someone is
supposed to read -- the same instinct as scripts/build.tcl failing the build on
inferred latches and negative slack.

Usage:
    python scripts/run_sim.py                     # every frozen scenario
    python scripts/run_sim.py --scenario rx_min_gap
    python scripts/run_sim.py --tb tb_gem_mac_rx
    python scripts/run_sim.py --all               # include the random sweeps

Why Python rather than Tcl: the scenario list, the pass/fail tally and the exit
code all have to survive across many separate xsim invocations, and xsim's own
Tcl runs inside one simulation. Vivado is still doing all the work; this only
sequences it.

Two Vivado 2024.2-on-Windows quirks are worked around here rather than left to
bite whoever runs this next:
  * xsim.bat mangles `-testplusarg NAME=value`, splitting it at the '=', so the
    scenario is handed over in sim/run.cfg instead (see gem_tb_pkg::get_scenario)
  * `--runall` is rejected by the wrapper while `-R` is accepted
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SIM = REPO / "sim"

RTL_SOURCES = ["rtl/gem_mac_stub.v"]

TB_SOURCES = [
    "tb/gem_tb_pkg.sv",
    "tb/rgmii_bfm.sv",
    "tb/assertions/gem_axis_sva.sv",
    "tb/assertions/gem_rgmii_sva.sv",
    "tb/assertions/gem_internal_sva.sv",
    "tb/tb_gem_mac_rx.sv",
    "tb/tb_gem_mac_tx.sv",
]

# Which testbench drives which direction.
TB_FOR_DIRECTION = {"rx": "tb_gem_mac_rx", "tx": "tb_gem_mac_tx"}


def vivado_bin(name: str) -> str:
    """Locate an XSim executable, preferring PATH, then the usual installs."""
    found = shutil.which(name) or shutil.which(name + ".bat")
    if found:
        return found

    env = os.environ.get("VIVADO_BIN")
    if env and (Path(env) / f"{name}.bat").exists():
        return str(Path(env) / f"{name}.bat")

    for root in (Path("D:/Vivado"), Path("C:/Xilinx/Vivado"), Path("/opt/Xilinx/Vivado")):
        if root.is_dir():
            for version in sorted(root.iterdir(), reverse=True):
                for candidate in (version / "bin" / f"{name}.bat", version / "bin" / name):
                    if candidate.exists():
                        return str(candidate)

    sys.exit(
        f"error: could not find {name}. Put Vivado's bin/ on PATH or set "
        f"VIVADO_BIN to it."
    )


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def scenarios_from_catalogue(include_random: bool) -> list[tuple[str, str]]:
    """Read the scenario list out of model/+gem/scenarios.m.

    Parsed rather than duplicated: the catalogue is the single source of truth
    for what the regression covers, and a second copy here would drift the
    first time a scenario is added.
    """
    text = (REPO / "model" / "+gem" / "scenarios.m").read_text(encoding="utf-8")
    pattern = re.compile(r"add\('([\w]+)',\s*'(rx|tx)',\s*(true|false)")

    out = []
    for name, direction, frozen in pattern.findall(text):
        if frozen == "true" or include_random:
            out.append((name, direction))
    return out


def compile_sources(xvlog: str) -> bool:
    print("==> Compiling")
    cmd = [xvlog, "-sv", "-i", str(REPO / "rtl")]
    cmd += [str(REPO / s) for s in RTL_SOURCES + TB_SOURCES]

    result = run(cmd, SIM)
    errors = [l for l in result.stdout.splitlines() if "ERROR" in l]
    if errors or result.returncode != 0:
        print("\n".join(errors) or result.stdout[-4000:])
        return False
    print("    ok")
    return True


def elaborate(xelab: str, tb: str, snapshot: str) -> bool:
    print(f"==> Elaborating {tb}")
    # -relax keeps XSim from rejecting the bind statements' parameter
    # overrides; assertions stay enabled, which is the whole point of binding
    # them in the first place.
    cmd = [xelab, "-debug", "typical", "-relax", tb, "-s", snapshot]
    result = run(cmd, SIM)

    errors = [l for l in result.stdout.splitlines() if "ERROR" in l]
    if errors or result.returncode != 0:
        print("\n".join(errors) or result.stdout[-4000:])
        return False
    print("    ok")
    return True


def run_scenario(xsim: str, snapshot: str, name: str) -> tuple[bool, str]:
    """Run one scenario. Returns (passed, one-line summary)."""
    vecdir = REPO / "model" / "vectors" / name
    if not vecdir.is_dir():
        return False, f"vectors missing -- run `make vectors` (looked in {vecdir})"

    # The scenario is handed over by file, not plusarg (see module docstring).
    (SIM / "run.cfg").write_text(f"{name}\n{vecdir.as_posix()}\n", encoding="utf-8")

    result = run([xsim, snapshot, "-R", "-log", f"{name}.log"], SIM)
    output = result.stdout

    (SIM / f"{name}.out").write_text(output, encoding="utf-8")

    if f"[gem_tb] PASS {name}" in output:
        checks = re.search(r"(\d+) checks, (\d+) failures", output)
        return True, f"{checks.group(1)} checks" if checks else "passed"

    fails = [l for l in output.splitlines() if l.startswith("FAIL ")]
    summary = fails[0][:150] if fails else "no PASS line -- see the log"
    return False, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", help="run only this scenario")
    parser.add_argument("--tb", help="run only scenarios for this testbench")
    parser.add_argument("--all", action="store_true",
                        help="include the large random sweeps")
    parser.add_argument("--no-compile", action="store_true",
                        help="reuse the existing snapshots")
    args = parser.parse_args()

    SIM.mkdir(exist_ok=True)

    xvlog, xelab, xsim = vivado_bin("xvlog"), vivado_bin("xelab"), vivado_bin("xsim")

    todo = scenarios_from_catalogue(args.all)
    if args.scenario:
        todo = [s for s in todo if s[0] == args.scenario]
        if not todo:
            sys.exit(f"error: no scenario named '{args.scenario}' in the catalogue")
    if args.tb:
        todo = [s for s in todo if TB_FOR_DIRECTION[s[1]] == args.tb]

    if not args.no_compile:
        if not compile_sources(xvlog):
            return 1
        for direction in sorted({d for _, d in todo}):
            tb = TB_FOR_DIRECTION[direction]
            if not elaborate(xelab, tb, tb):
                return 1

    print(f"\n==> Running {len(todo)} scenario(s)\n")
    results = []
    for name, direction in todo:
        passed, detail = run_scenario(xsim, TB_FOR_DIRECTION[direction], name)
        results.append((name, passed))
        status = "PASS" if passed else "FAIL"
        print(f"  {status}  {name:<22} {detail}")

    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)} of {len(results)} scenario(s) passed.")

    if failed:
        print("\nFailed: " + ", ".join(failed))
        print(f"Per-scenario output is in {SIM.relative_to(REPO)}/<scenario>.out")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
