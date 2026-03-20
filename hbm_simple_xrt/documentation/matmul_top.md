# matmul_top.sv — HBM Integration Wrapper for MXU

**Path:** `src/matmul_top.sv`

## Purpose

`matmul_top` bridges the 512-bit wide HBM memory interface to the MXU's 32-bit element interface. It is the integration point between Subsystem A (HBM bandwidth) and Subsystem B (systolic array compute). The module unpacks incoming HBM words into per-element BRAMs that the MXU reads, then repacks the MXU's output elements back into 512-bit words for the HBM write.

The host only interacts with word-addressed HBM memory and three base addresses; all orchestration is handled internally.

## Interface

| Port              | Direction | Width              | Description                                           |
|-------------------|-----------|--------------------|-------------------------------------------------------|
| `clk`             | input     | 1                  | Clock                                                 |
| `rst_n`           | input     | 1                  | Active-low asynchronous reset                         |
| `start`           | input     | 1                  | Pulse to begin one matrix multiply                    |
| `done`            | output    | 1                  | Pulses high for one cycle on completion               |
| `addr_w`          | input     | ADDRESS_WIDTH      | HBM word address of W matrix                          |
| `addr_x`          | input     | ADDRESS_WIDTH      | HBM word address of X matrix                          |
| `addr_out`        | input     | ADDRESS_WIDTH      | HBM word address of output matrix                     |
| `mem_addr`        | output    | ADDRESS_WIDTH      | Word address issued to HBM memory                     |
| `mem_wr_data`     | output    | HBM_DATA_WIDTH     | 512-bit write data to HBM                             |
| `mem_rd_data`     | input     | HBM_DATA_WIDTH     | 512-bit read data from HBM                            |
| `mem_rd_en`       | output    | 1                  | Read enable to HBM                                    |
| `mem_wr_en`       | output    | 1                  | Write enable to HBM                                   |

**Memory interface is word-addressed:** each address points to one `HBM_DATA_WIDTH`-bit word (64 bytes at 512 bits).

### Parameters

| Parameter         | Default | Description                                              |
|-------------------|---------|----------------------------------------------------------|
| `N`               | 16      | Matrix dimension (N×N)                                   |
| `DATA_WIDTH`      | 32      | FP32 element width in bits                               |
| `HBM_DATA_WIDTH`  | 512     | HBM bus width in bits                                    |
| `ADDRESS_WIDTH`   | 32      | Address width for HBM interface                          |
| `HBM_MEM_LATENCY` | 2       | Cycles to wait after `mem_rd_en` before sampling data    |

### Key Derived Constants

```systemverilog
ELEMS_PER_WORD   = HBM_DATA_WIDTH / DATA_WIDTH    // 512/32 = 16 elements per word
TOTAL_ELEMS      = N * N                           // 256 for N=16
WORDS_PER_MATRIX = ceil(TOTAL_ELEMS / ELEMS_PER_WORD)  // 16 for N=16; 1 for N=4
```

## Internal BRAMs

Three register arrays serve as staging areas between HBM words and the MXU's element-level interface:

| Buffer     | Size                | Owner                        | Description                              |
|------------|---------------------|------------------------------|------------------------------------------|
| `w_bram`   | `TOTAL_ELEMS × 32b` | Main FSM (write), MXU (read) | W matrix, unpacked from HBM words        |
| `x_bram`   | `TOTAL_ELEMS × 32b` | Main FSM (write), MXU (read) | X matrix, unpacked from HBM words        |
| `out_bram` | `TOTAL_ELEMS × 32b` | MXU (write), Main FSM (read) | Output matrix, repacked into HBM words   |

The `out_bram` is owned by a **separate `always_ff` block** from the main FSM. This avoids a multiple-driver conflict: the FSM owns `w_bram` and `x_bram`; the MXU write path owns `out_bram`. The `out_bram` is cleared on reset and on `start`.

## FSM States

```
S_IDLE
  └──(start)──► S_LOAD_W_REQ
                    └──► S_LOAD_W_WAIT ──(repeat WORDS_PER_MATRIX times)──► S_LOAD_X_REQ
                                                                                 └──► S_LOAD_X_WAIT ──(repeat)──► S_COMPUTE_START
                                                                                                                       └──► S_COMPUTE_WAIT
                                                                                                                                └──(mxu_done)──► S_STORE_REQ
                                                                                                                                                     └──► S_STORE_WAIT ──(repeat)──► S_DONE
                                                                                                                                                                                         └──► S_IDLE
```

### State Details

#### S_IDLE
Waits for `start`. Latches `addr_w`, `addr_x`, `addr_out` into internal registers and resets `word_idx` to 0.

#### S_LOAD_W_REQ
Issues one HBM read: asserts `mem_addr = addr_w_reg + word_idx`, raises `mem_rd_en`. Resets `lat_cnt` to 0, transitions to WAIT.

#### S_LOAD_W_WAIT
Counts down `HBM_MEM_LATENCY` cycles. When the count reaches `HBM_MEM_LATENCY - 1`, samples `mem_rd_data` and unpacks into `w_bram`:

```systemverilog
for (int i = 0; i < ELEMS_PER_WORD; i++) begin
    int idx;
    idx = int'(word_idx) * ELEMS_PER_WORD + i;
    if (idx < TOTAL_ELEMS)
        w_bram[idx] <= mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH];
end
```

Increments `word_idx` and loops back to REQ until all `WORDS_PER_MATRIX` words are read.

#### S_LOAD_X_REQ / S_LOAD_X_WAIT
Identical pattern for the X matrix.

