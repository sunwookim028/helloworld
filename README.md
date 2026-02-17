# HBM Data Mover

This project demonstrates a high-bandwidth **Data Mover** on the Alveo U280 FPGA using High Bandwidth Memory (HBM).

## Overview
The design acts as a pure DMA copy engine. It reads data from one HBM bank and writes it to another, saturating the AXI channels to measure peak realizable bandwidth on hardware.

## Results (Measured on U280)
*   **Single Bank Reuse**: ~13.5 GB/s (Limited by bank contention)
*   **Multi-Bank Transfer**: ~28.9 GB/s
    *   Efficiency: ~14.4 GB/s per bank (Theoretical max ~14.9 GB/s).
*   **Software-Driven Tensor Operations**: Tested via `tensor_test`.
    *   Bulk Copy: 8.47 GB/s
    *   Tiled/Row-by-Row Copy: 0.17 GB/s (Demonstrates ~84x software overhead, justifying hardware descriptors).
*   **Connectivity**: Limited to `HBM[0:3]` by bitstream configuration.

### Test Details
**Standard Bandwidth Test** (`./run.sh hbm`):
- Case 1 (Single Bank): All buffers in Bank 0 → 14.6 GB/s
- Case 2 (Multi-Bank): Buffers in Banks 1,2,3 → 27.8 GB/s (near-peak efficiency)
- Case 3 (High Banks 4,5,6): **Failed** - `std::bad_alloc` (connectivity limited to HBM[0:3])

**Tensor Scenario Test** (`./run.sh tensor`):
- Bulk Copy (1M elements, single call): 9.2 GB/s
- Software Orchestration (1024 calls of 1K elements): 0.19 GB/s
- **Overhead**: 73x slowdown demonstrates need for hardware descriptor support

## Directory Structure
```
hbm_simple_xrt/
├── src/
│   ├── host.cpp              # Standard bandwidth test (Cases 1-3)
│   ├── host_tensor.cpp       # Tensor scenario test (software orchestration)
│   └── krnl_vadd.cpp         # 512-bit pure copy kernel
├── krnl_vadd.cfg             # Linker config: HBM bank connectivity
├── xrt.ini                   # Runtime config: profiling/debug settings
├── Makefile                  # Build system (host + kernel)
├── run.sh                    # Helper script with XRT environment setup
├── hbm_simple_xrt            # Compiled host executable
├── tensor_test               # Compiled tensor test executable
├── krnl_vadd.xo              # Compiled kernel object (161KB)
└── krnl_vadd.xclbin          # Hardware bitstream (49MB)
```

## Configuration Files

### `krnl_vadd.cfg`
*   **Role**: Linker Configuration File
*   **Usage**: Tells the `v++ -l` (link) command how to map kernel arguments (`in1`, `in2`, `out`) to specific physical HBM banks (`HBM[0:3]`). Without this, the tools wouldn't know which memory interfaces to wire up.

### `xrt.ini`
*   **Role**: XRT Runtime Configuration
*   **Usage**: Read by the XRT library (on the host) at execution time. Enables features like Native Trace (`[Debug] native_xrt_trace=true`), which generates profiling data (`native_trace.csv`, `summary.csv`). Useful for debugging and profiling but not strictly required for production.

## Building and Running
### Prerequisites
*   Xilinx Vitis/XRT 2023.2

### Build
```bash
cd hbm_simple_xrt
make
```

### Run
*Ensure XRT environment is sourced before running:*
```bash
source /opt/xilinx/xrt/setup.sh
# OR use the provided wrapper script:
./run.sh hbm
```

```bash
# Standard Bandwidth Test (Manual)
./hbm_simple_xrt -x krnl_vadd.xclbin -d 0

# Software Tensor Scenario Test (Manual)
./tensor_test -x krnl_vadd.xclbin -d 0
```
