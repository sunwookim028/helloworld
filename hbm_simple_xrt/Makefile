# HBM Data Mover Makefile
CXX := g++
CXXFLAGS := -I/opt/xilinx/xrt/include -Isrc -std=c++17 -Wall -O0 -g
LDFLAGS := -L/opt/xilinx/xrt/lib -lxrt_coreutil -luuid -pthread

# Kernel Compiler Settings
VPP := v++
PLATFORM := xilinx_u280_gen3x16_xdma_1_202211_1
TARGET := hw
VPP_FLAGS := -t $(TARGET) --platform $(PLATFORM) --save-temps

# Targets
.PHONY: all build clean host phase1 phase2

all: host build

# Phase 1 targets (baseline)
phase1: hbm_simple_xrt tensor_test krnl_vadd.xclbin

# Phase 2 targets (descriptor-based)
phase2: host_descriptor krnl_vadd_desc.xclbin

host: hbm_simple_xrt tensor_test host_descriptor

# Phase 1 Host Applications
hbm_simple_xrt: src/host.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

tensor_test: src/host_tensor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# Phase 2 Host Application
host_descriptor: src/host_descriptor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# Phase 1 Kernel Rules
build: krnl_vadd.xclbin krnl_vadd_desc.xclbin

krnl_vadd.xo: src/krnl_vadd.cpp
	$(VPP) -c $(VPP_FLAGS) -k krnl_vadd -Isrc -o $@ $<

krnl_vadd.xclbin: krnl_vadd.xo
	$(VPP) -l $(VPP_FLAGS) --config krnl_vadd.cfg -o $@ $<

# Phase 2 Kernel Rules
krnl_vadd_desc.xo: src/krnl_vadd_desc.cpp src/dma_descriptor.h
	$(VPP) -c $(VPP_FLAGS) -k krnl_vadd_desc -Isrc -o $@ $<

krnl_vadd_desc.xclbin: krnl_vadd_desc.xo
	$(VPP) -l $(VPP_FLAGS) --config krnl_vadd_desc.cfg -o $@ $<

clean:
	rm -f hbm_simple_xrt tensor_test host_descriptor
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log _x .Xil
	rm -rf .run .ipcache
