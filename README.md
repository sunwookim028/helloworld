# HBM Data Mover + Systolic Array — Command Reference

All commands you might want to run in this repository, organized by environment.

---

## Environment Setup

### Linux Server (hardware builds + FPGA execution)

Source Vitis and XRT before any hardware build or FPGA run command:

```bash
source /opt/xilinx/Vitis/2023.2/settings64.sh
source /opt/xilinx/xrt/setup.sh
```

Or use the helper script (handles hostname-specific paths):

```bash
source setup_xilinxtools.sh
```

To check what platform shells are installed:
```bash
v++ --list_platforms
```

### WSL (RTL simulation only)

Simulation uses cocotb + Icarus Verilog inside WSL. Always use this exact invocation pattern:

```bash
wsl -u leishen -e bash -c "source /mnt/c/Users/benso/coding/hbm_context/helloworld/cocotb_env/bin/activate && cd /mnt/c/Users/benso/coding/hbm_context/helloworld/hbm_simple_xrt/verification && make <target> 2>&1 | tail -80"
```

> **Do NOT** use `wsl --` (Windows PATH leaks in and breaks the shell).
> **Do NOT** assume `python3` in the default WSL shell has cocotb — only the venv does.

---

## Building (Linux server, from `hbm_simple_xrt/`)

**Full build — host binaries + bitstream:**
```bash
make
```

**Host binaries only — fast, no FPGA toolchain needed:**
```bash
make host
```
Use when you only changed host C++ code (`host.cpp` or `host_tensor.cpp`).

**RTL packaging only — Vivado packages RTL into .xo (minutes, not hours):**
```bash
make krnl_vadd.xo
```
Use to verify Vivado can elaborate your RTL without committing to full implementation.

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

## Running on Hardware (Linux server, from `hbm_simple_xrt/`)

XRT must be sourced first. The `run.sh` wrapper handles this automatically.

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

## RTL Simulation (WSL only — do NOT run on Linux server)

Replace `<target>` in the WSL command above with one of:

| Target | What it runs |
|--------|-------------|
| `all` | All three suites at N=16 (systolic_array + mxu + matmul_top) |
| `test_systolic_array` | 19 systolic array tests, N=16 |
| `test_mxu` | 19 MXU tests, N=16 |
| `test_matmul` | 9 matmul_top integration tests, N=16 |
| `test_systolic_4x4` | 19 systolic array tests, N=4 (fast) |
| `test_mxu_4x4` | 19 MXU tests, N=4 (fast) |
| `test_matmul_4x4` | 9 matmul_top tests, N=4 (fast) |
| `clean` | Remove sim_build/, results.xml, __pycache__, *.vcd |

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

## Platform and Toolchain

- **FPGA:** Xilinx Alveo U280
- **Vitis/v++ version:** 2023.2
- **Platform shell:** xilinx_u280_gen3x16_xdma_1_202211_1
- **XRT:** /opt/xilinx/xrt
- **Kernel type:** RTL (Verilog/SystemVerilog), packaged via Vivado `package_xo`
- **Simulator (WSL):** Icarus Verilog 12.0 with cocotb 2.0.1
