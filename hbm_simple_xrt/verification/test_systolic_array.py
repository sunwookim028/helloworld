"""
Cocotb test suite for the parameterized N×N systolic array (BF16).

Tests the systolic array directly by driving the same protocol
that the MXU FSM uses (weight loading, switch, X input feeding).

The systolic array computes: OUT = X * W^T

Test values use small integers so BF16 products and accumulated sums
are representable exactly (max sum for N=32 with values ≤3 is 288,
which is exactly representable in BF16).
"""

import os
import struct
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

random.seed(0xBEEF_CAFE)

N = int(os.environ.get("SYSTOLIC_N", 32))
DW = 16  # DATA_WIDTH (BF16)


# =============================================================================
# BF16 helpers — BF16 = upper 16 bits of IEEE 754 float32
# =============================================================================
def float_to_bits(val: float) -> int:
    """Float32 → BF16 bit pattern."""
    bits32 = struct.unpack(">I", struct.pack(">f", float(val)))[0]
    return (bits32 >> 16) & 0xFFFF


def bits_to_float(bits: int) -> float:
    """BF16 bit pattern → float32."""
    bits32 = (int(bits) & 0xFFFF) << 16
    return struct.unpack(">f", struct.pack(">I", bits32))[0]


def pack_vector(values):
    """Pack list of N BF16 bit-patterns into a single wide integer."""
    result = 0
    for i, v in enumerate(values):
        result |= (v & 0xFFFF) << (i * DW)
    return result


def unpack_value(packed, index):
    """Extract the index-th 16-bit BF16 element from a packed vector."""
    return (int(packed) >> (index * DW)) & 0xFFFF


def bf16_mat(m: np.ndarray) -> np.ndarray:
    """Round float32 matrix to BF16 precision (for reference computation)."""
    return np.array([[bits_to_float(float_to_bits(m[i][j])) for j in range(m.shape[1])]
                     for i in range(m.shape[0])], dtype=np.float32)


# =============================================================================
# Drive protocol — matches MXU S_RUN exactly
# =============================================================================
async def reset_dut(dut):
    """Apply reset and initialize all inputs to zero."""
    dut.rst_n.value = 0
    dut.data_in.value = 0
    dut.valid_in.value = 0
    dut.weight_in.value = 0
    dut.accept_w.value = 0
    dut.switch_in.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_matmul(dut, W, X):
    """
    Drive a matmul and capture results in a single sequential loop.
    Returns NxN numpy array with BF16-decoded float32 values.
    """
    total_drive_phases = 3 * N - 1
    total_cycles = total_drive_phases + 2 * N

    row_ptr = [0] * N
    result = np.zeros((N, N), dtype=np.float32)

    for cycle in range(total_cycles):
        if cycle < total_drive_phases:
            phase = cycle
            weight_bits = [0] * N
            accept_w_val = 0
            data_bits = [0] * N
            valid_val = 0

            for c_idx in range(N):
                if c_idx <= phase < c_idx + N:
                    p = phase - c_idx
                    weight_bits[c_idx] = float_to_bits(W[c_idx][N - 1 - p])
                    accept_w_val |= (1 << c_idx)

            switch_val = 1 if phase == N - 1 else 0

            for r in range(N):
                ph = phase - (N + r)
                if 0 <= ph < N:
                    data_bits[r] = float_to_bits(X[ph][r])
                    valid_val |= (1 << r)

            dut.weight_in.value = pack_vector(weight_bits)
            dut.accept_w.value = accept_w_val
            dut.switch_in.value = switch_val
            dut.data_in.value = pack_vector(data_bits)
            dut.valid_in.value = valid_val
        else:
            dut.weight_in.value = 0
            dut.accept_w.value = 0
            dut.switch_in.value = 0
            dut.data_in.value = 0
            dut.valid_in.value = 0

        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")

        try:
            valid_bits = int(dut.valid_out.value)
            data_packed = int(dut.data_out.value)
        except ValueError:
            continue

        for c_idx in range(N):
            if (valid_bits >> c_idx) & 1 and row_ptr[c_idx] < N:
                bits = unpack_value(data_packed, c_idx)
                result[row_ptr[c_idx]][c_idx] = bits_to_float(bits)
                row_ptr[c_idx] += 1

        if all(p >= N for p in row_ptr):
            break

    return result


