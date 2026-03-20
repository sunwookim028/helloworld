# Master Architecture — HBM Data Mover + 16×16 Systolic Array

This document explains how all the RTL and verification files connect together. The project contains three layers:

1. **HBM Data Mover Kernel** — A Vitis RTL kernel that performs DMA copies through HBM on an Alveo U280. FPGA-deployable.
2. **Systolic Array Compute Engine** — A 16×16 weight-stationary matrix multiply unit with full cocotb verification.
3. **HBM Integration Layer** — `matmul_top`: bridges the 512-bit HBM interface to the MXU's 32-bit element interface.

---

## Subsystem A: HBM Data Mover Kernel

A pure DMA copy engine: reads 512-bit words from HBM bank(s) and writes them to another location. Used to benchmark peak HBM bandwidth (~28.9 GB/s multi-bank).

```
┌───────────────────────────────────────────────────────┐
│                    krnl_vadd.sv                       │
│                   (RTL Kernel Top)                    │
│                                                       │
│  ┌─────────────┐   ┌──────────┐   ┌──────────────┐   │
│  │ krnl_vadd   │   │          │   │ krnl_vadd    │   │
│  │ _ctrl.v     │   │  fifo4   │   │ _rd_mst.v    │   │
│  │ (AXI-Lite)  │   │  (FWFT)  │   │ (AXI4 Read)  │   │
│  │             │   │ 512b×64  │   │              │   │
│  │ ap_ctrl_hs  │   │          │   │  AR→R→done   │   │
│  │ reg map     │   └────┬─────┘   └──────┬───────┘   │
│  └──────┬──────┘        │                │            │
│         │               │     ┌──────────▼───────┐   │
│    start/done      wr◄──┘     │ krnl_vadd        │   │
│    addresses              rd──┤ _wr_mst.v        │   │
│    size                       │ (AXI4 Write)     │   │
│                               │ AW→W→B→done      │   │
│                               └──────────────────┘   │
│                                                       │
│  m_axi_gmem0 (read)    m_axi_gmem2 (write)           │
│  m_axi_gmem1 (unused, tied off for XRT compat)       │
└───────────────────────────────────────────────────────┘
         │                           │
     ┌───▼───┐                   ┌───▼───┐
     │  HBM  │                   │  HBM  │
     │Bank(s)│                   │Bank(s)│
     └───────┘                   └───────┘
```

### Kernel Files

| File                   | Role                                                    |
|------------------------|---------------------------------------------------------|
| `krnl_vadd.sv`         | Top-level: instantiates ctrl, rd_mst, wr_mst, FIFO     |
| `krnl_vadd_ctrl.v`     | AXI4-Lite slave, ap_ctrl_hs registers                   |
| `krnl_vadd_rd_mst.v`   | AXI4 burst read master (512-bit, up to 256-beat bursts) |
| `krnl_vadd_wr_mst.v`   | AXI4 burst write master (FWFT FIFO consumer)            |
| `fifo4.sv`             | 512-bit FWFT FIFO, depth 64, decouples read/write       |
| `kernel.xml`           | Vitis kernel descriptor (ports, args, register offsets)  |
| `package_kernel.tcl`   | Vivado batch script to package RTL into `.xo`            |

### Data Flow

1. Host writes addresses + size to AXI-Lite registers, sets `ap_start`
2. Top FSM fires `start_masters` to both read and write masters simultaneously
3. Read master issues AXI4 bursts to HBM, pushes 512-bit words into FIFO
4. Write master pops from FIFO, issues AXI4 bursts to write side of HBM
5. When both masters signal done, top FSM pulses `ap_done`

The FWFT FIFO idiom is critical: `WVALID`, `WDATA`, and `fifo_rd_en` are all combinational, achieving zero-bubble streaming between read and write paths.

---

## Subsystem B: Systolic Array Compute Engine

Computes **OUT = X × W^T** for N×N FP32 matrices (default N=16) using a weight-stationary systolic array. Two layers:

1. **Compute core** — The systolic array itself (256 PEs in a 16×16 grid)
2. **Controller** — The MXU FSM that orchestrates memory loads, array driving, and result storage

