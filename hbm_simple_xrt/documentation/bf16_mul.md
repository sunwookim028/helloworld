# bf16_mul.sv — BF16 Multiplier
**Path:** `src/bf16_mul.sv`
**Origin:** Adapted from `fp32_mul.sv`; mantissa width reduced from 23 to 7 bits.

## Purpose
Combinational IEEE-754 BF16 multiplier. Given two 16-bit BF16 inputs `a` and `b`, produces `result = a × b` in a single combinational pass — no pipeline stages, no clock dependency.

BF16 format: `[15]` sign · `[14:7]` exponent (bias 127, identical to FP32) · `[6:0]` mantissa.

## Interface
| Port     | Direction | Width | Description          |
|----------|-----------|-------|----------------------|
| `a`      | input     | 16    | First BF16 operand   |
| `b`      | input     | 16    | Second BF16 operand  |
| `result` | output    | 16    | BF16 product `a × b` |

No parameters — hardcoded 16-bit BF16.

## Internal Operation

### 1. Field Extraction
Decomposes each input into sign (`a_s`, `b_s`), biased exponent (`a_e`, `b_e`, unbiased by −127), and 7-bit mantissa (`a_m[6:0]`, `b_m[6:0]`).

### 2. Special Case Handling
Priority-ordered:
- **NaN inputs** → output NaN (`16'h7FC0`)
- **Infinity × zero** → NaN
- **Infinity × finite** → Infinity with XOR'd sign
- **Zero × anything** → Zero with XOR'd sign

### 3. Normal Multiplication
1. **Implicit bit restoration:** Normal numbers get hidden `1` prepended → 8-bit mantissa `{1, mant[6:0]}`. Subnormals stay as-is with exponent adjusted to −126.
2. **Subnormal normalization:** Left-shift mantissa and decrement exponent if hidden bit is still 0.
3. **Mantissa multiplication:** `product = a_m × b_m × 4` — 18-bit result. The `×4` positions the 8-bit product at `product[17:10]`, with guard=`[9]`, round=`[8]`, sticky=`[7:0] != 0`.
4. **Exponent:** `z_e = a_e + b_e + 1`.
5. **Rounding (IEEE round-to-nearest-even):** Rounds up when guard is set AND (round OR sticky OR LSB of mantissa).
6. **Underflow:** Shift mantissa right to create subnormal if `z_e < −126`.
7. **Overflow:** Set ±Infinity if `z_e > 127`.
8. **Result assembly:** `{z_s, z_e[7:0]+127, z_m[6:0]}`.

## Design Notes
- **Purely combinational** — entire multiply in one `always @(*)` block.
- **Used inside `pe.sv`** as the multiply stage of MAC: `mult_out = pe_input_in × weight_reg_active`.
- **18-bit product width:** max `255 × 255 × 4 = 260,100 < 2^18 = 262,144` — fits exactly.
- Exponent logic is identical to FP32; only the mantissa path is narrower (8-bit operands vs 24-bit).
