# Reading Order
You have an RTL/digital design background but have never seen this codebase. The project has two subsystems: a proven HBM DMA kernel (bandwidth reference + burst AXI patterns) and a 16×16 systolic array matmul kernel. Read them in the order below.

---

## Part 0: Shared Infrastructure

### 1. `src/krnl_vadd_ctrl.v` → [krnl_vadd_ctrl.md](krnl_vadd_ctrl.md)
Start here. It's the AXI4-Lite slave shared by both kernels. Focus on the **register map** (offsets `0x00`–`0x28`) and the **ap_ctrl_hs protocol**: `ap_start` self-clears on done; `ap_done` is sticky/COR. Every other module depends on these semantics.

---

## Part 1: HBM Data Mover Kernel (Burst AXI Reference)

A standalone DMA kernel used to validate HBM burst bandwidth and fix the >4KB AXI hang. Its burst read/write pattern will be integrated into `krnl_matmul` for high-throughput HBM access. Read bottom-up.

### 2. `src/fifo4.sv` → [fifo4.md](fifo4.md)
Small (73 lines), self-contained. Understand the **FWFT property**: `rd_data` is valid combinationally when `!empty` — no read latency. The `WVALID`/`WDATA`/`fifo_rd_en` combinational idiom in the write master depends on this.

### 3. `src/krnl_vadd_rd_mst.v` → [krnl_vadd_rd_mst.md](krnl_vadd_rd_mst.md)
AXI4 burst read master. Focus on: how burst length is computed and capped at 256 beats; how `RREADY` is driven combinationally from `!fifo_almost_full` for natural backpressure; how `RLAST` triggers next-burst computation.

### 4. `src/krnl_vadd_wr_mst.v` → [krnl_vadd_wr_mst.md](krnl_vadd_wr_mst.md)
AXI4 burst write master. The critical lines are the four combinational assigns:
```verilog
assign M_AXI_WVALID = (state == S_W) && !fifo_empty;
assign M_AXI_WDATA  = fifo_rd_data;
assign M_AXI_WLAST  = M_AXI_WVALID && (beats_left == 1);
assign fifo_rd_en   = M_AXI_WVALID && M_AXI_WREADY;
```
Understand why these are combinational (FWFT → zero-bubble streaming).

### 5. `src/krnl_vadd.sv` → [krnl_vadd.md](krnl_vadd.md)
Kernel top-level. See how steps 1–4 connect. The two-state FSM fires both masters in parallel and waits for both done latches. `num_words = size >> 4` converts element count to 512-bit word count.

---

## Part 2: Systolic Array Compute Engine

16×16 FP32 matrix multiply: `OUT = X × W^T`. Read bottom-up through the datapath, then the controller.

### 6. `src/fp32_mul.sv` → [fp32_mul.md](fp32_mul.md)
Combinational FP32 multiplier — pure `always @(*)`. Skim special-case handling (NaN, Inf, zero), then the normal mantissa multiply. Takeaway: `result = a × b` in one combinational pass, zero latency.

### 7. `src/fp32_add.sv` → [fp32_add.md](fp32_add.md)
Combinational FP32 adder. Same idea. Both arithmetic blocks are **zero-latency**.

### 8. `src/pe.sv` → [pe.md](pe.md)
A PE instantiates one `fp32_mul` and one `fp32_add`: `psum_out = (input × weight) + psum_in`. Focus on:
- **Double-buffered weight registers** and how `switch_in` swaps them
- **Signal propagation**: activations pass east, partial sums south, weights south, valid/switch registered and forwarded
- Each PE adds **exactly one cycle of latency** to everything passing through it

### 9. `src/systolic_array.sv` → [systolic_array.md](systolic_array.md)
16×16 grid of PEs, wired with generate blocks. Read the three generate sections:
1. **West edge mux**: activations enter from `data_in` vs. from left PE
2. **Switch routing**: right along row 0, then down each column
3. **North edge mux**: `psum_in=0` at top row vs. from PE above

Bottom row's `psum_out` → `data_out`.

### 10. `src/mxu.sv` → [mxu.md](mxu.md)
The controller. Read the FSM states in order:
1. **LOAD_W / LOAD_X**: sequential memory reads into flat buffers
2. **S_RUN**: three interleaved pipelines (weights, switch, X inputs) driven by `phase_counter`
3. **Output capture**: separate `always_ff` with per-column `row_ptr` counters
4. **STORE**: writes results back to memory