def assert_matrix_close(actual, expected, rtol=1e-3, atol=1e-4, label=""):
    """Compare two NxN matrices element-wise."""
    for i in range(N):
        for j in range(N):
            a = float(actual[i][j])
            e = float(expected[i][j])
            if abs(e) > 1e-6:
                if abs(a - e) / abs(e) > rtol:
                    raise AssertionError(
                        f"{label}Mismatch at [{i}][{j}]: got {a}, expected {e} "
                        f"(rel err {abs(a-e)/abs(e):.2e})"
                    )
            else:
                if abs(a - e) > atol:
                    raise AssertionError(
                        f"{label}Mismatch at [{i}][{j}]: got {a}, expected {e} "
                        f"(abs err {abs(a-e):.2e})"
                    )


def small_x():
    """Return a small-integer X matrix (values 1-4) exact in BF16."""
    return (np.arange(N * N, dtype=np.float32) % 4 + 1).reshape(N, N)


# =============================================================================
# Tests
# =============================================================================

@cocotb.test()
async def test_identity_matrix(dut):
    """W = identity → OUT = X * I^T = X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.eye(N, dtype=np.float32)
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[identity] ")
    cocotb.log.info("PASS: identity matrix")


@cocotb.test()
async def test_scalar_multiply(dut):
    """W = 2*I → OUT = 2*X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = 2.0 * np.eye(N, dtype=np.float32)
    X = np.ones((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i % 4 + 1)

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[scalar] ")
    cocotb.log.info("PASS: scalar multiply")


@cocotb.test()
async def test_all_ones(dut):
    """W = all 1s → each output element = sum of corresponding X row."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.ones((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i % 4 + 1)

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[all_ones] ")
    cocotb.log.info("PASS: all ones weight matrix")


@cocotb.test()
async def test_zero_weights(dut):
    """W = 0 → OUT = 0 regardless of X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_matrix_close(result, expected, label="[zero_w] ")
    cocotb.log.info("PASS: zero weight matrix")


@cocotb.test()
async def test_zero_inputs(dut):
    """X = 0 → OUT = 0 regardless of W."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = small_x()
    X = np.zeros((N, N), dtype=np.float32)

    result = await run_matmul(dut, W, X)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_matrix_close(result, expected, label="[zero_x] ")
    cocotb.log.info("PASS: zero input matrix")


@cocotb.test()
async def test_single_column_weight(dut):
    """Only column 0 of W is non-zero → only column 0 of output should be non-zero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    W[0, :] = 1.0
    X = np.ones((N, N), dtype=np.float32)

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[single_col] ")
    cocotb.log.info("PASS: single column weight")


@cocotb.test()
async def test_known_small_integers(dut):
    """Small integer matrices — exact in BF16."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = float((i + j) % 3 + 1)
            X[i][j] = float((i + j + 1) % 3 + 1)

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[small_int] ")
    cocotb.log.info("PASS: small integer matrices")


@cocotb.test()
async def test_random_integer_matrices(dut):
    """Random small-integer matrices (range 0 to 3), 5 cases."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    num_cases = 5
    for case_idx in range(num_cases):
        await reset_dut(dut)

        W = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                      dtype=np.float32)
        X = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                      dtype=np.float32)

        result = await run_matmul(dut, W, X)
        expected = bf16_mat(X @ W.T)
        assert_matrix_close(result, expected, rtol=0.02,
                            label=f"[random_{case_idx}] ")
        cocotb.log.info(f"PASS: random case {case_idx + 1}/{num_cases}")


