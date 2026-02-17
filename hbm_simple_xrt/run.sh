#!/bin/bash
# Wrapper script to setup environment and run HBM applications

# Source XRT setup (adjust path if needed, standard is /opt/xilinx/xrt)
if [ -f /opt/xilinx/xrt/setup.sh ]; then
    source /opt/xilinx/xrt/setup.sh
else
    echo "Warning: /opt/xilinx/xrt/setup.sh not found. Ensure XRT is installed."
fi

# Default to hbm_simple_xrt if no app specified
APP=${1:-hbm}
XCLBIN=${2:-krnl_vadd.xclbin}
DEV=${3:-0}

if [ "$APP" == "hbm" ]; then
    echo "Running HBM Bandwidth Test..."
    ./hbm_simple_xrt -x $XCLBIN -d $DEV
elif [ "$APP" == "tensor" ]; then
    echo "Running Tensor Scenario Test..."
    ./tensor_test -x $XCLBIN -d $DEV
else
    echo "Usage: ./run.sh [hbm|tensor] <xclbin> <device_id>"
    echo "Example: ./run.sh hbm krnl_vadd.xclbin 0"
fi
