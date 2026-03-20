# mxu.sv — Matrix Unit (Systolic Array Wrapper with FSM)

**Path:** `src/mxu.sv`
**Origin:** Generalized from `minitpu/tpu/src/compute_tile/mxu.sv` (which was hardcoded for N=4)

## Purpose

The MXU is a self-contained matrix multiply accelerator. Given base addresses for weight (W), input (X), and output matrices in memory, it autonomously:

1. Loads W and X from memory into internal buffers
2. Drives the systolic array to compute **OUT = X × W^T**
3. Captures outputs as they emerge from the array
4. Stores the result back to memory

The host only needs to pulse `start` and wait for `done`.

## Interface

| Port            | Direction | Width                      | Description                         |
|-----------------|-----------|----------------------------|-------------------------------------|
| `clk`           | input     | 1                          | Clock                               |
| `rst_n`         | input     | 1                          | Active-low asynchronous reset       |
| `start`         | input     | 1                          | Pulse to begin operation            |
| `done`          | output    | 1                          | Pulses high for one cycle when done |
| `base_addr_w`   | input     | ADDRESS_WIDTH              | Memory base address for W matrix    |
| `base_addr_x`   | input     | ADDRESS_WIDTH              | Memory base address for X matrix    |
| `base_addr_out` | input     | ADDRESS_WIDTH              | Memory base address for output      |
| `mem_req_addr`  | output    | ADDRESS_WIDTH              | Memory request address              |
| `mem_req_data`  | output    | BANKING_FACTOR×DATA_WIDTH  | Memory write data                   |
| `mem_resp_data` | input     | BANKING_FACTOR×DATA_WIDTH  | Memory read response data           |
| `mem_read_en`   | output    | 1                          | Memory read enable                  |
| `mem_write_en`  | output    | 1                          | Memory write enable                 |

### Parameters

| Parameter        | Default | Description                                           |
|------------------|---------|-------------------------------------------------------|
| `N`              | 16      | Matrix dimension (N×N)                                |
| `DATA_WIDTH`     | 32      | Width of each element (FP32)                          |
| `BANKING_FACTOR` | 1       | Number of elements per memory transaction             |
| `ADDRESS_WIDTH`  | 16      | Width of memory addresses                             |
| `MEM_LATENCY`    | 2       | Clock cycles to wait for memory response              |

## FSM States

```
IDLE ──start──► LOAD_W_REQ ──► LOAD_W_WAIT ──(N² elements)──►
                                                                LOAD_X_REQ ──► LOAD_X_WAIT ──(N² elements)──►
                                                                                                              RUN ──(3N-2 phases)──►
                                                                                                                                     CAPTURE ──(wait for valid_out)──►
                                                                                                                                                                       STORE_REQ ──► STORE_WAIT ──(N² elements)──►
                                                                                                                                                                                                                    DONE ──► IDLE
```

### State Details

#### S_IDLE
Waits for `start` pulse. Latches base addresses into internal registers.

#### S_LOAD_W_REQ / S_LOAD_W_WAIT
Loads N² weight elements from memory starting at `base_addr_w`. Issues one read request per cycle, waits `MEM_LATENCY` cycles for the response, stores into `weight_matrix[]` buffer. Supports `BANKING_FACTOR` elements per transaction.

#### S_LOAD_X_REQ / S_LOAD_X_WAIT
Same pattern as weight loading, but for the X matrix from `base_addr_x` into `x_matrix[]`.

#### S_RUN
The core compute phase. Runs for `3N - 1` phases (phase_counter 0 through 3N-2), driving three interleaved pipelines into the systolic array:

**Weight Pipeline (phases 0 to 2N-2):**
- Column `c` loads weights at phases `[c, c+N-1]`
- Weight value at phase `p` for column `c`: `weight_matrix[c*N + N-1-(p-c)]`
- The reversed row order (`N-1-p`) ensures the bottom PE gets the first weight

**Switch Signal (phase N-1):**
- Single-cycle pulse that tells all PEs to swap their background weight register to the foreground

**X Input Pipeline (phases N to 3N-2):**
- Row `r` feeds activations at phases `[N+r, N+r+N-1]`
- Value: `x_matrix[(phase-N-r)*N + r]`
- The staggered start (row 0 at phase N, row 1 at phase N+1, etc.) creates the diagonal wavefront

#### S_CAPTURE
Waits for all N columns to produce N valid outputs. Uses per-column `row_ptr[col]` counters (managed in a separate `always_ff` block) to track how many results have been captured per column. Has a watchdog timeout of `4N` cycles.

#### S_STORE_REQ / S_STORE_WAIT
Writes N² output elements back to memory starting at `base_addr_out`. Same req/wait pattern as loading.

#### S_DONE
Pulses `done` for one cycle, then returns to S_IDLE.

## Output Capture (Separate always_ff Block)

Output capture runs independently from the main FSM in its own `always_ff` block (lines 120–141). On every cycle where `sys_valid_out[col]` is asserted and `row_ptr[col] < N`:

```
out_matrix[row_ptr[col] * N + col] ← sys_data_out[col*DATA_WIDTH +: DATA_WIDTH]
row_ptr[col] ← row_ptr[col] + 1
```

Both `row_ptr` and `out_matrix` are cleared on reset or on `start`.

## Internal Buffers

| Buffer          | Size         | Description                           |
|-----------------|--------------|---------------------------------------|
| `weight_matrix` | N² × 32-bit  | Local copy of W, loaded from memory   |
| `x_matrix`      | N² × 32-bit  | Local copy of X, loaded from memory   |
| `out_matrix`    | N² × 32-bit  | Captured results, stored to memory    |

## Debug Generate Block

```systemverilog
generate
    for (genvar i = 0; i < TOTAL_ELEMS; i++) begin : OUT_DEBUG
        logic [DATA_WIDTH-1:0] out_elem;
        assign out_elem = out_matrix[i];
    end
endgenerate
```

This breaks out `out_matrix` elements as named signals visible in waveform viewers and accessible from cocotb for debugging.

## Design Notes

- **MEM_LATENCY = 2:** The default was originally 1 but was changed to 2 because the cocotb memory driver runs in the ReadWrite region (after Verilog `always_ff` in the Active region). With latency 1, the MXU would capture stale data before the memory driver had a chance to update `mem_resp_data`.
- **BANKING_FACTOR = 1:** Each memory transaction reads/writes one 32-bit element. Increasing this would allow wider memory buses (e.g., 512-bit HBM).
- **Parameterized loops:** The original minitpu used hardcoded `if (phase_counter == 0)`, `if (phase_counter == 1)`, etc. for each of N phases. This version uses `for` loops that scale to any N.
