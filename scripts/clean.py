#!/usr/bin/env python3
"""Remove build or simulation outputs.

Exists because `rm -rf` in a Makefile recipe is not portable to this project's
actual environment. GNU Make on Windows runs recipes through cmd.exe unless it
finds sh.exe on PATH, and cmd has no `rm`. The targets appeared to work only
because they happened to be invoked from Git Bash, which puts Git's rm.exe on
PATH -- from PowerShell or cmd, where a Windows user is most likely to run
make, they failed outright. Python is already a hard dependency of every other
Makefile target, so routing these through it too costs nothing and removes the
dependence on which shell happened to launch make.

Deliberately conservative about what it deletes: every path is resolved and
checked to be inside the repository before removal, so a mistyped pattern
cannot escape upwards. Nothing here is interactive, but nothing here should
ever be able to reach outside the project either.

Usage:
    python scripts/clean.py build
    python scripts/clean.py sim
    python scripts/clean.py all
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Directories and glob patterns, relative to the repo root.
TARGETS = {
    "build": [
        "build",
        ".Xil",
        "vivado*.jou",
        "vivado*.log",
    ],
    "sim": [
        "sim",
        "xsim.dir",
        "*.wdb",
        "*.pb",
        "xvlog.log",
        "xelab.log",
        "xsim.log",
        "xsim.jou",
    ],
}


def inside_repo(path: Path) -> bool:
    try:
        path.resolve().relative_to(REPO)
        return True
    except ValueError:
        return False


def remove(path: Path) -> str | None:
    """Remove one path. Returns a description if something was removed."""
    if not inside_repo(path):
        print(f"    refusing to remove {path} -- outside the repository")
        return None
    if not path.exists():
        return None

    if path.is_dir():
        shutil.rmtree(path, ignore_errors=True)
        return f"{path.relative_to(REPO)}/"
    path.unlink(missing_ok=True)
    return str(path.relative_to(REPO))


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("build", "sim", "all"):
        sys.exit(f"usage: {Path(__file__).name} build|sim|all")

    which = sys.argv[1]
    groups = ["build", "sim"] if which == "all" else [which]

    removed = []
    for group in groups:
        for pattern in TARGETS[group]:
            if any(c in pattern for c in "*?["):
                for match in REPO.glob(pattern):
                    got = remove(match)
                    if got:
                        removed.append(got)
            else:
                got = remove(REPO / pattern)
                if got:
                    removed.append(got)

    if removed:
        print(f"Removed {len(removed)}: {', '.join(sorted(removed))}")
    else:
        print("Nothing to remove.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
