# Agent Context: HBM Data Mover Project

## Quick Start
See [README.md](README.md) for complete project documentation, build instructions, and results.

## Project Status
**Current Phase**: Phase 2 Implementation Complete - Descriptor-Based DMA  
**Hardware**: Alveo U280 with HBM2  
**Phase 1 Performance**: 27.8 GB/s (multi-bank), 14.6 GB/s (single-bank)  
**Phase 2 Status**: Code complete, awaiting hardware testing

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
hbm_simple_xrt/          # Self-contained project
├── src/
│   ├── Phase 1 (Baseline):
│   │   ├── host.cpp              # Standard bandwidth test
│   │   ├── host_tensor.cpp       # Tensor scenario (0.19 GB/s - 73x overhead)
│   │   └── krnl_vadd.cpp         # Pure data mover kernel
│   └── Phase 2 (Descriptor-Based):
│       ├── dma_descriptor.h      # 128-bit descriptor structure
│       ├── krnl_vadd_desc.cpp    # Descriptor-based DMA kernel
│       └── host_descriptor.cpp   # Test suite (single/chain/tensor)
├── krnl_vadd.xclbin     # Phase 1 bitstream (49MB)
├── run.sh               # Phase 1 test runner
├── run_desc.sh          # Phase 2 test runner
└── Makefile             # Build system (phase1, phase2 targets)
```

## Phase 1 Key Findings
1. **Bandwidth**: Achieved ~28 GB/s using 512-bit vectorization (`ap_uint<512>`)
2. **Connectivity**: Limited to `HBM[0:3]` by `krnl_vadd.cfg` linker configuration
3. **Software Overhead**: Tensor scenarios show ~73x slowdown (0.19 GB/s vs 9.2 GB/s)
   - Root cause: ~100μs XRT API overhead per kernel launch
   - Justifies hardware descriptor-based approach

## Phase 2: Descriptor-Based Control (IMPLEMENTED)

### Implementation Complete
- ✅ **Descriptor Structure**: 128-bit format with src/dst/length/control
- ✅ **Kernel**: Autonomous descriptor fetching and chaining
- ✅ **Host Application**: Test suite with single/chain/tensor scenarios
- ✅ **Build System**: Updated Makefile with phase2 targets
- ✅ **Documentation**: Comprehensive walkthrough

### Design Decisions
- **Descriptor Storage**: HBM-based (industry standard: Xilinx AXI DMA, Intel IOAT)
- **Memory Layout**: Descriptors in HBM[0], data in HBM[1:3]
- **Overhead**: ~10-20ns descriptor fetch vs ~100μs software orchestration

### Test Suite
1. **Single Descriptor**: 64 MB transfer (target: ≥26.5 GB/s)
2. **Chained Descriptors**: 16 × 4 MB transfers
3. **Tensor Scenario**: 1024 × 4 KB transfers (target: ≥10 GB/s, 50x improvement)

### Build Workflow (Recommended)

**Strategy**: Run long hardware builds in background tmux while verifying with fast hardware emulation.

#### Step 1: Launch Hardware Build in Background
```bash
# Source environment and start hardware build in tmux session
cd /home/sk3463/main/projects/helloworld
source setup_xilinxtools.sh

# Start hardware build in detached tmux session (~2-3 hours)
tmux new-session -d -s hbm_hw_build \
  "cd hbm_simple_xrt && make TARGET=hw krnl_vadd_desc.xclbin 2>&1 | tee build_hw.log"

# Check build progress anytime
tmux attach -t hbm_hw_build  # Ctrl+B, D to detach
tail -f hbm_simple_xrt/build_hw.log
```

#### Step 2: Verify with Hardware Emulation (Parallel)
```bash
# Build and run hardware emulation (~10-15 minutes)
cd hbm_simple_xrt
make TARGET=hw_emu krnl_vadd_desc.xclbin

# Set emulation mode and run tests
export XCL_EMULATION_MODE=hw_emu
emconfigutil --platform xilinx_u280_gen3x16_xdma_1_202211_1
./host_descriptor -x krnl_vadd_desc.xclbin -d 0 --test single
```

#### Step 3: Run on Hardware (After Build Completes)
```bash
# Unset emulation mode
unset XCL_EMULATION_MODE

# Run full test suite on U280
./run_desc.sh all
```

**Success Criteria**:
- Single descriptor: ≥26.5 GB/s (95% of Phase 1)
- Tensor scenario: ≥10 GB/s (50x improvement over 0.19 GB/s)
- Descriptor overhead: <5% performance impact

### Emulation Limitations for HBM Designs

**sw_emu (Software Emulation)**:
- ✅ **Use for**: Functional verification, host code debugging
- ❌ **NOT for**: HBM performance/bandwidth analysis (abstracts memory details)
- ⚠️ **Status**: Being deprecated (Vitis 2024.2+, removed in 2025.1)

**hw_emu (Hardware Emulation)**:
- ✅ **Use for**: RTL correctness, cycle-accurate simulation, waveform debugging
- ⚠️ **Limitations**: 
  - HBM bank conflicts and pseudo-channel details abstracted
  - Performance metrics unreliable (bandwidth/latency don't reflect real hardware)
  - Slow simulation speed (not practical for extensive testing)
- ✅ **Value**: Catches RTL issues before 2-3 hour hardware builds

**Best Practice for HBM Performance Validation**:
1. **Compile check**: Verify kernel compiles and meets timing (Fmax ≥ 300 MHz)
2. **Optional hw_emu**: Quick functional check if time permits
3. **Hardware testing**: **Always required** for performance validation
   - HBM bandwidth, latency, and bank utilization only accurate on real hardware
   - Emulation cannot predict actual HBM performance

**For this project**: Kernel compiled successfully (Fmax=411 MHz), proceed directly to hardware testing.

## Phase 3: Performance Features (PLANNED)
- **Stride/2D DMA**: Support strided access (e.g., sub-matrix extraction)
- **Descriptor Prefetch**: 4-8 entry on-chip FIFO to hide HBM latency
- **Interrupts**: Add `s_axilite` interrupt for completion notification
- **Multi-CU**: Scale to multiple compute units for higher throughput

## References
- [README.md](README.md) - Complete documentation and test results
- [hbm_simple_xrt/](hbm_simple_xrt/) - Source code and build artifacts