# test_matmul_top.py — Cocotb Test Suite for matmul_top

**Path:** `verification/test_matmul_top.py`

Tests the full `matmul_top` pipeline using a 512-bit word-addressed memory model matching the HBM interface. Unlike `test_mxu.py` (32-bit per element), the memory model here operates on 512-bit Python integers at word-addressed locations.

## Test Inventory (9 tests)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `test_identity` | W=I → OUT=X; end-to-end HBM load/store + MXU |
| 2 | `test_zero_weight` | W=0 → OUT=0; BRAM clear on start |
| 3 | `test_small_integers` | Structured integer patterns; exact FP32 |
| 4 | `test_negative_values` | W=-I → OUT=-X; sign bit through pack/unpack |
| 5 | `test_scalar_multiply` | W=5I; word-boundary alignment |
| 6 | `test_diagonal_weight` | W=diag(1..N); partial fill within HBM words |
| 7 | `test_random_matrices` | 3 random cases in [-3,3] |
| 8 | `test_back_to_back` | Two ops without reset; BRAM cleared between runs |
| 9 | `test_hbm_word_boundary` | Only element 15 (bits [480:511]) of each word nonzero; targets MSB extraction in unpack |

## Configuration

```python
N              = int(os.environ.get("MATMUL_N", 16))
ELEMS_PER_WORD = HBM_DW // DW   # 16 elements per 512-bit word
WORDS_PER_MAT  = ceil(N*N / ELEMS_PER_WORD)
HBM_ADDR_W     = 0
HBM_ADDR_X     = WORDS_PER_MAT
HBM_ADDR_OUT   = 2 * WORDS_PER_MAT
TIMEOUT_CYCLES = 50000           # larger than test_mxu.py (extra HBM phases)
```

For N=16: `WORDS_PER_MAT=16`, addresses 0/16/32. For N=4: `WORDS_PER_MAT=1`, addresses 0/1/2.

## Key Components

### `pack_matrix(mat, base_word_addr, mem)`
Flattens an N×N float32 array row-major, packs ELEMS_PER_WORD elements per 512-bit word. Element `i` in word `w` → bits `[i*32 +: 32]` of `mem[base + w]`. Matches the RTL's `mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH]` unpack.

### `unpack_matrix(base_word_addr, mem)`
Inverse of `pack_matrix`. Reads WORDS_PER_MAT words, extracts each 32-bit field, reconstructs N×N float32.

### `memory_driver(dut, mem)`
Cocotb coroutine modeling a 512-bit word-addressed memory. After each rising edge: if `mem_rd_en`, latch `last_addr`; if `mem_wr_en`, write `mem[addr]=wr_data`. Always drives `dut.mem_rd_data = mem.get(last_addr, 0)`.

Timing for `HBM_MEM_LATENCY=2`:
- Cycle N: FSM sets `mem_rd_en=1`, `mem_addr=A`. Driver (ReadWrite region) sets `mem_rd_data=mem[A]`.
- Cycle N+1: FSM waits (`lat_cnt=0 < 1`).
- Cycle N+2: FSM samples `mem_rd_data`. ✓

### `run_matmul(dut, mem, W, X)`
1. `pack_matrix(W/X, ...)` → set `addr_w/x/out` → pulse `start` → poll `done` (up to 50k cycles) → `unpack_matrix(HBM_ADDR_OUT, mem)`.

## Design Notes

- **Python big integers**: 512-bit values fit naturally in Python's arbitrary-precision ints; no special library needed.
- **`test_hbm_word_boundary`**: Sets only element 15 of each word (`range(ELEMS_PER_WORD-1, TOTAL_ELEMS, ELEMS_PER_WORD)`). Catches off-by-one errors in the `[i*DW +: DW]` bit-slice where i=15 (bits [480:511]). N=4 is especially strong here: the entire 4×4 matrix fits in one word, so any element misplacement corrupts the whole result.
- **Seed**: `random.seed(0xCAFE_F00D)`.
