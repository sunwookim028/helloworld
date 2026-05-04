# Master Architecture — HBM Matmul Kernel

This project computes **OUT = X × W^T** (32×32 FP32 matrix multiply) on an Alveo U280 using a weight-stationary systolic array, with data loaded from and stored to HBM. Three layers build on each other:

- **A: HBM Data Mover** — proven standalone DMA kernel (`krnl_vadd.sv`), reference for burst AXI patterns
- **B: Systolic Array Compute Engine** — 32×32 FP32 matrix multiply
- **C: HBM Integration Kernel** — `krnl_matmul.sv`: combines B with AXI4 master ports, Vitis ap_ctrl_hs, and an HBM bridge

## Subsystem A: HBM Data Mover (Reference)

Standalone DMA kernel used to validate HBM burst bandwidth. Not used in production but its burst AXI master pattern (`krnl_vadd_rd_mst.v`, `krnl_vadd_wr_mst.v`, `fifo4.sv`) will be integrated into krnl_matmul for burst-mode HBM reads/writes.

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

**Key lesson from krnl_vadd:** The FWFT FIFO idiom enables zero-bubble W-channel streaming. The burst masters resolve the >4KB AXI transaction bug that caused hangs in the previous C++ implementation.

## Subsystem B: Systolic Array Compute Engine

Computes **OUT = X × W^T** for 32×32 FP32 matrices using weight-stationary dataflow.

```
┌─────────────────────────── mxu.sv ────────────────────────────────────┐
│  Weight Buffer ──►┌──────────────────┐──► Output Capture              │
│  (N²=1024 words)  │  systolic_array  │    (N²=1024 words) ◄──► Memory │
│  X Buffer     ──►│  (32×32 PE units)│                      Interface  │
│  (N²=1024 words)  └──────────────────┘                                │
│  FSM: IDLE→LOAD_W→LOAD_X→RUN→CAPTURE→STORE→DONE                      │
└───────────────────────────────────────────────────────────────────────┘
```

## Subsystem C: HBM Integration Kernel

`krnl_matmul.sv` is the production kernel. It wraps `matmul_top` (the B-subsystem HBM bridge) with Vitis-compatible AXI4 master ports and the ap_ctrl_hs protocol reused from krnl_vadd_ctrl.

```
┌──────────────────────────── krnl_matmul.sv ───────────────────────────┐
│  krnl_vadd_ctrl.v  (AXI4-Lite, ap_ctrl_hs register map)              │
│                                                                        │
│  Kernel FSM: IDLE →(ap_start)→ RUN → DONE                             │
│                                                                        │
│  matmul_top (Subsystem B + HBM bridge)                                │
│    w_bram / x_bram / out_bram  ←→ mxu → systolic_array               │
│                                                                        │
│  AXI Bridge FSM: converts matmul_top's sequential word requests        │
│    into AXI4 transactions:                                             │
│      gmem0 reads → W  |  gmem1 reads → X  |  gmem2 writes → OUT      │
│    Currently: single-beat (ARLEN=0); upgrade path: burst (ARLEN=63)   │
└───────────────────────────────────────────────────────────────────────┘
```

**Current bridge:** 64+64 single-beat reads + 64 single-beat writes = 192 AXI round trips per matmul. **Planned upgrade:** use burst masters from Subsystem A → 1+1+1 = 3 burst transactions.

## matmul_top: The HBM-to-MXU Bridge

`matmul_top` unpacks 512-bit HBM words into per-element BRAMs for the MXU.

```
┌──────────────────────────── matmul_top ───────────────────────────────┐
│  mem_rd_data   unpack     w_bram / x_bram                             │
│  (512-bit)  ──16 elems──►  (per-element)  ──► mxu.sv (Subsystem B)   │
│  mem_wr_data   pack       out_bram                                    │
│  (512-bit)  ◄─16 elems──  (per-element)  ◄── mxu.sv                  │
│  FSM: LOAD_W → LOAD_X → COMPUTE → STORE  (handshake mem_rsp_valid)   │
└───────────────────────────────────────────────────────────────────────┘
```

