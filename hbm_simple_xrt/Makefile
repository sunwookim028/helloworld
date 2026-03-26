# HBM Data Mover Makefile — RTL kernel edition (Vivado/Vitis 2023.2)
#
# Build flow:
#   1. Host (unchanged):   g++ src/host.cpp      → hbm_simple_xrt
#                          g++ src/host_tensor.cpp → tensor_test
#   2. RTL kernel:         vivado (package_kernel.tcl) → krnl_vadd.xo
#   3. Bitstream:          v++ -l                 → krnl_vadd.xclbin
#
# VADD RTL sources (src/) — only the DMA copy engine, NOT systolic array:
#   krnl_vadd.sv          — top-level kernel (Vitis port names: ap_clk, s_axi_control, m_axi_gmem*)
#   krnl_vadd_ctrl.v      — AXI4-Lite slave, ap_ctrl_hs register map (adapted from minitpu)
#   krnl_vadd_rd_mst.v    — AXI4 burst read master, 512-bit (gmem0 / in1)
#   krnl_vadd_wr_mst.v    — AXI4 burst write master, 512-bit (gmem2 / out_r)
#   fifo4.sv              — FWFT FIFO, copied from minitpu tpu/src/system/fifo4.sv

# ── Toolchain ────────────────────────────────────────────────────────────────
CXX     := g++
VIVADO  := vivado
VPP     := v++

# ── Host build flags ─────────────────────────────────────────────────────────
# XRT default install path; override with: make XRT_ROOT=/your/path host
XRT_ROOT ?= /opt/xilinx/xrt
CXXFLAGS := -I$(XRT_ROOT)/include -std=c++17 -Wall -O0 -g
LDFLAGS  := -L$(XRT_ROOT)/lib -lxrt_coreutil -luuid -pthread

# ── Kernel build settings ────────────────────────────────────────────────────
# Platform for Vitis 2023.2 + U280 shell — Alveo U280 Gen3x16 XDMA
# The tool version (Vitis 2023.2) and the platform shell version are independent.
# This machine has the 2022.1 platform shell installed under Vitis 2023.2.
# To find installed platforms:  v++ --list_platforms  OR  ls $XILINX_VITIS/platforms/
# Common U280 platform names by tool version:
#   2022.1: xilinx_u280_gen3x16_xdma_1_202211_1  ← installed on this machine
#   2023.2: xilinx_u280_gen3x16_xdma_1_202320_1
#   2024.x: xilinx_u280_gen3x16_xdma_1_202410_1
PLATFORM    ?= xilinx_u280_gen3x16_xdma_1_202211_1
TARGET      := hw
VPP_FLAGS   := -t $(TARGET) --platform $(PLATFORM) --save-temps
VPP_LDFLAGS := --config krnl_vadd.cfg

# ── VADD RTL source files (DMA engine only) ──────────────────────────────────
VADD_RTL_SRCS := \
    src/krnl_vadd.sv \
    src/krnl_vadd_ctrl.v \
    src/krnl_vadd_rd_mst.v \
    src/krnl_vadd_wr_mst.v \
    src/fifo4.sv

# ── Systolic array + MXU + HBM integration RTL ───────────────────────────────
MATMUL_RTL_SRCS := \
    src/fp32_mul.sv \
    src/fp32_add.sv \
    src/pe.sv \
    src/systolic_array.sv \
    src/mxu.sv \
    src/matmul_top.sv

# ── All RTL: DMA engine + full systolic array hierarchy ───────────────────────
# Used by build_full. krnl_vadd.sv is still the kernel top — wire matmul_top
# into krnl_vadd.sv before build_full produces a functionally integrated kernel.
ALL_RTL_SRCS := $(VADD_RTL_SRCS) $(MATMUL_RTL_SRCS)

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build build_full clean host

all: host build

# ── Host executables (unchanged from HLS version) ────────────────────────────
host: hbm_simple_xrt tensor_test

hbm_simple_xrt: src/host.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

tensor_test: src/host_tensor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# ── RTL kernel: package VADD sources as .xo via Vivado ───────────────────────
#   package_kernel.tcl calls ipx::package_project then package_xo.
#   Args: <kernel_name> <output.xo> <kernel.xml> <rtl_file1> [rtl_file2 ...]
krnl_vadd.xo: $(VADD_RTL_SRCS) kernel.xml package_kernel.tcl
	$(VIVADO) -mode batch -source package_kernel.tcl \
	    -tclargs krnl_vadd $@ kernel.xml $(VADD_RTL_SRCS)

# ── Bitstream: link .xo to .xclbin ───────────────────────────────────────────
build: krnl_vadd.xclbin

krnl_vadd.xclbin: krnl_vadd.xo
	$(VPP) -l $(VPP_FLAGS) $(VPP_LDFLAGS) -o $@ $<

# ── Full build: DMA engine + systolic array RTL ───────────────────────────────
# Packages all RTL (VADD + MATMUL) through Vivado, then links to .xclbin.
# krnl_vadd.sv remains the Vitis kernel top. To produce a functionally
# integrated kernel, instantiate matmul_top inside krnl_vadd.sv first.
build_full: krnl_vadd_full.xclbin

krnl_vadd_full.xo: $(ALL_RTL_SRCS) kernel.xml package_kernel.tcl
	$(VIVADO) -mode batch -source package_kernel.tcl \
	    -tclargs krnl_vadd $@ kernel.xml $(ALL_RTL_SRCS)

krnl_vadd_full.xclbin: krnl_vadd_full.xo
	$(VPP) -l $(VPP_FLAGS) $(VPP_LDFLAGS) -o $@ $<

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f hbm_simple_xrt tensor_test
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log
	rm -rf _x .Xil .run .ipcache
	rm -rf kernel_pack_tmp packaged_kernel_krnl_vadd packaged_kernel_krnl_vadd_full
