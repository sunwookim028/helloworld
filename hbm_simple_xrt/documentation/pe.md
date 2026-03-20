# pe.sv — Processing Element (MAC Unit)
**Path:** `src/pe.sv`
**Origin:** Copied from `minitpu/tpu/src/compute_tile/pe.sv`

## Purpose
A single PE for the weight-stationary systolic array. Computes `psum_out = (input × weight_active) + psum_in`, pipelines activations east, weights/psums south, and propagates valid/switch signals.

## Interface
| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low async reset |
| `pe_psum_in` | in | DATA_WIDTH | Partial sum from PE above (north) |
| `pe_weight_in` | in | DATA_WIDTH | Weight from PE above (north) |
| `pe_accept_w_in` | in | 1 | Weight-load enable |
| `pe_input_in` | in | DATA_WIDTH | Activation from PE to the left (west) |
| `pe_valid_in` | in | 1 | Data valid from west |
| `pe_switch_in` | in | 1 | Weight switch signal |
| `pe_enabled` | in | 1 | PE enable (tied `1'b1`) |
| `pe_psum_out` | out | DATA_WIDTH | Partial sum to PE below (south) |
| `pe_weight_out` | out | DATA_WIDTH | Weight to PE below (south) |
| `pe_input_out` | out | DATA_WIDTH | Activation to PE to the right (east) |
| `pe_valid_out` | out | 1 | Valid to east |
| `pe_switch_out` | out | 1 | Switch to south |

**Parameter:** `DATA_WIDTH` (default 32)

## Internal Architecture
```
          pe_weight_in / pe_psum_in
                  │
pe_input_in ──►┌──▼───────┐──► pe_input_out
pe_valid_in ──►│  fp32_mul│──► pe_valid_out
pe_switch_in──►│  fp32_add│──► pe_switch_out
               └──────────┘
                  │
          pe_psum_out / pe_weight_out
```
**Submodules:** `fp32_mul` (combinational: `mult_out = input × weight_active`), `fp32_add` (combinational: `mac_out = mult_out + psum_in`)

**Registers:** `weight_reg_active` (foreground, used for MAC), `weight_reg_inactive` (background, loaded during compute)

## Operation
| Condition | Behavior |
|-----------|----------|
| Reset / disabled | All outputs and weight registers zeroed |
| `pe_accept_w_in` | `weight_reg_inactive ← pe_weight_in`; pass weight south |
| `pe_switch_in` (with `accept_w`) | `weight_reg_active ← pe_weight_in` (direct) |
| `pe_switch_in` (without `accept_w`) | `weight_reg_active ← weight_reg_inactive` (swap) |
| `pe_valid_in` | `psum_out = (input × weight_active) + psum_in`; `input_out = input_in`; `valid_out = 1` |
| `pe_valid_in` deasserted | `psum_out = 0`; `valid_out = 0` |
| Every cycle | `valid_in` and `switch_in` registered and forwarded east/south |

## Design Notes
- **Single-cycle latency:** Each PE delays activations (east), psums (south), weights (south), and control signals by exactly one cycle — creates the staggered systolic timing.
- **Weight-stationary:** Weights loaded once per matrix multiply; activations flow through.
- **Double-buffered weights:** active/inactive pair allows overlapping weight loading with computation.
