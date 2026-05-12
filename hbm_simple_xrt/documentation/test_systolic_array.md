# test_systolic_array.py — Cocotb Test Suite for the Systolic Array
**Path:** `verification/test_systolic_array.py`

## Purpose
Directly tests the `systolic_array` module by driving the same weight-loading, switch, and activation-feeding protocol that the MXU FSM uses. This isolates the systolic array from the MXU's memory interface and FSM logic, making it easier to diagnose whether a failure is in the array itself or in the wrapper.

## Test Inventory (19 tests)
| # | Test Name                     | What It Verifies                                                  |
|---|-------------------------------|-------------------------------------------------------------------|
| 1 | `test_identity_matrix`        | W = I → OUT = X (pass-through)                                   |
| 2 | `test_scalar_multiply`        | W = 2I → OUT = 2X (uniform scaling)                              |
| 3 | `test_all_ones`               | W = all 1s → each output element = row sum of X                  |
| 4 | `test_zero_weights`           | W = 0 → OUT = 0 regardless of X                                  |
| 5 | `test_zero_inputs`            | X = 0 → OUT = 0 regardless of W                                  |
| 6 | `test_single_column_weight`   | Only row 0 of W nonzero → only column 0 of output nonzero        |
| 7 | `test_known_small_integers`   | Structured integer patterns, hand-verifiable                      |
| 8 | `test_random_integer_matrices`| 5 random cases with integers in [-3, 3]                           |
| 9 | `test_negative_values`        | W = -I → OUT = -X (sign handling)                                 |
| 10| `test_back_to_back`           | Two matmuls without reset (no stale state)                        |
| 11| `test_permutation_matrix`     | W = reverse permutation → column reordering                      |
| 12| `test_upper_triangular`       | Upper triangular W (cumulative sum pattern)                       |
| 13| `test_lower_triangular`       | Lower triangular W (complementary accumulation)                   |
| 14| `test_sparse_matrix`          | Only 4 corner elements nonzero (selective routing)                |
| 15| `test_symmetric_weight`       | W = W^T so OUT = X × W (self-transpose invariance)               |
| 16| `test_large_values`           | Powers of 2 (exact in BF16: W=256*I, X rows = 2^(i%8))          |
| 17| `test_alternating_signs`      | Checkerboard +1/-1 in both W and X (sign cancellation stress)    |
| 18| `test_single_row_nonzero`     | Only row 0 of X nonzero (zero propagation through other rows)    |
| 19| `test_triple_back_to_back`    | Three consecutive matmuls without reset                           |

## Key Components
### BF16 Helpers
- `float_to_bits(val)` — Converts Python float to 16-bit BF16 bit pattern (`bits32 >> 16`)
- `bits_to_float(bits)` — Converts 16-bit BF16 pattern back to Python float (`bits << 16`)
- `pack_vector(values)` — Packs N 16-bit BF16 patterns into a single wide integer for flat packed ports
- `unpack_value(packed, index)` — Extracts the index-th 16-bit BF16 element from a packed vector
- `bf16_mat(m)` — Rounds a float32 numpy matrix to BF16 precision (for reference computation)

### `reset_dut(dut)`
Applies asynchronous reset for 2 cycles, then releases. Initializes all inputs to zero.

### `run_matmul(dut, W, X)` — The Core Driver
This function drives the exact same protocol as the MXU's S_RUN state, implemented as a single sequential loop (combined drive + capture). This pattern was chosen over separate concurrent cocotb tasks because `cocotb.start_soon()` + `await task` didn't reliably return coroutine results in cocotb 2.0.

**Drive phases (0 to 3N-2):**

1. **Weight loading (phases 0 to 2N-2):**
   - Column `c` loads at phases `[c, c+N-1]`
   - Weight value: `W[c][N-1-(phase-c)]` — reversed row order
   - `accept_w` bit set for active columns

2. **Switch (phase N-1):**
   - Single-cycle pulse

3. **X input feeding (phases N to 3N-2):**
   - Row `r` feeds at phases `[N+r, N+r+N-1]`
   - Value: `X[phase-N-r][r]`
   - `valid_in` bit set for active rows

**Capture phase:**
After each `RisingEdge(dut.clk)` + `Timer(1, "ns")` (to let combinational outputs settle), the function reads `valid_out` and `data_out`. For each column with valid output and `row_ptr[col] < N`, it stores the result and increments the pointer. Exits early when all columns have received N outputs.

### `assert_matrix_close(actual, expected, rtol, atol, label)`
Element-wise comparison with relative tolerance (for nonzero expected values) and absolute tolerance (for near-zero values). Default `rtol=1e-3`, `atol=1e-4`. Raises `AssertionError` with detailed position and error magnitude on mismatch.

## Configuration
| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `N`      | `SYSTOLIC_N` env var | 32 | Array dimension |
| `DW`     | Hardcoded | 16 | Data width (BF16) |

## Design Notes
- **Sequential drive+capture pattern:** The `Timer(1, "ns")` after each `RisingEdge` is critical — it allows the combinational `data_out` and `valid_out` to settle after the clock edge before sampling.
- **Deterministic random:** `random.seed(0xBEEF_CAFE)` ensures reproducible test cases across runs.
- **Reference uses `bf16_mat()`:** `expected = bf16_mat(X @ W.T)` truncates both inputs to BF16 precision before computing the reference, matching what the hardware will produce.
- **Small integer test data:** Values in [−3, 3] keep maximum sums (32 × 9 = 288) within exact BF16 range.
