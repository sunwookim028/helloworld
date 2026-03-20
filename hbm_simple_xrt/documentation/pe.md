# pe.sv — Processing Element (MAC Unit)

**Path:** `src/pe.sv`
**Origin:** Copied from `minitpu/tpu/src/compute_tile/pe.sv`

## Purpose

A single processing element (PE) for the weight-stationary systolic array. Each PE performs a multiply-accumulate (MAC) operation: it multiplies an incoming activation by its stored weight, adds the partial sum from the PE above, and passes the result downward. It also pipelines activations rightward, weights downward, and control signals (valid, switch) through the array.

## Interface

| Port             | Direction | Width      | Description                                    |
|------------------|-----------|------------|------------------------------------------------|
| `clk`            | input     | 1          | Clock                                          |
| `rst_n`          | input     | 1          | Active-low asynchronous reset                  |
| `pe_psum_in`     | input     | DATA_WIDTH | Partial sum from PE above (north)              |
| `pe_weight_in`   | input     | DATA_WIDTH | Weight from PE above (north)                   |
| `pe_accept_w_in` | input     | 1          | Weight-load enable (broadcast per column)       |
| `pe_input_in`    | input     | DATA_WIDTH | Activation from PE to the left (west)           |
| `pe_valid_in`    | input     | 1          | Data valid from PE to the left (west)           |
| `pe_switch_in`   | input     | 1          | Weight switch signal                            |
| `pe_enabled`     | input     | 1          | PE enable (tied to `1'b1` in this design)       |
| `pe_psum_out`    | output    | DATA_WIDTH | Partial sum to PE below (south)                 |
| `pe_weight_out`  | output    | DATA_WIDTH | Weight to PE below (south)                      |
| `pe_input_out`   | output    | DATA_WIDTH | Activation to PE to the right (east)            |
| `pe_valid_out`   | output    | 1          | Data valid to PE to the right (east)            |
| `pe_switch_out`  | output    | 1          | Weight switch signal (propagated)               |

### Parameters

| Parameter    | Default | Description       |
|--------------|---------|-------------------|
| `DATA_WIDTH` | 32      | Width of data bus |

## Internal Architecture

```
              pe_weight_in
              pe_psum_in
                  │
                  ▼
pe_input_in ──►┌──────────┐──► pe_input_out
pe_valid_in ──►│    PE    │──► pe_valid_out
pe_switch_in──►│          │──► pe_switch_out
               │ MAC unit │
               └──────────┘
                  │
                  ▼
              pe_psum_out
              pe_weight_out
```

### Submodules

1. **`fp32_mul`** — Combinational FP32 multiplier: `mult_out = pe_input_in × weight_reg_active`
2. **`fp32_add`** — Combinational FP32 adder: `mac_out = mult_out + pe_psum_in`

### Registers

| Register              | Purpose                                                  |
|-----------------------|----------------------------------------------------------|
| `weight_reg_active`   | Foreground weight — used for the current MAC operation    |
| `weight_reg_inactive` | Background weight — loaded while previous compute runs   |

## Operation

### Reset / Disabled
All outputs and weight registers are zeroed.

### Weight Loading (`pe_accept_w_in` asserted)
- Incoming weight is stored in `weight_reg_inactive` (background register)
- Weight is also passed through to `pe_weight_out` for the PE below

### Weight Switch (`pe_switch_in` asserted)
The background weight is promoted to the foreground:
- If `pe_accept_w_in` is also asserted: `weight_reg_active ← pe_weight_in` (direct)
- Otherwise: `weight_reg_active ← weight_reg_inactive` (swap)

This double-buffering allows the next set of weights to be loaded while the current computation is in progress.

### MAC Operation (`pe_valid_in` asserted)
- `pe_psum_out ← (pe_input_in × weight_reg_active) + pe_psum_in`
- `pe_input_out ← pe_input_in` (pass activation rightward)
- `pe_valid_out ← 1`

### Idle (`pe_valid_in` deasserted)
- `pe_psum_out ← 0`
- `pe_valid_out ← 0`

### Signal Propagation
Every cycle, `pe_valid_in` and `pe_switch_in` are registered and forwarded to the east/south outputs. This creates the diagonal wavefront that is fundamental to systolic array timing.

## Design Notes

- **Single-cycle latency:** Each PE adds exactly one clock cycle of delay to activations (east), partial sums (south), weights (south), and control signals. This creates the staggered timing pattern of the systolic array.
- **Weight-stationary architecture:** Weights are loaded once and stay in place for an entire matrix multiply. Activations flow through, accumulating partial sums as they go.
- **Double-buffered weights:** The active/inactive register pair allows overlapping weight loading with computation.
