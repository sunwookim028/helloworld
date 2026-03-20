# test_matmul_top.py — Cocotb Test Suite for matmul_top

**Path:** `verification/test_matmul_top.py`

## Purpose

Tests the full `matmul_top` pipeline at the HBM interface level: load matrices from a 512-bit word-addressed memory model, trigger computation, and verify the 512-bit output written back to memory. This is the integration-level test that exercises all three subsystems together — HBM packing/unpacking logic, MXU FSM, and the systolic array compute core.

Unlike `test_mxu.py` (which uses a 32-bit per-element memory model), this test uses a **512-bit word-addressed** memory model, matching the HBM interface that `matmul_top` exposes.

## Test Inventory (9 tests)

| # | Test Name                   | What It Verifies                                                    |
|---|-----------------------------|---------------------------------------------------------------------|
| 1 | `test_identity`             | W = I → OUT = X; end-to-end HBM load/store + MXU compute           |
| 2 | `test_zero_weight`          | W = 0 → OUT = 0; BRAM clear on start, zero word written to HBM     |
| 3 | `test_small_integers`       | Structured integer patterns; exact FP32 arithmetic through pipeline |
| 4 | `test_negative_values`      | W = -I → OUT = -X; sign bit preserved through HBM pack/unpack      |
| 5 | `test_scalar_multiply`      | W = 5I → OUT = 5X; exercises word-boundary alignment               |
| 6 | `test_diagonal_weight`      | W = diag(1,2,...,N); partial fill within each HBM word             |
| 7 | `test_random_matrices`      | 3 random integer cases in [-3,3]; general correctness               |
| 8 | `test_back_to_back`         | Two operations without reset; verifies BRAM cleared between runs    |
| 9 | `test_hbm_word_boundary`    | Only element index 15 (last per word) nonzero; stresses unpacker   |

## Key Components

### Configuration Constants

```python
N             = int(os.environ.get("MATMUL_N", 16))
DW            = 32             # Data width per element
HBM_DW        = 512            # HBM bus width
ELEMS_PER_WORD = HBM_DW // DW  # 16 elements per 512-bit word
TOTAL_ELEMS   = N * N
WORDS_PER_MAT = ceil(TOTAL_ELEMS / ELEMS_PER_WORD)
```

HBM memory layout (word-addressed):

| Region | Word Address             |
|--------|--------------------------|
| W      | `HBM_ADDR_W = 0`         |
| X      | `HBM_ADDR_X = WORDS_PER_MAT` |
| OUT    | `HBM_ADDR_OUT = 2 * WORDS_PER_MAT` |

For N=16: `WORDS_PER_MAT=16`, so W at 0, X at 16, OUT at 32.
For N=4:  `WORDS_PER_MAT=1`,  so W at 0, X at 1,  OUT at 2.

### `pack_matrix(mat, base_word_addr, mem)`

Converts an N×N float32 numpy array to 512-bit HBM words and writes them into the `mem` dictionary:

```python
for w in range(WORDS_PER_MAT):
    word_val = 0
    for i in range(ELEMS_PER_WORD):
        elem_idx = w * ELEMS_PER_WORD + i
        elem_f = flat[elem_idx] if elem_idx < len(flat) else 0.0
        word_val |= (float_to_bits(elem_f) & 0xFFFFFFFF) << (i * DW)
    mem[base_word_addr + w] = word_val
```

Element layout within each word: element `i` occupies bits `[i*32 + 31 : i*32]`, matching the `matmul_top` RTL's `mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH]` unpack pattern.

### `unpack_matrix(base_word_addr, mem)`

Reads `WORDS_PER_MAT` words from `mem`, extracts 32-bit fields, and reconstructs the N×N float32 array. The inverse of `pack_matrix`.

### HBM Memory Driver (`memory_driver(dut, mem)`)

A cocotb coroutine modeling a word-addressed 512-bit memory:

```python
async def memory_driver(dut, mem):
    last_addr = 0
    while True:
        await RisingEdge(dut.clk)
        rd_en   = int(dut.mem_rd_en.value)
        wr_en   = int(dut.mem_wr_en.value)
        addr    = int(dut.mem_addr.value)
        wr_data = int(dut.mem_wr_data.value)

        if rd_en:   last_addr = addr
        if wr_en:   mem[addr] = wr_data

        dut.mem_rd_data.value = mem.get(last_addr, 0)
```

**Timing:** Matches `HBM_MEM_LATENCY=2` in the DUT:
- Cycle N: FSM asserts `mem_rd_en=1`, `mem_addr=A`. Driver (running in cocotb's ReadWrite region) latches `last_addr=A` and sets `mem_rd_data=mem[A]`.
- Cycle N+1: FSM waits (`lat_cnt=0 < HBM_MEM_LATENCY-1=1`).
- Cycle N+2: FSM samples `mem_rd_data` (valid). ✓

Write transactions are captured immediately: when the FSM asserts `mem_wr_en` and `mem_wr_data`, the driver writes `mem[addr] = wr_data` at that rising edge. The DUT's STORE state also uses `HBM_MEM_LATENCY` wait cycles, but for writes this is just pacing — the memory model doesn't need latency to capture a write.

### `run_matmul(dut, mem, W, X)`

Complete operation:

1. Call `pack_matrix(W, HBM_ADDR_W, mem)` and `pack_matrix(X, HBM_ADDR_X, mem)`
2. Set `addr_w`, `addr_x`, `addr_out` ports
3. Pulse `start` for one cycle
4. Poll `done` for up to `TIMEOUT_CYCLES` (50,000) cycles
5. Call `unpack_matrix(HBM_ADDR_OUT, mem)` and return the result

The timeout is 50,000 cycles — larger than `test_mxu.py`'s 10,000 — because `matmul_top` has additional HBM load/store phases beyond the MXU's compute time.

### `assert_matrix_close(actual, expected, rtol, atol, label)`

Element-wise comparison with `rtol=1e-4`, `atol=1e-5` by default. Same function as in the other test suites.

## Configuration

| Variable     | Source        | Default | Description                  |
|--------------|---------------|---------|------------------------------|
| `N`          | `MATMUL_N` env| 16      | Matrix dimension              |
| `TIMEOUT_CYCLES` | Hardcoded | 50,000  | Max cycles to wait for `done` |

The Makefile sets `MATMUL_N=4` for the 4×4 variant.

## Design Notes

- **512-bit Python integers:** Python's arbitrary-precision integers naturally hold 512-bit values. The `mem` dictionary maps word addresses to these integers, so no special bit-vector library is needed.
- **Seed:** `random.seed(0xCAFE_F00D)` for deterministic random test cases.
- **`test_hbm_word_boundary`** specifically targets element index `ELEMS_PER_WORD - 1 = 15` (the MSB field of each 512-bit word) being the only nonzero element. This catches off-by-one errors in the `i*DATA_WIDTH +: DATA_WIDTH` bit-slice unpack logic.
- **Back-to-back test:** Verifies that `out_bram` is cleared at the start of each operation. If it were not, results from a first run could contaminate the second.
- **N=4 fast regression:** At N=4, `WORDS_PER_MAT=1` — the entire W matrix fits in one 512-bit word. This makes N=4 tests especially good at catching element-ordering bugs in the pack/unpack logic since all elements are visible within a single memory transaction.
