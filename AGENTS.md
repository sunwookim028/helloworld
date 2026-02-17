# Agent Context: HBM Data Mover Project

## Quick Start
See [README.md](README.md) for complete project documentation, build instructions, and results.

## Project Status
**Current Phase**: Phase 1 Complete - Pure Data Mover verified on hardware  
**Hardware**: Alveo U280 with HBM2  
**Performance**: 27.8 GB/s (multi-bank), 14.6 GB/s (single-bank)

## Environment Setup
```bash
source /opt/xilinx/xrt/setup.sh
# Or use project root script:
source setup_xilinxtools.sh
```

**Key Variables:**
- `XILINX_VITIS`: Vitis 2023.2 installation path
- `XILINX_XRT`: XRT runtime path (`/opt/xilinx/xrt`)

## Project Structure
```
hbm_simple_xrt/          # Self-contained project (see README.md for details)
├── src/                 # Source files (host.cpp, host_tensor.cpp, krnl_vadd.cpp)
├── krnl_vadd.xclbin     # Hardware bitstream (49MB)
├── run.sh               # Helper script with environment setup
└── Makefile             # Build system (host + v++ kernel compilation)
```

## Key Findings
1. **Bandwidth**: Achieved ~28 GB/s using 512-bit vectorization (`ap_uint<512>`)
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