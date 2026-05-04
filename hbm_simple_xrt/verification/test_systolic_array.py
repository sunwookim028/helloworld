"""
Cocotb test suite for the parameterized N×N systolic array.

Tests the systolic array directly by driving the same protocol
that the MXU FSM uses (weight loading, switch, X input feeding).

The systolic array computes: OUT = X * W^T

Test values use "nice" FP32 numbers (small integers) so expected
outputs are exact in IEEE-754 single precision.
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
DW = 32  # DATA_WIDTH


# =============================================================================
# FP32 helpers
# =============================================================================
def float_to_bits(val: float) -> int:
    return struct.unpack(">I", struct.pack(">f", float(val)))[0]


def bits_to_float(bits: int) -> float:
    bits = bits & 0xFFFFFFFF
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def pack_vector(values):
    """Pack list of N FP32 bit-patterns into a single wide integer."""
    result = 0
    for i, v in enumerate(values):
        result |= (v & 0xFFFFFFFF) << (i * DW)
    return result


def unpack_value(packed, index):
    """Extract the index-th 32-bit element from a packed vector."""
    return (int(packed) >> (index * DW)) & 0xFFFFFFFF


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
    Combines drive + capture to avoid cocotb concurrent task issues.
    Returns NxN numpy array.
    """
    total_drive_phases = 3 * N - 1
    # Extra cycles after drive for pipeline drain
    total_cycles = total_drive_phases + 2 * N

    row_ptr = [0] * N
    result = np.zeros((N, N), dtype=np.float32)

    for cycle in range(total_cycles):
        # --- Drive phase (set inputs) ---
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
            # Clear inputs after drive is done
            dut.weight_in.value = 0
            dut.accept_w.value = 0
            dut.switch_in.value = 0
            dut.data_in.value = 0
            dut.valid_in.value = 0

        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")

        # --- Capture phase (read outputs) ---
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


def assert_matrix_close(actual, expected, rtol=1e-5, atol=1e-6, label=""):
    """Compare two NxN matrices element-wise."""
    for i in range(N):
        for j in range(N):
            a = float(actual[i][j])
            e = float(expected[i][j])
            if abs(e) > 1e-10:
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
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
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
        X[i, :] = float(i + 1)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
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
        X[i, :] = float(i + 1)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[all_ones] ")
    cocotb.log.info("PASS: all ones weight matrix")


@cocotb.test()
async def test_zero_weights(dut):
    """W = 0 → OUT = 0 regardless of X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.zeros((N, N), dtype=np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

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

    W = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)
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
    W[0, :] = 1.0  # row 0 of W → column 0 of W^T
    X = np.ones((N, N), dtype=np.float32)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[single_col] ")
    cocotb.log.info("PASS: single column weight")


@cocotb.test()
async def test_known_small_integers(dut):
    """Small integer matrices with hand-verifiable results."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Simple pattern: W[i][j] = i+1, X[i][j] = j+1
    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = float(i + 1)
            X[i][j] = float(j + 1)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[small_int] ")
    cocotb.log.info("PASS: small integer matrices")


@cocotb.test()
async def test_random_integer_matrices(dut):
    """Random integer matrices (range -3 to 3), 5 cases."""
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
        expected = (X @ W.T).astype(np.float32)
        assert_matrix_close(result, expected, rtol=1e-4,
                            label=f"[random_{case_idx}] ")
        cocotb.log.info(f"PASS: random case {case_idx + 1}/{num_cases}")


@cocotb.test()
async def test_negative_values(dut):
    """Test with negative weights and inputs."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = -1.0 * np.eye(N, dtype=np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)  # = -X
    assert_matrix_close(result, expected, label="[negative] ")
    cocotb.log.info("PASS: negative values")


@cocotb.test()
async def test_back_to_back(dut):
    """Two consecutive matmuls without reset between them."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # First matmul
    W1 = np.eye(N, dtype=np.float32)
    X1 = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)
    result1 = await run_matmul(dut, W1, X1)
    expected1 = (X1 @ W1.T).astype(np.float32)
    assert_matrix_close(result1, expected1, label="[b2b_1] ")

    # Wait a few cycles
    for _ in range(5):
        await RisingEdge(dut.clk)

    # Second matmul — different matrices, no reset
    W2 = 3.0 * np.eye(N, dtype=np.float32)
    X2 = np.ones((N, N), dtype=np.float32) * 2.0
    result2 = await run_matmul(dut, W2, X2)
    expected2 = (X2 @ W2.T).astype(np.float32)
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
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[perm] ")
    cocotb.log.info("PASS: permutation matrix")


@cocotb.test()
async def test_upper_triangular(dut):
    """Upper triangular W with 1s on and above diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.triu(np.ones((N, N), dtype=np.float32))
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[upper_tri] ")
    cocotb.log.info("PASS: upper triangular")


@cocotb.test()
async def test_lower_triangular(dut):
    """Lower triangular W with 1s on and below diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.tril(np.ones((N, N), dtype=np.float32))
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[lower_tri] ")
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
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[sparse] ")
    cocotb.log.info("PASS: sparse matrix")


@cocotb.test()
async def test_symmetric_weight(dut):
    """Symmetric W (W = W^T) so OUT = X * W."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Build symmetric: W = A + A^T with small integers
    A = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(i, N):
            A[i][j] = float((i + j) % 3)
    W = (A + A.T).astype(np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[symmetric] ")
    cocotb.log.info("PASS: symmetric weight")


@cocotb.test()
async def test_large_values(dut):
    """Larger FP32 values (powers of 2, exact in IEEE-754)."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    W = np.eye(N, dtype=np.float32) * 256.0
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(2 ** (i % 8))

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[large_val] ")
    cocotb.log.info("PASS: large values")


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
    expected = (X @ W.T).astype(np.float32)
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
    X[0, :] = np.arange(1, N + 1, dtype=np.float32)

    result = await run_matmul(dut, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[single_row] ")
    cocotb.log.info("PASS: single row nonzero")


@cocotb.test()
async def test_triple_back_to_back(dut):
    """Three consecutive matmuls without reset."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    configs = [
        (np.eye(N, dtype=np.float32), np.arange(1, N*N+1, dtype=np.float32).reshape(N, N)),
        (2.0 * np.eye(N, dtype=np.float32), np.ones((N, N), dtype=np.float32) * 3.0),
        (-1.0 * np.eye(N, dtype=np.float32), np.arange(1, N*N+1, dtype=np.float32).reshape(N, N)),
    ]

    for idx, (W, X) in enumerate(configs):
        if idx > 0:
            for _ in range(5):
                await RisingEdge(dut.clk)
        result = await run_matmul(dut, W, X)
        expected = (X @ W.T).astype(np.float32)
        assert_matrix_close(result, expected, label=f"[triple_b2b_{idx}] ")

    cocotb.log.info("PASS: triple back-to-back")
