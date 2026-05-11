# bf16_add.sv — BF16 Adder
**Path:** `src/bf16_add.sv`
**Origin:** Adapted from `fp32_add.sv`; mantissa width reduced from 23 to 7 bits.

## Purpose
Combinational IEEE-754 BF16 adder. Given two 16-bit BF16 inputs `a` and `b`, produces `result = a + b` in a single combinational pass.

BF16 format: `[15]` sign · `[14:7]` exponent (bias 127) · `[6:0]` mantissa.

## Interface
| Port     | Direction | Width | Description         |
|----------|-----------|-------|---------------------|
| `a`      | input     | 16    | First BF16 operand  |
| `b`      | input     | 16    | Second BF16 operand |
| `result` | output    | 16    | BF16 sum `a + b`    |

No parameters — hardcoded 16-bit BF16.

## Internal Operation (Normal Case)

### 1. Field Extraction
Continuous assigns decompose each input into sign, 8-bit exponent, and 7-bit mantissa.

### 2. Special Value Detection
Combinational flags: `a_nan`, `b_nan`, `a_inf`, `b_inf`, `a_zero`, `b_zero`.

### 3. Special Case Handling
Priority-ordered:
- **NaN** → `16'h7FC0` (canonical BF16 NaN)
- **Inf + Inf (same sign)** → Infinity
- **Inf + Inf (opposite sign)** → NaN
- **Inf + finite** → Infinity
- **Zero + Zero** → Zero (sign = AND of input signs)
- **Zero + nonzero** → the nonzero operand

### 4. Normal Addition
1. **Implicit bit restoration:** `{1'b1, mant[6:0]}` for normals, `{1'b0, mant[6:0]}` for subnormals — yields 8-bit `mant_ext`.
2. **Exponent alignment:** Smaller mantissa right-shifted by exponent difference; larger exponent kept.
3. **Mantissa add/subtract:**
   - Same sign → add 8-bit mantissas into 9-bit `sum_mant`; `result_sign = input sign`
   - Opposite sign → subtract smaller from larger; `result_sign = sign of larger`
4. **Normalization:**
   - `sum_mant[8]` set → carry-out: right-shift + increment exponent
   - `sum_mant[7]` set → already normalized
   - Otherwise → scan bits 6..0 for leading 1, left-shift, decrement exponent accordingly
5. **Result assembly:**
   - Zero → `16'h0000`
   - Overflow (exp ≥ 255) → ±Infinity
   - Underflow (exp ≤ 0) → Subnormal (right-shift by `1 − exp`)
   - Normal → `{result_sign, result_exp[7:0], sum_mant[6:0]}`

## Design Notes
- **Purely combinational** — `always_comb` block with no clock dependency.
- **Used inside `pe.sv`** as the accumulate stage: `mac_out = mult_out + pe_psum_in`.
- Exponent/special-case logic is identical to FP32 add; only the mantissa path is narrower (7-bit mantissa vs 23-bit, 8-bit extended vs 24-bit).
- No explicit rounding — for the small integer values used in testing, additions are always exact.
