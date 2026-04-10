# HBM Data Mover Makefile — RTL kernel edition (Vivado/Vitis 2023.2)
#
# Build flow:
#   1. Host:       g++ src/host.cpp       → hbm_simple_xrt
#                  g++ src/host_tensor.cpp → tensor_test
#   2. RTL kernel: vivado (pack_kernel.tcl) → krnl_vadd.xo
#   3. Bitstream:  v++ -l                  → krnl_vadd.xclbin
#
# RTL sources (DMA data mover only — no systolic array):
#   krnl_vadd.sv       — top-level kernel (Vitis ports: ap_clk, s_axi_control, m_axi_gmem*)
#   krnl_vadd_ctrl.v   — AXI4-Lite slave, ap_ctrl_hs register map
#   krnl_vadd_rd_mst.v — AXI4 burst read master, 512-bit (gmem0 / in1)
#   krnl_vadd_wr_mst.v — AXI4 burst write master, 512-bit (gmem2 / out_r)
#   fifo4.sv           — FWFT FIFO (depth=64, 512-bit)

# ── Toolchain ────────────────────────────────────────────────────────────────
CXX    := g++
VPP    := v++

# ── Host build flags ─────────────────────────────────────────────────────────
XRT_ROOT ?= /opt/xilinx/xrt
CXXFLAGS := -I$(XRT_ROOT)/include -std=c++17 -Wall -O0 -g
LDFLAGS  := -L$(XRT_ROOT)/lib -lxrt_coreutil -luuid -pthread

# ── Kernel build settings ────────────────────────────────────────────────────
PLATFORM    ?= xilinx_u280_gen3x16_xdma_1_202211_1
TARGET      := hw
VPP_FLAGS   := -t $(TARGET) --platform $(PLATFORM) --save-temps
VPP_LDFLAGS := --config krnl_vadd.cfg

# ── RTL source files (DMA data mover only) ───────────────────────────────────
RTL_SRCS := src/krnl_vadd.sv src/krnl_vadd_ctrl.v \
            src/krnl_vadd_rd_mst.v src/krnl_vadd_wr_mst.v src/fifo4.sv

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build clean host

all: host build

# ── Host executables ─────────────────────────────────────────────────────────
host: hbm_simple_xrt tensor_test

hbm_simple_xrt: src/host.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

tensor_test: src/host_tensor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# ── RTL kernel: package RTL sources as .xo via Vivado ────────────────────────
build: krnl_vadd.xclbin

krnl_vadd.xo: $(RTL_SRCS) kernel.xml pack_kernel.tcl
	vivado -mode batch -source pack_kernel.tcl -notrace

# ── Bitstream: link .xo to .xclbin ──────────────────────────────────────────
krnl_vadd.xclbin: krnl_vadd.xo
	$(VPP) -l $(VPP_FLAGS) $(VPP_LDFLAGS) -o $@ $<

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	rm -f hbm_simple_xrt tensor_test
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log _x .Xil
	rm -rf .run .ipcache
	rm -rf kernel_pack_tmp packaged_kernel_krnl_vadd _pack_project ip_repo