#### S_COMPUTE_START
Pulses `mxu_start` for one cycle, then transitions to WAIT.

#### S_COMPUTE_WAIT
Waits for `mxu_done` (from the MXU submodule). While waiting, the MXU reads `w_bram`/`x_bram` through the BRAM read path and writes results to `out_bram`.

#### S_STORE_REQ
Packs `ELEMS_PER_WORD` elements from `out_bram` into one 512-bit word and issues a write to HBM:

```systemverilog
for (int i = 0; i < ELEMS_PER_WORD; i++) begin
    int idx;
    idx = int'(word_idx) * ELEMS_PER_WORD + i;
    if (idx < TOTAL_ELEMS)
        mem_wr_data[i*DATA_WIDTH +: DATA_WIDTH] <= out_bram[idx];
    else
        mem_wr_data[i*DATA_WIDTH +: DATA_WIDTH] <= '0;  // pad last word
end
mem_wr_en <= 1;
```

#### S_STORE_WAIT
Waits `HBM_MEM_LATENCY` cycles per write, then advances `word_idx`. Loops until all `WORDS_PER_MATRIX` words are written.

#### S_DONE
Pulses `done` for one cycle, returns to S_IDLE.

## BRAM Read Path for MXU

The MXU reads BRAMs through a latched-address mechanism that matches the same MEM_LATENCY=2 timing used by the MXU's internal memory interface:

```systemverilog
// Latch address one cycle after read_en (Cycle 0: rd_en + addr asserted)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            bram_rd_addr <= '0;
    else if (mxu_mem_rd_en) bram_rd_addr <= mxu_mem_addr;
end

// Combinational output from latched address (Cycle 1: data valid)
always_comb begin
    if      (bram_rd_addr >= MXU_BASE_OUT) mxu_mem_resp_data = out_bram[bram_rd_addr - MXU_BASE_OUT];
    else if (bram_rd_addr >= MXU_BASE_X)   mxu_mem_resp_data = x_bram [bram_rd_addr - MXU_BASE_X];
    else                                    mxu_mem_resp_data = w_bram [bram_rd_addr];
end
// Cycle 2: MXU captures mxu_mem_resp_data ✓
```

The MXU's internal memory address space uses fixed offsets:

| Region | Base Address |
|--------|-------------|
| W      | `0x0000`    |
| X      | `0x0100` (256 = N² for N=16) |
| OUT    | `0x0200`    |

These are large enough for N≤16 (N²=256=0x100).

## MXU Instantiation

The MXU is instantiated with `BANKING_FACTOR=1` (one 32-bit element per memory transaction), `MEM_LATENCY=2`, and `ADDRESS_WIDTH=16` (internal BRAM address space):

```systemverilog
mxu #(
    .N             (N),
    .DATA_WIDTH    (DATA_WIDTH),
    .BANKING_FACTOR(1),
    .ADDRESS_WIDTH (16),
    .MEM_LATENCY   (2)
) u_mxu (
    .clk           (clk),
    .rst_n         (rst_n),
    .start         (mxu_start),
    .done          (mxu_done),
    .base_addr_w   (MXU_BASE_W),    // 16'h0000
    .base_addr_x   (MXU_BASE_X),    // 16'h0100
    .base_addr_out (MXU_BASE_OUT),  // 16'h0200
    .mem_req_addr  (mxu_mem_addr),
    .mem_req_data  (mxu_mem_req_data),
    .mem_resp_data (mxu_mem_resp_data),
    .mem_read_en   (mxu_mem_rd_en),
    .mem_write_en  (mxu_mem_wr_en)
);
```

## Data Flow Summary

```
HBM Memory                    matmul_top                       MXU
──────────                    ──────────                       ───
                   LOAD_W:
[addr_w + 0]  ──► unpack 16 elems ──► w_bram[0..15]
[addr_w + 1]  ──► unpack 16 elems ──► w_bram[16..31]
...
[addr_w + 15] ──► unpack 16 elems ──► w_bram[240..255]

                   LOAD_X: (same pattern into x_bram)

                   COMPUTE:
                              w_bram ──► mxu.mem_resp_data ──► systolic array
                              x_bram ──► mxu.mem_resp_data ──► systolic array
                                         out_bram ◄── mxu.mem_req_data (MXU writes results)

                   STORE:
                              out_bram ──► pack 16 elems ──► [addr_out + 0]
                              ...
                              out_bram ──► pack 16 elems ──► [addr_out + 15]
```

## Design Notes

- **`HBM_MEM_LATENCY = 2`** for the same reason as `MEM_LATENCY=2` in the MXU: the cocotb memory driver runs after Verilog `always_ff` blocks in the simulation scheduling order. Two cycles guarantees valid data by the time it is sampled.
- **Word-addressed:** `mem_addr` increments by 1 per 512-bit word, not by byte or element count. The host must set `addr_w`, `addr_x`, `addr_out` in word-address units.
- **Separate `out_bram` always_ff:** Splitting ownership between the MXU (writes) and the main FSM (reads during STORE) avoids a multiple-driver conflict that would arise if a single `always_ff` block tried to handle both cases.
- **No `automatic` variables:** Icarus Verilog does not support `automatic` lifetime overrides in `always_ff`. All loop temporaries use the `int idx; idx = expr;` split-declaration pattern.
- **Padding in last word:** When `TOTAL_ELEMS` is not a multiple of `ELEMS_PER_WORD`, the final write word pads unused element slots with zero. For N=16 and ELEMS_PER_WORD=16, TOTAL_ELEMS=256=16×16 divides evenly, so no padding is needed.
