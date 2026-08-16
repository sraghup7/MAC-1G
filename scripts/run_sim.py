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

# The design, leaves first. Order does not matter to xvlog, but reading it
# top-down here is the fastest way to see what the hierarchy is.
RTL_SOURCES = [
    "rtl/gem_oddr.v",
    "rtl/gem_iddr.v",
    "rtl/gem_crc32.v",
    "rtl/gem_pulse_sync.v",
    "rtl/gem_rgmii_tx.v",
    "rtl/gem_rgmii_rx.v",
    "rtl/gem_tx_ingress.v",
    "rtl/gem_tx_engine.v",
    "rtl/gem_rx_deframe.v",
    "rtl/gem_rx_fifo.v",
    "rtl/gem_rx_egress.v",
    "rtl/gem_stats.v",
    "rtl/gem_mdio.v",
    "rtl/gem_mac.v",
]

# Simulation gets the plain-Verilog models of the DDR I/O cells; synthesis gets
# the Xilinx primitives. rtl/gem_oddr.v explains why that is the direction the
# default points in.
RTL_DEFINES = ["GEM_BEHAVIORAL_IO"]

TB_SOURCES = [
    "tb/gem_tb_pkg.sv",
    "tb/rgmii_bfm.sv",
    "tb/axis_tx_driver.sv",
    "tb/assertions/gem_axis_sva.sv",
    "tb/assertions/gem_rgmii_sva.sv",
    "tb/assertions/gem_internal_sva.sv",
    "tb/tb_gem_crc32.sv",
    "tb/tb_gem_rx_fifo.sv",
    "tb/tb_gem_mdio.sv",
    "tb/tb_rgmii_bfm.sv",
    "tb/tb_axis_tx_driver.sv",
    "tb/tb_gem_mac_rx.sv",
    "tb/tb_gem_mac_tx.sv",
    "tb/tb_gem_mac_loopback.sv",
]

# Which testbench drives which direction.
TB_FOR_DIRECTION = {"rx": "tb_gem_mac_rx", "tx": "tb_gem_mac_tx"}

# Harness self-tests. Neither has a DUT in it, so both pass today, and they are
# what to run first when something downstream looks impossible: they check the
# things every other result silently depends on. Each names the vectors it
# borrows -- it is exercising the harness, not those vectors.
#
# Both exist because the harness had real bugs that masqueraded as design bugs:
# the RGMII monitor sampled on the wrong clock phases, and nothing would have
# noticed the TX driver stalling in the wrong place.
SELFTESTS = [
    ("tb_rgmii_bfm",     "rx_min_gap",  "rgmii_bfm_selftest"),
    ("tb_axis_tx_driver", "tx_underrun", "axis_tx_driver_selftest"),
]

# Per-module testbenches (Stage 4 step 4: "write its self-checking testbench",
# before the module is integrated). None of them reads a vector file -- each
# builds its own stimulus and checks a property the integrated regression
# cannot isolate:
#
#   tb_gem_crc32   the published CRC-32 check value and the residue, which come
#                  from outside this project. The scenario regression compares
#                  the design against the golden model, so a model that was
#                  wrong about the CRC would agree with an RTL that was wrong
#                  the same way. These numbers do not come from either.
#   tb_gem_rx_fifo the async FIFO at full, at empty, and with the two clocks
#                  running at unrelated rates -- none of which the integrated
#                  tests reach, because R18's contract keeps it nearly empty.
#   tb_gem_mdio    Clause 22 framing against a PHY register-file model (V-3).
#
# They run first, because a failure here explains a failure everywhere else.
UNIT_TBS = ["tb_gem_crc32", "tb_gem_rx_fifo", "tb_gem_mdio"]

# The loopback runs the design against itself, so it takes a TX scenario's
# stimulus and needs no expected-output file of its own.
LOOPBACK_TB = "tb_gem_mac_loopback"
LOOPBACK_SCENARIOS = ["tx_clean_sweep", "tx_padding"]


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
    for macro in RTL_DEFINES:
        cmd += ["-d", macro]
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


def run_scenario(xsim: str, snapshot: str, name: str,
                 label: str | None = None) -> tuple[bool, str]:
    """Run one scenario. Returns (passed, one-line summary).

    `label` names the run in the log and the PASS line when the testbench
    reports under a name of its own (the BFM self-test) or when the same
    scenario is run by more than one testbench (the loopback).
    """
    vecdir = REPO / "model" / "vectors" / name
    if not vecdir.is_dir():
        return False, f"vectors missing -- run `make vectors` (looked in {vecdir})"

    # The scenario is handed over by file, not plusarg (see module docstring).
    (SIM / "run.cfg").write_text(f"{name}\n{vecdir.as_posix()}\n", encoding="utf-8")

    tag = label or name
    result = run([xsim, snapshot, "-R", "-log", f"{tag}.log"], SIM)
    output = result.stdout

    (SIM / f"{tag}.out").write_text(output, encoding="utf-8")

    # Bound SVA failures do NOT route through gem_tb_pkg's fail_count -- an
    # assert's $error goes straight to the simulator log. So a scenario whose
    # data comparison passed while an assertion fired would print
    # "[gem_tb] PASS" and, without this, be reported as passing. That would
    # make the whole assertion layer decorative exactly when it starts
    # mattering: today every scenario fails anyway, so the hole is invisible,
    # and it would have debuted in Stage 4 on the first scenario that went
    # green.
    sva = [l for l in output.splitlines() if l.startswith("Error:")]

    if "[gem_tb] PASS " in output and not sva:
        checks = re.search(r"(\d+) checks, (\d+) failures", output)
        return True, f"{checks.group(1)} checks" if checks else "passed"

    if sva and "[gem_tb] PASS " in output:
        return False, (f"data comparison passed but {len(sva)} assertion failure(s) fired -- "
                       f"first: {sva[0][7:].strip()[:100]}")

    fails = [l for l in output.splitlines() if l.startswith("FAIL ")]
    if fails:
        summary = fails[0][:150]
    elif sva:
        summary = f"{len(sva)} assertion failure(s) -- first: {sva[0][7:].strip()[:100]}"
    else:
        summary = "no PASS line -- see the log"
    return False, summary