```
┌─────────────────────────────────────────────────────────┐
│                         MXU                             │
│                                                         │
│  ┌──────────┐    ┌────────────────────┐    ┌─────────┐  │
│  │          │    │                    │    │         │  │    ┌──────────┐
│  │ Weight   │───►│                    │───►│ Output  │──┼───►│          │
│  │ Buffer   │    │   Systolic Array   │    │ Capture │  │    │  Memory  │
│  │ (N²)     │    │   (N×N PEs)        │    │ (N²)    │  │    │Interface │
│  └──────────┘    │                    │    └─────────┘  │    │          │
│  ┌──────────┐    │                    │                 │◄──►│ mem_req  │
│  │ X Buffer │───►│                    │                 │    │ mem_resp │
│  │ (N²)     │    └────────────────────┘                 │    │ mem_r/w  │
│  └──────────┘                                           │    └──────────┘
│                                                         │
│  ┌──────────┐                                           │
│  │   FSM    │  IDLE→LOAD_W→LOAD_X→RUN→CAPTURE→STORE   │
│  └──────────┘                                           │
└─────────────────────────────────────────────────────────┘
```

---

## Complete File Dependency Graph

```
Subsystem A: HBM Data Mover Kernel
──────────────────────────────────
krnl_vadd.sv (top-level kernel)
├── krnl_vadd_ctrl.v      (AXI4-Lite slave, register file)
├── krnl_vadd_rd_mst.v    (AXI4 burst read master)
├── krnl_vadd_wr_mst.v    (AXI4 burst write master)
└── fifo4.sv              (512-bit FWFT FIFO, depth=64)

kernel.xml                (Vitis kernel descriptor)
package_kernel.tcl        (Vivado IP packaging script)

Subsystem B: Systolic Array Compute Engine
──────────────────────────────────────────
mxu.sv (matrix unit controller)
└── systolic_array.sv
    └── pe.sv  (×N², instantiated via generate)
        ├── fp32_mul.sv  (combinational FP32 multiplier)
        └── fp32_add.sv  (combinational FP32 adder)

Integration Layer (Subsystem C)
────────────────────────────────
matmul_top.sv (HBM-width wrapper)
└── mxu.sv (full Subsystem B hierarchy)

Shared: fifo4.sv used by Subsystem A;
        fp32_mul.sv, fp32_add.sv, pe.sv are from minitpu
```

### All Source Files

| File                 | Layer | Role                                              |
|----------------------|-------|---------------------------------------------------|
| `krnl_vadd.sv`       | A     | Kernel top-level: FSM + submodule instantiation   |
| `krnl_vadd_ctrl.v`   | A     | AXI4-Lite slave, ap_ctrl_hs register map          |
| `krnl_vadd_rd_mst.v` | A     | AXI4 burst read master (HBM → FIFO)              |
| `krnl_vadd_wr_mst.v` | A     | AXI4 burst write master (FIFO → HBM)             |
| `fifo4.sv`           | A     | FWFT FIFO (512-bit, depth 64)                     |
| `fp32_mul.sv`        | B     | IEEE-754 FP32 multiply (combinational)            |
| `fp32_add.sv`        | B     | IEEE-754 FP32 add (combinational)                 |
| `pe.sv`              | B     | Single MAC unit with double-buffered weights      |
| `systolic_array.sv`  | B     | N×N PE grid with generate-block wiring            |
| `mxu.sv`             | B     | FSM + memory interface + array orchestration      |
| `matmul_top.sv`      | C     | 512-bit HBM ↔ 32-bit MXU bridge via BRAMs        |

### Non-RTL Files

| File                 | Layer | Role                                              |
|----------------------|-------|---------------------------------------------------|
| `kernel.xml`         | A     | Vitis kernel descriptor (ports, args, offsets)    |
| `package_kernel.tcl` | A     | Vivado batch script → `.xo` packaging            |
| `krnl_vadd.cfg`      | A     | Vitis linker connectivity (HBM bank assignments)  |

### Verification Files

