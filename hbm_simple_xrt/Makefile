# HBM Matmul Kernel Makefile — krnl_matmul (32×32 systolic array)
#
# Build flow:
#   1. Host:   g++ src/host_matmul.cpp → host_matmul
#   2. Kernel: vivado (pack_krnl_matmul.tcl) → krnl_matmul.xo
#   3. Link:   v++ -l → krnl_matmul.<TARGET>.xclbin
#
# Targets:
#   make build     — full hardware build  (krnl_matmul.xclbin, TARGET=hw)
#   make hw_emu    — hardware emulation   (krnl_matmul.hw_emu.xclbin)
#   make host      — host executable only
#   make all       — host + full build
#
# Hardware emulation run:
#   export XCL_EMULATION_MODE=hw_emu
#   ./host_matmul -x krnl_matmul.hw_emu.xclbin

# ── Toolchain ────────────────────────────────────────────────────────────────
CXX := g++
VPP := v++

# ── Host build flags ─────────────────────────────────────────────────────────
XRT_ROOT ?= /opt/xilinx/xrt
CXXFLAGS := -I$(XRT_ROOT)/include -std=c++17 -Wall -O0 -g
LDFLAGS  := -L$(XRT_ROOT)/lib -lxrt_coreutil -luuid -pthread

# ── Kernel build settings ────────────────────────────────────────────────────
PLATFORM    ?= xilinx_u280_gen3x16_xdma_1_202211_1
VPP_LDFLAGS  = --config krnl_matmul.cfg

# Shorthand: "make build" defaults to hw
build: krnl_matmul.hw.xclbin

# ── RTL source files ──────────────────────────────────────────────────────────
RTL_SRCS := src/krnl_matmul.sv src/krnl_vadd_ctrl.v \
            src/krnl_vadd_rd_mst.v src/krnl_vadd_wr_mst.v \
            src/matmul_top.sv src/mxu.sv src/systolic_array.sv \
            src/pe.sv src/bf16_add.sv src/bf16_mul.sv \
            src/fifo4.sv

# ── Targets ───────────────────────────────────────────────────────────────────
.PHONY: all build clean host hw_emu

all: host build

# ── Host executable ───────────────────────────────────────────────────────────
host: host_matmul

host_matmul: src/host_matmul.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# ── Hardware emulation ────────────────────────────────────────────────────────
emconfig.json:
	emconfigutil --platform $(PLATFORM) --nd 1

hw_emu: emconfig.json krnl_matmul.hw_emu.xclbin
	@echo ""
	@echo "hw_emu xclbin built: krnl_matmul.hw_emu.xclbin"
	@echo "Run with:  export XCL_EMULATION_MODE=hw_emu && ./host_matmul -x krnl_matmul.hw_emu.xclbin"

# ── RTL kernel: package as .xo ────────────────────────────────────────────────
krnl_matmul.xo: $(RTL_SRCS) krnl_matmul.xml pack_krnl_matmul.tcl
	vivado -mode batch -source pack_krnl_matmul.tcl -notrace

# ── Link .xo → .xclbin ────────────────────────────────────────────────────────
krnl_matmul.hw_emu.xclbin: krnl_matmul.xo
	$(VPP) -l -t hw_emu --platform $(PLATFORM) --save-temps $(VPP_LDFLAGS) -o $@ $<

krnl_matmul.hw.xclbin: krnl_matmul.xo
	$(VPP) -l -t hw --platform $(PLATFORM) --save-temps $(VPP_LDFLAGS) -o $@ $<

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f host_matmul emconfig.json
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log _x .Xil
	rm -rf .run .ipcache
	rm -rf _pack_project_matmul ip_repo_matmul