---

## Part 3: HBM Integration Layer

Bridges the 512-bit HBM interface to MXU's 32-bit element interface. Read after completing Parts 1 and 2.

### 11. `src/matmul_top.sv` → [matmul_top.md](matmul_top.md)
Focus on:
1. **Localparam arithmetic**: `ELEMS_PER_WORD=16`, `WORDS_PER_MATRIX=16` for N=16
2. **Handshake interface**: `mem_rsp_valid` / `mem_wr_done` replace fixed-latency counter; FSM stalls in WAIT states
3. **BRAM read path**: `bram_rd_addr` latched one cycle after `mxu_mem_rd_en`, then `mxu_mem_resp_data` driven combinationally (implements MEM_LATENCY=2)
4. **Store pack loop**: 32-bit `out_bram` elements packed into one 512-bit `mem_wr_data` word

---

## Part 4: Production Vitis Kernel

### 12. `src/krnl_matmul.sv` → [krnl_matmul.md](krnl_matmul.md)
The top-level Vitis kernel. Now you see how everything connects:
- `krnl_vadd_ctrl` provides ap_ctrl_hs (from Part 0)
- `matmul_top` provides the compute (from Parts 2–3)
- The AXI bridge converts matmul_top's sequential word requests to AXI4 transactions on gmem0/1/2
- Address routing: `w_offs = mt_mem_addr - addr_w_word; if w_offs < 16 → gmem0 else → gmem1`

### 13. `krnl_matmul.xml`
Kernel descriptor: 3 AXI4 master ports (gmem0/1/2), AXI4-Lite slave, args at offsets 0x10/0x18/0x20. Offsets must match `krnl_vadd_ctrl.v`'s register map exactly.

### 14. `pack_krnl_matmul.tcl`
Vivado batch script: creates IP project, associates clock/reset, configures AXI address spaces, calls `package_xo` → `krnl_matmul.xo`.

---

## Part 5: Verification

### 15. `verification/Makefile` → [Makefile.md](Makefile.md)
Skim the RTL source dependency chain and how cocotb/iverilog are invoked. All targets default to N=16.

### 16. `verification/test_systolic_array.py` → [test_systolic_array.md](test_systolic_array.md)
Drives the **exact same protocol** as the MXU's S_RUN state, from Python. If you understood step 10's S_RUN, this clicks immediately.

### 17. `verification/test_mxu.py` → [test_mxu.md](test_mxu.md)
`memory_driver()` models the 32-bit BRAM interface. `run_matmul()` just loads matrices, pulses start, waits for done.

### 18. `verification/test_matmul_top.py` → [test_matmul_top.md](test_matmul_top.md)
512-bit memory model with handshake. Read `pack_matrix()`/`unpack_matrix()` first — Python-side equivalents of the RTL pack/unpack. `test_hbm_word_boundary` specifically targets MSB extraction bugs.

### 19. `verification/test_krnl_matmul.py` → [test_krnl_matmul.md](test_krnl_matmul.md)
Full AXI4 kernel test. Three concurrent memory slaves (gmem0/1/2), AXI4-Lite host control, ap_ctrl_hs start/poll.

---

## Part 6: The Big Picture

### 20. `architecture.md` → [architecture.md](architecture.md)
Read last. Complete data flow diagrams, systolic timing, verification strategy, design pitfalls, and the planned burst-mode upgrade path.

---

## Summary
**Steps 1–5**: HBM DMA engine — burst AXI4 patterns, FWFT FIFO idiom.  
**Steps 6–10**: Systolic array — FP32 arithmetic → PE → 16×16 grid → MXU controller.  
**Step 11**: HBM bridge — 512-bit packing, handshake memory interface.  
**Steps 12–14**: Production Vitis kernel — AXI bridge, packaging.  
**Steps 15–19**: Verification — cocotb testbenches at four isolation levels.

The three sentences to carry through:
- **DMA reference:** reads from HBM via AXI4 bursts, streams through a FWFT FIFO, writes back — zero-bubble burst DMA, fixing the >4KB hang.
- **Compute:** the systolic array computes OUT = X × W^T using weight-stationary dataflow with staggered activation feeding.
- **Integration:** matmul_top unpacks 512-bit HBM words into per-element BRAMs, runs the MXU, repacks results — bridge between memory bandwidth and compute. krnl_matmul wraps this with Vitis AXI4 master ports.
