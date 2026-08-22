#!/usr/bin/env python3
"""Check that the committed vector files still match what the model produces.

The frozen scenarios under model/vectors/ are committed so the regression can
run without MATLAB and so a reviewer can read them. That convenience comes with
a hazard: change the golden model and the committed vectors become a fossil,
and the regression carries on comparing the design against the *old* model's
opinion. Nothing about that failure looks like staleness -- it looks like a
design bug, and it is a design bug that is not there.

So: regenerate the frozen set into a temporary directory and diff it against
what is committed. Any difference means one of two things, and the message says
which to suspect:

  * the model changed deliberately  -> run `make vectors` and commit the result
  * the model changed accidentally  -> that is the bug, go and find it

manifest.json is excluded because it carries a generation timestamp. Everything
else in each scenario directory is compared byte for byte -- the comparison is
a directory diff, not a name whitelist, so a sixth artifact the model starts
emitting is compared rather than silently ignored, and a file the model stops
emitting is reported as the fossil it has become.

Usage:
    python scripts/check_vectors.py
    python scripts/check_vectors.py --matlab "C:/Program Files/MATLAB/R2025b/bin/matlab"
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VECTORS = REPO / "model" / "vectors"

# The one file never compared, and the only one: manifest.json records when it
# was generated. Everything else in a scenario directory is diffed, by name and
# then byte for byte -- a whitelist of expected filenames here would silently
# exempt whatever the model starts emitting next from both halves of this
# gate's job (staleness detection and committed-set completeness).


def find_matlab(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = shutil.which("matlab")
    if found:
        return found
    for root in (Path("C:/Program Files/MATLAB"), Path("/usr/local/MATLAB")):
        if root.is_dir():
            for version in sorted(root.iterdir(), reverse=True):
                for candidate in (version / "bin" / "matlab.exe",
                                  version / "bin" / "matlab"):
                    if candidate.exists():
                        return str(candidate)
    sys.exit("error: could not find matlab. Put it on PATH or pass --matlab.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matlab", help="path to the MATLAB executable")
    args = parser.parse_args()

    matlab = find_matlab(args.matlab)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        print(f"==> Regenerating the frozen set into {tmp_path}")

        script = (
            "addpath('model'); "
            f"genVectors('Set', 'frozen', 'Dir', '{tmp_path.as_posix()}');"
        )
        result = subprocess.run([matlab, "-batch", script],
                                cwd=REPO, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout[-4000:])
            print(result.stderr[-2000:], file=sys.stderr)
            print("error: regeneration failed -- the model itself is broken, "
                  "so staleness is not the question yet.")
            return 1

        stale: list[str] = []
        missing: list[str] = []
        fossils: list[str] = []
        checked = 0

        for scenario_dir in sorted(tmp_path.iterdir()):
            if not scenario_dir.is_dir():
                continue
            committed = VECTORS / scenario_dir.name

            # Directory diff, not a whitelist: whatever the generator emitted
            # is exactly what must be committed, under the same name.
            fresh_files = {p.name for p in scenario_dir.iterdir()
                           if p.is_file() and p.name != "manifest.json"}

            if not committed.is_dir():
                missing.extend(f"{scenario_dir.name}/{f}"
                               for f in sorted(fresh_files))
                continue

            committed_files = {p.name for p in committed.iterdir()
                               if p.is_file() and p.name != "manifest.json"}

            for filename in sorted(fresh_files - committed_files):
                missing.append(f"{scenario_dir.name}/{filename}")

            for filename in sorted(committed_files - fresh_files):
                fossils.append(f"{scenario_dir.name}/{filename}")

            for filename in sorted(fresh_files & committed_files):
                checked += 1
                if not filecmp.cmp(scenario_dir / filename,
                                   committed / filename, shallow=False):
                    stale.append(f"{scenario_dir.name}/{filename}")

        # A scenario directory that is committed but no longer generated is a
        # fossil the rest of this check cannot see: it only walks what was just
        # produced. Left alone it sits in the repo looking authoritative, and
        # run_sim.py will happily run it if someone names it directly.
        generated = {d.name for d in tmp_path.iterdir() if d.is_dir()}
        orphaned = sorted(
            d.name for d in VECTORS.iterdir()
            if d.is_dir() and d.name not in generated and not d.name.startswith("random_")
        )

        print(f"    compared {checked} file(s)")

        if orphaned:
            print(f"\n{len(orphaned)} committed scenario director(ies) are no longer generated:")
            for name in orphaned:
                print(f"    {name}")
            print("\nThe catalogue in model/+gem/scenarios.m no longer produces these.")
            print("Delete them, or put the scenario back.")
            return 1

        if not stale and not missing and not fossils:
            print("\nCommitted vectors are up to date with the model.")
            return 0

        if fossils:
            print(f"\n{len(fossils)} committed file(s) are no longer generated:")
            for name in fossils:
                print(f"    {name}")

        if missing:
            print(f"\n{len(missing)} generated file(s) are not committed:")
            for name in missing:
                print(f"    {name}")

        if stale:
            print(f"\n{len(stale)} committed file(s) no longer match the model:")
            for name in stale:
                print(f"    {name}")

        print(
            "\nThe golden model and the committed vectors disagree.\n"
            "  If the model change was intended: run `make vectors` and commit.\n"
            "  If it was not: this is the bug -- the regression has been\n"
            "  comparing the design against a stale reference."
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
