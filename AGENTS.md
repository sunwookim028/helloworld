# Agent Context: HBM Data Mover Project

## Quick Start
See [README.md](README.md) for all build, run, and simulation commands.
See [hbm_simple_xrt/documentation/](hbm_simple_xrt/documentation/) for per-file architecture docs.

## Project Status
**Current Phase**: Phase 1 Complete — RTL Data Mover verified on hardware  
**Kernel Type**: RTL (Verilog/SystemVerilog), packaged via Vivado `package_xo`  
**Hardware**: Alveo U280 with HBM2  
**Performance**: 27.8 GB/s (multi-bank), 14.6 GB/s (single-bank)

## Project Structure
```
hbm_simple_xrt/
├── src/
│   ├── krnl_vadd.sv             # RTL top-level kernel
│   ├── krnl_vadd_ctrl.v         # AXI4-Lite slave (ap_ctrl_hs)
│   ├── krnl_vadd_rd_mst.v       # AXI4 burst read master
│   ├── krnl_vadd_wr_mst.v       # AXI4 burst write master
│   ├── fifo4.sv                 # FWFT FIFO (512-bit, depth=64)
│   ├── host.cpp                 # Host app: bandwidth test
│   └── host_tensor.cpp          # Host app: tensor scenario test
├── package_kernel.tcl           # Vivado Tcl: packages RTL → .xo
├── kernel.xml                   # RTL kernel descriptor for Vitis
├── krnl_vadd.cfg                # Linker config: HBM bank connectivity
├── Makefile                     # Build system
└── run.sh                       # Wrapper script with env setup
```

## Key Design Notes
- `m_axi_gmem1` (`in2`) is present for XRT interface compatibility but never initiates transactions.
- Max AXI4 burst = 256 beats × 64 bytes = 16 KB; rd and wr masters run in parallel via FIFO.
- `krnl_vadd.cpp` (HLS C++) is kept as reference but is not used in the build.

## Next Steps: DMA IP Evolution

### Phase 2: Descriptor-Based Control
- Replace scalar arguments with descriptor-based interface
- Enable scatter/gather operations, queue multiple transfers without CPU intervention

### Phase 3: Performance Features
- Stride/2D DMA for sub-matrix extraction
- Interrupts for completion notification
- Multi-CU for higher throughput