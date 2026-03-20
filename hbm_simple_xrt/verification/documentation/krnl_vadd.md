# krnl_vadd.sv — RTL Kernel Top-Level

**Path:** `src/krnl_vadd.sv`

## Purpose

The top-level Vitis RTL kernel for the HBM Data Mover. This module replaces the original HLS C kernel (`krnl_vadd.cpp`) with functionally equivalent RTL. It reads `size/16` 512-bit words from HBM via `in1` and writes them to `out` — a pure DMA copy engine used to benchmark HBM bandwidth (~28.9 GB/s multi-bank on Alveo U280).

## Interface

The port names follow Vitis conventions exactly (required for `kernel.xml` / shell auto-connect):

| Port Group          | AXI Type   | Width   | Role                                         |
|---------------------|------------|---------|----------------------------------------------|
| `s_axi_control_*`   | AXI4-Lite  | 32-bit  | Host control: sets addresses, size, ap_start  |
| `m_axi_gmem0_*`     | AXI4       | 512-bit | Read master for `in1` (HBM source)            |
| `m_axi_gmem1_*`     | AXI4       | 512-bit | `in2` — **unused**, tied inactive for XRT compat |
| `m_axi_gmem2_*`     | AXI4       | 512-bit | Write master for `out_r` (HBM destination)    |
| `ap_clk`, `ap_rst_n`| —          | 1       | Clock and active-low reset                    |

## Internal Architecture

```
                    s_axi_control
                         │
                    ┌────▼─────┐
                    │  ctrl    │ ap_start, ap_done, ap_idle
                    │(AXI-Lite)│ in1_ptr, in2_ptr, out_ptr, size
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ Top FSM  │  IDLE ──start──► RUN ──both done──► IDLE
                    └──┬────┬──┘
                       │    │
           start_masters    start_masters
                       │    │
                 ┌─────▼┐  ┌▼──────┐
                 │rd_mst│  │wr_mst │
                 │(AR→R)│  │(AW→W→B)│
                 └──┬───┘  └───▲───┘
                    │          │
                    └──►FIFO───┘
                     512-bit, depth=64
                         │
              m_axi_gmem0 (read)     m_axi_gmem2 (write)
```

### Submodule Instantiations

| Instance    | Module           | Role                                           |
|-------------|------------------|-------------------------------------------------|
| `u_ctrl`    | `krnl_vadd_ctrl` | AXI4-Lite slave, register file, ap_ctrl_hs       |
| `u_rd_mst`  | `krnl_vadd_rd_mst` | AXI4 burst read master (gmem0/in1)            |
| `u_wr_mst`  | `krnl_vadd_wr_mst` | AXI4 burst write master (gmem2/out_r)         |
| `u_fifo`    | `fifo4`          | 512-bit FWFT FIFO, depth 64, decouples rd/wr    |

### Top-Level FSM (lines 175–236)

Two states:

- **S_IDLE:** Waits for rising edge on `ap_start`. On detection, clears done latches and pulses `start_masters` to both read and write masters simultaneously.
- **S_RUN:** Waits for both `rd_done_pulse` and `wr_done_pulse` to fire (latched). When both are done, pulses `ap_done` and returns to S_IDLE.

The read and write masters run **in parallel** — the FIFO decouples them so the write master can proceed as soon as data is available, without waiting for all reads to complete.

### gmem1 (in2) — Tied Inactive

All AXI4 channels for `m_axi_gmem1` are tied to inactive values (lines 395–416). This port exists because the original HLS C kernel declared an `in2` argument. XRT requires all declared ports to be present in the RTL interface, even if unused.

### Data Width Conversion

`num_words = size >> 4` — the `size` parameter from the host is in 32-bit elements. Each 512-bit AXI beat carries 16 × 32-bit elements, so dividing by 16 gives the number of AXI beats.
