# gem_mac build entry points. Wraps scripts/build.tcl (non-project mode,
# fpga_project_flow.md Stage 2) so the whole build is one command, not a
# sequence of steps someone has to remember.
#
# VIVADO can be overridden if vivado isn't on PATH, e.g.:
#   make bitstream VIVADO="D:/Vivado/2024.2/bin/vivado.bat"

VIVADO    ?= vivado
BUILD_DIR := build

.PHONY: synth impl bitstream program clean

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