def run_unit(xsim: str, tb: str) -> tuple[bool, str]:
    """Run a per-module testbench. No vectors, so no run.cfg to hand over."""
    result = run([xsim, tb, "-R", "-log", f"{tb}.log"], SIM)
    output = result.stdout
    (SIM / f"{tb}.out").write_text(output, encoding="utf-8")

    sva = [l for l in output.splitlines() if l.startswith("Error:")]
    if "[gem_tb] PASS " in output and not sva:
        checks = re.search(r"(\d+) checks, (\d+) failures", output)
        return True, f"{checks.group(1)} checks" if checks else "passed"

    fails = [l for l in output.splitlines() if l.startswith("FAIL ")]
    if fails:
        return False, fails[0][:150]
    if sva:
        return False, f"{len(sva)} assertion failure(s) -- first: {sva[0][7:].strip()[:100]}"
    return False, "no PASS line -- see the log"


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
        known_tbs = set(TB_FOR_DIRECTION.values()) | {LOOPBACK_TB} \
                    | {tb for tb, _, _ in SELFTESTS}
        if args.tb not in known_tbs:
            sys.exit(f"error: unknown testbench '{args.tb}'. "
                     f"Known: {', '.join(sorted(known_tbs))}")
        todo = [s for s in todo if TB_FOR_DIRECTION.get(s[1]) == args.tb]

    # The BFM self-test and the loopback are extra runs layered on top of the
    # scenario list, not scenarios themselves.
    run_units = not args.scenario and not args.tb
    run_bfm = not args.scenario and not args.tb
    run_loopback = not args.scenario and (not args.tb or args.tb == LOOPBACK_TB)

    if not args.no_compile:
        if not compile_sources(xvlog):
            return 1
        needed = {TB_FOR_DIRECTION[d] for _, d in todo}
        if run_units:
            needed.update(UNIT_TBS)
        if run_bfm:
            for tb, _, _ in SELFTESTS:
                needed.add(tb)
        if run_loopback:
            needed.add(LOOPBACK_TB)
        for tb in sorted(needed):
            if not elaborate(xelab, tb, tb):
                return 1

    results = []

    # Per-module tests before anything integrated: they are the cheapest layer
    # that can fail, and each one isolates a module the scenarios can only
    # reach through everything else.
    if run_units:
        print("\n==> Per-module testbenches\n")
        for tb in UNIT_TBS:
            passed, detail = run_unit(xsim, tb)
            results.append((tb, passed))
            print(f"  {'PASS' if passed else 'FAIL'}  {tb:<24} {detail}")

    # Self-tests first. If the harness is wrong, every result after it is
    # noise -- and these are the only runs with no DUT in them, so they are
    # also the only ones expected to pass today.
    if run_bfm:
        print("\n==> Harness self-tests\n")
        for tb, vectors, label in SELFTESTS:
            passed, detail = run_scenario(xsim, tb, vectors, label=label)
            results.append((label, passed))
            print(f"  {'PASS' if passed else 'FAIL'}  {label:<24} {detail}")

    print(f"\n==> Running {len(todo)} scenario(s)\n")
    for name, direction in todo:
        passed, detail = run_scenario(xsim, TB_FOR_DIRECTION[direction], name)
        results.append((name, passed))
        status = "PASS" if passed else "FAIL"
        print(f"  {status}  {name:<22} {detail}")

    if run_loopback:
        print("\n==> Loopback (the design against itself)\n")
        for name in LOOPBACK_SCENARIOS:
            label = f"loopback_{name}"
            passed, detail = run_scenario(xsim, LOOPBACK_TB, name, label=label)
            results.append((label, passed))
            print(f"  {'PASS' if passed else 'FAIL'}  {label:<22} {detail}")

    # A run that executed nothing must not report success. `--tb tb_rgmii_bfm`
    # used to select zero scenarios, skip the self-tests and the loopback, print
    # "0 of 0 scenario(s) passed" and exit 0 -- a gate reporting green for work
    # it never did, which is the one thing a gate must never do.
    if not results:
        print("\nerror: that selection ran nothing. Nothing passed, because "
              "nothing was executed.")
        return 1

    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)} of {len(results)} scenario(s) passed.")

    if failed:
        print("\nFailed: " + ", ".join(failed))
        print(f"Per-scenario output is in {SIM.relative_to(REPO)}/<scenario>.out")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
