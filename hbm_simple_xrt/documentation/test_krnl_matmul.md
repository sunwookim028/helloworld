# test_krnl_matmul.py — Cocotb Test Suite for krnl_matmul (Burst AXI)

**Path:** `verification/test_krnl_matmul.py`

Tests the complete `krnl_matmul` Vitis kernel at the AXI protocol level. Models both the AXI4-Lite host control interface and three AXI4 burst memory slave ports (gmem0/1/2) in Python, then runs the full ap_ctrl_hs start/poll sequence.

## Test Inventory (4 tests)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `test_identity` | W=I → OUT=X; full burst AXI4 round-trip + kernel control |
| 2 | `test_zero_weight` | W=0 → OUT=0; FIFOs and BRAMs cleared between runs |
| 3 | `test_small_integers` | Structured integer patterns; exact FP32 |
| 4 | `test_random` | Two back-to-back random matmuls without reset |

## Memory Layout

```
gmem0 (W):   byte 0x0000 → word 0   (64 words × 64 bytes = 4096 bytes)
gmem1 (X):   byte 0x1000 → word 64
gmem2 (OUT): byte 0x2000 → word 128
```

All three memories share a single Python dict `mem` keyed by word address (byte_addr >> 6).

## Key Components

### AXI4 Burst Read Slave (`axi_rd_slave`)
Handles the burst read pattern issued by `krnl_vadd_rd_mst`:
1. Waits for ARVALID; accepts with ARREADY=1
2. Reads `ARLEN` from the DUT port → sends `ARLEN+1` R beats
3. Asserts RLAST on the final beat; loops to accept the next AR transaction

For page-aligned 4096-byte matrices, rd_mst issues exactly one 64-beat burst (ARLEN=63) per matrix.

### AXI4 Burst Write Slave (`axi_wr_slave`)
Handles the burst write pattern issued by `krnl_vadd_wr_mst`:
1. Waits for AWVALID; accepts AW address and `AWLEN`
2. Accepts `AWLEN+1` W beats with WREADY=1
3. Sends BVALID after all beats received; waits for BREADY

### `start_slaves(dut, mem)`
Launches all three slave coroutines with `cocotb.start_soon()`. Called once per test; slaves loop indefinitely handling successive transactions.

### `run_kernel_matmul(dut, W, X, mem)`
Complete host-side sequence:
1. Pack W into `mem` starting at word 0, X at word 64
2. Write six AXI-Lite registers: `in1_lo/hi` (W addr), `in2_lo/hi` (X addr), `out_lo/hi` (OUT addr)
3. Write `ap_start = 1` to REG_CTRL (offset 0x00)
4. Poll REG_CTRL bit 1 (`ap_done`) for up to TIMEOUT_CYCLES
5. Unpack OUT from `mem` starting at word 128

### Register Map Used
```python
REG_CTRL   = 0x00   # [0]=ap_start, [1]=ap_done, [2]=ap_idle
REG_IN1_LO = 0x10   # W byte address [31:0]
REG_IN1_HI = 0x14   # W byte address [63:32]
REG_IN2_LO = 0x18   # X byte address [31:0]
REG_IN2_HI = 0x1C   # X byte address [63:32]
REG_OUT_LO = 0x20   # OUT byte address [31:0]
REG_OUT_HI = 0x24   # OUT byte address [63:32]
```

## Configuration

| Variable | Value | Description |
|----------|-------|-------------|
| `N` | 32 | Matrix dimension |
| `TIMEOUT_CYCLES` | 500,000 | Max cycles to wait for ap_done |
| W base | 0x0000 | Byte address of W in gmem0 |
| X base | 0x1000 | Byte address of X in gmem1 |
| OUT base | 0x2000 | Byte address of OUT in gmem2 |

## Design Notes

- **Burst protocol**: slaves read `arlen`/`awlen` from the DUT and loop for exactly that many beats. For N=32 with page-aligned addresses, rd_mst always issues ARLEN=63 (64 beats = one full matrix) per transaction.
- **Three concurrent slaves**: started with `cocotb.start_soon()` before the kernel runs, looping independently.
- **Single shared dict**: gmem0, gmem1, gmem2 share `mem` keyed by word address. Non-overlapping base addresses (word 0, 64, 128) prevent aliasing.
- **ap_done is COR**: `krnl_vadd_ctrl` clears `ap_done` when the host reads REG_CTRL. The test polls until bit 1 is set.
- **TIMEOUT sizing**: 500,000 cycles is sufficient for 3 burst transactions + systolic array pipeline + cocotb AXI-Lite polling overhead.
