# HBM Data Mover — RTL Kernel Build & Run Guide

Pure DMA copy engine on the Alveo U280 FPGA using High Bandwidth Memory (HBM).
The kernel is implemented in RTL (Verilog/SystemVerilog), packaged via Vivado into a `.xo`, and linked into an `.xclbin` bitstream by `v++`.

---

## Environment Setup (Linux server — run once per shell session)

Source Vitis and XRT before any hardware build or FPGA run command:

```bash
source /opt/xilinx/Vitis/2023.2/settings64.sh
source /opt/xilinx/xrt/setup.sh
```

---

## Project Structure

```
hbm_simple_xrt/
├── src/
│   ├── krnl_vadd.sv          # RTL top-level kernel (wires ctrl + rd_mst + wr_mst + FIFO)
│   ├── krnl_vadd_ctrl.v      # AXI4-Lite slave, ap_ctrl_hs register map
│   ├── krnl_vadd_rd_mst.v    # AXI4 burst read master, 512-bit (gmem0 / in1)
│   ├── krnl_vadd_wr_mst.v    # AXI4 burst write master, 512-bit (gmem2 / out_r)
│   ├── fifo4.sv              # FWFT FIFO (depth=64, 512-bit)
│   ├── host.cpp              # Host app: HBM bandwidth test (Cases 1-3)
│   └── host_tensor.cpp       # Host app: tensor scenario test (software orchestration)
├── pack_kernel.tcl           # Vivado Tcl script: packages RTL → krnl_vadd.xo
├── krnl_vadd.cfg             # Linker config: maps kernel args to HBM[0:3]
├── krnl_vadd.xclbin          # Pre-built hardware bitstream (49MB)
├── xrt.ini                   # XRT runtime config (profiling/debug)
├── Makefile                  # Build system (host + RTL kernel + bitstream)
├── run.sh                    # Wrapper script with XRT environment setup
├── hbm_simple_xrt            # Compiled host executable
└── tensor_test               # Compiled tensor test executable
```

---

## Building (Linux server, from helloworld/hbm_simple_xrt/)

**Full build — host binaries + bitstream (start here if building from scratch):**
```bash
make
```

**Host binaries only — fast, no FPGA toolchain needed:**
```bash
make host
```
Use this when you only changed host C++ code (host.cpp or host_tensor.cpp).

**RTL packaging only — Vivado packages RTL into .xo (minutes, not hours):**
```bash
make krnl_vadd.xo
```
Use this to verify Vivado can elaborate your RTL without committing to full implementation.

**Bitstream only — v++ links .xo to .xclbin (requires .xo to exist, takes hours):**
```bash
make build
```

**Clean all build artifacts:**
```bash
make clean
```
Always run this before rebuilding after RTL changes, or after a failed build.

---

## Running on Hardware (Linux server, from helloworld/hbm_simple_xrt/)

XRT must be sourced first. The run.sh wrapper handles this automatically:

**HBM bandwidth test — single-bank, multi-bank, high banks:**
```bash
./run.sh hbm
```

**Tensor scenario test — bulk transfer vs software-orchestrated transfers:**
```bash
./run.sh tensor
```

**Run manually (after sourcing XRT yourself):**
```bash
./hbm_simple_xrt -x krnl_vadd.xclbin -d 0
./tensor_test    -x krnl_vadd.xclbin -d 0
```
`-d 0` selects device index 0. Change if multiple Alveo cards are in the system.

---

## RTL Kernel Architecture

The kernel is a direct RTL equivalent of the original HLS C++ `krnl_vadd.cpp`.
It reads 512-bit words from HBM via AXI4 burst reads, passes them through a FIFO, and writes them out via AXI4 burst writes.

```
Host (XRT)
  │
  ▼ AXI4-Lite (s_axi_control)
┌─────────────────────────────────────────┐
│  krnl_vadd.sv (top-level)              │
│                                         │
│  krnl_vadd_ctrl ──► ap_start/done/idle │
│       │                                 │
│       ▼ (base_addr, num_words)          │
│  krnl_vadd_rd_mst ──► fifo4 ──► krnl_vadd_wr_mst  │
│       │ AXI4 (gmem0)           │ AXI4 (gmem2)     │
└───────┼─────────────────────────┼───────┘
        ▼                         ▼
    HBM Bank (in1)           HBM Bank (out_r)
```

**Register map** (AXI4-Lite, byte offsets):

| Offset | Name | Size | Description |
|--------|------|------|-------------|
| 0x00 | ap_ctrl | 32-bit | [0]=ap_start, [1]=ap_done, [2]=ap_idle |
| 0x10 | in1 | 64-bit | Base address of input buffer |
| 0x18 | in2 | 64-bit | Base address of second input (unused, kept for XRT compat) |
| 0x20 | out_r | 64-bit | Base address of output buffer |
| 0x28 | size | 32-bit | Number of 32-bit elements to copy |

---

## Measured Results (U280 Hardware)

| Test | Result |
|------|--------|
| Single-bank HBM | ~13.5 GB/s |
| Multi-bank HBM (banks 0-3) | ~28.9 GB/s |
| Bulk tensor copy (1M elements) | ~9.2 GB/s |
| Software-orchestrated (1024 × 1K) | ~0.19 GB/s (~73x overhead) |

HBM connectivity is limited to HBM[0:3] by the bitstream configuration (`krnl_vadd.cfg`).

---

## Configuration Files

### `krnl_vadd.cfg`
Maps kernel arguments to physical HBM banks during the `v++ -l` link step:
```
[connectivity]
sp=krnl_vadd_1.in1:HBM[0:3]
sp=krnl_vadd_1.in2:HBM[0:3]
sp=krnl_vadd_1.out_r:HBM[0:3]
```

### `xrt.ini`
Read by XRT at runtime. Enables native tracing for profiling data.

### `pack_kernel.tcl`
Vivado batch-mode Tcl script that:
1. Creates a temporary Vivado project with the 5 DMA RTL files
2. Packages them as a Vivado IP with Vitis kernel metadata
3. Defines the ap_ctrl_hs register map (in1, in2, out_r, size)
4. Calls `package_xo` to produce `krnl_vadd.xo`
5. Cleans up temporary project files

---

## Platform and Toolchain

- **FPGA:** Xilinx Alveo U280
- **Vitis/v++ version:** 2023.2
- **Platform shell:** xilinx_u280_gen3x16_xdma_1_202211_1 (2022.1 shell installed on this machine)
- **XRT:** /opt/xilinx/xrt
- **Kernel type:** RTL (Verilog/SystemVerilog), packaged via Vivado `package_xo`

To check what platform shells are installed on the machine:
```bash
v++ --list_platforms
```
