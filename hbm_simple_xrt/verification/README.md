# Verification — Systolic Array & MXU Tests

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
# All 16×16 tests (19 systolic array + 19 MXU)
make all

# Individual targets
make test_systolic_array    # 16×16 systolic array (19 tests)
make test_mxu               # 16×16 MXU with memory interface (19 tests)

# 4×4 variants (faster, good for quick regression)
make test_systolic_4x4      # 4×4 systolic array (19 tests)
make test_mxu_4x4           # 4×4 MXU (19 tests)

# Clean build artifacts
make clean
```

## What's Being Tested

Both test suites verify `OUT = X × W^T` (FP32 matrix multiply) against numpy reference results.

**Systolic array tests** (`test_systolic_array.py`) drive the array protocol directly — weights, switch, activations — bypassing the MXU FSM.

**MXU tests** (`test_mxu.py`) exercise the full pipeline: memory load → systolic array → output capture → memory store, using a cocotb memory model.

Test cases include: identity, scalar, zero, negative, diagonal, permutation, triangular, sparse, alternating signs, large values, single-row/element, random integers, and back-to-back operations.

## Documentation

See `../documentation/READING_ORDER.md` for a guided walkthrough of every file in the project.
