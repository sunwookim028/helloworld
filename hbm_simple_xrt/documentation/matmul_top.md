# matmul_top.sv — HBM Integration Wrapper for MXU

**Path:** `src/matmul_top.sv`

`matmul_top` bridges the 512-bit HBM memory interface to the MXU's 32-bit element interface. It unpacks HBM words into per-element BRAMs for the MXU to read, runs the MXU, then repacks the outputs into HBM words for the write. The host provides three word-addressed HBM base addresses and pulses `start`.

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low async reset |
| `start` | in | 1 | Pulse to begin one matrix multiply |
| `done` | out | 1 | One-cycle pulse on completion |
| `addr_w` | in | ADDRESS_WIDTH | HBM word address of W matrix |
| `addr_x` | in | ADDRESS_WIDTH | HBM word address of X matrix |
| `addr_out` | in | ADDRESS_WIDTH | HBM word address of output |
| `mem_addr` | out | ADDRESS_WIDTH | Word address to HBM |
| `mem_wr_data` | out | HBM_DATA_WIDTH | 512-bit write data |
| `mem_rd_data` | in | HBM_DATA_WIDTH | 512-bit read data |
| `mem_rd_en` | out | 1 | Read enable |
| `mem_wr_en` | out | 1 | Write enable |

Memory interface is **word-addressed**: each address = one HBM_DATA_WIDTH-bit word (64 bytes at 512 bits).

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 16 | Matrix dimension (N×N) |
| `DATA_WIDTH` | 32 | FP32 element width |
| `HBM_DATA_WIDTH` | 512 | HBM bus width |
| `ADDRESS_WIDTH` | 32 | Address width |
| `HBM_MEM_LATENCY` | 2 | Cycles to wait after mem_rd_en before sampling |

Key derived constants: `ELEMS_PER_WORD = 512/32 = 16`, `TOTAL_ELEMS = N²`, `WORDS_PER_MATRIX = N²/16` (16 for N=16, 1 for N=4).

## Internal BRAMs

| Buffer | Owner (write) | Owner (read) |
|--------|--------------|--------------|
| `w_bram[TOTAL_ELEMS]` | Top FSM (LOAD_W) | MXU |
| `x_bram[TOTAL_ELEMS]` | Top FSM (LOAD_X) | MXU |
| `out_bram[TOTAL_ELEMS]` | MXU (via mxu_mem_wr_en) | Top FSM (STORE) |

`out_bram` lives in a **separate `always_ff`** to avoid multiple-driver conflicts; it is cleared on reset and on `start`.

## FSM

```
S_IDLE →(start)→ S_LOAD_W_REQ → S_LOAD_W_WAIT → (×WORDS_PER_MATRIX)
     → S_LOAD_X_REQ → S_LOAD_X_WAIT → (×WORDS_PER_MATRIX)
     → S_COMPUTE_START → S_COMPUTE_WAIT →(mxu_done)
     → S_STORE_REQ → S_STORE_WAIT → (×WORDS_PER_MATRIX) → S_DONE → S_IDLE
```

**LOAD_W_REQ/WAIT:** Issues `mem_rd_en`, waits `HBM_MEM_LATENCY` cycles, unpacks `mem_rd_data` into `w_bram`:
```systemverilog
for (int i = 0; i < ELEMS_PER_WORD; i++) begin
    int idx; idx = int'(word_idx) * ELEMS_PER_WORD + i;
    if (idx < TOTAL_ELEMS) w_bram[idx] <= mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH];
end
```
**LOAD_X_REQ/WAIT:** Identical for `x_bram`. **COMPUTE_START:** Pulses `mxu_start`. **COMPUTE_WAIT:** Waits for `mxu_done`. **STORE_REQ/WAIT:** Packs `out_bram` into `mem_wr_data` and asserts `mem_wr_en`, waits `HBM_MEM_LATENCY` cycles per word. **DONE:** Pulses `done`, returns to S_IDLE.

## BRAM Read Path for MXU

The MXU's BRAM reads use MEM_LATENCY=2, implemented by latching the address:
```systemverilog
always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)            bram_rd_addr <= '0;
    else if (mxu_mem_rd_en) bram_rd_addr <= mxu_mem_addr;  // latch on cycle 0

always_comb  // combinational output on cycle 1, MXU samples on cycle 2
    if      (bram_rd_addr >= MXU_BASE_OUT) mxu_mem_resp_data = out_bram[bram_rd_addr - MXU_BASE_OUT];
    else if (bram_rd_addr >= MXU_BASE_X)   mxu_mem_resp_data = x_bram [bram_rd_addr - MXU_BASE_X];
    else                                    mxu_mem_resp_data = w_bram [bram_rd_addr];
```

MXU internal address space: W=`0x0000`, X=`0x0100`, OUT=`0x0200` (fixed, sufficient for N≤16).

## MXU Instantiation

```systemverilog
mxu #(.N(N), .DATA_WIDTH(DATA_WIDTH), .BANKING_FACTOR(1), .ADDRESS_WIDTH(16), .MEM_LATENCY(2))
u_mxu (.clk(clk), .rst_n(rst_n), .start(mxu_start), .done(mxu_done),
       .base_addr_w(MXU_BASE_W), .base_addr_x(MXU_BASE_X), .base_addr_out(MXU_BASE_OUT),
       .mem_req_addr(mxu_mem_addr), .mem_req_data(mxu_mem_req_data),
       .mem_resp_data(mxu_mem_resp_data), .mem_read_en(mxu_mem_rd_en), .mem_write_en(mxu_mem_wr_en));
```

## Design Notes

- **`HBM_MEM_LATENCY=2`**: Same cocotb timing constraint as the MXU's internal MEM_LATENCY — the memory driver runs after Verilog `always_ff` in the simulation scheduling order.
- **Word-addressed**: `mem_addr` increments by 1 per 512-bit word. Host sets `addr_w/x/out` in word-address units.
- **No `automatic` variables**: Icarus limitation; all loop temporaries use `int idx; idx = expr;` split-declaration.
- **Last-word padding**: If `TOTAL_ELEMS % ELEMS_PER_WORD != 0`, the final store word pads unused slots with zero (not needed for N=16 where 256/16=16 is exact).
