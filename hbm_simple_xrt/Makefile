# HBM Data Mover Makefile — RTL kernel edition
#
# Build flow:
#   1. Host (unchanged):   g++ src/host.cpp      → hbm_simple_xrt
#                          g++ src/host_tensor.cpp → tensor_test
#   2. RTL kernel:         vivado (package_kernel.tcl) → krnl_vadd.xo
#   3. Bitstream:          v++ -l                 → krnl_vadd.xclbin
#
# RTL sources (src/):
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
CXXFLAGS := -I/opt/xilinx/xrt/include -std=c++17 -Wall -O0 -g
LDFLAGS  := -L/opt/xilinx/xrt/lib -lxrt_coreutil -luuid -pthread

# ── Kernel build settings ────────────────────────────────────────────────────
PLATFORM    := xilinx_u280_gen3x16_xdma_1_202211_1
TARGET      := hw
VPP_FLAGS   := -t $(TARGET) --platform $(PLATFORM) --save-temps
VPP_LDFLAGS := --config krnl_vadd.cfg

# ── RTL source files ─────────────────────────────────────────────────────────
RTL_SRCS := $(wildcard src/*.sv src/*.v)

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build clean host

all: host build

# ── Host executables (unchanged from HLS version) ────────────────────────────
host: hbm_simple_xrt tensor_test

hbm_simple_xrt: src/host.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

tensor_test: src/host_tensor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# ── RTL kernel: package RTL sources as .xo via Vivado ────────────────────────
#   package_kernel.tcl calls ipx::package_project then package_xo.
#   Args: <kernel_name> <output.xo> <kernel.xml> <rtl_src_dir>
krnl_vadd.xo: $(RTL_SRCS) kernel.xml package_kernel.tcl
	$(VIVADO) -mode batch -source package_kernel.tcl \
	    -tclargs krnl_vadd $@ kernel.xml src

# ── Bitstream: link .xo to .xclbin (same as HLS version) ────────────────────
build: krnl_vadd.xclbin

krnl_vadd.xclbin: krnl_vadd.xo
	$(VPP) -l $(VPP_FLAGS) $(VPP_LDFLAGS) -o $@ $<

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f hbm_simple_xrt tensor_test
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log
	rm -rf _x .Xil .run .ipcache
	rm -rf kernel_pack_tmp packaged_kernel_krnl_vadd
