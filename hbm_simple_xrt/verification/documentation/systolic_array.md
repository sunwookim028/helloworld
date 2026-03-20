# systolic_array.sv — Parameterized N×N Weight-Stationary Systolic Array

**Path:** `src/systolic_array.sv`
**Origin:** Generalized from `minitpu/tpu/src/compute_tile/systolic.sv` (which was hardcoded for N=4)

## Purpose

An N×N grid of processing elements (PEs) that performs matrix multiplication using the weight-stationary dataflow. The array computes **OUT = X × W^T** where X is the input activation matrix and W is the weight matrix. The transpose happens naturally from how weights are loaded into columns.

## Interface

| Port        | Direction | Width            | Description                                      |
|-------------|-----------|------------------|--------------------------------------------------|
| `clk`       | input     | 1                | Clock                                            |
| `rst_n`     | input     | 1                | Active-low asynchronous reset                    |
| `data_in`   | input     | N×DATA_WIDTH     | Activation inputs, one per row (west edge)       |
| `valid_in`  | input     | N                | Valid flags, one per row                          |
| `weight_in` | input     | N×DATA_WIDTH     | Weight inputs, one per column (north edge)       |
| `accept_w`  | input     | N                | Weight-load enable, one per column                |
| `switch_in` | input     | 1                | Weight switch signal (enters at PE[0][0])         |
| `data_out`  | output    | N×DATA_WIDTH     | Partial sum outputs from bottom row               |
| `valid_out` | output    | N                | Valid flags from bottom row                       |

### Parameters

| Parameter    | Default | Description                    |
|--------------|---------|--------------------------------|
| `N`          | 16      | Array dimension (N×N PEs)      |
| `DATA_WIDTH` | 32      | Width of each data element     |

### Flat Packed Ports

All vector ports use flat packed bit-vectors for Icarus Verilog compatibility (Icarus doesn't support unpacked array ports). Element `i` occupies bits `[i*DATA_WIDTH +: DATA_WIDTH]`.

## Internal Architecture

```
        weight_in[0]   weight_in[1]   weight_in[2]  ...  weight_in[N-1]
        accept_w[0]    accept_w[1]    accept_w[2]        accept_w[N-1]
             │              │              │                   │
switch_in ──►PE[0][0] ──sw──PE[0][1] ──sw──PE[0][2] ... ──sw──PE[0][N-1]
             │    ▲         │              │                   │
             sw   │         sw             sw                  sw
             ▼    │         ▼              ▼                   ▼
data_in[0]──►PE[1][0] ───► PE[1][1] ───► PE[1][2] ... ───► PE[1][N-1]
             │              │              │                   │
             ▼              ▼              ▼                   ▼
data_in[1]──►PE[2][0] ───► PE[2][1] ───► PE[2][2] ... ───► PE[2][N-1]
             │              │              │                   │
             ⋮              ⋮              ⋮                   ⋮
             ▼              ▼              ▼                   ▼
          data_out[0]   data_out[1]   data_out[2]        data_out[N-1]
          valid_out[0]  valid_out[1]  valid_out[2]       valid_out[N-1]
```

### Signal Flow

| Signal          | Direction       | Description                                        |
|-----------------|-----------------|----------------------------------------------------|
| **Activations** | West → East     | `data_in[r]` enters row `r`, pipelines rightward   |
| **Valid**        | West → East     | Same path as activations                           |
| **Weights**     | North → South   | `weight_in[c]` enters column `c`, pipelines down   |
| **Partial sums**| North → South   | Accumulated MAC results, output at bottom row      |
| **Switch**      | Special routing | PE[0][0] → right along row 0, then down each column |

### Switch Routing (Critical Detail)

The switch signal follows a unique path that differs from other signals:

```systemverilog
if (r == 0 && c == 0)  → switch_in                    // External input
if (r == 0 && c > 0)   → pe_switch_out[c - 1]         // Right along row 0
if (r > 0)             → pe_switch_out[(r-1)*N + c]    // Down within column
```

This ensures all PEs in column `c` receive the switch signal one cycle after PE[0][c], cascading down the column.

## Generate Block Structure

The array is built with nested `generate for` loops:

```
gen_row[r] / gen_col[c]
├── west_edge / west_internal       — activation source mux
├── switch_origin / switch_row0 / switch_col — switch routing
├── north_edge / north_internal     — partial sum and weight source mux
└── u_pe                            — PE instance
```

Each PE's internal wires are stored in flat 1D arrays indexed by `r*N + c`:
- `pe_input_out[r*N + c]` — activation output (east)
- `pe_psum_out[r*N + c]` — partial sum output (south)
- `pe_weight_out[r*N + c]` — weight output (south)
- `pe_valid_out[r*N + c]` — valid output (east)
- `pe_switch_out[r*N + c]` — switch output

### Output Connection

The bottom row's partial sum outputs are connected to `data_out`:
```systemverilog
assign data_out[oc*DATA_WIDTH +: DATA_WIDTH] = pe_psum_out[(N-1)*N + oc];
assign valid_out[oc] = pe_valid_out[(N-1)*N + oc];
```

## Design Notes

- **Parameterized vs. hardcoded:** The original minitpu used flat, copy-pasted wiring for each of 16 PEs (4×4). This version uses generate blocks that work for any N.
- **Validated at N=4 and N=16:** Cross-checked against minitpu's known-good 4×4 behavior, then scaled to 16×16. All 19 tests pass at both sizes.
- **Icarus Verilog compatible:** Uses flat packed ports and avoids `automatic` variable lifetime overrides.
- **`pe_enabled` always tied to `1'b1`:** All PEs are always active in this design.
