#!/bin/bash
# Phase 2 Descriptor-Based DMA Test Runner
# Usage: ./run_desc.sh [test_name]
# Tests: single, chain, tensor, all (default)

# Setup XRT environment
if [ -f /opt/xilinx/xrt/setup.sh ]; then
    source /opt/xilinx/xrt/setup.sh
else
    echo "Warning: XRT setup script not found at /opt/xilinx/xrt/setup.sh"
fi

# Default test
TEST=${1:-all}
XCLBIN="krnl_vadd_desc.xclbin"
DEVICE=0

# Check if bitstream exists
if [ ! -f "$XCLBIN" ]; then
    echo "Error: Bitstream $XCLBIN not found!"
    echo "Please build the kernel first:"
    echo "  make krnl_vadd_desc.xclbin"
    exit 1
fi

# Check if host executable exists
if [ ! -f "host_descriptor" ]; then
    echo "Error: host_descriptor executable not found!"
    echo "Building host application..."
    make host_descriptor
fi

echo "=========================================="
echo "Phase 2: Descriptor-Based DMA Test"
echo "=========================================="
echo "Bitstream: $XCLBIN"
echo "Device: $DEVICE"
echo "Test: $TEST"
echo ""

# Run test
./host_descriptor -x $XCLBIN -d $DEVICE --test $TEST

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
