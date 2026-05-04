# Makefile — Verification Build and Run System
**Path:** `verification/Makefile`

## Purpose
Orchestrates compilation of SystemVerilog RTL sources with Icarus Verilog and execution of cocotb test suites via VVP. All targets default to N=32.

## Targets
| Target                      | Description                                                        |
|-----------------------------|--------------------------------------------------------------------|
| `make all`                  | Runs all four test suites                                          |
| `make test_systolic_array`  | Compile + run 32×32 systolic array tests (19 tests)               |
| `make test_mxu`             | Compile + run 32×32 MXU tests (19 tests)                          |
| `make test_matmul`          | Compile + run 32×32 matmul_top HBM integration tests (9 tests)    |
| `make test_krnl_matmul`     | Compile + run full Vitis AXI kernel tests (4 tests)               |
| `make clean`                | Remove `sim_build/`, `results.xml`, `__pycache__`, `*.vcd`        |

## How It Works
### Step 1: Compilation (Icarus Verilog)
Each test target depends on a compiled `.vvp` file in `sim_build/`:

```makefile
$(SIM_BUILD)/systolic_array.vvp: $(SRC_SYSTOLIC) | $(SIM_BUILD)
    iverilog -g2012 -Wall -o $@ -s systolic_array $(SRC_SYSTOLIC)
```

- **`-g2012`**: Enable SystemVerilog 2012 syntax (`always_ff`, `logic`, `generate`, `typedef enum`, etc.)
- **`-Wall`**: Enable all warnings
- **`-s <module>`**: Set the top-level module name

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

### RTL Source Dependencies
```
SRC_FP32     = fp32_add.sv, fp32_mul.sv
SRC_PE       = pe.sv + SRC_FP32
SRC_SYSTOLIC = systolic_array.sv + SRC_PE
SRC_MXU      = mxu.sv + SRC_SYSTOLIC
SRC_MATMUL   = matmul_top.sv + SRC_MXU
SRC_KRNL     = krnl_matmul.sv + krnl_vadd_ctrl.v + SRC_MATMUL + fifo4.sv
```

All source files are in `../src/` relative to the verification directory. `fifo4.sv` is included in `SRC_KRNL` for forward compatibility with the planned burst-mode integration.

### Environment Setup
| Variable              | Purpose                                             |
|-----------------------|-----------------------------------------------------|
| `COCOTB_REDUCED_LOG_FMT` | Compact log format (less verbose timestamps)    |
| `LIBPYTHON_LOC`       | Path to `libpython3.so` (needed for VPI Python bridge) |
| `PYTHONPATH`          | Includes current directory for test module import   |
| `PYGPI_PYTHON_BIN`    | Python3 binary path                                 |

## Design Notes
- **WSL required on Windows:** Icarus Verilog for Windows cannot load cocotb's VPI DLL. Run under WSL.
- **No `SIM` variable:** This Makefile directly invokes `iverilog` and `vvp` for full control over compilation flags, rather than using cocotb's standard Makefile.sim flow.
- **N is baked in:** All modules default to N=32. Override with environment variables (`SYSTOLIC_N`, `MXU_N`, `MATMUL_N`) if needed for debug.
