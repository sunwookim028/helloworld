# Verification — Systolic Array, MXU, matmul_top, krnl_matmul Tests

## Prerequisites

- **WSL** (Windows) or native Linux
- **Icarus Verilog** (`iverilog`, `vvp`) with `-g2012` support
- **Python 3** with `cocotb`, `numpy`, `find_libpython`

```bash
# Create a virtual environment named 'venv'
python3 -m venv venv

# Activate the virtual environment
source venv/bin/activate

# Install the required packages
pip install cocotb numpy find_libpython
```

## Running Tests

From the `verification/` directory (inside WSL if on Windows):

```bash
# All tests (systolic array + MXU + matmul_top + krnl_matmul)
make all

# Individual targets
make test_systolic_array    # 16×16 systolic array (19 tests)
make test_mxu               # 16×16 MXU with memory interface (19 tests)
make test_matmul            # 16×16 matmul_top HBM integration (9 tests)
make test_krnl_matmul       # Full Vitis AXI kernel (4 tests)

# Clean build artifacts
make clean
```

## What's Being Tested

All test suites verify `OUT = X × W^T` (FP32 matrix multiply, N=16) against numpy reference results.

**Systolic array tests** (`test_systolic_array.py`) drive the array protocol directly — weights, switch, activations — bypassing the MXU FSM.

**MXU tests** (`test_mxu.py`) exercise the full pipeline: memory load → systolic array → output capture → memory store, using a cocotb 32-bit memory model.

**matmul_top tests** (`test_matmul_top.py`) exercise the HBM integration layer: 512-bit word packing/unpacking, handshake memory model, and full end-to-end matmul via the HBM-width interface.

**krnl_matmul tests** (`test_krnl_matmul.py`) exercise the complete Vitis RTL kernel: AXI4-Lite host control (ap_ctrl_hs), AXI4 master memory bridge (gmem0/1/2), and back-to-back operation.

Test cases include: identity, scalar, zero, negative, diagonal, permutation, triangular, sparse, alternating signs, large values, single-row/element, random integers, and back-to-back operations.

## Documentation

See `../documentation/READING_ORDER.md` for a guided walkthrough of every file in the project.
