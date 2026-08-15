# gem_mac build and verification entry points. Wraps scripts/build.tcl
# (non-project mode, fpga_project_flow.md Stage 2) and scripts/run_sim.py
# (Stage 3) so each flow is one command, not a sequence someone has to
# remember.
#
# Tool paths can be overridden if they aren't on PATH, e.g.:
#   make bitstream VIVADO="D:/Vivado/2024.2/bin/vivado.bat"
#   make regress   VIVADO_BIN="D:/Vivado/2024.2/bin"

VIVADO    ?= vivado
MATLAB    ?= matlab
PYTHON    ?= python
VERILATOR ?= verilator
BUILD_DIR := build
SIM_DIR   := sim

.PHONY: help synth impl bitstream program clean \
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

# R22: zero warnings, suppressions require a justifying comment. Verilator is
# not installed here yet; the target says so plainly rather than reporting
# success for a check that did not run -- "silently passed because the tool was
# missing" is the worst outcome a quality gate can have.
# R22. Driven from Python rather than inline so the gate behaves the same from
# Windows -- where Verilator lives inside WSL -- as it does on a Linux box, and
# so "verilator is missing" stays an error rather than becoming a silent skip.
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

# ---- Stage 2: build -------------------------------------------------------

synth:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs synth

impl:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs impl

bitstream:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs bitstream

program: bitstream
	$(VIVADO) -mode batch -source scripts/program.tcl -tclargs $(BUILD_DIR)/skeleton_top.bit

# Via Python rather than `rm -rf`, which is not portable to the shell make
# actually gets here. See the note in scripts/clean.py: these targets only ever
# worked when make happened to be launched from Git Bash.
clean:
	$(PYTHON) scripts/clean.py build

clean-sim:
	$(PYTHON) scripts/clean.py sim
