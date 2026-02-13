# V80 FPGA Development - Agent Notes

## Useful Paths and Resources

### AVED Example Design Locations
- **Source**: `/opt/Xilinx/AVED/hw/amd_v80_gen5x8_25.1/`
- **Working Copy**: `/home/sk3463/helloworld/amd_v80_gen5x8_25.1/`
- **Firmware**: `/opt/Xilinx/AVED/fw/AMC/`
- **Documentation**: https://xilinx.github.io/AVED/

### Key Configuration Details

#### HBM Memory Map (from AVED design)
- Base address: `0x004000000000`
- 16 pseudo-channels (PC0-PC15)
- Each channel: 1GB (0x40000000 range)
- Example addresses:
  - HBM0_PC0: `0x004000000000` - `0x00403FFFFFFF`
  - HBM0_PC1: `0x004040000000` - `0x00407FFFFFFF`
  - HBM1_PC0: `0x004080000000` - `0x0040BFFFFFFF`

#### PCIe Configuration
- Mode: QDMA (Queue DMA)
- Link: Gen5 x8
- Vendor ID: `0x10EE` (Xilinx)
- Device ID: `0x50B4` (PF0), `0x50B5` (PF1)
- Two PCIe NOC interfaces: CPM_PCIE_NOC_0 and CPM_PCIE_NOC_1

#### AXI NoC Configuration
- 4 Slave Interfaces (S00-S03):
  - S00_AXI: PCIe QDMA interface 0
  - S01_AXI: PCIe QDMA interface 1
  - S02_AXI: PMC (Platform Management Controller)
  - S03_AXI: RPU (Real-time Processing Unit)
- 1 Master Interface (M00_AXI): PL management interface
- 4 NoC Master Interfaces (M00-M03_INI): DDR memory controllers
- HBM: 16 channels, 2 ports each (32 total HBM ports)

### Build System

#### Build Script: `build_all.sh`
Located at: `/home/sk3463/helloworld/amd_v80_gen5x8_25.1/build_all.sh`

**Build Steps:**
1. **Hardware (Vivado)**:
   - Runs `src/create_design.tcl` - creates block design
   - Runs `src/build_design.tcl` - synthesizes and implements
   - Outputs: `build/amd_v80_gen5x8_25.1.xsa` (hardware export)

2. **Firmware (AMC)**:
   - Builds RPU firmware using CMake
   - Outputs: `build/amc.elf`

3. **FPT (Firmware Partition Table)**:
   - Generates partition table from `fpt.json`
   - Outputs: `build/fpt.bin`

4. **PDI Generation**:
   - Uses `bootgen` to combine hardware + firmware
   - Uses `fpt_pdi_gen.py` to add FPT
   - Final output: `amd_v80_gen5x8_25.1.pdi`

### System Status

#### Tools Available
- ✅ AVED framework installed at `/opt/Xilinx/AVED/`
- ✅ Firmware source available
- ❌ Vivado 2025.1 - **NOT INSTALLED**
- ❌ bootgen - **NOT INSTALLED** (comes with Vivado)

#### What We Can Do Without Vivado
1. ✅ Analyze existing AVED design structure
2. ✅ Create custom RTL modules (Verilog/SystemVerilog)
3. ✅ Modify block design TCL scripts
4. ✅ Create host software and test scripts
5. ✅ Document the design and build process
6. ❌ Build/synthesize the design
7. ❌ Generate PDI file
8. ❌ Program the FPGA

### Previous Issues (from user context)
- "deadbeef loopback didn't work"
- "couldn't create the right top-level interface for communicating with the host"
- Connection issues with PCIe interface

### Solution Approach
Instead of creating from scratch, modify the proven AVED design:
- AVED has working PCIe CIPS + HBM NoC configuration
- Add minimal custom logic for loopback test
- Ensures proper top-level interface and connectivity

## Next Steps (When Vivado Available)
1. Install Vivado 2025.1
2. Source settings: `source /opt/Xilinx/Vivado/2025.1/settings64.sh`
3. Run build: `cd /home/sk3463/helloworld/amd_v80_gen5x8_25.1 && ./build_all.sh`
4. Program FPGA with generated PDI file
5. Test with host software
