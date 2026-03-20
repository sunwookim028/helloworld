# test_mxu.py — Cocotb Test Suite for the MXU

**Path:** `verification/test_mxu.py`

## Purpose

Tests the full MXU module including its FSM, memory interface, systolic array orchestration, and output capture. Unlike the systolic array tests (which drive the array protocol directly), these tests interact with the MXU at its memory-mapped interface level: load matrices into a memory model, pulse `start`, wait for `done`, and read results back from memory.

## Test Inventory (19 tests)

| # | Test Name                     | What It Verifies                                                  |
|---|-------------------------------|-------------------------------------------------------------------|
| 1 | `test_identity`               | W = I → OUT = X (FSM end-to-end with simplest case)              |
| 2 | `test_scalar_multiply`        | W = 3I → OUT = 3X (scaling through full pipeline)                |
| 3 | `test_all_ones`               | W = all 1s → row sums (dense accumulation)                       |
| 4 | `test_zero_weight`            | W = 0 → OUT = 0 (zero propagation through MAC)                   |
| 5 | `test_zero_input`             | X = 0 → OUT = 0 (zero propagation through input path)            |
| 6 | `test_known_small_integers`   | Structured modular patterns, exact in FP32                        |
| 7 | `test_negative_values`        | W = -I → OUT = -X (sign bit handling)                             |
| 8 | `test_random_matrices`        | 5 random cases with integers in [-3, 3]                           |
| 9 | `test_back_to_back`           | Two operations without reset (state cleanup between ops)          |
| 10| `test_diagonal_weight`        | W = diag(1,2,...,N) (per-column scaling)                          |
| 11| `test_single_element`         | Only W[0][0]=1, rest zero (minimal nonzero output)                |
| 12| `test_permutation_matrix`     | Reverse permutation W (column reordering through full pipeline)   |
| 13| `test_upper_triangular`       | Upper triangular W (cumulative sums via memory→array→memory)      |
| 14| `test_lower_triangular`       | Lower triangular W (complementary pattern)                        |
| 15| `test_sparse_corners`         | Only 4 corner elements nonzero (sparse routing)                   |
| 16| `test_alternating_signs`      | Checkerboard +1/-1 (sign cancellation through full pipeline)      |
| 17| `test_large_values`           | Powers of 2 up to 256×128 (FP32 dynamic range)                   |
| 18| `test_single_row_input`       | Only row 0 of X nonzero (zero propagation through memory+array)   |
| 19| `test_triple_back_to_back`    | Three consecutive operations without reset                        |

## Key Components

### `memory_driver(dut, mem)` — Cocotb Memory Model

An `async` coroutine started with `cocotb.start_soon()` that runs continuously, modeling a simple memory:

```python
while True:
    await RisingEdge(dut.clk)
    # Read: latch address, output mem[last_addr]
    # Write: store mem[addr] = data
    dut.mem_resp_data.value = mem.get(last_addr, 0)
```

- **Read behavior:** When `mem_read_en` is asserted, the address is latched. The data for that address appears on `mem_resp_data` on the *same* rising edge (for the next cycle's capture).
- **Write behavior:** When `mem_write_en` is asserted, data is stored immediately.
- **Dictionary-based:** Uses a Python `dict` for sparse memory — only addresses that have been written contain data.

### Memory Map

| Region            | Base Address | Size   | Contents            |
|-------------------|-------------|--------|---------------------|
| Weight matrix (W) | `0x0000`    | N² words| Row-major FP32     |
| Input matrix (X)  | `0x0200`    | N² words| Row-major FP32     |
| Output matrix     | `0x0400`    | N² words| Row-major FP32     |

### `load_matrices(mem, W, X)`
Writes W and X numpy arrays into the memory dictionary at their respective base addresses, converting each float to its 32-bit IEEE-754 representation.

### `read_output(mem)`
Reads N² elements from the output region, converts from bit patterns back to floats, and returns an N×N numpy array.

### `run_matmul(dut, mem, W, X)`
Complete operation sequence:
1. Call `load_matrices()` to populate memory
2. Set base address ports
3. Pulse `start` for one cycle
4. Poll `done` for up to `TIMEOUT_CYCLES` (10,000) cycles
5. Read and return the output matrix

### `reset_dut(dut)`
Applies reset, sets base addresses, clears `mem_resp_data`.

### `assert_matrix_close(actual, expected, rtol, atol, label)`
Same element-wise comparison as the systolic array tests, with default `rtol=1e-4` and `atol=1e-5`.

## Configuration

| Variable         | Source       | Default | Description                      |
|------------------|-------------|---------|----------------------------------|
| `N`              | `MXU_N` env | 16      | Matrix dimension                 |
| `DW`             | Hardcoded   | 32      | Data width                       |
| `TIMEOUT_CYCLES` | Hardcoded   | 10,000  | Max cycles to wait for `done`    |

## Design Notes

- **MEM_LATENCY interaction:** The memory driver runs in cocotb's ReadWrite scheduling region, which executes *after* Verilog `always_ff` blocks in the Active region. This means the MXU needs `MEM_LATENCY ≥ 2` to capture valid data — with latency 1, it would sample `mem_resp_data` before the driver updates it.
- **Deterministic random:** `random.seed(0xDEAD_BEEF)` ensures reproducible random test cases.
- **Memory driver lifecycle:** A new memory driver coroutine is started for each test (or each case within `test_random_matrices`). The `mem` dictionary is fresh for each test, preventing cross-contamination.
