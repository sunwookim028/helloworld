# Master Architecture — HBM Data Mover + Systolic Array
Three layers: **A** HBM Data Mover Kernel (FPGA DMA), **B** Systolic Array Compute Engine (matmul), **C** HBM Integration Layer (bridge).

## Subsystem A: HBM Data Mover Kernel
Pure DMA copy engine: reads 512-bit HBM words, writes to another HBM location. Benchmarks peak HBM bandwidth (~28.9 GB/s multi-bank).
```
┌──────────────────────────── krnl_vadd.sv ─────────────────────────────┐
│  krnl_vadd_ctrl.v    fifo4.sv (FWFT     krnl_vadd_rd_mst.v            │
│  (AXI-Lite slave,    512b×64)           (AXI4 burst read, AR→R→done)  │
│   ap_ctrl_hs regs)      │                       │                     │
│                    wr◄──┘          krnl_vadd_wr_mst.v                 │
│                                    (AXI4 burst write, AW→W→B→done)    │
│  m_axi_gmem0 (read)   m_axi_gmem2 (write)   m_axi_gmem1 (tied off)   │
└───────────────────────────────────────────────────────────────────────┘
```
**Data flow:** host writes addresses+size → `ap_start` → FSM fires both masters → rd master bursts HBM→FIFO → wr master pops FIFO→HBM → both done → `ap_done`. `WVALID`/`WDATA`/`fifo_rd_en` are combinational (FWFT idiom) — zero-bubble W-channel streaming.

## Subsystem B: Systolic Array Compute Engine
Computes **OUT = X × W^T** for N×N FP32 matrices (default N=16) using weight-stationary dataflow.
```
┌─────────────────────────── mxu.sv ────────────────────────────────────┐
│  Weight Buffer ──►┌──────────────────┐──► Output Capture              │
│  (N² words)       │  systolic_array  │    (N² words)   ◄──► Memory    │
│  X Buffer     ──►│  (N×N pe units)  │                      Interface  │
│  (N² words)       └──────────────────┘                                │
│  FSM: IDLE→LOAD_W→LOAD_X→RUN→CAPTURE→STORE→DONE                      │
└───────────────────────────────────────────────────────────────────────┘
```

## Subsystem C: HBM Integration Layer
`matmul_top` bridges the 512-bit HBM interface to MXU's 32-bit element interface via BRAMs.
```
┌──────────────────────────── matmul_top ───────────────────────────────┐
│  mem_rd_data   unpack     w_bram / x_bram                             │
│  (512-bit)  ──16 elems──►  (per-element)  ──► mxu.sv (Subsystem B)   │
│  mem_wr_data   pack       out_bram                                    │
│  (512-bit)  ◄─16 elems──  (per-element)  ◄── mxu.sv                  │
│  FSM: LOAD_W → LOAD_X → COMPUTE → STORE  (HBM_MEM_LATENCY=2/word)    │
└───────────────────────────────────────────────────────────────────────┘
```
**Dimensional translation:** `ELEMS_PER_WORD=16`, `WORDS_PER_MATRIX=N²/16`. At N=16: 16+16 read + 16 write = 48 HBM word transactions. At N=4: 1+1+1 = 3.

## File Dependency Graph
```
Subsystem A: krnl_vadd.sv → krnl_vadd_ctrl.v, krnl_vadd_rd_mst.v,
                             krnl_vadd_wr_mst.v, fifo4.sv
Subsystem B: mxu.sv → systolic_array.sv → pe.sv → fp32_mul.sv, fp32_add.sv
Subsystem C: matmul_top.sv → mxu.sv (full B hierarchy)
Non-RTL: kernel.xml (Vitis descriptor), package_kernel.tcl (Vivado packager), krnl_vadd.cfg (HBM connectivity)
```

## All Source Files
| File | Layer | Role |
|------|-------|------|
| `krnl_vadd.sv` | A | Kernel top-level: two-state FSM + submodule instantiation |
| `krnl_vadd_ctrl.v` | A | AXI4-Lite slave, ap_ctrl_hs register map |
| `krnl_vadd_rd_mst.v` | A | AXI4 burst read master (HBM → FIFO) |
| `krnl_vadd_wr_mst.v` | A | AXI4 burst write master (FIFO → HBM) |
| `fifo4.sv` | A | FWFT FIFO (512-bit, depth 64) |
| `fp32_mul.sv` | B | IEEE-754 FP32 multiply (combinational) |
| `fp32_add.sv` | B | IEEE-754 FP32 add (combinational) |
| `pe.sv` | B | Single MAC unit with double-buffered weights |
| `systolic_array.sv` | B | N×N PE grid, generate-block wiring |
| `mxu.sv` | B | FSM + memory interface + array orchestration |
| `matmul_top.sv` | C | 512-bit HBM ↔ 32-bit MXU bridge via BRAMs |
| `kernel.xml` | A | Vitis kernel descriptor (ports, args, offsets) |
| `package_kernel.tcl` | A | Vivado batch script → `.xo` packaging |