| File                      | Tests               | Level                                          |
|---------------------------|---------------------|------------------------------------------------|
| `test_systolic_array.py`  | 19 tests            | Array-level (direct protocol drive)            |
| `test_mxu.py`             | 19 tests            | MXU-level (32-bit memory model)                |
| `test_matmul_top.py`      | 9 tests             | Integration-level (512-bit HBM memory model)   |
| `Makefile`                | Build orchestration | Compiles RTL, runs cocotb via VVP              |
| `run_test.sh`             | Environment helper  | Clean WSL PATH for make invocation             |

---

## Data Flow: How a Matrix Multiply Executes

### Phase 1: Memory → Buffers (LOAD_W, LOAD_X)

The MXU FSM reads N² elements from memory for each matrix:

```
Memory[base_addr_w + 0]   → weight_matrix[0]      (W[0][0])
Memory[base_addr_w + 1]   → weight_matrix[1]      (W[0][1])
...
Memory[base_addr_w + N²-1]→ weight_matrix[N²-1]   (W[N-1][N-1])
```

Same pattern for X. Both matrices are stored row-major in flat arrays.

### Phase 2: Buffers → Systolic Array (RUN)

The FSM drives three interleaved signal pipelines over `3N - 1` clock phases:

#### Weight Loading (phases 0 to 2N-2)

Each column `c` receives its N weights over phases `[c, c+N-1]`:

```
Phase 0:  col 0 gets W[0][N-1]  (bottom PE's weight loaded first)
Phase 1:  col 0 gets W[0][N-2],  col 1 gets W[1][N-1]
Phase 2:  col 0 gets W[0][N-3],  col 1 gets W[1][N-2],  col 2 gets W[2][N-1]
...
```

The reversed order (`N-1-p`) is critical: weights pipeline downward through the column, so the first weight loaded ends up in the bottom PE, and the last weight ends up in the top PE. After switch, each PE[r][c] holds `W[c][r]` — the transpose happens naturally.

#### Switch (phase N-1)

A single-cycle pulse tells all PEs to swap their background weight register to the foreground. After this point, every PE has its operational weight loaded and is ready to compute.

The switch signal propagates:
1. Right along row 0: PE[0][0] → PE[0][1] → ... → PE[0][N-1]
2. Down each column: PE[0][c] → PE[1][c] → ... → PE[N-1][c]

#### Activation Feeding (phases N to 3N-2)

Row `r` starts feeding at phase `N + r` (staggered by one cycle per row):

```
Phase N:    row 0 gets X[0][0]
Phase N+1:  row 0 gets X[1][0],  row 1 gets X[0][1]
Phase N+2:  row 0 gets X[2][0],  row 1 gets X[1][1],  row 2 gets X[0][2]
...
```

The diagonal staggering aligns with the systolic array's pipeline depth — by the time X[i][r] reaches PE[r][c], the partial sum from PE[r-1][c] is also arriving.

### Phase 3: Inside the Systolic Array

Each PE computes on every clock cycle (when valid):

```
PE[r][c].psum_out = PE[r][c].input_in × PE[r][c].weight_active + PE[r][c].psum_in
```

Where:
- `input_in` = activation arriving from the west (from PE[r][c-1] or the west edge)
- `weight_active` = the weight loaded during Phase 2 = `W[c][r]`
- `psum_in` = partial sum from PE[r-1][c] above (or 0 at the top edge)

As activations flow left→right and partial sums accumulate top→bottom, the bottom row of the array outputs the final dot products:

```
data_out[c] = Σ(r=0 to N-1) X[·][r] × W[c][r] = (X × W^T)[·][c]
```

Each column `c` outputs N values sequentially (one per activation wavefront), producing one full column of the output matrix.

### Phase 4: Output Capture (CAPTURE)

The output capture logic runs in a separate `always_ff` block, concurrently with the FSM:

```
For each column c:
    When valid_out[c] is asserted and row_ptr[c] < N:
        out_matrix[row_ptr[c] * N + c] = data_out[c]
        row_ptr[c]++
```

The `row_ptr[c]` counter tracks how many results have been captured for each column. The CAPTURE state waits until all N columns have received all N outputs (or a 4N-cycle watchdog fires).

### Phase 5: Buffers → Memory (STORE)

The FSM writes N² elements back to memory:

