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
    # Collapses the FIFO's per-octet drop into one event per frame, so the
    # rx_drop counter survives the crossing into tx_clk.
    "rtl/gem_rx_drop_episode.v",
    "rtl/gem_rx_egress.v",
    # V-25: closes a frame the link took away in band. Downstream of
    # gem_rx_egress; must be listed after it for anyone reading top-down.
    "rtl/gem_rx_abort.v",
    "rtl/gem_stats.v",
    "rtl/gem_mdio.v",
    "rtl/gem_mac.v",
    # Stage 5's clock/reset block. It sits beside gem_mac rather than inside
    # it -- it is what feeds gem_mac its clocks and resets -- so it is listed
    # here in its own right until the Stage 5 top level instantiates both.
    "rtl/gem_reset_sync.v",
    "rtl/gem_mmcm.v",
    # Stage 6 part 2: the RX deskew MMCM, instantiated by gem_clk_rst.
    "rtl/gem_rx_mmcm.v",
    "rtl/gem_clk_rst.v",
    # R17's readout (V-20, spec B.7 item 5).
    "rtl/gem_uart_tx.v",
    "rtl/gem_stat_report.v",
    # Stage 5's echo path (B.5 step 6), application logic above the MAC.
    "rtl/gem_echo.v",
    "rtl/gem_top.v",
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
    "tb/tb_gem_clk_rst.sv",
    "tb/tb_gem_uart_tx.sv",
    "tb/tb_gem_stat_report.sv",
    "tb/tb_gem_echo.sv",
    "tb/tb_gem_top.sv",
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

# The DDR primitive self-test, and why it is not just another unit testbench:
# every simulation above compiles rtl/ with GEM_BEHAVIORAL_IO, so the Xilinx
# IDDR/ODDR branches -- the code synthesis actually builds -- were elaborated
# by out-of-context synthesis and never executed by anything. tb_gem_ddr_io.sv
# runs them for real, including the PHY's RX_CLK skew that decides which half
# of each octet lands on IDDR's Q1 (the mapping V-17 got wrong). It therefore
# needs its own compile pass WITHOUT the define, its own work library, and the
# vendor's unisim libraries at elaboration.
PRIM_WORK     = "prim"
PRIM_SOURCES  = ["rtl/gem_iddr.v", "rtl/gem_oddr.v", "tb/tb_gem_ddr_io.sv"]
PRIM_SNAPSHOT = "ddr_prim_selftest"

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
#   tb_gem_clk_rst reset assert without a clock, release on an edge, and the
#                  two dependencies B.1b forbids. There is no data path here
#                  for the scenario regression to compare, so if this module is
#                  not checked here it is not checked at all.
#   tb_gem_uart_tx framing and baud, decoded by a receiver whose bit period
#                  comes from 115200 as a duration and never from the design's
#                  divider -- the only arrangement in which a wrong divisor
#                  cannot agree with itself.
#   tb_gem_stat_report
#                  the record R17's readout prints, compared against the whole
#                  line it should have printed, with every input changed the
#                  moment transmission starts so the snapshot has to hold.
#
# They run first, because a failure here explains a failure everywhere else.
UNIT_TBS = ["tb_gem_crc32", "tb_gem_rx_fifo", "tb_gem_mdio", "tb_gem_clk_rst",
            "tb_gem_uart_tx", "tb_gem_stat_report",
            "tb_gem_echo", "tb_gem_top"]

# The loopback runs the design against itself, so it takes a TX scenario's
# stimulus and needs no expected-output file of its own.
LOOPBACK_TB = "tb_gem_mac_loopback"
LOOPBACK_SCENARIOS = ["tx_clean_sweep", "tx_padding"]


