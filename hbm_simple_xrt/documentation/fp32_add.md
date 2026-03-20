# fp32_add.sv — IEEE-754 FP32 Adder
**Path:** `src/fp32_add.sv`
**Origin:** Copied from `minitpu/tpu/src/compute_tile/fp32_add.sv`

## Purpose
Combinational IEEE-754 single-precision floating-point adder. Given two 32-bit FP32 inputs `a` and `b`, it produces `result = a + b` in a single combinational pass. Also supports a fixed-point mode via the `FORMAT` parameter, though only `"FP32"` mode is used in this design.

## Interface
| Port     | Direction | Width  | Description                |
|----------|-----------|--------|----------------------------|
| `a`      | input     | WIDTH  | First FP32 operand         |
| `b`      | input     | WIDTH  | Second FP32 operand        |
| `result` | output    | WIDTH  | FP32 sum `a + b`           |

### Parameters
| Parameter   | Default   | Description                               |
|-------------|-----------|-------------------------------------------|
| `FORMAT`    | `"FP32"`  | Selects FP32 or fixed-point mode          |
| `INT_BITS`  | 16        | Fixed-point integer bits (unused in FP32) |
| `FRAC_BITS` | 16        | Fixed-point fraction bits (unused in FP32)|
| `WIDTH`     | 32        | Data width                                |

## Internal Operation (FP32 Mode)
The adder uses a `generate` block to select between FP32 and fixed-point implementations. Only FP32 mode is active in this design.

### 1. Field Extraction (lines 29–36)
Continuous assigns decompose each input into sign, 8-bit exponent, and 23-bit mantissa.

### 2. Special Value Detection (lines 37–42)
Combinational flags for NaN, infinity, and zero detection on both inputs.

### 3. Special Case Handling (lines 57–77)
Priority-ordered:
- **NaN** → output canonical NaN (`0x7FC00000`)
- **Inf + Inf (same sign)** → Infinity
- **Inf + Inf (opposite sign)** → NaN
- **Inf + finite** → Infinity
- **Zero + Zero** → Zero (sign = AND of input signs, per IEEE)
- **Zero + nonzero** → the nonzero operand

### 4. Normal Addition (lines 78–162)
1. **Implicit bit restoration:** Normal numbers get `{1, mantissa}` (24 bits); subnormals get `{0, mantissa}`.

2. **Exponent alignment:** The smaller operand's mantissa is right-shifted by the exponent difference. The larger exponent is kept.

3. **Mantissa add/subtract:**
   - Same sign → add mantissas, result sign = input sign
   - Different sign → subtract smaller from larger mantissa, result sign = sign of the larger

4. **Normalization:**
   - **Overflow (bit 24 set):** Right-shift mantissa, increment exponent
   - **Already normalized (bit 23 set):** No action needed
   - **Leading-zero normalization:** Scan from bit 22 down to find the first `1`, left-shift accordingly, decrement exponent

5. **Result assembly:**
   - Zero result → `0x00000000`
   - Overflow (exp ≥ 255) → ±Infinity
   - Underflow (exp ≤ 0) → Subnormal result (right-shift mantissa)
   - Normal → `{sign, exp[7:0], mantissa[22:0]}`

### Fixed-Point Mode (lines 166–180)
Simple saturating integer addition: `result = a + b` with overflow clamping to max positive or max negative.

## Design Notes
- **Purely combinational** — completes in one `always_comb` block. Critical path includes exponent comparison, mantissa shift, 25-bit add, and normalization scan.
- **Used inside `pe.sv`** as the accumulation stage: `mac_out = mult_out + pe_psum_in`.
- **No rounding:** Unlike the multiplier, this adder doesn't implement explicit round-to-nearest-even. For the small integer values used in testing, this produces exact results.
