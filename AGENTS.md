# Agent Context: HBM Data Mover Project

## Quick Start
See [README.md](README.md) for complete project documentation, build instructions, and results.

## Project Status
**Current Phase**: Phase 1 Complete — RTL Data Mover verified on hardware  
**Kernel Type**: RTL (Verilog/SystemVerilog), packaged via Vivado `package_xo`  
**Hardware**: Alveo U280 with HBM2  
**Performance**: 27.8 GB/s (multi-bank), 14.6 GB/s (single-bank)

## Environment Setup
```bash
source /opt/xilinx/Vitis/2023.2/settings64.sh
source /opt/xilinx/xrt/setup.sh
```

**Key Variables:**
- `XILINX_VITIS`: Vitis 2023.2 installation path
- `XILINX_XRT`: XRT runtime path (`/opt/xilinx/xrt`)

## Project Structure
```
hbm_simple_xrt/                  # Self-contained project (see README.md for details)
├── src/                         # Source files
│   ├── krnl_vadd.sv             # RTL top-level kernel
│   ├── krnl_vadd_ctrl.v         # AXI4-Lite slave (ap_ctrl_hs)
│   ├── krnl_vadd_rd_mst.v       # AXI4 burst read master
│   ├── krnl_vadd_wr_mst.v       # AXI4 burst write master
│   ├── fifo4.sv                 # FWFT FIFO (512-bit, depth=64)
│   ├── host.cpp                 # Host app: bandwidth test
│   └── host_tensor.cpp          # Host app: tensor scenario test
├── pack_kernel.tcl              # Vivado Tcl: packages RTL → .xo
├── krnl_vadd.cfg                # Linker config: HBM bank connectivity
├── krnl_vadd.xclbin             # Hardware bitstream (49MB)
├── Makefile                     # Build system (host + RTL kernel + bitstream)
└── run.sh                       # Helper script with environment setup
```

## Build Flow
The kernel is built in RTL (not HLS C++). The Makefile uses a two-step process:
1. `vivado -mode batch -source pack_kernel.tcl` → packages RTL into `krnl_vadd.xo`
2. `v++ -l` → links `.xo` into `krnl_vadd.xclbin` (uses `krnl_vadd.cfg` for HBM mapping)

Host binaries are compiled with `g++` against XRT headers/libraries.

## Key Findings
1. **Bandwidth**: Achieved ~28 GB/s using 512-bit vectorization (`ap_uint<512>` equivalent in RTL)
2. **Connectivity**: Limited to `HBM[0:3]` by `krnl_vadd.cfg` linker configuration
3. **Software Overhead**: Tensor scenarios show ~73x slowdown, justifying hardware DMA descriptors

## Next Steps: DMA IP Evolution

### Phase 2: Descriptor-Based Control
- **Goal**: Replace scalar arguments with descriptor-based interface
- **Descriptor Structure**: `{ src_addr, dst_addr, length, control_flags, next_desc_addr }`
- **Benefit**: Enable scatter/gather operations, queue multiple transfers without CPU intervention

### Phase 3: Performance Features
- **Stride/2D DMA**: Support strided access (e.g., sub-matrix extraction)
- **Interrupts**: Add `s_axilite` interrupt for completion notification
- **Multi-CU**: Scale to multiple compute units for higher throughput

## References
- [README.md](README.md) - Complete documentation and test results
- [hbm_simple_xrt/](hbm_simple_xrt/) - Source code and build artifacts