# Where Vivado gets installed, and the two shapes the install takes.
#
# The layout difference is not cosmetic. A standalone Vivado install puts the
# executables at <root>/<version>/bin. AMD's *unified* installer -- which is
# what 2025.1 ships as -- puts them at <root>/<version>/Vivado/bin, because
# Vitis and Model Composer sit beside Vivado under the same version directory.
#
# Searching only the first layout is a failure worth naming, because the error
# it produced pointed at the wrong thing: on a machine with a perfectly good
# C:/Xilinx/2025.1/Vivado install, every target died with "could not find
# vivado ... put Vivado's bin/ on PATH", and the reader went off to audit PATH
# for a tool that was never missing. A locator that cannot see a stock install
# is worse than no locator, because it accuses the environment.
SEARCH_ROOTS = (
    Path("D:/Vivado"),
    Path("C:/Xilinx"),
    Path("C:/Xilinx/Vivado"),
    Path("/opt/Xilinx"),
    Path("/opt/Xilinx/Vivado"),
    Path("/tools/Xilinx/Vivado"),
)


def vivado_bin(name: str) -> str:
    """Locate an XSim executable, preferring PATH, then the usual installs."""
    found = shutil.which(name) or shutil.which(name + ".bat")
    if found:
        return found

    env = os.environ.get("VIVADO_BIN")
    if env and (Path(env) / f"{name}.bat").exists():
        return str(Path(env) / f"{name}.bat")

    # Reverse lexical order, so the newest version wins when several are
    # installed. That is a convenience, not a policy: the tool version a
    # bitstream was built with is part of its provenance (flow-doc Stage 9), so
    # pin it with VIVADO_BIN rather than trusting this to keep picking the same
    # one after the next install.
    for root in SEARCH_ROOTS:
        if not root.is_dir():
            continue
        for version in sorted(root.iterdir(), reverse=True):
            if not version.is_dir():
                continue
            for bindir in (version / "bin", version / "Vivado" / "bin"):
                for candidate in (bindir / f"{name}.bat", bindir / name):
                    if candidate.exists():
                        return str(candidate)

    sys.exit(
        f"error: could not find {name}. Put Vivado's bin/ on PATH or set "
        f"VIVADO_BIN to it."
    )


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess | None:
    """Run a tool, returning None on timeout rather than blocking forever.

    A hung xsim used to block `make check` indefinitely; now the invocation is
    killed and the caller reports the run as failed with why. The ceiling is
    generous -- seconds per run today -- and overridable with GEM_SIM_TIMEOUT
    for whoever runs on a machine slow enough to need it.
    """
    timeout = float(os.environ.get("GEM_SIM_TIMEOUT", "900"))
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"    TIMEOUT after {timeout:.0f}s: {' '.join(cmd[:2])} ...")
        return None


# Shared adjudication of simulator output. The PASS line a testbench prints is
# evidence, not verdict: it is believed only when everything around it agrees.
#   * the printed tally must say zero failures -- trusting "[gem_tb] PASS" alone
#     would make the gate's correctness depend on gem_tb_pkg's printing discipline;
#   * any "FAIL ..." line fails, even beside a PASS line (a testbench that
#     reports both has a bug, and the safe reading of a contradiction is "bad");
#   * any bound-assertion "Error:" line fails, PASS or not (see run_scenario).
PASS_MARK = "[gem_tb] PASS "
CHECKS_RE = re.compile(r"(\d+) checks, (\d+) failures")


def adjudicate(output: str) -> tuple[bool, str]:
    """Return (passed, one-line summary) for one simulator run."""
    lines = output.splitlines()
    sva = [l for l in lines if l.startswith("Error:")]
    fails = [l for l in lines if l.startswith("FAIL ")]
    checks = CHECKS_RE.search(output)

    tally_bad = checks is not None and int(checks.group(2)) != 0

    if not sva and not fails and not tally_bad and PASS_MARK in output:
        if checks:
            return True, f"{checks.group(1)} checks"
        return True, "passed"

    if sva and PASS_MARK in output and not fails and not tally_bad:
        # Data comparison passed but an assertion fired. This gets its own
        # message because it means the assertion layer earned its keep exactly
        # where a data-only checker would have reported green.
        return False, (f"data comparison passed but {len(sva)} assertion "
                       f"failure(s) fired -- first: {sva[0][7:].strip()[:100]}")

    if tally_bad:
        return False, f"tally says {checks.group(2)} failure(s): {checks.group(0)}"
    if fails:
        return False, fails[0][:150]
    if sva:
        return False, f"{len(sva)} assertion failure(s) -- first: {sva[0][7:].strip()[:100]}"
    return False, "no PASS line -- see the log"


