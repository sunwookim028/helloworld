# fifo4.sv — Synchronous FWFT FIFO
**Path:** `src/fifo4.sv`
**Origin:** Copied from `minitpu/tpu/src/system/fifo4.sv`

## Purpose
A synchronous First-Word-Fall-Through (FWFT) FIFO. The key property of FWFT is that `rd_data` is valid **combinationally** whenever `!empty` — there is no extra clock cycle of read latency. This enables back-to-back data streaming without pipeline bubbles.

In this project, the FIFO sits between the AXI4 read master and write master inside `krnl_vadd.sv`, buffering 512-bit data words as they arrive from HBM reads before being written out.

## Interface
| Port          | Direction | Width | Description                                     |
|---------------|-----------|-------|-------------------------------------------------|
| `clk`         | input     | 1     | Clock                                           |
| `rst_n`       | input     | 1     | Active-low asynchronous reset                   |
| `flush`       | input     | 1     | Synchronous clear (resets pointers, active high) |
| `wr_en`       | input     | 1     | Write enable                                    |
| `wr_data`     | input     | WIDTH | Data to write                                   |
| `rd_en`       | input     | 1     | Read acknowledge (advance read pointer)          |
| `rd_data`     | output    | WIDTH | FWFT output: valid combinationally when `!empty` |
| `full`        | output    | 1     | FIFO is full                                    |
| `empty`       | output    | 1     | FIFO is empty                                   |
| `almost_full` | output    | 1     | Count >= DEPTH-1 (one slot remaining or full)    |

### Parameters
| Parameter | Default | Description                        |
|-----------|---------|------------------------------------|
| `WIDTH`   | 32      | Data word width in bits            |
| `DEPTH`   | 64      | FIFO depth (must be power of 2)    |

## Internal Architecture
### Pointer Scheme
Uses `$clog2(DEPTH) + 1`-bit pointers (index bits + one wrap bit). The wrap bit disambiguates full vs. empty:

- **Empty:** `wptr == rptr` (same index, same wrap bit)
- **Full:** `wptr` and `rptr` have the same index bits but different wrap bits (the write pointer has lapped the read pointer)

### FWFT Read
```systemverilog
assign rd_data = mem[rptr[PTR_W-2:0]];  // combinational — no register delay
```

The read data is always the memory word at the current read pointer. When `rd_en` is asserted and `!empty`, the read pointer advances on the next clock edge, exposing the next word combinationally.

### Flow Control
- **Write:** On `wr_en && !full`, data is written to `mem[wptr]` and `wptr` increments.
- **Read:** On `rd_en && !empty`, `rptr` increments (data was already output combinationally).
- **`almost_full`:** Asserted when `count >= DEPTH-1`. Used by the read master to backpressure AXI reads (`RREADY = !fifo_almost_full`).

## How It's Used in krnl_vadd.sv
```
rd_mst ──fifo_wr_en/data──► fifo4 (512-bit, depth=64) ──fifo_rd_data──► wr_mst
                              ▲                                           │
                              │◄──────────── fifo_rd_en ──────────────────┘
                              │              (combinational: WVALID && WREADY)
                              │
                    fifo_almost_full ──────► rd_mst (backpressure: RREADY=0)
```

The write master's `WVALID` is combinational (`!fifo_empty && state==S_W`) and `WDATA` is wired directly to `fifo_rd_data`. The `fifo_rd_en` signal is also combinational (`WVALID && WREADY`). This FWFT idiom — identical to minitpu's AXI-Stream master — achieves zero-bubble streaming.
