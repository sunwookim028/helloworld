# krnl_matmul.sv — Vitis RTL Kernel: 32×32 FP32 Matrix Multiply

**Path:** `src/krnl_matmul.sv`

Top-level Vitis RTL kernel integrating the 32×32 systolic array (`matmul_top` + `mxu` hierarchy) with a Vitis-compatible AXI4 host interface. Computes **OUT = X × W^T** on matrices stored in HBM. Replaces `krnl_vadd.sv` (DMA-only) with a compute kernel.

## Interface

Same port structure as `krnl_vadd.sv`: `ap_clk`, `ap_rst_n`, `s_axi_control` (AXI4-Lite slave), and three 512-bit AXI4 master ports.

| AXI Master | Direction | Use |
|-----------|-----------|-----|
| `m_axi_gmem0` | Read | W matrix (weight) |
| `m_axi_gmem1` | Read | X matrix (activation) |
| `m_axi_gmem2` | Write | OUT matrix (result) |

The write channels of gmem0/gmem1 and read channels of gmem2 are tied inactive.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 32 | Matrix dimension |
| `DATA_WIDTH` | 32 | FP32 element width |
| `C_M_AXI_DATA_WIDTH` | 512 | AXI data bus width |
| `C_M_AXI_ADDR_WIDTH` | 64 | AXI address width |

## Internal Architecture

```
s_axi_control
  └─ krnl_vadd_ctrl (ap_ctrl_hs, register map)
       ├── ap_start/done/idle
       └── in1_ptr (W), in2_ptr (X), out_ptr (OUT)  ← byte addresses

Kernel FSM (KS_IDLE → KS_RUN → KS_DONE)
  └─ matmul_top (32×32, handshake memory interface)
       └─ mxu → systolic_array → N² PE units

AXI Bridge FSM (BR_IDLE → BR_RD_AR → BR_RD_R → BR_WR_AW → BR_WR_W → BR_WR_B)
  ├── gmem0 reads  (W range: addr_w_word to addr_w_word+63)
  ├── gmem1 reads  (X range: all other reads)
  └── gmem2 writes (OUT)
```

## Address Conversion

Registers hold 64-bit byte addresses from the host. Word address (bit 37:6) = byte address >> 6 (since 512-bit = 64 bytes):

```systemverilog
wire [31:0] addr_w_word   = in1_ptr_w[37:6];
wire [31:0] addr_x_word   = in2_ptr_w[37:6];
wire [31:0] addr_out_word = out_ptr_w[37:6];
```

Read routing: `w_offs = mt_mem_addr - addr_w_word`. If `w_offs < 64` → gmem0 (W); else → gmem1 (X). This unsigned subtraction works correctly as long as W and X allocations don't overlap.

## Kernel FSM

```
KS_IDLE →(ap_start rising edge)→ KS_RUN: pulse mt_start
KS_RUN  →(mt_done)→ KS_DONE: assert ap_done_w for one cycle
KS_DONE → KS_IDLE
```

`ap_idle_w = (ks_state == KS_IDLE)`.

## AXI Bridge FSM

Converts `matmul_top`'s sequential single-word memory requests into AXI4 single-beat transactions. `matmul_top` issues one `mem_rd_en` or `mem_wr_en` at a time and waits for `mem_rsp_valid` / `mem_wr_done`.

| State | Action |
|-------|--------|
| `BR_IDLE` | Wait for `mt_mem_rd_en` or `mt_mem_wr_en` |
| `BR_RD_AR` | Assert ARVALID on gmem0 or gmem1; hold until ARREADY |
| `BR_RD_R` | Assert RREADY; capture RDATA on RVALID; assert `mem_rsp_valid` |
| `BR_WR_AW` | Assert AWVALID on gmem2; hold until AWREADY |
| `BR_WR_W` | Assert WVALID+WDATA+WLAST; hold until WREADY |
| `BR_WR_B` | Assert BREADY; wait for BVALID; assert `mem_wr_done` |

All transactions use single-beat (ARLEN=0/AWLEN=0) to guarantee correctness regardless of AXI latency. **Note:** This is the initial correct implementation. A burst-mode upgrade (ARLEN=63 for all 64 matrix words in one transaction) will significantly improve HBM throughput by reducing AXI round-trips from 192 to 3.

## Host Usage

```cpp
// XRT host
auto krnl = xrt::kernel(device, uuid, "krnl_matmul");
auto bo_W   = xrt::bo(device, 4096, krnl.group_id(0));  // 32*32*4 bytes
auto bo_X   = xrt::bo(device, 4096, krnl.group_id(1));
auto bo_out = xrt::bo(device, 4096, krnl.group_id(2));
// fill bo_W and bo_X, sync to device, run kernel, sync bo_out from device
```

See `src/host_matmul.cpp` for the full host program with 5 test cases.

## Build Artifacts

| File | Purpose |
|------|---------|
| `krnl_matmul.xml` | Vitis kernel descriptor (ports, arg offsets) |
| `krnl_matmul.cfg` | HBM bank assignments (gmem0→HBM[0], gmem1→HBM[1], gmem2→HBM[2]) |
| `pack_krnl_matmul.tcl` | Vivado batch script → `krnl_matmul.xo` |
