# MAC1G

## Git workflow

`main` holds final, confirmed work only. Everything reaches it through a branch.

**Never commit directly to `main`, and never push to `main` without being asked to.**
This holds even when a change is small, obviously correct, or urgent.

Day to day:

- Work happens on the branch that is currently checked out, which must not be `main`.
  If `main` is checked out when work is about to start, stop and ask which branch to use.
- Current working branches: `charan/dev` (Sai Charan), `fix/*` (Vijay Yellapu).
- Commit freely to the working branch. Diverging from `main` is the point of it.
- A change reaches `main` only after it has been verified, and only when the user says so.

Merging into `main`, once the user confirms:

```
git checkout main
git merge <branch>
git push
```

Before any merge into `main`, and periodically during long stretches of work, pull
`main` back into the working branch first so conflicts surface in the branch rather
than at the merge:

```
git checkout <branch>
git merge main
```

The primary shell here is Windows PowerShell 5.1, which does not accept `&&` as a
statement separator. Give shell commands one per line rather than chained, so they
work as written on either platform.

## Verifying before a merge

"Verified" means the checks were run and passed, not that the change looks right.
Report what was run and what it said. If a check could not be run, say so plainly
rather than merging on the assumption it would have passed.

The vector gate (`scripts/check_vectors.py`, via `make vectors-check`) regenerates
the golden vectors and compares them byte for byte against the committed ones, so it
is sensitive to line-ending corruption as well as model drift. `.gitattributes` pins
`model/vectors/**` to `-text` to keep Git from rewriting them on checkout; do not
reorder that file, since the last matching pattern wins and a catch-all placed below
a narrow rule silently overrides it.

## Error messages

Do not point the reader at a file, script, or command without confirming it exists.
An error that misdirects costs more than one that simply states the failure.
