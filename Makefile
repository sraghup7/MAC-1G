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

help:
	@echo "Verification (Stage 3):"
	@echo "  make model            run the golden model's own test suite"
	@echo "  make vectors          regenerate every scenario's vector files"
	@echo "  make vectors-frozen   regenerate only the committed directed set"
	@echo "  make vectors-check    committed vectors still match the model?"
	@echo "  make lint             Verilator --lint-only on the RTL (R22)"
	@echo "  make sim S=rx_min_gap run one scenario"
	@echo "  make regress          run every frozen scenario (the gate)"
	@echo "  make regress-all      ... including the large random sweeps"
	@echo ""
	@echo "Build (Stage 2):"
	@echo "  make synth impl bitstream program"
	@echo ""
	@echo "  make clean            remove build outputs"
	@echo "  make clean-sim        remove simulation outputs"

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
lint:
	@command -v $(VERILATOR) >/dev/null 2>&1 || { \
	  echo "ERROR: verilator not found. Install it, or set VERILATOR=<path>."; \
	  echo "       R22 requires a clean lint; this target will not pass by default."; \
	  exit 1; }
	$(VERILATOR) --lint-only -Wall -Irtl rtl/gem_mac_stub.v

S ?= rx_min_gap
sim:
	$(PYTHON) scripts/run_sim.py --scenario $(S)

regress:
	$(PYTHON) scripts/run_sim.py

regress-all:
	$(PYTHON) scripts/run_sim.py --all

# Everything, in the order that makes a failure diagnosable: validate the model
# first, then that the committed vectors still reflect it, then the design
# against them. Running these the other way round means debugging a design
# against a reference nobody has checked.
check: model vectors-check regress

# ---- Stage 2: build -------------------------------------------------------

synth:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs synth

impl:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs impl

bitstream:
	$(VIVADO) -mode batch -source scripts/build.tcl -tclargs bitstream

program: bitstream
	$(VIVADO) -mode batch -source scripts/program.tcl -tclargs $(BUILD_DIR)/skeleton_top.bit

clean:
	rm -rf $(BUILD_DIR) .Xil vivado*.jou vivado*.log

clean-sim:
	rm -rf $(SIM_DIR) xsim.dir *.wdb *.pb xvlog.log xelab.log xsim.log