**Dimensional translation:** `ELEMS_PER_WORD=16`, `WORDS_PER_MATRIX=64` (for N=32). 64+64 read + 64 write = 192 HBM word transactions.

**Handshake memory interface:** `mem_rsp_valid` signals that read data is available; `mem_wr_done` signals write accepted. FSM stalls in WAIT states until the signal fires. This makes `matmul_top` latency-agnostic — it works with both the fixed-latency cocotb driver and the AXI bridge in `krnl_matmul`.

## File Dependency Graph

```
Production kernel:
  krnl_matmul.sv → krnl_vadd_ctrl.v
                 → matmul_top.sv → mxu.sv → systolic_array.sv
                                           → pe.sv → fp32_mul.sv, fp32_add.sv

Reference DMA kernel (burst pattern source):
  krnl_vadd.sv   → krnl_vadd_ctrl.v
                 → krnl_vadd_rd_mst.v
                 → krnl_vadd_wr_mst.v
                 → fifo4.sv
```

## All Source Files

| File | Layer | Role |
|------|-------|------|
| `krnl_matmul.sv` | C | Production kernel: systolic matmul over HBM |
| `krnl_vadd_ctrl.v` | A/C | AXI4-Lite slave, ap_ctrl_hs register map (shared) |
| `matmul_top.sv` | C | 512-bit HBM ↔ 32-bit MXU bridge via BRAMs |
| `mxu.sv` | B | FSM + memory interface + array orchestration |
| `systolic_array.sv` | B | 32×32 PE grid, generate-block wiring |
| `pe.sv` | B | Single MAC unit with double-buffered weights |
| `fp32_mul.sv` | B | IEEE-754 FP32 multiply (combinational) |
| `fp32_add.sv` | B | IEEE-754 FP32 add (combinational) |
| `krnl_vadd.sv` | A | Reference DMA kernel (burst pattern) |
| `krnl_vadd_rd_mst.v` | A | AXI4 burst read master (HBM → FIFO) |
| `krnl_vadd_wr_mst.v` | A | AXI4 burst write master (FIFO → HBM) |
| `fifo4.sv` | A | FWFT FIFO (512-bit, depth 64) |
| `krnl_matmul.xml` | C | Vitis kernel descriptor (ports, args, offsets) |
| `pack_krnl_matmul.tcl` | C | Vivado batch script → `.xo` packaging |
| `krnl_matmul.cfg` | C | HBM bank connectivity |
| `host_matmul.cpp` | C | XRT host program, 5 test cases |

## Verification Files

| File | Tests | Level |
|------|-------|-------|
| `test_systolic_array.py` | 19 | Direct protocol drive to systolic_array DUT |
| `test_mxu.py` | 19 | 32-bit memory model + MXU FSM |
| `test_matmul_top.py` | 9 | 512-bit HBM memory model + matmul_top handshake |
| `test_krnl_matmul.py` | 4 | Full AXI4 kernel: control + gmem0/1/2 slaves |

## Matrix Multiply Execution: Phase-by-Phase

### Phase 1 — LOAD_W / LOAD_X
MXU reads N²=1024 elements sequentially from memory into flat row-major buffers `weight_matrix[]` and `x_matrix[]`.

### Phase 2 — RUN (3N−1 = 95 phases)
Three interleaved signal streams over `phase_counter`:
- **Weight loading (phases 0 to 2N−2):** Column `c` gets weights on phases `[c, c+N−1]`. Weight index is `W[c][N-1-p]` — reversed so weights pipeline through column correctly.
- **Switch (phase N−1 = 31):** Single-cycle pulse. All PEs swap inactive→active weight.
- **Activation feeding (phases N to 3N−2):** Row `r` starts at phase `N+r`. `x_matrix[ph*N + row]` — diagonal alignment ensures `X[i][r]` meets the correct partial sum from above.