## Verification Files
| File | Tests | Level |
|------|-------|-------|
| `test_systolic_array.py` | 19 | Direct protocol drive to systolic_array DUT |
| `test_mxu.py` | 19 | 32-bit memory model + MXU FSM |
| `test_matmul_top.py` | 9 | 512-bit HBM memory model + matmul_top |
| `Makefile` | — | iverilog compile + cocotb/VVP execution |

## Matrix Multiply Execution: Phase-by-Phase

### Phase 1 — LOAD_W / LOAD_X
MXU reads N² elements sequentially from memory into flat row-major buffers `weight_matrix[]` and `x_matrix[]`.

### Phase 2 — RUN (3N−1 phases)
Three interleaved signal streams over `phase_counter`:
- **Weight loading (phases 0 to 2N−2):** Column `c` gets weights on phases `[c, c+N−1]`. Weight index is `W[c][N-1-p]` — reversed so weights pipeline through column correctly: first loaded ends in bottom PE, last in top PE.
- **Switch (phase N−1):** Single-cycle pulse. All PEs swap inactive→active weight. Propagates: right along row 0, then down each column.
- **Activation feeding (phases N to 3N−2):** Row `r` starts at phase `N+r` (staggered by one per row). `x_matrix[ph*N + row]` — diagonal alignment ensures activation `X[i][r]` meets the correct partial sum from above.

### Phase 3 — Inside the Array
Each PE on every valid cycle: `psum_out = (input × weight_active) + psum_in`. After N accumulations, bottom row outputs `data_out[c] = Σ X[·][r] × W[c][r] = (X × W^T)[·][c]`.

### Phase 4 — CAPTURE
Separate `always_ff` block: per-column `row_ptr[c]` increments on each `valid_out[c]`. FSM waits until all columns have N results (or 4N watchdog).

### Phase 5 — STORE
N² elements from `out_matrix[]` written sequentially back to memory.

## Timing Diagram (N=4)
```
Phase:   0    1    2    3    4    5    6    7    8    9   10
         ├── Weight loading (2N-1=7 phases) ──┤
                              │
                           Switch (ph 3)
Col 0:   W0   W0   W0   W0
Col 1:        W1   W1   W1   W1
Col 2:             W2   W2   W2   W2
Col 3:                  W3   W3   W3   W3
Row 0:                            X0   X0   X0   X0
Row 1:                                 X1   X1   X1   X1
Row 2:                                      X2   X2   X2   X2
Row 3:                                           X3   X3   X3   X3
```

## Three-Level Verification Strategy
Testing is layered so failures isolate to the right subsystem:
- **Level 1 failure** → bug in systolic array compute core or FP32 arithmetic
- **Level 2 failure** (L1 passing) → bug in MXU FSM or 32-bit memory interface
- **Level 3 failure** (L2 passing) → bug in matmul_top HBM packing/unpacking or BRAM latch timing

| | N=4 | N=16 |
|--|-----|------|
| Systolic Array (L1) | 19/19 | 19/19 |
| MXU (L2) | 19/19 | 19/19 |
| matmul_top (L3) | 9/9 | 9/9 |
| **Total** | **47/47** | **47/47** |

## Key Design Decisions and Pitfalls

**1. MEM_LATENCY = 2 (not 1)**
The cocotb memory driver runs in the ReadWrite scheduling region, after Verilog `always_ff` (Active region). With MEM_LATENCY=1 the FSM samples `mem_resp_data` in the same cycle the driver updates it — but `always_ff` fires first, reading the previous value. MEM_LATENCY=2 adds one wait cycle so the FSM samples committed data.

**2. Flat Packed Ports**
Icarus doesn't support unpacked array ports (`input logic [31:0] data_in [0:N-1]`). All array ports use flat packed vectors (`[N*DATA_WIDTH-1:0]`) with bit-slicing (`[r*DATA_WIDTH +: DATA_WIDTH]`).

**3. No `automatic` Variables**
Icarus doesn't support `automatic` in `always_ff`. Loop variables use `int` declarations at module scope: `int p; p = int'(phase_counter) - col;`

**4. Sequential Drive+Capture in cocotb**
`cocotb.start_soon()` + `await task` didn't reliably return results for concurrent coroutines. `run_matmul()` in `test_systolic_array.py` combines drive and capture in a single loop with `await Timer(1, "ns")` for combinational settling.

**5. Weight Reversal**
Weights load in reversed row order (`W[c][N-1-p]`): first weight loaded into column `c` ends up in PE[N-1][c] (bottom), last in PE[0][c] (top). After switch, PE[r][c] holds `W[c][r]` = `W^T[r][c]`.

## Origin and Lineage
All RTL adapted from **minitpu** (`minitpu/tpu/src/compute_tile/`):

| This project | minitpu original | Changes |
|---|---|---|
| `fp32_mul.sv` | `fp32_mul.sv` | Direct copy |
| `fp32_add.sv` | `fp32_add.sv` | Direct copy |
| `pe.sv` | `pe.sv` | Direct copy |
| `systolic_array.sv` | `systolic.sv` | Hardcoded 4×4 → parameterized N×N |
| `mxu.sv` | `mxu.sv` | Hardcoded if-blocks → parameterized loops, MEM_LATENCY=2 |
| `matmul_top.sv` | *(new)* | HBM integration layer; no minitpu equivalent |
