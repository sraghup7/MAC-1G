# gem_mac build and verification entry points. Wraps scripts/build.tcl
# (non-project mode, fpga_project_flow.md Stage 2) and scripts/run_sim.py
# (Stage 3) so each flow is one command, not a sequence someone has to
# remember.
#
# Every target that needs Vivado, Verilator or MATLAB goes through a script in
# scripts/ that locates the tool itself, so none of them has to be on PATH.
# Override a search with an environment variable if needed:
#   VIVADO_BIN="D:/Vivado/2024.2/bin"    (run_sim.py, build.py)
#   python scripts/lint.py --verilator <path>
#
# MATLAB is invoked directly because -batch is the whole interface and it is on
# PATH here; if that stops being true it gets the same treatment.

MATLAB    ?= matlab
PYTHON    ?= python
BUILD_DIR := build
SIM_DIR   := sim

.PHONY: help synth oocsynth impl bitstream program clean \
        model vectors vectors-frozen vectors-check lint sim regress regress-all \
        check clean-sim

# Printed with $(info) rather than a stack of @echo lines, because @echo is not
# portable across the shells this repo actually runs under: make here comes from
# Vivado's gnuwin bundle and drives cmd.exe, where `echo "text"` prints the
# quotes literally and a bare `echo` prints "ECHO is on." $(info) is expanded by
# make itself, never reaches a shell, and so reads identically on cmd, sh and
# WSL. The `@:` gives the target a no-op command to run afterwards.
define HELP_TEXT

Verification (Stage 3):
  make model            run the golden model's own test suite
  make vectors          regenerate every scenario's vector files
  make vectors-frozen   regenerate only the committed directed set
  make vectors-check    committed vectors still match the model?
  make lint             Verilator --lint-only on the RTL (R22)
  make sim S=rx_min_gap run one scenario
  make regress          run every frozen scenario (the gate)
  make regress-all      ... including the large random sweeps
  make check            model, vectors-check, lint, regress -- the whole thing

Build (Stage 2):
  make synth impl bitstream program

Build (Stage 4 step 6):
  make oocsynth         gem_mac out of context: area, timing, B.2 budget
  make oocsynth M=gem_crc32   ... one module alone

  make clean            remove build outputs
  make clean-sim        remove simulation outputs

endef

help:
	$(info $(HELP_TEXT))
	@:

# ---- Stage 3: verification ------------------------------------------------

# The golden model validates itself before anything compares a design against
# it. Nothing else in this file means much if this target is red.
model:
	$(MATLAB) -batch "addpath('model'); runModelTests('Exit', true);"

vectors:
	$(MATLAB) -batch "addpath('model'); genVectors('Exit', true);"

vectors-frozen:
	$(MATLAB) -batch "addpath('model'); genVectors('Set', 'frozen', 'Exit', true);"

# The committed vectors are a convenience -- they let the regression run without
# MATLAB and let a reviewer read them -- and the hazard that comes with the
# convenience is that an edited model leaves them a fossil. Then the regression
# keeps comparing the design against the *old* model's opinion, and the failure
# looks exactly like a design bug that is not there. This is the check that
# makes that impossible rather than merely unlikely.
vectors-check:
	$(PYTHON) scripts/check_vectors.py

# R22: zero warnings, and suppressions require a justifying comment in the
# source. Driven from Python so the gate behaves the same from Windows -- where
# Verilator lives inside WSL -- as on a Linux box, and so "verilator is missing"
# stays an error rather than becoming a silent skip.
lint:
	$(PYTHON) scripts/lint.py

S ?= rx_min_gap
sim:
	$(PYTHON) scripts/run_sim.py --scenario $(S)

regress:
	$(PYTHON) scripts/run_sim.py

regress-all:
	$(PYTHON) scripts/run_sim.py --all

# Everything, in the order that makes a failure diagnosable: validate the model
# first, then that the committed vectors still reflect it, then lint (cheap,
# and a lint error explains a lot of simulation nonsense), then the design
# against the vectors. Running these the other way round means debugging a
# design against a reference nobody has checked.
check: model vectors-check lint regress

# The order in `check` is the point, so never let -j shuffle it. Each gate's
# output is also meant to be read in sequence when one fails.
.NOTPARALLEL:

# ---- Stage 2: build -------------------------------------------------------

# Through Python for the same reason lint and clean are: `vivado` is not on
# PATH here, so a bare invocation died with "cannot find the file specified"
# and these four targets had never been runnable. scripts/build.py reuses
# run_sim.py's locator rather than carrying a second copy of it.
synth:
	$(PYTHON) scripts/build.py synth

# Stage 4 step 6. M=<module> synthesises one module alone; the default is the
# whole MAC, out of context, checked against B.2's resource budget.
M ?=
oocsynth:
	$(PYTHON) scripts/build.py oocsynth $(M)

impl:
	$(PYTHON) scripts/build.py impl

bitstream:
	$(PYTHON) scripts/build.py bitstream

program: bitstream
	$(PYTHON) scripts/build.py program $(BUILD_DIR)/skeleton_top.bit

# Via Python rather than `rm -rf`, which is not portable to the shell make
# actually gets here. See the note in scripts/clean.py: these targets only ever
# worked when make happened to be launched from Git Bash.
clean:
	$(PYTHON) scripts/clean.py build

clean-sim:
	$(PYTHON) scripts/clean.py sim
