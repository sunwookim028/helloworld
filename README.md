# V80 FPGA PCIe-HBM Loopback Project

This project demonstrates a simple PCIe-to-HBM loopback design on the AMD Alveo V80 FPGA board.

## Prerequisites

- AMD Alveo V80 FPGA board installed in PCIe slot
- **Vivado 2025.1** installed and in PATH
  - **Current Status**: ⚠️ Vivado not found on this system
  - Installation needed before building
  - Typical install locations: `/opt/Xilinx/Vivado/2025.1/` or `/tools/Xilinx/Vivado/2025.1/`
- Linux host system with PCIe access
- AVED (Alveo Versal Example Design) framework (included in this repo)

> **Note**: This README documents the complete flow. Some steps (building) require Vivado installation.
> We can still prepare RTL modules, understand the design, and create test software without Vivado.

## Project Structure

```
helloworld/
├── README.md                    # This file
├── AGENTS.md                    # Technical reference
├── build_loopback.sh            # Main build script
├── setup_github.sh              # GitHub setup helper
├── amd_v80_gen5x8_25.1/        # AVED base design
│   ├── src/                     # Vivado source files
│   │   ├── bd/                  # Block design TCL
│   │   └── constraints/         # Timing constraints
│   ├── build_all.sh            # AVED build script
│   └── fpt/                     # Firmware partition table
├── fw/                          # AVED firmware (self-contained)
│   └── AMC/                     # Management controller firmware
├── hw/                          # Custom hardware
│   ├── rtl/
│   │   └── hbm_loopback.v      # Loopback RTL module
│   └── integrate_loopback.tcl   # Integration script
└── sw/                          # Host software
    └── test_hbm_loopback.py    # Test script
```

> **Note**: This project is now **self-contained** with all dependencies included.
> The firmware is copied locally so the project can be built on any system with Vivado.

## Quick Start Guide

### Step 1: Verify Environment

Check that Vivado is available:
```bash
which vivado
vivado -version
```

Expected output: Vivado v2025.1 or compatible version.

**If Vivado is not found:**
```bash
# Source Vivado settings (adjust path as needed)
source /opt/Xilinx/Vivado/2025.1/settings64.sh
```

### Step 2: Build the Complete Design

The build script will:
1. Integrate the HBM loopback module into AVED block design
2. Run Vivado synthesis and implementation
3. Build the AMC firmware
4. Generate the complete PDI file

```bash
cd /home/sk3463/helloworld
./build_loopback.sh
```

**Expected duration:** 30-60 minutes depending on system performance.

**Output:** `amd_v80_gen5x8_25.1/build/amd_v80_gen5x8_25.1_loopback.pdi`

### Step 3: Program the FPGA

**Option A: Using AVED ami_tool (recommended)**
```bash
# Check if V80 is detected
lspci | grep Xilinx

# Program the FPGA
ami_tool program -d /dev/xdma0 -p amd_v80_gen5x8_25.1/build/amd_v80_gen5x8_25.1_loopback.pdi
```

**Option B: Using Vivado Hardware Manager**
```bash
vivado -mode tcl
# In Vivado TCL console:
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {amd_v80_gen5x8_25.1/build/amd_v80_gen5x8_25.1_loopback.pdi} [current_hw_device]
program_hw_devices [current_hw_device]
```

### Step 4: Verify PCIe Enumeration

After programming, verify the FPGA is visible on PCIe bus:
```bash
lspci -d 10ee:
# Should show Xilinx device with ID 10ee:50b4 or 10ee:50b5

# Check detailed info
lspci -vvv -d 10ee: | grep -E "LnkSta|Width|Speed"
# Should show Gen5 x8 link
```

### Step 5: Run the Test

```bash
cd /home/sk3463/helloworld
sudo python3 sw/test_hbm_loopback.py
```