```
out_matrix[0]      → Memory[base_addr_out + 0]     (OUT[0][0])
out_matrix[1]      → Memory[base_addr_out + 1]     (OUT[0][1])
...
out_matrix[N²-1]   → Memory[base_addr_out + N²-1]  (OUT[N-1][N-1])
```

---

## Timing Diagram (Simplified, N=4)

```
Phase:  0    1    2    3    4    5    6    7    8    9   10   ...
        ├────────────────────┤    ├────────────────────┤
        Weight loading            X input feeding
                         │
                       Switch
                       (phase 3)

Col 0:  W0   W0   W0   W0
Col 1:       W1   W1   W1   W1
Col 2:            W2   W2   W2   W2
Col 3:                 W3   W3   W3   W3

Row 0:                           X0   X0   X0   X0
Row 1:                                X1   X1   X1   X1
Row 2:                                     X2   X2   X2   X2
Row 3:                                          X3   X3   X3   X3

Outputs begin emerging ~N cycles after first X input
```

---

## Verification Architecture

### Three-Level Testing Strategy

```
Level 1: Systolic Array Tests (test_systolic_array.py)
┌──────────────────────────────────────────────┐
│  Python test code                            │
│  ├── Directly drives weight_in, accept_w     │
│  ├── Directly drives switch_in               │
│  ├── Directly drives data_in, valid_in       │
│  └── Directly reads data_out, valid_out      │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │        systolic_array (DUT)            │  │
│  │        └── N×N pe instances            │  │
│  │            └── fp32_mul + fp32_add     │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘

Level 2: MXU Tests (test_mxu.py)
┌──────────────────────────────────────────────┐
│  Python test code                            │
│  ├── Writes W and X to 32-bit memory dict    │
│  ├── Pulses start, waits for done            │
│  └── Reads output from 32-bit memory dict    │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │              mxu (DUT)                 │  │
│  │  ├── FSM (load, run, capture, store)   │  │
│  │  ├── systolic_array                    │  │
│  │  │   └── N×N pe instances              │  │
│  │  └── Memory interface (32-bit)         │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  memory_driver (cocotb coroutine)      │  │
│  │  └── Python dict, 32-bit per address   │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘

Level 3: matmul_top Tests (test_matmul_top.py)
┌──────────────────────────────────────────────┐
│  Python test code                            │
│  ├── pack_matrix() → 512-bit HBM words       │
│  ├── Pulses start, waits for done            │
│  └── unpack_matrix() ← 512-bit HBM words     │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │          matmul_top (DUT)              │  │
│  │  ├── Top FSM (LOAD_W/X, COMPUTE, STORE)│  │
│  │  ├── w_bram, x_bram, out_bram          │  │
│  │  └── mxu (full Level 2 hierarchy)      │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  memory_driver (cocotb coroutine)      │  │
│  │  └── Python dict, 512-bit per address  │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

**Why three levels?**
- A Level 1 failure isolates the bug to the systolic array compute core or FP32 arithmetic.
- A Level 2 failure (with Level 1 passing) isolates the bug to the MXU FSM or memory interface.
- A Level 3 failure (with Level 2 passing) isolates the bug to `matmul_top`'s HBM packing/unpacking logic or BRAM latch timing.

### Test Matrix

All tests run at both N=4 and N=16:

```
                     4×4          16×16
