# Reading Order
You have an RTL/digital design background but have never seen this codebase. This project has two independent subsystems in the same source directory. Read them in the order below — the FIFO is shared infrastructure, so it appears first.

Each entry points you to a detailed doc in this same `documentation/` folder.

---

## Part 0: Shared Infrastructure
### 1. `src/fifo4.sv` → [fifo4.md](fifo4.md)
Start here. It's small (73 lines) and self-contained. Understand the FWFT (First-Word-Fall-Through) property: `rd_data` is valid **combinationally** when `!empty` — no read latency. Notice how full/empty use an extra wrap bit on the pointers. This FIFO is used in the kernel subsystem and the same idiom (combinational read → zero-bubble streaming) recurs throughout.

---

## Part 1: HBM Data Mover Kernel (Subsystem A)
This subsystem is a Vitis RTL kernel deployed on an Alveo U280. It copies data through HBM — a DMA engine for benchmarking bandwidth. Read bottom-up through the submodules, then the top-level, then the packaging.

### 2. `src/krnl_vadd_ctrl.v` → [krnl_vadd_ctrl.md](krnl_vadd_ctrl.md)
AXI4-Lite slave register file. Skim the write/read state machines (they're textbook AXI-Lite, adapted from minitpu). Focus on the **register map** at the top of the file (offsets `0x00` through `0x28`) and the **ap_ctrl_hs protocol**: how `ap_start` is self-cleared by hardware and `ap_done` is sticky/COR. Everything else in the kernel depends on these register semantics.

### 3. `src/krnl_vadd_rd_mst.v` → [krnl_vadd_rd_mst.md](krnl_vadd_rd_mst.md)
AXI4 burst read master. Four-state FSM: `IDLE → AR → R → DONE`. Focus on:
- How burst length is computed and capped at 256 beats (AXI4 max)
- How `RREADY` is driven **combinationally** from `!fifo_almost_full` — backpressure from the FIFO stalls HBM reads naturally
- How `RLAST` triggers address advancement and next-burst computation

### 4. `src/krnl_vadd_wr_mst.v` → [krnl_vadd_wr_mst.md](krnl_vadd_wr_mst.md)
AXI4 burst write master. This is where the FWFT idiom from step 1 pays off. The critical lines are the four **combinational assigns** (lines 89–93):

```verilog
assign M_AXI_WVALID = (state == S_W) && !fifo_empty;
assign M_AXI_WDATA  = fifo_rd_data;
assign M_AXI_WLAST  = M_AXI_WVALID && (beats_left == 1);
assign fifo_rd_en   = M_AXI_WVALID && M_AXI_WREADY;
```

Understand why these are combinational (not registered) and how that gives zero-bubble W-channel streaming. Compare with step 3's registered `fifo_wr_en` to see the asymmetry.

### 5. `src/krnl_vadd.sv` → [krnl_vadd.md](krnl_vadd.md)
Kernel top-level. Now you see how steps 1–4 connect. The two-state top FSM (`IDLE → RUN`) just fires both masters in parallel and waits for both done latches. The rest is wiring. Note:
- `m_axi_gmem1` (`in2`) is entirely tied off — present for XRT interface compatibility only
- `num_words = size >> 4` — converts 32-bit element count to 512-bit word count

### 6. `kernel.xml` → [kernel_xml.md](kernel_xml.md)
The bridge between RTL and the Vitis toolchain. Skim the `<args>` section — each argument's `offset` must match `krnl_vadd_ctrl.v`'s register map exactly. The `port` attribute maps each argument to an AXI master interface.

### 7. `package_kernel.tcl` → [package_kernel_tcl.md](package_kernel_tcl.md)
Skim. It's build infrastructure: creates a Vivado IP from the RTL sources, associates clock domains, then calls `package_xo` to produce the `.xo` that the Vitis linker consumes. You only need to read this if you're modifying the build flow.

---

## Part 2: Systolic Array Compute Engine (Subsystem B)
This subsystem is a standalone matrix multiply unit: `OUT = X × W^T`. It uses real FP32 arithmetic (not stubs). Read bottom-up through the datapath, then the controller, then verification.

### 8. `src/fp32_mul.sv` → [fp32_mul.md](fp32_mul.md)
Combinational FP32 multiplier. Pure `always @(*)`, no clock. Read the special-case handling (NaN, Inf, zero) first, then skim the normal-path mantissa multiply and rounding. You don't need to memorize the bit manipulation — just understand that `result = a × b` in one combinational pass.

### 9. `src/fp32_add.sv` → [fp32_add.md](fp32_add.md)
Combinational FP32 adder. Same idea — exponent alignment, mantissa add/sub, normalization. Skim it. The key takeaway: both arithmetic blocks are **zero-latency combinational logic**, not pipelined.

### 10. `src/pe.sv` → [pe.md](pe.md)
Now you see why 8 and 9 exist. A PE instantiates one `fp32_mul` and one `fp32_add` to form a MAC: `psum_out = (input × weight) + psum_in`. Focus on:
- The **double-buffered weight registers** (`weight_reg_active` / `weight_reg_inactive`) and how `switch_in` swaps them
- The **signal propagation**: activations pass east, partial sums pass south, weights pass south, valid/switch are registered and forwarded
- Each PE adds **exactly one cycle of latency** to everything passing through it

### 11. `src/systolic_array.sv` → [systolic_array.md](systolic_array.md)
N×N grid of PEs from step 10, wired with generate blocks. Read the three generate-block sections in order:
1. **West edge mux** (lines 69–75): where activations enter from `data_in` vs. from the PE to the left
2. **Switch routing** (lines 81–87): the unusual path — right along row 0, then down each column
3. **North edge mux** (lines 93–99): where `psum_in=0` at the top row vs. from the PE above

The bottom row's `psum_out` connects to `data_out` — that's where results emerge.

### 12. `src/mxu.sv` → [mxu.md](mxu.md)
The controller that makes the systolic array useful. Read the FSM states in order:
1. **LOAD_W / LOAD_X** (lines 200–256): sequential memory reads into flat buffers — straightforward
2. **S_RUN** (lines 272–304): the interesting part — three interleaved pipelines (weights, switch, X inputs) driven by `phase_counter`. This is where the systolic timing protocol lives. Cross-reference with step 11's wiring to see how signals enter the array.
3. **Output capture** (lines 120–141): separate `always_ff` block with per-column `row_ptr` counters — captures results as they emerge from the bottom row
4. **STORE** (lines 330–358): writes results back to memory

### 13. `verification/Makefile` → [Makefile.md](Makefile.md)
Skim the RTL source dependency chain (`SRC_FP32 → SRC_PE → SRC_SYSTOLIC → SRC_MXU → SRC_MATMUL`) and how the 4×4 variants override parameters with `-Psystolic_array.N=4`. The rest is cocotb/iverilog plumbing.

### 14. `verification/test_systolic_array.py` → [test_systolic_array.md](test_systolic_array.md)
Read `run_matmul()` (line 71) carefully — it drives the **exact same protocol** as the MXU's S_RUN state, but from Python. If you understood step 12's S_RUN, this will click immediately. Then skim a few tests to see what matrix patterns are being validated.

### 15. `verification/test_mxu.py` → [test_mxu.md](test_mxu.md)
Read `memory_driver()` (line 45) first — it's the cocotb coroutine that models memory for the MXU. Then read `run_matmul()` (line 107) — it just loads matrices, pulses start, and waits for done. The tests are structurally identical to step 14 but exercise the full FSM + memory path.

---

## Part 2.5: HBM Integration Layer
This is the bridge between the two subsystems: a wrapper that connects the 512-bit HBM interface from Subsystem A to the 32-bit element interface of Subsystem B. Read after completing both Part 1 and Part 2.

### 16. `src/matmul_top.sv` → [matmul_top.md](matmul_top.md)
The integration wrapper. Focus on three things:
1. **The localparam arithmetic** at the top: `ELEMS_PER_WORD = 512/32 = 16`, `WORDS_PER_MATRIX = N²/16` — understand the dimensional translation from HBM words to matrix elements.
2. **The BRAM latch pattern** (lines 106–120): `bram_rd_addr` is latched one cycle after `mxu_mem_rd_en`, then `mxu_mem_resp_data` is driven combinationally from the latched address. This is what makes MEM_LATENCY=2 work for the MXU reading these BRAMs.
3. **The store pack loop** (lines 281–288): how the 32-bit `out_bram` elements get merged back into one 512-bit `mem_wr_data` word.

### 17. `verification/test_matmul_top.py` → [test_matmul_top.md](test_matmul_top.md)
Read `pack_matrix()` and `unpack_matrix()` first — these are the Python-side equivalents of the RTL's HBM word packing/unpacking. Then `memory_driver()`: same coroutine pattern as `test_mxu.py` but now `mem_rd_data` and `mem_wr_data` are 512-bit integers. The `test_hbm_word_boundary` test is the most interesting one to read — it was specifically designed to catch element-ordering bugs in the bit-slice unpack logic.

---

## Part 3: The Big Picture
### 18. `architecture.md` → [architecture.md](architecture.md)
Read this last. It ties everything together: complete data flow diagrams, systolic timing walkthrough, the three-level verification strategy, and the key design pitfalls (MEM_LATENCY, FWFT idiom, weight reversal, Icarus limitations).

---

## Summary
**Steps 1–7** cover the HBM kernel (DMA engine, AXI4 mastery, Vitis packaging).
**Steps 8–15** cover the systolic array (FP32 arithmetic → PE → array → MXU controller → cocotb verification).
**Steps 16–17** cover the HBM integration layer (matmul_top + 512-bit test harness).
**Step 18** connects everything and explains the design decisions.


The three sentences to carry through:
- **Kernel:** reads from HBM via AXI4 bursts, streams through a FWFT FIFO, writes back — zero-bubble DMA.
- **Compute:** the systolic array computes OUT = X × W^T using a weight-stationary dataflow with staggered activation feeding.
- **Integration:** matmul_top unpacks 512-bit HBM words into per-element BRAMs, runs the MXU, then repacks results — the bridge between memory bandwidth and compute.