def scenarios_from_catalogue(include_random: bool) -> list[tuple[str, str]]:
    """Read the scenario list out of model/+gem/scenarios.m.

    Parsed rather than duplicated: the catalogue is the single source of truth
    for what the regression covers, and a second copy here would drift the
    first time a scenario is added.

    Parsed catalogues fail in one specific silent way: the regex stops
    matching and the regression shrinks -- possibly to nothing -- while every
    layer around it stays green. So three refusals guard it:

      * catalogue file missing,
      * catalogue present but parsing to zero entries (formatting change),
      * asymmetry between the parsed frozen set and the directories of
        committed vectors, which catches the partial case -- one add() line
        renamed or reformatted leaves its vectors behind with no entry to
        claim them.
    """
    catalogue = REPO / "model" / "+gem" / "scenarios.m"
    if not catalogue.is_file():
        sys.exit(f"error: scenario catalogue not found: {catalogue}")

    text = catalogue.read_text(encoding="utf-8")
    pattern = re.compile(r"add\('([\w]+)',\s*'(rx|tx)',\s*(true|false)")
    found = pattern.findall(text)

    if not found:
        sys.exit(
            f"error: {catalogue} parsed to zero entries.\n"
            "  The file exists, so this is a parse failure (its add(...) lines\n"
            "  changed shape), not an empty catalogue. A regression that ran no\n"
            "  golden-vector scenario must not be able to report green.")

    vecroot = REPO / "model" / "vectors"
    on_disk = {d.name for d in vecroot.iterdir()
               if d.is_dir() and (d / "manifest.json").is_file()} \
        if vecroot.is_dir() else set()
    parsed_frozen = {n for n, _, frozen in found if frozen == "true"}
    parsed_random = {n for n, _, frozen in found if frozen != "true"}

    missing_vectors = sorted(parsed_frozen - on_disk)
    if missing_vectors:
        sys.exit("error: frozen scenario(s) with no committed vectors: "
                 + ", ".join(missing_vectors))

    unaccounted = sorted(on_disk - parsed_frozen - parsed_random)
    if unaccounted:
        sys.exit(
            "error: committed vector director(ies) that no catalogue entry "
            "claims: " + ", ".join(unaccounted)
            + "\n  Either scenarios.m changed shape and the parser missed an"
            "\n  entry, or vectors were committed without a catalogue row."
            "\n  Either way the regression would quietly shrink. Refusing to"
            "\n  guess which entries were lost.")

    return [(name, direction) for name, direction, frozen in found
            if frozen == "true" or include_random]


def compile_sources(xvlog: str) -> bool:
    print("==> Compiling")
    cmd = [xvlog, "-sv", "-i", str(REPO / "rtl")]
    for macro in RTL_DEFINES:
        cmd += ["-d", macro]
    cmd += [str(REPO / s) for s in RTL_SOURCES + TB_SOURCES]

    result = run(cmd, SIM)
    if result is None:
        return False
    errors = [l for l in result.stdout.splitlines() if "ERROR" in l]
    if errors or result.returncode != 0:
        print("\n".join(errors) or result.stdout[-4000:])
        return False
    print("    ok")
    return True


