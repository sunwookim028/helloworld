# README.md — HBM Matmul Kernel

## Commands

### Hardware build (Linux server only — source Xilinx tools first)
```bash
source setup_xilinxtools.sh          # hostname-aware; handles brg-zhang-xcel vs dev server
# or manually:
source /opt/xilinx/Vitis/2023.2/settings64.sh && source /opt/xilinx/xrt/setup.sh
```

From `hbm_simple_xrt/`:
```bash
make host                            # compile host_matmul (fast, no FPGA tools needed)
make krnl_matmul.xo                  # package RTL → .xo via Vivado (~1 min, catches elab errors)
make build                           # link .xo → .xclbin (hours)
make hw_emu                          # hardware emulation target (minutes)
make clean                           # required before rebuild after RTL changes
```

Hardware emulation run:
```bash
emconfigutil --platform xilinx_u280_gen3x16_xdma_1_202211_1 --nd 1  # generates emconfig.json
export XCL_EMULATION_MODE=hw_emu
./host_matmul -x krnl_matmul.hw_emu.xclbin
```

Hardware run:
```bash
./host_matmul -x krnl_matmul.hw.xclbin [-d <device_id>]
./run.sh hbm        # bandwidth test via krnl_vadd
./run.sh tensor     # tensor scenario test
```

### RTL simulation (WSL only — use this exact invocation)
```bash
wsl -u leishen -e bash -c "source /mnt/c/Users/benso/coding/hbm_context/helloworld/cocotb_env/bin/activate && cd /mnt/c/Users/benso/coding/hbm_context/helloworld/hbm_simple_xrt/verification && make <target> 2>&1 | tail -80"
```

Simulation targets: `test_systolic_array`, `test_mxu`, `test_matmul`, `test_krnl_matmul`, `all`, `clean`

## Architecture

Two independent kernels share the AXI master/slave building blocks:

- **krnl_vadd** — HBM bandwidth DMA kernel (reference/Phase 1). Reads `in1`, writes `out`. `in2` is tied inactive but declared for XRT compatibility.
- **krnl_matmul** — Production matmul kernel (Phase 2). Computes `OUT = X × W^T` (32×32 BF16).

The **Makefile is currently wired for `krnl_matmul`** (not krnl_vadd). `krnl_vadd.cfg` / `pack_kernel.tcl` are for the DMA kernel; `krnl_matmul.cfg` / `pack_krnl_matmul.tcl` are for the matmul kernel.

**`krnl_vadd_ctrl.v` is shared** between both kernels — the AXI4-Lite register map / ap_ctrl_hs is identical.

**krnl_matmul kernel FSM** (sequential, not pipelined):
`IDLE → BURST_RD_W → BURST_RD_X → MT_START → MT_RUN → BURST_WR → DONE`
W and X bursts run sequentially so FIFO routing (by address range) is unambiguous. Each burst is 32 beats (one word per BF16 matrix row).

**matmul_top memory interface** is handshake-based (`mem_rsp_valid` / `mem_wr_done`), not fixed-latency — same code works with the cocotb 1-cycle model and the AXI bridge.

**Simulation environment**: cocotb + Icarus Verilog in WSL. The Linux server does NOT have Icarus; simulation must run in WSL.

## Key Files

| File | Role |
|---|---|
| `src/krnl_matmul.sv` | Production kernel top; FSM + FIFO glue + AXI bridge |
| `src/krnl_vadd.sv` | Reference DMA kernel top |
| `src/krnl_vadd_ctrl.v` | AXI4-Lite slave (ap_ctrl_hs); shared by both kernels |
| `src/krnl_vadd_rd_mst.v` | AXI4 burst read master (HBM → FIFO) |
| `src/krnl_vadd_wr_mst.v` | AXI4 burst write master (FIFO → HBM) |
| `src/matmul_top.sv` | 512-bit HBM ↔ 16-bit (BF16) MXU BRAM bridge |
| `src/mxu.sv` | FSM + memory interface + systolic array orchestration |
| `src/systolic_array.sv` | 32×32 PE grid (parameterized N) |
| `src/pe.sv` | Single BF16 MAC unit with double-buffered weights |
| `src/bf16_mul.sv` | Combinational BF16 multiplier (adapted from fp32_mul) |
| `src/bf16_add.sv` | Combinational BF16 adder (adapted from fp32_add) |
| `src/fifo4.sv` | 512-bit FWFT FIFO, depth 64 (krnl_vadd) / 128 (krnl_matmul) |
| `krnl_matmul.xml` | Vitis kernel descriptor — port/arg offsets for XRT |
| `pack_krnl_matmul.tcl` | Vivado batch Tcl → `.xo` packaging |
| `krnl_matmul.cfg` | HBM bank assignment: W→HBM[0], X→HBM[1], OUT→HBM[2] |
| `verification/test_krnl_matmul.py` | Full AXI kernel cocotb test (AXI4 slave models included) |
| `documentation/architecture.md` | Detailed design doc including execution phases and pitfalls |

