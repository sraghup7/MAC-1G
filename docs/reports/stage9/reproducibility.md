# Stage 9 — the reproducibility check

Stage 9's first item, verbatim from `fpga_project_flow.md`:

> **Reproducibility check** — clone the repo fresh, run one command, get a
> bit-identical bitstream. If that fails, the design is captured in your
> machine's state and your memory, not in version control.

**Result: passed.** A fresh clone of `charan/dev` at `c5be581` produced a
bitstream whose configuration payload is byte-identical to the one built in
the working tree.

## What was run

```
git clone --no-hardlinks --branch charan/dev <repo> <scratch>/clone
cd <scratch>/clone
python scripts/build.py bitstream gem_top
```

One command after the clone. No manual step, no environment fix-up, no
submodule initialisation (the vendored `reference/` tree is reading material,
not a build input — `scripts/build.tcl` globs `rtl/*.v` and never reaches it).

The clone came up clean: `git status --porcelain` empty, 24 files in `rtl/`.
That is worth stating rather than assuming, because this repository has been
bitten there before — `.gitattributes` once let a fresh clone rewrite the
committed vectors to CRLF, and the resulting failure blamed the golden model
rather than the checkout. A clone that arrives dirty is the same class of
defect one layer up.

All nine gates passed in the clone, in order: critical-warning cleanliness
(before and after implementation), the RX capture-clock anchor, both latch
checks, constraint coverage, slack (with the five fenced RX waivers), CDC,
and physical DRC plus route status.

## The comparison, and why it is not a naive `cmp`

The two `.bit` files differ in exactly **4 bytes**, at offsets 94, 95, 97 and
98:

```
reference : 25 \0 d \0 \t 0 9 : 0 0 : 1 9 \0 e ...
clone     : 25 \0 d \0 \t 0 9 : 4 9 : 0 6 \0 e ...
                            ^^^^^^^^^^^
```

That is field `d` of the `.bit` header — the build **time**, as ASCII —
immediately before field `e`, which carries the length and then the
configuration payload. `09:00:19` against `09:49:06`: the two builds ran
forty-nine minutes apart, and the header records it.

Everything else matches:

```
$ cmp <(tail -c +129 build/gem_top.bit) \
      <(tail -c +129 <scratch>/clone/build/gem_top.bit)
(no output)
```

**2,191,988 bytes of configuration payload, byte-identical.** Both files are
2,192,116 bytes total.

So a byte-for-byte `cmp` of the whole file *fails*, and reporting that as a
reproducibility failure would be wrong. The claim Stage 9 actually cares about
is that the same sources and the same tool produce the same silicon
configuration, and they do. The embedded timestamp is metadata about when the
file was written, not about what it configures. Anyone re-running this check
should skip the header rather than widen a tolerance, and should confirm the
differing bytes really are the timestamp — as above — rather than assume it.

## What this does and does not establish

**Does:** the design is captured in version control. A clone on this machine,
with this tool, reproduces the shipped configuration exactly. Nothing
load-bearing lives in the working tree's accumulated state.

**Does not:** this was run on the same machine and the same Vivado 2024.2
install. It is the reproducibility half of Stage 9, not the portability half.
A different machine, or a different tool version, is a separate question — and
`fpga_project_flow.md` is explicit that tool version is part of a release's
identity ("a design that closed timing in one may not in the next"). Recording
the tool version alongside a tag is Stage 9's next item and is not done yet.