@cocotb.test()
async def test_negative_values(dut):
    """Test with negative weights and inputs."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = -1.0 * np.eye(N, dtype=np.float32)
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[negative] ")
    cocotb.log.info("PASS: negative values")


@cocotb.test()
async def test_back_to_back(dut):
    """Two consecutive matmuls without reset between them."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W1 = np.eye(N, dtype=np.float32)
    X1 = small_x()
    result1 = await run_matmul(dut, W1, X1)
    expected1 = bf16_mat(X1 @ W1.T)
    assert_matrix_close(result1, expected1, label="[b2b_1] ")

    for _ in range(5):
        await RisingEdge(dut.clk)

    W2 = 3.0 * np.eye(N, dtype=np.float32)
    X2 = np.ones((N, N), dtype=np.float32) * 2.0
    result2 = await run_matmul(dut, W2, X2)
    expected2 = bf16_mat(X2 @ W2.T)
    assert_matrix_close(result2, expected2, label="[b2b_2] ")

    cocotb.log.info("PASS: back-to-back matmuls")


@cocotb.test()
async def test_permutation_matrix(dut):
    """W = permutation (reverse rows) → OUT columns are reversed."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        W[i][N - 1 - i] = 1.0
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[perm] ")
    cocotb.log.info("PASS: permutation matrix")


@cocotb.test()
async def test_upper_triangular(dut):
    """Upper triangular W with 1s on and above diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.triu(np.ones((N, N), dtype=np.float32))
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[upper_tri] ")
    cocotb.log.info("PASS: upper triangular")


@cocotb.test()
async def test_lower_triangular(dut):
    """Lower triangular W with 1s on and below diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.tril(np.ones((N, N), dtype=np.float32))
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[lower_tri] ")
    cocotb.log.info("PASS: lower triangular")


@cocotb.test()
async def test_sparse_matrix(dut):
    """Sparse W with only corner elements nonzero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    W[0][0] = 2.0
    W[0][N-1] = -1.0
    W[N-1][0] = 3.0
    W[N-1][N-1] = -2.0
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[sparse] ")
    cocotb.log.info("PASS: sparse matrix")


@cocotb.test()
async def test_symmetric_weight(dut):
    """Symmetric W (W = W^T) so OUT = X * W."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    A = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(i, N):
            A[i][j] = float((i + j) % 3)
    W = (A + A.T).astype(np.float32)
    X = small_x()

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[symmetric] ")
    cocotb.log.info("PASS: symmetric weight")


@cocotb.test()
async def test_large_values(dut):
    """Powers-of-2 values (exact in BF16)."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.eye(N, dtype=np.float32) * 256.0
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(2 ** (i % 8))

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[large_val] ")
    cocotb.log.info("PASS: large values (powers of 2)")


@cocotb.test()
async def test_alternating_signs(dut):
    """Checkerboard pattern of +1/-1 in both W and X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = 1.0 if (i + j) % 2 == 0 else -1.0
            X[i][j] = 1.0 if (i + j) % 2 == 0 else -1.0

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, label="[alt_sign] ")
    cocotb.log.info("PASS: alternating signs")


@cocotb.test()
async def test_single_row_nonzero(dut):
    """Only row 0 of X is nonzero → only row 0 of output should be nonzero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.ones((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    X[0, :] = np.array([float(j % 4 + 1) for j in range(N)], dtype=np.float32)

    result = await run_matmul(dut, W, X)
    expected = bf16_mat(X @ W.T)
    assert_matrix_close(result, expected, rtol=0.02, label="[single_row] ")
    cocotb.log.info("PASS: single row nonzero")


@cocotb.test()
async def test_triple_back_to_back(dut):
    """Three consecutive matmuls without reset."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    configs = [
        (np.eye(N, dtype=np.float32), small_x()),
        (2.0 * np.eye(N, dtype=np.float32), np.ones((N, N), dtype=np.float32) * 3.0),
        (-1.0 * np.eye(N, dtype=np.float32), small_x()),
    ]

    for idx, (W, X) in enumerate(configs):
        if idx > 0:
            for _ in range(5):
                await RisingEdge(dut.clk)
        result = await run_matmul(dut, W, X)
        expected = bf16_mat(X @ W.T)
        assert_matrix_close(result, expected, label=f"[triple_b2b_{idx}] ")

    cocotb.log.info("PASS: triple back-to-back")