## Code Style & Conventions

- `.sv` = SystemVerilog (production RTL); `.v` = Verilog (ctrl + masters — unchanged from original)
- All array ports use flat packed vectors (`[N*DATA_WIDTH-1:0]`) with `[r*DATA_WIDTH +: DATA_WIDTH]` bit-slicing — **never unpacked array ports** (Icarus limitation)
- **No `automatic` variables in `always_ff`** — Icarus doesn't support them; loop vars declared at module scope as `int`
- AXI master ports always declare **all channels** (read + write), even for read-only or write-only masters. Unused channels are tied off with explicit `assign` statements — never left floating
- `ap_done` and `ap_start` are **one-cycle pulses**; the top-level FSM uses a rising-edge detector (`ap_start_prev`) and latches to handle concurrent done signals

## Gotchas

- **WSL simulation command**: Must use `wsl -u leishen -e bash -c`. Do NOT use `wsl --` (Windows PATH leaks in and breaks the shell). Do NOT assume `python3` in the default WSL shell has cocotb — only the venv at `/mnt/c/Users/benso/coding/hbm_context/helloworld/cocotb_env/` does.
- **krnl_vadd.xclbin in the repo** was built from the C++ HLS `krnl_vadd.cpp`, not the RTL `krnl_vadd.sv`. To run the RTL kernel on hardware, `make clean && make` to rebuild from scratch.
- **FIFO depth in krnl_matmul must be > 32** (WORDS_PER_MATRIX for 32×32 BF16). `fifo4` has `almost_full` at `DEPTH-1`; if depth=32, `almost_full` fires at 31 and stalls the read master before the final beat, deadlocking the burst. Depth is set to 128 to prevent this.
- **`make clean` before RTL rebuild** — Vivado caches project state in `_pack_project_matmul/` and `ip_repo_matmul/`. Stale state causes silent packaging failures.
- **Deployment server** (`brg-zhang-xcel.ece.cornell.edu`) has XRT + full Vitis license. The development server does not have XRT; hw_emu/hw execution must run on the deployment server.
- **krnl_matmul.cfg vs krnl_vadd.cfg**: They assign different HBM banks. The matmul cfg puts each matrix on a separate bank; the vadd cfg assigns all ports to HBM[0:3]. Using the wrong cfg will link but give wrong connectivity.
- **`kernel.xml` vs `krnl_matmul.xml`**: `kernel.xml` is for the krnl_vadd DMA kernel; `krnl_matmul.xml` is for the matmul kernel. `pack_krnl_matmul.tcl` uses `krnl_matmul.xml`.
- **Weight packing**: Weights load in reversed row order into the systolic array — `W[c][N-1-p]`. This is intentional so that after the PE pipeline, `PE[r][c]` holds `W^T[r][c]`. Do not "fix" this reversal.
- **AXI address routing** in krnl_matmul uses unsigned subtraction: `w_offs = mt_mem_addr - addr_w_word`. If `w_offs < 32` (WORDS_PER_MATRIX) → gmem0 (W), else → gmem1 (X). Works correctly only when W and X allocations are non-overlapping.
- **BF16 test tolerance**: Tests use `bf16_ref()` which truncates inputs to BF16 then computes reference in FP32. Small-integer data (0–4) keeps sums within BF16 exact range. `rtol=0.02` for accumulation tests.

## Testing

**Simulation (WSL):**
```bash
# Run all 51 tests
make all   # from verification/, inside the cocotb venv

# Run individual suites
make test_systolic_array  # 19 tests — direct systolic_array drive
make test_mxu             # 19 tests — MXU FSM + 16-bit BF16 memory model
make test_matmul          # 9 tests  — matmul_top with 512-bit HBM model
make test_krnl_matmul     # 4 tests  — full AXI kernel with cocotb AXI slaves
```

Tests are layered: a failure in `test_mxu` with `test_systolic_array` passing isolates to the MXU FSM. A failure in `test_krnl_matmul` with `test_matmul` passing isolates to the krnl_matmul AXI bridge or kernel FSM.

All tests verify `OUT = X × W^T` against BF16 numpy reference (`bf16_ref()`). Tolerance: `rtol=0.02`.

**Hardware verification:**
```bash
./host_matmul -x krnl_matmul.hw.xclbin   # 8 test cases (identity, scale, zero, integers, diagonal, 3× random)
```
