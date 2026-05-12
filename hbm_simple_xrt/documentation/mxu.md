# mxu.sv — Matrix Unit (Systolic Array Wrapper with FSM)

**Path:** `src/mxu.sv`
**Origin:** Generalized from `minitpu/tpu/src/compute_tile/mxu.sv` (hardcoded N=4 → parameterized N)

Autonomous matrix multiply accelerator. Given base addresses, it loads W and X from memory, drives the systolic array to compute **OUT = X × W^T**, captures outputs, and stores the result. Host pulses `start`, waits for `done`.

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low async reset |
| `start` | in | 1 | Pulse to begin |
| `done` | out | 1 | One-cycle pulse when done |
| `base_addr_w/x/out` | in | ADDRESS_WIDTH | Memory base addresses |
| `mem_req_addr` | out | ADDRESS_WIDTH | Memory address |
| `mem_req_data` | out | BANKING_FACTOR×DATA_WIDTH | Write data |
| `mem_resp_data` | in | BANKING_FACTOR×DATA_WIDTH | Read response |
| `mem_read_en` | out | 1 | Read enable |
| `mem_write_en` | out | 1 | Write enable |

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 32 | Matrix dimension (N×N) |
| `DATA_WIDTH` | 16 | Element width (BF16) |
| `BANKING_FACTOR` | 1 | Elements per memory transaction |
| `ADDRESS_WIDTH` | 16 | Memory address width |
| `MEM_LATENCY` | 2 | Cycles to wait for memory response |

## FSM

```
IDLE →(start)→ LOAD_W_REQ → LOAD_W_WAIT → (×N²) → LOAD_X_REQ → LOAD_X_WAIT → (×N²)
     → RUN → (3N-1 phases) → CAPTURE → (all outputs valid) → STORE_REQ → STORE_WAIT → (×N²) → DONE → IDLE
```

**LOAD_W_REQ/WAIT**: Sequential reads from `base_addr_w + load_idx`, waits `MEM_LATENCY` cycles, stores `mem_resp_data` into `weight_matrix[]`. Loops N² times. Same for LOAD_X into `x_matrix[]`.

**S_RUN** (3N−1 phases): Three interleaved pipelines driven by `phase_counter`:
- **Weight pipeline (phases 0 to 2N-2):** Column `c` loads at phases `[c, c+N-1]`. Value at phase p: `weight_matrix[c*N + N-1-(p-c)]`. Reversed row order ensures bottom PE gets first weight.
- **Switch (phase N-1):** Single-cycle pulse to swap background→foreground weights.
- **X input (phases N to 3N-2):** Row `r` feeds at phases `[N+r, N+r+N-1]`. Value: `x_matrix[(phase-N-r)*N + r]`.

**S_CAPTURE**: Waits for per-column `row_ptr[col]` counters (managed in separate `always_ff`) to reach N. Watchdog of 4N cycles.

**S_STORE_REQ/WAIT**: Writes `out_matrix[]` back to `base_addr_out + load_idx`, one element per cycle.

## Output Capture (Separate `always_ff`)

Runs concurrently with the FSM. On each cycle where `sys_valid_out[col]` and `row_ptr[col] < N`:
```systemverilog
out_matrix[row_ptr[col] * N + col] <= sys_data_out[col*DATA_WIDTH +: DATA_WIDTH];
row_ptr[col] <= row_ptr[col] + 1;
```
Both `row_ptr` and `out_matrix` cleared on reset and on `start`.

## Internal Buffers

| Buffer | Size | Description |
|--------|------|-------------|
| `weight_matrix` | N²×16b | W loaded from memory |
| `x_matrix` | N²×16b | X loaded from memory |
| `out_matrix` | N²×16b | Results captured, then stored |

## Design Notes

- **MEM_LATENCY=2**: Default changed from 1 to 2 because the cocotb memory driver runs in the ReadWrite region (after Verilog `always_ff` Active region). Latency 1 would sample stale data.
- **BANKING_FACTOR=1**: Each transaction is one 16-bit BF16 element. matmul_top uses this as a BRAM interface.
- **Parameterized loops**: Original minitpu used hardcoded `if (phase_counter == 0)` per phase. This version uses `for` loops scaling to any N.
- **Debug generate block**: `OUT_DEBUG[i].out_elem = out_matrix[i]` makes outputs visible in waveform viewers.
