# krnl_matmul.sv — Vitis RTL Kernel: 32×32 BF16 Matrix Multiply (Burst AXI)

**Path:** `src/krnl_matmul.sv`

Top-level Vitis RTL kernel integrating the 32×32 BF16 systolic array (`matmul_top` + `mxu` hierarchy) with a Vitis-compatible AXI4 host interface. Computes **OUT = X × W^T** on matrices stored in HBM. Uses burst AXI4 DMA (via `krnl_vadd_rd_mst` / `krnl_vadd_wr_mst`) with 3 burst transactions (one per matrix).

## Interface

| AXI Master | Direction | Use |
|-----------|-----------|-----|
| `m_axi_gmem0` | Read | W matrix (weight) — one 32-beat burst |
| `m_axi_gmem1` | Read | X matrix (activation) — one 32-beat burst |
| `m_axi_gmem2` | Write | OUT matrix (result) — one 32-beat burst |

Write channels of gmem0/gmem1 and read channel of gmem2 are tied inactive.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 32 | Matrix dimension |
| `DATA_WIDTH` | 16 | BF16 element width |
| `C_M_AXI_DATA_WIDTH` | 512 | AXI data bus width |
| `C_M_AXI_ADDR_WIDTH` | 64 | AXI address width |

## Internal Architecture

```
s_axi_control
  └─ krnl_vadd_ctrl (ap_ctrl_hs, register map)
       ├── ap_start/done/idle
       └── in1_ptr (W), in2_ptr (X), out_ptr (OUT)  ← byte addresses

Sequencer FSM
  ├── KS_BURST_RD_W: krnl_vadd_rd_mst → w_rd_fifo (32 words via gmem0)
  ├── KS_BURST_RD_X: krnl_vadd_rd_mst → x_rd_fifo (32 words via gmem1)
  ├── KS_MT_START/RUN: matmul_top drains FIFOs, runs MXU, fills wr_fifo
  ├── KS_BURST_WR:  krnl_vadd_wr_mst ← wr_fifo (32 words via gmem2)
  └── KS_DONE: assert ap_done

matmul_top (32×32 BF16, handshake memory interface)
  └─ mxu → systolic_array → N² PE units
```

## Sequencer FSM

```
KS_IDLE →(start_rise, flush FIFOs)→ KS_BURST_RD_W
KS_BURST_RD_W →(rd_w_done)→ KS_BURST_RD_X
KS_BURST_RD_X →(rd_x_done)→ KS_MT_START
KS_MT_START   →(pulse mt_start)→ KS_MT_RUN
KS_MT_RUN     →(mt_done)→ KS_BURST_WR
KS_BURST_WR   →(wr_out_done)→ KS_DONE
KS_DONE       →(assert ap_done)→ KS_IDLE
```

`ap_idle_w = (ks_state == KS_IDLE)`

## FIFO Glue

Three `fifo4` instances (512-bit wide, depth 128) buffer data between the burst masters and `matmul_top`'s sequential memory port:

- **w_rd_fifo / x_rd_fifo**: preloaded by rd_mst before matmul_top starts. When `mt_mem_rd_en` fires, the correct FIFO is popped combinationally and `mem_rsp_valid` is asserted one cycle later (1-cycle read latency).
- **wr_fifo**: filled by `matmul_top` during the store phase. After `mt_done`, `wr_mst` drains it in one burst.

FIFO depth 128 > 32 words ensures `almost_full` (fires at 127) never triggers during our 32-word bursts, preventing the rd_mst from stalling on the final beat.

## Address Conversion

```systemverilog
wire [31:0] addr_w_word   = in1_ptr_w[37:6];  // byte >> 6 = 512-bit word addr
wire [31:0] addr_x_word   = in2_ptr_w[37:6];
wire [31:0] addr_out_word = out_ptr_w[37:6];
```

Read routing to correct FIFO: `w_offs = mt_mem_addr - addr_w_word`. If `w_offs < 32` (WORDS_PER_MATRIX) → w_rd_fifo (W phase); else → x_rd_fifo (X phase).

## Host Usage

```cpp
auto krnl  = xrt::kernel(device, uuid, "krnl_matmul");
auto bo_W  = xrt::bo(device, 2048, krnl.group_id(0));  // 32×32×2 bytes
auto bo_X  = xrt::bo(device, 2048, krnl.group_id(1));
auto bo_out = xrt::bo(device, 2048, krnl.group_id(2));
// fill bo_W and bo_X with uint16_t BF16 values, sync to device, run kernel, sync bo_out from device
```

See `src/host_matmul.cpp` for the full host program.

## Build Artifacts

| File | Purpose |
|------|---------|
| `krnl_matmul.xml` | Vitis kernel descriptor (ports, arg offsets) |
| `krnl_matmul.cfg` | HBM bank assignments (gmem0→HBM[0], gmem1→HBM[1], gmem2→HBM[2]) |
| `pack_krnl_matmul.tcl` | Vivado batch script → `krnl_matmul.xo` |
