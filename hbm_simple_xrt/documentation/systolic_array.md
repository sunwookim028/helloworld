# systolic_array.sv — Parameterized N×N Weight-Stationary Systolic Array

**Path:** `src/systolic_array.sv`
**Origin:** Generalized from `minitpu/tpu/src/compute_tile/systolic.sv` (hardcoded 4×4 → parameterized N×N)

N×N grid of PEs computing **OUT = X × W^T** using weight-stationary dataflow. The transpose of W emerges naturally from how weights are loaded into columns.

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low async reset |
| `data_in` | in | N×DATA_WIDTH | Activation inputs, one per row (west edge) |
| `valid_in` | in | N | Valid flags per row |
| `weight_in` | in | N×DATA_WIDTH | Weight inputs, one per column (north edge) |
| `accept_w` | in | N | Weight-load enable per column |
| `switch_in` | in | 1 | Weight switch (enters at PE[0][0]) |
| `data_out` | out | N×DATA_WIDTH | Partial sum outputs from bottom row |
| `valid_out` | out | N | Valid flags from bottom row |

All ports use flat packed vectors (`[i*DATA_WIDTH +: DATA_WIDTH]` for element i) — required for Icarus Verilog compatibility.

## Signal Flow

| Signal | Direction | Notes |
|--------|-----------|-------|
| Activations | West → East | `data_in[r]` enters row r, pipelines rightward |
| Valid | West → East | Same path as activations |
| Weights | North → South | `weight_in[c]` enters column c, pipelines down |
| Partial sums | North → South | Accumulated MAC results, zero injected at top row |
| Switch | Special | PE[0][0] → right along row 0, then down each column |

### Switch Routing (critical detail)
```systemverilog
if (r==0 && c==0): w_switch = switch_in
if (r==0 && c>0):  w_switch = pe_switch_out[c-1]        // rightward along row 0
if (r>0):          w_switch = pe_switch_out[(r-1)*N + c] // downward in column
```

## Generate Block Structure

Nested `generate for` loops build the grid. For each PE[r][c]:
- **West mux** (c==0): `data_in[r*DW +: DW]`, else `pe_input_out[r*N+c-1]`
- **North mux** (r==0): `psum_in=0`, `weight_in[c*DW +: DW]`, else from PE above
- **Switch mux**: as above
- **PE instance**: `pe #(.DATA_WIDTH) u_pe(...)`

Internal wire arrays (flat 1D, indexed `r*N+c`): `pe_input_out`, `pe_psum_out`, `pe_weight_out`, `pe_valid_out`, `pe_switch_out`.

Bottom row output: `data_out[oc*DATA_WIDTH +: DATA_WIDTH] = pe_psum_out[(N-1)*N + oc]`.

## Design Notes

- Validated at N=4 (cross-check against minitpu's known-good behavior), N=16, and N=32.
- `pe_enabled` tied to `1'b1` — all PEs always active.
- No `automatic` variables; no unpacked array ports.
- **Default N=32, DATA_WIDTH=16 (BF16)** — PEs instantiate `bf16_mul` and `bf16_add`.
