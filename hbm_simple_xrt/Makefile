# HBM Data Mover Makefile
CXX := g++
CXXFLAGS := -I/opt/xilinx/xrt/include -std=c++17 -Wall -O0 -g
LDFLAGS := -L/opt/xilinx/xrt/lib -lxrt_coreutil -luuid -pthread

# Kernel Compiler Settings
VPP := v++
PLATFORM := xilinx_u280_gen3x16_xdma_1_202211_1
TARGET := hw
VPP_FLAGS := -t $(TARGET) --platform $(PLATFORM) --save-temps
VPP_LDFLAGS := --config krnl_vadd.cfg

# Targets
.PHONY: all build clean host

all: host build

host: hbm_simple_xrt tensor_test

hbm_simple_xrt: src/host.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

tensor_test: src/host_tensor.cpp
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LDFLAGS)

# Kernel Rules
build: krnl_vadd.xclbin

krnl_vadd.xo: src/krnl_vadd.cpp
	$(VPP) -c $(VPP_FLAGS) -k krnl_vadd -Isrc -o $@ $<

krnl_vadd.xclbin: krnl_vadd.xo
	$(VPP) -l $(VPP_FLAGS) $(VPP_LDFLAGS) -o $@ $<

clean:
	rm -f hbm_simple_xrt tensor_test
	rm -rf *.xo *.xclbin *.xclbin.info *.xclbin.link_summary *.jou *.log _x .Xil
	rm -rf .run .ipcache
