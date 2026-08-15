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
    """True only for paths strictly below the repo root.

    The repo root itself is excluded deliberately. Nothing in TARGETS can
    resolve to it today, but a future empty or mistyped pattern could, and the
    difference between "removed build/" and "removed the repository" should not
    rest on the pattern list staying correct.
    """
    try:
        rel = path.resolve().relative_to(REPO)
    except ValueError:
        return False
    return rel != Path(".")


def remove(path: Path) -> str | None:
    """Remove one path. Returns a description if something was removed."""
    if not inside_repo(path):
        print(f"    refusing to remove {path} -- outside the repository")
        return None
    if not path.exists():
        return None

    label = f"{path.relative_to(REPO)}/" if path.is_dir() else str(path.relative_to(REPO))

    # Errors are NOT ignored. shutil.rmtree(ignore_errors=True) would let this
    # print "Removed build/" while build/ was still there -- a file held open by
    # Vivado is the ordinary way that happens -- and a clean that reports work
    # it did not do sends the next person debugging a stale artifact they were
    # told had been deleted.
    try:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
    except OSError as exc:
        print(f"    could not remove {label}: {exc}")
        return None

    if path.exists():
        print(f"    {label} still present after removal")
        return None
    return label


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("build", "sim", "all"):
        sys.exit(f"usage: {Path(__file__).name} build|sim|all")

    which = sys.argv[1]
    groups = ["build", "sim"] if which == "all" else [which]

    removed = []
    attempted = 0
    for group in groups:
        for pattern in TARGETS[group]:
            if any(c in pattern for c in "*?["):
                for match in REPO.glob(pattern):
                    attempted += 1
                    got = remove(match)
                    if got:
                        removed.append(got)
            else:
                target = REPO / pattern
                if target.exists():
                    attempted += 1
                got = remove(target)
                if got:
                    removed.append(got)

    if removed:
        print(f"Removed {len(removed)}: {', '.join(sorted(removed))}")
    elif attempted == 0:
        print("Nothing to remove.")

    if len(removed) != attempted:
        print(f"\n{attempted - len(removed)} item(s) could not be removed "
              f"(see above). Something is probably still holding them open.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