**Expected output:**
```
============================================================
V80 FPGA HBM Loopback Test
============================================================
✓ Found Xilinx PCIe device:
  01:00.0 Processing accelerators: Xilinx Corporation Device 50b4

Testing with value: 0xDEADBEEF
  Initial state: 0
  Wrote 0xDEADBEEF to control register
  Operation completed in 2.34ms
  Read back: 0xDEADBEEF
  ✓ Data matches!

... (more tests) ...

============================================================
Test Summary: 6 passed, 0 failed
============================================================
✓ All tests PASSED!
```

## HBM Loopback Design Details

### Module: `hbm_loopback.v`

The loopback module provides a simple test interface for PCIe-to-HBM communication:

**Register Interface (AXI-Lite Slave, base 0x020101050000):**
- `0x00` - CTRL_DATA: Write test data here to trigger loopback operation
- `0x04` - STATUS: Read back data retrieved from HBM
- `0x08` - STATE: Current FSM state (for debugging)
  - 0: IDLE
  - 1: WRITE_ADDR
  - 2: WRITE_DATA
  - 3: WRITE_RESP
  - 4: READ_ADDR
  - 5: READ_DATA
  - 6: DONE
- `0x0C` - ERROR: Error flags
  - Bit 0: HBM write error
  - Bit 1: HBM read error

**Operation Flow:**
1. Host writes test value to CTRL_DATA register via PCIe
2. Module writes value to HBM at address 0x004000000000
3. Module reads value back from HBM
4. Module stores result in STATUS register
5. Host reads STATUS register to verify data integrity

**HBM Access:**
- Uses AXI4 master interface (256-bit data width)
- Fixed address: 0x004000000000 (HBM0_PC0)
- Single-beat transactions for simplicity

### Integration Points

The loopback module is integrated into AVED via `integrate_loopback.tcl`:
- Connects to AXI NoC S04_AXI slave interface
- Routes to HBM through NoC
- Accessible from PCIe via management SmartConnect
- Uses usr_clk_0 (300 MHz) clock domain

The AVED base design includes:

1. **CIPS (Control, Interfaces, and Processing System)**
   - PCIe Gen5 x8 in QDMA mode
   - RPU (Real-time Processing Unit) running management firmware
   - Multiple clock domains

2. **AXI NoC (Network on Chip)**
   - Connects PCIe to HBM and DDR memory
   - 16 HBM channels configured
   - High-bandwidth interconnect

3. **HBM (High Bandwidth Memory)**
   - 32GB HBM2e memory
   - Accessible from PCIe at base address `0x004000000000`
   - 16 pseudo-channels, each 1GB (0x40000000 range)

4. **Management Infrastructure**
   - Hardware discovery IP for PCIe enumeration
   - Command queue for RPU-to-host communication
   - SMBus interface for out-of-band management

## Key Files and Their Purpose

| File | Purpose |
|------|---------|
| `src/bd/create_bd_design.tcl` | Vivado block design - defines all IP connections |
| `src/create_design.tcl` | Top-level design creation script |
| `src/build_design.tcl` | Synthesis and implementation script |
| `build_all.sh` | Master build script orchestrating the entire flow |
| `fpt/pdi_combine.bif` | Boot image format file for PDI generation |

## Troubleshooting

### Build fails with "Vivado not found"
Ensure Vivado 2025.1 is installed and sourced:
```bash
source /tools/Xilinx/Vivado/2025.1/settings64.sh
```

### Build fails during firmware compilation
Check that the firmware directory exists:
```bash
ls -la /opt/Xilinx/AVED/fw/AMC
```

## Next Steps

After successfully building the base design:
1. Add custom HBM loopback RTL module
2. Integrate into the block design
3. Create host software for testing
4. Deploy and verify functionality

## Resources

- AVED Documentation: https://xilinx.github.io/AVED/
- AVED GitHub: https://github.com/Xilinx/AVED
- V80 Datasheet: Search for "Alveo V80 Data Sheet DS1013"