### Phase 3 — Inside the Array
Each PE on every valid cycle: `psum_out = (input × weight_active) + psum_in`. After N=32 accumulations, bottom row outputs `data_out[c] = Σ X[·][r] × W[c][r] = (X × W^T)[·][c]`.

### Phase 4 — CAPTURE
Per-column `row_ptr[c]` increments on each `valid_out[c]`. FSM waits until all columns have N=32 results.

### Phase 5 — STORE
N²=1024 elements from `out_matrix[]` written sequentially back to memory.

## Three-Level Verification Strategy

Testing is layered so failures isolate to the right subsystem:
- **Level 1 failure** → bug in systolic array compute core or FP32 arithmetic
- **Level 2 failure** (L1 passing) → bug in MXU FSM or 32-bit memory interface
- **Level 3 failure** (L2 passing) → bug in matmul_top HBM packing/unpacking or handshake
- **Level 4 failure** (L3 passing) → bug in krnl_matmul AXI bridge or kernel FSM

| | N=32 |
|--|------|
| Systolic Array (L1) | 19 tests |
| MXU (L2) | 19 tests |
| matmul_top (L3) | 9 tests |
| krnl_matmul (L4) | 4 tests |
| **Total** | **51 tests** |

## Key Design Decisions and Pitfalls

**1. Handshake Memory Interface (not fixed latency)**
`matmul_top` uses `mem_rsp_valid`/`mem_wr_done` handshake signals rather than a fixed `HBM_MEM_LATENCY` counter. This makes it correct regardless of whether the memory is a cocotb model (1-cycle response) or an AXI bridge (variable latency). The cocotb driver asserts these signals 1 cycle after seeing `mem_rd_en`/`mem_wr_en`, matching the AXI bridge's behavior.

**2. Flat Packed Ports**
Icarus doesn't support unpacked array ports (`input logic [31:0] data_in [0:N-1]`). All array ports use flat packed vectors (`[N*DATA_WIDTH-1:0]`) with bit-slicing (`[r*DATA_WIDTH +: DATA_WIDTH]`).

**3. No `automatic` Variables**
Icarus doesn't support `automatic` in `always_ff`. Loop variables use `int` declarations at module scope.

**4. Weight Reversal**
Weights load in reversed row order (`W[c][N-1-p]`): first weight loaded into column `c` ends up in PE[N-1][c] (bottom), last in PE[0][c] (top). After switch, PE[r][c] holds `W[c][r]` = `W^T[r][c]`.

**5. AXI Address Routing**
Read routing in krnl_matmul uses unsigned 32-bit subtraction: `w_offs = mt_mem_addr - addr_w_word`. If `w_offs < 64` (WORDS_PER_MATRIX) → gmem0 (W), else → gmem1 (X). Works correctly for non-overlapping W/X allocations.

## Origin and Lineage

| This project | minitpu original | Changes |
|---|---|---|
| `fp32_mul.sv` | `fp32_mul.sv` | Direct copy |
| `fp32_add.sv` | `fp32_add.sv` | Direct copy |
| `pe.sv` | `pe.sv` | Direct copy |
| `systolic_array.sv` | `systolic.sv` | Hardcoded 4×4 → parameterized N×N |
| `mxu.sv` | `mxu.sv` | Hardcoded if-blocks → parameterized, N=32 default |
| `matmul_top.sv` | *(new)* | HBM integration layer, handshake interface |
| `krnl_matmul.sv` | *(new)* | Vitis kernel wrapper + AXI bridge |
| `krnl_vadd_ctrl.v` | `tpu_slave_axi_lite.v` | AXI4-Lite slave, reused unchanged |
| `krnl_vadd.sv` | *(new)* | HBM DMA reference kernel |