def compile_primitive_branch(xvlog: str) -> bool:
    """Compile the Xilinx IDDR/ODDR branches into their own work library.

    No GEM_BEHAVIORAL_IO here -- that is the entire point: every other
    compilation in this repository defines it, so the primitive code path
    synthesis actually builds is never the one simulation executes. The
    vendor's glbl.v is compiled alongside so the primitives' global signals
    resolve, and the install's xsim.ini is copied beside the run so xelab can
    find unisims_ver.
    """
    viv_root = Path(xvlog).resolve().parents[1]

    ini_src = viv_root / "data" / "xsim" / "xsim.ini"
    ini_dst = SIM / "xsim.ini"
    if not ini_dst.exists():
        if not ini_src.is_file():
            print(f"error: {ini_src} not found; cannot set up unisim libraries.")
            return False
        shutil.copyfile(ini_src, ini_dst)

    glbl = viv_root / "data" / "verilog" / "src" / "glbl.v"
    files = [str(REPO / s) for s in PRIM_SOURCES]
    if glbl.is_file():
        files.append(str(glbl))
    else:
        print(f"note: {glbl} not found -- elaborating without glbl.")

    print("==> Compiling DDR primitive branch (no GEM_BEHAVIORAL_IO)")
    cmd = [xvlog, "-sv", "-work", PRIM_WORK] + files
    result = run(cmd, SIM)
    if result is None:
        return False
    errors = [l for l in result.stdout.splitlines() if "ERROR" in l]
    if errors or result.returncode != 0:
        print("\n".join(errors) or result.stdout[-4000:])
        return False
    print("    ok")
    return True


def elaborate_primitives(xelab: str) -> bool:
    print(f"==> Elaborating {PRIM_SNAPSHOT} (unisims_ver)")
    # -L unisims_ver resolves the IDDR/ODDR definitions from the vendor's
    # precompiled simulation libraries (mapped by the xsim.ini copied above).
    cmd = [xelab, "-debug", "typical", "-relax",
           f"{PRIM_WORK}.tb_gem_ddr_io", f"{PRIM_WORK}.glbl",
           "-L", "unisims_ver",
           "-s", PRIM_SNAPSHOT]
    result = run(cmd, SIM)
    if result is None:
        return False
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
    if result is None:
        (SIM / f"{tag}.out").write_text(
            f"[run_sim] killed: xsim exceeded the time limit on {tag}\n",
            encoding="utf-8")
        return False, "timed out -- see the .out file"
    output = result.stdout

    (SIM / f"{tag}.out").write_text(output, encoding="utf-8")

    return adjudicate(output)


def run_unit(xsim: str, tb: str) -> tuple[bool, str]:
    """Run a per-module testbench. No vectors, so no run.cfg to hand over."""
    result = run([xsim, tb, "-R", "-log", f"{tb}.log"], SIM)
    if result is None:
        (SIM / f"{tb}.out").write_text(
            f"[run_sim] killed: xsim exceeded the time limit on {tb}\n",
            encoding="utf-8")
        return False, "timed out -- see the .out file"
    output = result.stdout
    (SIM / f"{tb}.out").write_text(output, encoding="utf-8")

    return adjudicate(output)


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
    # scenario list, not scenarios themselves. The DDR primitive self-test
    # belongs to the same full-run layer.
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
        if run_units:
            # The primitive branch compiles into its own library from its own
            # pass (no GEM_BEHAVIORAL_IO), so it is built after the main flow,
            # not instead of it.
            if not compile_primitive_branch(xvlog):
                return 1
            if not elaborate_primitives(xelab):
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

        # The primitive branch runs beside them: like the harness self-tests,
        # it covers something every other run structurally skips.
        print("\n==> DDR primitive branch\n")
        passed, detail = run_unit(xsim, PRIM_SNAPSHOT)
        results.append((PRIM_SNAPSHOT, passed))
        print(f"  {'PASS' if passed else 'FAIL'}  {PRIM_SNAPSHOT:<24} {detail}")

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
