# fp32_mul.sv — IEEE-754 FP32 Multiplier
**Path:** `src/fp32_mul.sv`
**Origin:** Copied from `minitpu/tpu/src/compute_tile/fp32_mul.sv`

## Purpose
Combinational (purely logic, no clock) IEEE-754 single-precision floating-point multiplier. Given two 32-bit FP32 inputs `a` and `b`, it produces their product `result = a × b` in a single combinational pass — no pipeline stages, no clock dependency.

## Interface
| Port     | Direction | Width | Description                     |
|----------|-----------|-------|---------------------------------|
| `a`      | input     | 32    | First FP32 operand              |
| `b`      | input     | 32    | Second FP32 operand             |
| `result` | output    | 32    | FP32 product `a × b`           |

### Parameters (unused in this design, present for interface compatibility)
| Parameter   | Default | Description                        |
|-------------|---------|-------------------------------------|
| `FORMAT`    | `"FP32"`| Number format selector              |
| `INT_BITS`  | 16      | Fixed-point integer bits (unused)   |
| `FRAC_BITS` | 16      | Fixed-point fraction bits (unused)  |
| `WIDTH`     | 32      | Data width                          |

## Internal Operation
The multiplier follows the standard textbook IEEE-754 multiplication algorithm:

### 1. Field Extraction (lines 31–36)
Decomposes each input into sign (`a_s`, `b_s`), biased exponent (`a_e`, `b_e`), and mantissa (`a_m`, `b_m`). The exponent is unbiased by subtracting 127.

### 2. Special Case Handling (lines 38–60)
Checked in priority order:
- **NaN inputs** → output NaN (`{1, 0xFF, 1, 22'h0}`)
- **Infinity × zero** → NaN
- **Infinity × finite** → Infinity with XOR'd sign
- **Zero × anything** → Zero with XOR'd sign

### 3. Normal Multiplication (lines 61–129)
For normal (and subnormal) inputs:

1. **Implicit bit restoration:** Normal numbers get the hidden `1` prepended to the mantissa. Subnormals stay as-is with exponent adjusted to -126.

2. **Subnormal normalization:** If the implicit bit is still 0 after restoration, left-shift the mantissa and decrement the exponent (lines 74–81).

3. **Mantissa multiplication:** `product = a_m × b_m × 4` — the `× 4` (left shift by 2) positions the result bits for easier extraction of the 24-bit mantissa, guard, round, and sticky bits.

4. **Exponent computation:** `z_e = a_e + b_e + 1` — the +1 accounts for the product format.

5. **Rounding (IEEE round-to-nearest-even):**
   - Guard bit = `product[25]`, round bit = `product[24]`, sticky = `product[23:0] != 0`
   - Rounds up when guard is set AND (round OR sticky OR LSB of mantissa is set)

6. **Underflow handling:** If the result exponent falls below -126, the mantissa is right-shifted to create a subnormal result.

7. **Overflow handling:** If the result exponent exceeds 127, the result is set to ±infinity.

8. **Result assembly:** Sign = XOR of input signs; exponent = `z_e + 127` (re-bias); mantissa = lower 23 bits of `z_m`.

## Design Notes
- **Purely combinational** — the entire multiply completes in one `always @(*)` block. This means latency is zero clock cycles but the critical path is long (~50-bit multiply + normalization logic). In a real FPGA design, this would typically be pipelined.
- **Used inside `pe.sv`** as the multiply stage of the MAC (multiply-accumulate) operation.
- **Correctness:** Validated against IEEE-754 reference via cocotb tests using "nice" FP32 values (small integers, powers of 2) where results are exact.
