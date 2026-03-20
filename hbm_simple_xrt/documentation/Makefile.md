# Makefile — Verification Build and Run System

**Path:** `verification/Makefile`

## Purpose

Orchestrates compilation of SystemVerilog RTL sources with Icarus Verilog and execution of cocotb test suites via VVP (Verilog VVP simulator). Provides targets for both the systolic array and MXU at two sizes (4×4 and 16×16).

## Targets

| Target                      | Description                                                   |
|-----------------------------|---------------------------------------------------------------|
| `make all`                  | Runs `test_systolic_array`, `test_mxu`, and `test_matmul`    |
| `make test_systolic_array`  | Compile + run 16×16 systolic array tests (19 tests)           |
| `make test_mxu`             | Compile + run 16×16 MXU tests (19 tests)                      |
| `make test_matmul`          | Compile + run 16×16 matmul_top HBM integration tests (9 tests)|
| `make test_systolic_4x4`    | Compile + run 4×4 systolic array tests (fast regression)      |
| `make test_mxu_4x4`         | Compile + run 4×4 MXU tests                                   |
| `make test_matmul_4x4`      | Compile + run 4×4 matmul_top tests (fastest regression)       |
| `make clean`                | Remove `sim_build/`, `results.xml`, `__pycache__`, `*.vcd`    |

## How It Works

### Step 1: Compilation (Icarus Verilog)

Each test target depends on a compiled `.vvp` file in `sim_build/`:

```makefile
$(SIM_BUILD)/systolic_array.vvp: $(SRC_SYSTOLIC) | $(SIM_BUILD)
    iverilog -g2012 -Wall -o $@ -s systolic_array $(SRC_SYSTOLIC)
```

- **`-g2012`**: Enable SystemVerilog 2012 syntax (required for `always_ff`, `logic`, `generate`, etc.)
- **`-Wall`**: Enable all warnings
- **`-s <module>`**: Set the top-level module name
- **`-DN_PARAM=16`**: Define macro (used in some variants, though the default parameter handles this)

For 4×4 variants, parameter overrides are passed:
```makefile
-Psystolic_array.N=4    # Override N parameter at elaboration time
-Pmxu.N=4
```

### Step 2: Execution (VVP + cocotb)

```makefile
MODULE=test_systolic_array \
COCOTB_TEST_MODULES=test_systolic_array \
TOPLEVEL=systolic_array \
TOPLEVEL_LANG=verilog \
vvp -M $(COCOTB_LIBS) -m libcocotbvpi_icarus $<
```

Environment variables tell cocotb:
- `MODULE` / `COCOTB_TEST_MODULES`: Which Python test file to load
- `TOPLEVEL`: The top-level HDL module name
- `TOPLEVEL_LANG`: Language (for VPI binding selection)

VVP flags:
- `-M $(COCOTB_LIBS)`: Path to cocotb's shared library directory
- `-m libcocotbvpi_icarus`: Load the cocotb VPI module for Icarus

### RTL Source Dependencies

```
SRC_FP32     = fp32_add.sv, fp32_mul.sv
SRC_PE       = pe.sv + SRC_FP32
SRC_SYSTOLIC = systolic_array.sv + SRC_PE
SRC_MXU      = mxu.sv + SRC_SYSTOLIC
SRC_MATMUL   = matmul_top.sv + SRC_MXU
```

All source files are in `../src/` relative to the verification directory. The `SRC_MATMUL` chain includes all RTL because `matmul_top` instantiates the full `mxu` hierarchy.

### Environment Setup

The Makefile exports several variables needed by cocotb:

| Variable              | Purpose                                             |
|-----------------------|-----------------------------------------------------|
| `COCOTB_REDUCED_LOG_FMT` | Compact log format (less verbose timestamps)    |
| `LIBPYTHON_LOC`       | Path to `libpython3.so` (needed for VPI Python bridge) |
| `PYTHONPATH`          | Includes current directory for test module import   |
| `PYGPI_PYTHON_BIN`    | Python3 binary path                                 |

The cocotb VPI library path is auto-discovered:
```makefile
COCOTB_LIBS = $(shell python3 -c "import cocotb; ...")
```

## Design Notes

- **WSL required:** This Makefile is designed to run under WSL (Windows Subsystem for Linux). The Windows version of Icarus Verilog cannot load cocotb's VPI DLL due to a subsystem version mismatch.
- **No `SIM` variable:** Unlike cocotb's standard Makefile.sim flow, this Makefile directly invokes `iverilog` and `vvp` for full control over compilation flags.
- **4×4 variants share test files:** The same Python test files are used for both 4×4 and 16×16, with `N` read from environment variables (`SYSTOLIC_N`, `MXU_N`, `MATMUL_N`).
