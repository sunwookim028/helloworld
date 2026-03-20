#==============================================================================
# Systolic Array + MXU Verification Makefile
# Usage: make test_systolic_array   (or)   make test_mxu   (or)   make all
#==============================================================================

IVERILOG = iverilog
VVP = vvp

# Directories
SRC_DIR = ../src
SIM_BUILD = sim_build

# cocotb environment
export COCOTB_REDUCED_LOG_FMT = 1
export LIBPYTHON_LOC = $(shell python3 -c "import find_libpython; print(find_libpython.find_libpython())")
export PYTHONPATH := $(PWD):$(PYTHONPATH)
export PYGPI_PYTHON_BIN = $(shell which python3)

# cocotb VPI library path
COCOTB_LIBS = $(shell python3 -c "import cocotb; import os; print(os.path.join(os.path.dirname(cocotb.__file__), 'libs'))")

# Iverilog flags
IVFLAGS = -g2012 -Wall

# RTL sources
SRC_FP32      = $(SRC_DIR)/fp32_add.sv $(SRC_DIR)/fp32_mul.sv
SRC_PE        = $(SRC_DIR)/pe.sv $(SRC_FP32)
SRC_SYSTOLIC  = $(SRC_DIR)/systolic_array.sv $(SRC_PE)
SRC_MXU       = $(SRC_DIR)/mxu.sv $(SRC_SYSTOLIC)

#==============================================================================
.PHONY: all clean test_systolic_array test_mxu

all: test_systolic_array test_mxu

#==============================================================================
# Systolic array test (N=16 by default)
#==============================================================================
test_systolic_array: $(SIM_BUILD)/systolic_array.vvp
	@echo "=== Running systolic_array tests ==="
	MODULE=test_systolic_array \
	COCOTB_TEST_MODULES=test_systolic_array \
	TOPLEVEL=systolic_array \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/systolic_array.vvp: $(SRC_SYSTOLIC) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s systolic_array \
		-DN_PARAM=16 \
		$(SRC_SYSTOLIC)

#==============================================================================
# MXU wrapper test (N=16 by default)
#==============================================================================
test_mxu: $(SIM_BUILD)/mxu.vvp
	@echo "=== Running MXU tests ==="
	MODULE=test_mxu \
	COCOTB_TEST_MODULES=test_mxu \
	TOPLEVEL=mxu \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/mxu.vvp: $(SRC_MXU) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s mxu \
		$(SRC_MXU)

#==============================================================================
# Small array tests (N=4, for quick regression / cross-check with minitpu)
#==============================================================================
test_systolic_4x4: $(SIM_BUILD)/systolic_4x4.vvp
	@echo "=== Running 4x4 systolic tests ==="
	MODULE=test_systolic_array \
	COCOTB_TEST_MODULES=test_systolic_array \
	TOPLEVEL=systolic_array \
	TOPLEVEL_LANG=verilog \
	SYSTOLIC_N=4 \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/systolic_4x4.vvp: $(SRC_SYSTOLIC) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s systolic_array \
		-Psystolic_array.N=4 \
		$(SRC_SYSTOLIC)

test_mxu_4x4: $(SIM_BUILD)/mxu_4x4.vvp
	@echo "=== Running 4x4 MXU tests ==="
	MODULE=test_mxu \
	COCOTB_TEST_MODULES=test_mxu \
	TOPLEVEL=mxu \
	TOPLEVEL_LANG=verilog \
	MXU_N=4 \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/mxu_4x4.vvp: $(SRC_MXU) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s mxu \
		-Pmxu.N=4 \
		$(SRC_MXU)

#==============================================================================
$(SIM_BUILD):
	mkdir -p $(SIM_BUILD)

clean:
	rm -rf $(SIM_BUILD) results.xml __pycache__ *.vcd
