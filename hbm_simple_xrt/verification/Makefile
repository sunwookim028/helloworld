#==============================================================================
# Systolic Array + MXU + matmul_top + krnl_matmul Verification Makefile
#
# All modules target N=32.
#
# Usage:
#   make test_systolic_array   — systolic_array.sv  (32×32)
#   make test_mxu              — mxu.sv             (32×32)
#   make test_matmul           — matmul_top.sv       (32×32, HBM wrapper)
#   make test_krnl_matmul      — krnl_matmul.sv      (full AXI kernel)
#   make all                   — all of the above
#==============================================================================

IVERILOG = iverilog
VVP      = vvp

SRC_DIR  = ../src
SIM_BUILD = sim_build

# cocotb environment
export COCOTB_REDUCED_LOG_FMT = 1
export LIBPYTHON_LOC = $(shell python3 -c "import find_libpython; print(find_libpython.find_libpython())")
export PYTHONPATH   := $(PWD):$(PYTHONPATH)
export PYGPI_PYTHON_BIN = $(shell which python3)

COCOTB_LIBS = $(shell python3 -c "import cocotb; import os; print(os.path.join(os.path.dirname(cocotb.__file__), 'libs'))")

IVFLAGS = -g2012 -Wall

# Source groups
SRC_FP32     = $(SRC_DIR)/fp32_add.sv $(SRC_DIR)/fp32_mul.sv
SRC_PE       = $(SRC_DIR)/pe.sv $(SRC_FP32)
SRC_SYSTOLIC = $(SRC_DIR)/systolic_array.sv $(SRC_PE)
SRC_MXU      = $(SRC_DIR)/mxu.sv $(SRC_SYSTOLIC)
SRC_MATMUL   = $(SRC_DIR)/matmul_top.sv $(SRC_MXU)
SRC_KRNL     = $(SRC_DIR)/krnl_matmul.sv $(SRC_DIR)/krnl_vadd_ctrl.v $(SRC_MATMUL) $(SRC_DIR)/fifo4.sv

#==============================================================================
.PHONY: all clean test_systolic_array test_mxu test_matmul test_krnl_matmul

all: test_systolic_array test_mxu test_matmul test_krnl_matmul

#==============================================================================
# Systolic array (32×32)
#==============================================================================
test_systolic_array: $(SIM_BUILD)/systolic_array.vvp
	@echo "=== Running systolic_array tests (N=32) ==="
	MODULE=test_systolic_array \
	COCOTB_TEST_MODULES=test_systolic_array \
	TOPLEVEL=systolic_array \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/systolic_array.vvp: $(SRC_SYSTOLIC) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s systolic_array $(SRC_SYSTOLIC)

#==============================================================================
# MXU wrapper (32×32)
#==============================================================================
test_mxu: $(SIM_BUILD)/mxu.vvp
	@echo "=== Running MXU tests (N=32) ==="
	MODULE=test_mxu \
	COCOTB_TEST_MODULES=test_mxu \
	TOPLEVEL=mxu \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/mxu.vvp: $(SRC_MXU) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s mxu $(SRC_MXU)

#==============================================================================
# matmul_top integration test (32×32)
#==============================================================================
test_matmul: $(SIM_BUILD)/matmul.vvp
	@echo "=== Running matmul_top tests (N=32) ==="
	MODULE=test_matmul_top \
	COCOTB_TEST_MODULES=test_matmul_top \
	TOPLEVEL=matmul_top \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/matmul.vvp: $(SRC_MATMUL) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s matmul_top $(SRC_MATMUL)

#==============================================================================
# krnl_matmul full AXI kernel test (32×32)
#==============================================================================
test_krnl_matmul: $(SIM_BUILD)/krnl_matmul.vvp
	@echo "=== Running krnl_matmul tests (N=32) ==="
	MODULE=test_krnl_matmul \
	COCOTB_TEST_MODULES=test_krnl_matmul \
	TOPLEVEL=krnl_matmul \
	TOPLEVEL_LANG=verilog \
	$(VVP) -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<

$(SIM_BUILD)/krnl_matmul.vvp: $(SRC_KRNL) | $(SIM_BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ -s krnl_matmul $(SRC_KRNL)

#==============================================================================
$(SIM_BUILD):
	mkdir -p $(SIM_BUILD)

clean:
	rm -rf $(SIM_BUILD) results.xml __pycache__ *.vcd
