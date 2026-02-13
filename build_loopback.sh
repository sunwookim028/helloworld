#!/usr/bin/env bash
# Build script for V80 HBM Loopback Design
# This script builds the complete FPGA image including the loopback module
#
# Prerequisites:
#   - Vivado 2025.1 installed and in PATH
#   - AVED firmware available at /opt/Xilinx/AVED/fw/AMC
#
# Usage:
#   ./build_loopback.sh

set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "============================================================"
echo "V80 FPGA HBM Loopback Design Build Script"
echo "============================================================"

# Check for Vivado
if ! command -v vivado &> /dev/null; then
    echo -e "${RED}ERROR: Vivado not found in PATH${NC}"
    echo "Please source Vivado settings:"
    echo "  source /opt/Xilinx/Vivado/2025.1/settings64.sh"
    exit 1
fi

echo -e "${GREEN}✓ Vivado found:${NC} $(which vivado)"

# Check for bootgen
if ! command -v bootgen &> /dev/null; then
    echo -e "${RED}ERROR: bootgen not found in PATH${NC}"
    echo "bootgen should be included with Vivado"
    exit 1
fi

echo -e "${GREEN}✓ bootgen found:${NC} $(which bootgen)"

# Check for firmware
FW_DIR="/opt/Xilinx/AVED/fw/AMC"
if [ ! -d "$FW_DIR" ]; then
    echo -e "${RED}ERROR: AVED firmware not found at $FW_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ AVED firmware found${NC}"

# Init
DESIGN="amd_v80_gen5x8_25.1_loopback"
HW_DIR="$(cd amd_v80_gen5x8_25.1 && pwd)"
SCRIPT_DIR="$(pwd)"

echo ""
echo "Configuration:"
echo "  Design name: $DESIGN"
echo "  Hardware dir: $HW_DIR"
echo "  Firmware dir: $FW_DIR"
echo ""

# Step 1: Modify the block design to include loopback module
echo "============================================================"
echo "Step 1: Preparing modified block design"
echo "============================================================"

# Copy the integration script to the source directory
cp hw/integrate_loopback.tcl amd_v80_gen5x8_25.1/src/

# Modify create_design.tcl to source our integration script
if ! grep -q "integrate_loopback.tcl" amd_v80_gen5x8_25.1/src/create_design.tcl; then
    echo "# Source loopback integration" >> amd_v80_gen5x8_25.1/src/create_design.tcl
    echo "source \${script_folder}/integrate_loopback.tcl" >> amd_v80_gen5x8_25.1/src/create_design.tcl
    echo -e "${GREEN}✓ Added loopback integration to create_design.tcl${NC}"
else
    echo -e "${YELLOW}⚠ Loopback integration already present in create_design.tcl${NC}"
fi

# Step 2: Build Hardware
echo ""
echo "============================================================"
echo "Step 2: Building hardware with Vivado"
echo "============================================================"
echo "This will take 30-60 minutes..."
echo ""

pushd "$HW_DIR" > /dev/null
  mkdir -p ./build
  
  vivado -source src/create_design.tcl \
         -source src/build_design.tcl \
         -mode batch \
         -nojournal \
         -log ./build/vivado.log
  
  if [ $? -ne 0 ]; then
      echo -e "${RED}ERROR: Vivado build failed${NC}"
      echo "Check log: $HW_DIR/build/vivado.log"
      exit 1
  fi
  
  echo -e "${GREEN}✓ Hardware build completed${NC}"
popd > /dev/null

XSA="${HW_DIR}/build/${DESIGN}.xsa"

# Step 3: Build Firmware
echo ""
echo "============================================================"
echo "Step 3: Building firmware (AMC)"
echo "============================================================"

pushd "$FW_DIR" > /dev/null
  ./scripts/build.sh -os freertos10_xilinx -profile v80 -xsa "$XSA"
  
  if [ $? -ne 0 ]; then
      echo -e "${RED}ERROR: Firmware build failed${NC}"
      exit 1
  fi
  
  cp -a "${FW_DIR}/build/amc.elf" "${HW_DIR}/build/"
  echo -e "${GREEN}✓ Firmware build completed${NC}"
popd > /dev/null

# Step 4: Generate FPT
echo ""
echo "============================================================"
echo "Step 4: Generating Firmware Partition Table"
echo "============================================================"

pushd "${FW_DIR}/build" > /dev/null
  ../scripts/gen_fpt.py -f ../scripts/fpt.json
  cp -a "${FW_DIR}/build/fpt.bin" "${HW_DIR}/build/"
  echo -e "${GREEN}✓ FPT generated${NC}"
popd > /dev/null

# Step 5: Generate PDI
echo ""
echo "============================================================"
echo "Step 5: Generating PDI (Programmable Device Image)"
echo "============================================================"

pushd "$HW_DIR" > /dev/null
  # Generate PDI with bootgen
  bootgen -arch versal \
          -image "${HW_DIR}/fpt/pdi_combine.bif" \
          -w \
          -o "${HW_DIR}/build/${DESIGN}_nofpt.pdi"
  
  if [ $? -ne 0 ]; then
      echo -e "${RED}ERROR: bootgen failed${NC}"
      exit 1
  fi
popd > /dev/null

# Final PDI generation with FPT
"${HW_DIR}/fpt/fpt_pdi_gen.py" \
  --fpt "${HW_DIR}/build/fpt.bin" \
  --pdi "${HW_DIR}/build/${DESIGN}_nofpt.pdi" \
  --output "${DESIGN}.pdi"

if [ -f "${DESIGN}.pdi" ]; then
    mv "${DESIGN}.pdi" "${HW_DIR}/build/"
    echo -e "${GREEN}✓ PDI generated successfully${NC}"
else
    echo -e "${RED}ERROR: PDI generation failed${NC}"
    exit 1
fi

# Summary
echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo ""
echo "Output file: ${HW_DIR}/build/${DESIGN}.pdi"
echo ""
echo "Next steps:"
echo "  1. Program the FPGA with the PDI file"
echo "  2. Run the test script: sudo python3 sw/test_hbm_loopback.py"
echo ""
