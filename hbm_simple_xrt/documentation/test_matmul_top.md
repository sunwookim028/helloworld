# test_matmul_top.py — Cocotb Test Suite for matmul_top

**Path:** `verification/test_matmul_top.py`

Tests the full `matmul_top` pipeline using a 512-bit word-addressed memory model matching the HBM interface. Unlike `test_mxu.py` (16-bit BF16 per element), the memory model here operates on 512-bit Python integers at word-addressed locations.

## Test Inventory (9 tests)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `test_identity` | W=I → OUT=X; end-to-end HBM load/store + MXU |
| 2 | `test_zero_weight` | W=0 → OUT=0; BRAM clear on start |
| 3 | `test_small_integers` | Structured integer patterns; exact BF16 |
| 4 | `test_negative_values` | W=-I → OUT=-X; sign bit through pack/unpack |
| 5 | `test_scalar_multiply` | W=4I; word-boundary alignment |
| 6 | `test_diagonal_weight` | W=diag(1..N); partial fill within HBM words |
| 7 | `test_random_matrices` | 3 random cases in [-3,3] |
| 8 | `test_back_to_back` | Two ops without reset; BRAM cleared between runs |
| 9 | `test_hbm_word_boundary` | Only element 31 (bits [496:511]) of each word nonzero; targets MSB extraction in unpack |

## Configuration

```python
N              = int(os.environ.get("MATMUL_N", 32))
DW             = 16   # BF16
ELEMS_PER_WORD = HBM_DW // DW   # 32 BF16 elements per 512-bit word
WORDS_PER_MAT  = TOTAL_ELEMS // ELEMS_PER_WORD   # 32 words for N=32
HBM_ADDR_W     = 0
HBM_ADDR_X     = WORDS_PER_MAT               # 32
HBM_ADDR_OUT   = 2 * WORDS_PER_MAT           # 64
TIMEOUT_CYCLES = 500000
```

For N=32: `WORDS_PER_MAT=32`, addresses 0 / 32 / 64.

## Key Components

### `pack_matrix(mat, base_word_addr, mem)`
Flattens an N×N float32 array row-major, packs ELEMS_PER_WORD BF16 elements per 512-bit word. Element `i` in word `w` → bits `[i*16 +: 16]` of `mem[base + w]`. Matches the RTL's `mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH]` unpack.

### `unpack_matrix(base_word_addr, mem)`
Inverse of `pack_matrix`. Reads WORDS_PER_MAT words, extracts each 16-bit BF16 field, reconstructs N×N float32.

### `memory_driver(dut, mem)`
Cocotb coroutine modeling a 512-bit word-addressed memory with the **handshake interface** used by `matmul_top`:

```python
while True:
    await RisingEdge(dut.clk)
    last_rd_en = int(dut.mem_rd_en.value)
    last_wr_en = int(dut.mem_wr_en.value)
    addr       = int(dut.mem_addr.value)
    if last_wr_en:
        mem[addr] = int(dut.mem_wr_data.value)
    dut.mem_rd_data.value   = mem.get(addr if last_rd_en else last_addr, 0)
    dut.mem_rsp_valid.value = last_rd_en   # valid one cycle after rd_en
    dut.mem_wr_done.value   = last_wr_en   # done one cycle after wr_en
```

- **`mem_rsp_valid`**: asserted for one cycle after `mem_rd_en` was seen. `matmul_top` stalls in LOAD_W_WAIT/LOAD_X_WAIT until this is high.
- **`mem_wr_done`**: asserted for one cycle after `mem_wr_en` was seen. `matmul_top` stalls in STORE_WAIT until this is high.

### `run_matmul(dut, mem, W, X)`
1. `pack_matrix(W/X, ...)` → set `addr_w/x/out` → pulse `start` → poll `done` (up to 500k cycles) → `unpack_matrix(HBM_ADDR_OUT, mem)`.

## Design Notes

- **Python big integers**: 512-bit values fit naturally in Python's arbitrary-precision ints; no special library needed.
- **Handshake vs. fixed latency**: The memory driver asserts `mem_rsp_valid`/`mem_wr_done` the cycle *after* seeing `mem_rd_en`/`mem_wr_en`. This matches the one-cycle-delayed handshake from the AXI bridge in `krnl_matmul.sv`.
- **`test_hbm_word_boundary`**: Sets only element 31 of each word (`range(ELEMS_PER_WORD-1, TOTAL_ELEMS, ELEMS_PER_WORD)`). Catches off-by-one errors in the `[i*DW +: DW]` bit-slice where i=31 (bits [496:511]).
- **BF16 reference**: `bf16_ref(W, X)` truncates inputs to BF16 precision before computing the float32 reference.
- **Seed**: `random.seed(0xCAFE_F00D)`.