Systolic Array:    19/19 PASS    19/19 PASS
MXU:               19/19 PASS    19/19 PASS
matmul_top:         9/9  PASS     9/9  PASS
────────────────────────────────────────────
Total:                   94/94 PASS
```

---

## Key Design Decisions and Pitfalls

### 1. MEM_LATENCY = 2 (not 1)

The cocotb memory driver runs in the ReadWrite scheduling region, *after* Verilog `always_ff` blocks execute in the Active region. With MEM_LATENCY=1, the MXU captures `mem_resp_data` on the same cycle the driver updates it — but in Verilog simulation order, the `always_ff` fires first, reading the *previous* value. Setting MEM_LATENCY=2 adds one extra wait cycle, ensuring the FSM samples data that the memory driver has already committed.

### 2. Flat Packed Ports

Icarus Verilog doesn't support unpacked array ports (`input logic [31:0] data_in [0:N-1]`). All array ports use flat packed vectors (`input logic [N*DATA_WIDTH-1:0] data_in`) with bit-slicing (`data_in[r*DATA_WIDTH +: DATA_WIDTH]`).

### 3. No `automatic` Variables

Icarus doesn't support `automatic` variable lifetime overrides in `always_ff` blocks. Loop variables use `int` declarations with separate assignment statements:
```systemverilog
int p;
p = int'(phase_counter) - col;  // NOT: automatic int p = ...;
```

### 4. Sequential Drive+Capture in cocotb

Cocotb 2.0's `cocotb.start_soon()` + `await task` pattern didn't reliably return coroutine results for concurrent tasks. The systolic array test's `run_matmul()` combines drive and capture in a single loop with `await Timer(1, "ns")` for combinational settling.

### 5. Weight Reversal

Weights are loaded in reversed row order (`W[c][N-1-p]`) so they pipeline correctly: the first weight loaded into column `c` ends up in PE[N-1][c] (bottom), and the last ends up in PE[0][c] (top). After switch, PE[r][c] holds `W[c][r]`, which is exactly `W^T[r][c]`.

---

---

## Subsystem C: HBM Integration Layer

`matmul_top` is the bridge between Subsystems A and B. It presents the same 512-bit word-addressed memory interface as HBM, and internally drives the MXU with per-element BRAM reads.

```
┌────────────────────────────────────────────────────────────────┐
│                       matmul_top                               │
│                                                                │
│  512-bit HBM interface          32-bit MXU interface          │
│  (word-addressed)               (element-addressed)           │
│                                                                │
│  ┌──────────┐  unpack    ┌───────────┐    ┌───────────────┐   │
│  │mem_rd_data│ 16 elems  │  w_bram   │───►│               │   │
│  │(512-bit) │──────────►│  x_bram   │    │   mxu.sv      │   │
│  └──────────┘  per word  └───────────┘    │   (Subsystem  │   │
│                                           │    B)         │   │
│  ┌──────────┐  pack      ┌───────────┐◄───│               │   │
│  │mem_wr_data│ 16 elems  │  out_bram │    └───────────────┘   │
│  │(512-bit) │◄──────────│           │                        │
│  └──────────┘  per word  └───────────┘                        │
│                                                                │
│  Top FSM:                                                      │
│  LOAD_W → LOAD_X → COMPUTE → STORE                            │
│  (HBM_MEM_LATENCY=2 wait per word on reads and writes)        │
└────────────────────────────────────────────────────────────────┘
         │                                           │
    HBM words in                              HBM words out
  (W and X matrices)                        (OUT matrix)
```

### Data Translation

At N=16 with 512-bit HBM and 32-bit elements:
- Each HBM word holds **16 elements** (`ELEMS_PER_WORD = 512/32`)
- Each N×N matrix requires **16 HBM words** (`WORDS_PER_MATRIX = 256/16`)
- Total HBM transactions per matrix multiply: 32 reads (W+X) + 16 writes (OUT) = **48 HBM word transactions**

At N=4:
- Each N×N matrix (16 elements) fits in **exactly one** HBM word
- Total: 2 reads + 1 write = **3 HBM word transactions**

---

## Origin and Lineage

All RTL modules are adapted from the **minitpu** project (`minitpu/tpu/src/compute_tile/`):

| This project           | minitpu original                | Changes                                        |
|------------------------|---------------------------------|------------------------------------------------|
| `fp32_mul.sv`          | `fp32_mul.sv`                   | Direct copy                                    |
| `fp32_add.sv`          | `fp32_add.sv`                   | Direct copy                                    |
| `pe.sv`                | `pe.sv`                         | Direct copy                                    |
| `systolic_array.sv`    | `systolic.sv`                   | Hardcoded 4×4 → parameterized N×N              |
| `mxu.sv`               | `mxu.sv`                        | Hardcoded if-blocks → parameterized loops, MEM_LATENCY=2 |
| `matmul_top.sv`        | *(new)*                         | New integration layer; no minitpu equivalent   |

The test suites are new but follow the same protocol and mathematical conventions (`OUT = X × W^T`) as minitpu's verification.
