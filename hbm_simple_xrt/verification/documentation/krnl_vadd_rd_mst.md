# krnl_vadd_rd_mst.v — AXI4 Burst Read Master

**Path:** `src/krnl_vadd_rd_mst.v`

## Purpose

Reads `num_words` × 512-bit words from HBM starting at `base_addr` using AXI4 burst transactions. Data is pushed into an external FWFT FIFO for the write master to consume. Supports multi-burst transfers (each burst up to 256 beats = 16 KB at 512-bit width).

## Interface

| Port              | Direction | Width      | Description                              |
|-------------------|-----------|------------|------------------------------------------|
| `clk`, `rst_n`    | input     | 1          | Clock and active-low reset               |
| `start`           | input     | 1          | Pulse to begin reading                   |
| `base_addr`       | input     | ADDR_WIDTH | Byte address of first word in HBM        |
| `num_words`       | input     | 32         | Total 512-bit words to read              |
| `done`            | output    | 1          | One-cycle pulse when all reads complete  |
| `fifo_wr_en`      | output    | 1          | Write strobe to FIFO                     |
| `fifo_wr_data`    | output    | DATA_WIDTH | Data word to write into FIFO             |
| `fifo_almost_full`| input     | 1          | Backpressure from FIFO                   |
| `M_AXI_AR*`       | output    | various    | AXI4 read address channel                |
| `M_AXI_R*`        | input/out | various    | AXI4 read data channel                   |

## FSM

```
IDLE ──start──► AR ──ARREADY──► R ──RLAST──► AR (more bursts) or DONE ──► IDLE
```

### S_IDLE
Waits for `start` pulse. Computes first burst length: `min(num_words, 256)`.

### S_AR
Presents `ARVALID`, `ARADDR`, and `ARLEN` (beats - 1). Waits for `ARREADY` handshake, then transitions to S_R.

### S_R
Accepts read data beats:
- **`RREADY`** is driven **combinationally**: `(state == S_R) && !fifo_almost_full`. This provides natural backpressure — when the FIFO fills up, RREADY drops and the AXI interconnect stalls.
- On each `RVALID && RREADY` handshake: writes data into FIFO, decrements `beats_left`.
- On `RLAST`: updates `words_done`, advances `rd_addr` by `burst_len × 64` bytes, computes next burst length, and either loops to S_AR or transitions to S_DONE.

### S_DONE
Pulses `done` for one cycle, returns to S_IDLE.

## Burst Length Calculation

```verilog
wire [31:0] next_remaining = num_words - (words_done + burst_len);
wire [8:0]  next_burst_len = (next_remaining > 256) ? 256 : next_remaining[8:0];
```

The next burst length is computed **combinationally** from pre-NBA register values and latched on the RLAST cycle.

## AXI4 Constants

| Signal        | Value     | Meaning                            |
|---------------|-----------|------------------------------------|
| `ARSIZE`      | `3'b110`  | 64 bytes/beat (2^6 = 512 bits)     |
| `ARBURST`     | `2'b01`   | INCR (incrementing address)        |
| `ARCACHE`     | `4'b1111` | Write-back, read/write allocate    |
