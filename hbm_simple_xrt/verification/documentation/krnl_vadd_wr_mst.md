# krnl_vadd_wr_mst.v — AXI4 Burst Write Master

**Path:** `src/krnl_vadd_wr_mst.v`

## Purpose

Writes `num_words` × 512-bit words to HBM starting at `base_addr` using AXI4 burst transactions. Data is sourced from an external FWFT FIFO. The critical design pattern here is that `WVALID`, `WDATA`, `WLAST`, and `fifo_rd_en` are all **combinational** — this FWFT idiom (identical to minitpu's AXI-Stream master) achieves zero-bubble streaming on the W channel.

## Interface

| Port              | Direction | Width      | Description                              |
|-------------------|-----------|------------|------------------------------------------|
| `clk`, `rst_n`    | input     | 1          | Clock and active-low reset               |
| `start`           | input     | 1          | Pulse to begin writing                   |
| `base_addr`       | input     | ADDR_WIDTH | Byte address of first word in HBM        |
| `num_words`       | input     | 32         | Total 512-bit words to write             |
| `done`            | output    | 1          | One-cycle pulse when all writes complete |
| `fifo_rd_en`      | output    | 1          | **Combinational** read enable to FIFO    |
| `fifo_rd_data`    | input     | DATA_WIDTH | FWFT FIFO head (valid when `!empty`)     |
| `fifo_empty`      | input     | 1          | FIFO empty flag                          |
| `M_AXI_AW*`       | output    | various    | AXI4 write address channel               |
| `M_AXI_W*`        | output    | various    | AXI4 write data channel                  |
| `M_AXI_B*`        | input/out | various    | AXI4 write response channel              |

## FSM

```
IDLE ──start──► AW ──AWREADY──► W ──WLAST──► B ──BVALID──► AW (more) or IDLE
```

### S_IDLE
Waits for `start`, computes first burst length.

### S_AW
Presents `AWVALID`, `AWADDR`, `AWLEN`. Waits for `AWREADY`.

### S_W
Streams data from FIFO to AXI W channel. The key combinational signals:

```verilog
assign M_AXI_WVALID = (state == S_W) && !fifo_empty;
assign M_AXI_WDATA  = fifo_rd_data;           // direct FIFO head
assign M_AXI_WLAST  = M_AXI_WVALID && (beats_left == 1);
assign fifo_rd_en   = M_AXI_WVALID && M_AXI_WREADY;  // dequeue on handshake
```

**Why combinational?** With a FWFT FIFO, `rd_data` is always the current head word. On the handshake cycle, `fifo_rd_en` fires, the read pointer advances next cycle, and the new head is ready combinationally — no bubble.

### S_B
Waits for `BVALID` (write response). Updates `words_done`, advances address, either loops to S_AW or pulses `done` and returns to S_IDLE.

## FWFT Timing Detail

```
Cycle N:   WVALID=1, WREADY=1 → handshake. WDATA = mem[rptr_N]. fifo_rd_en=1.
Cycle N+1: rptr advances to rptr_N+1. WDATA = mem[rptr_N+1] (combinational). ✓
```

No dead cycle between beats. This is the same pattern minitpu uses for its AXI-Stream master (`tpu_master_axi_stream.v`).

## AXI4 Constants

| Signal        | Value     | Meaning                            |
|---------------|-----------|------------------------------------|
| `AWSIZE`      | `3'b110`  | 64 bytes/beat (512 bits)           |
| `AWBURST`     | `2'b01`   | INCR                               |
| `AWCACHE`     | `4'b1111` | Write-back, read/write allocate    |
| `BREADY`      | `1'b1`    | Always accept write response       |
