"""
Cocotb test suite for the parameterized MXU (systolic array wrapper).

Tests the full FSM: IDLE → LOAD_W → LOAD_X → RUN → CAPTURE → STORE → DONE.
Uses a simple memory model driven by a cocotb coroutine.

The MXU computes: OUT = X * W^T
"""

import os
import struct
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

random.seed(0xDEAD_BEEF)

N = int(os.environ.get("MXU_N", 16))
DW = 32

BASE_ADDR_W   = 0x0000
BASE_ADDR_X   = 0x0200
BASE_ADDR_OUT = 0x0400
TIMEOUT_CYCLES = 10000


# =============================================================================
# FP32 helpers
# =============================================================================
def float_to_bits(val: float) -> int:
    return struct.unpack(">I", struct.pack(">f", float(val)))[0]


def bits_to_float(bits: int) -> float:
    bits = bits & 0xFFFFFFFF
    return struct.unpack(">f", struct.pack(">I", bits))[0]


# =============================================================================
# Memory model (combinational response, same as minitpu test_mxu.py)
# =============================================================================
async def memory_driver(dut, mem):
    """
    Simple memory model:
      - On read_en: latch address, output mem[addr] (available next cycle)
      - On write_en: write mem[addr] = data
    """
    last_addr = 0
    while True:
        await RisingEdge(dut.clk)
        try:
            rd_en = int(dut.mem_read_en.value)
            wr_en = int(dut.mem_write_en.value)
            addr  = int(dut.mem_req_addr.value)
            wr_data = int(dut.mem_req_data.value)
        except ValueError:
            rd_en = 0
            wr_en = 0
            addr = 0
            wr_data = 0

        if rd_en:
            last_addr = addr
        if wr_en:
            mem[addr] = wr_data & 0xFFFFFFFF

        dut.mem_resp_data.value = mem.get(last_addr, 0)


# =============================================================================
# Test helpers
# =============================================================================
async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.base_addr_w.value = BASE_ADDR_W
    dut.base_addr_x.value = BASE_ADDR_X
    dut.base_addr_out.value = BASE_ADDR_OUT
    dut.mem_resp_data.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def load_matrices(mem, W, X):
    """Load W and X (NxN numpy float32) into the memory map."""
    for i in range(N):
        for j in range(N):
            mem[BASE_ADDR_W + i * N + j] = float_to_bits(W[i][j])
            mem[BASE_ADDR_X + i * N + j] = float_to_bits(X[i][j])


def read_output(mem):
    """Read NxN output matrix from memory."""
    out = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            bits = mem.get(BASE_ADDR_OUT + i * N + j, 0)
            out[i][j] = bits_to_float(bits)
    return out


async def run_matmul(dut, mem, W, X):
    """Load matrices, pulse start, wait for done, return output."""
    load_matrices(mem, W, X)

    dut.base_addr_w.value = BASE_ADDR_W
    dut.base_addr_x.value = BASE_ADDR_X
    dut.base_addr_out.value = BASE_ADDR_OUT

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for cycle in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk)
        try:
            if int(dut.done.value):
                break
        except ValueError:
            pass
    else:
        raise cocotb.result.TestFailure(f"Timeout after {TIMEOUT_CYCLES} cycles waiting for done")

    await RisingEdge(dut.clk)
    return read_output(mem)


def assert_matrix_close(actual, expected, rtol=1e-4, atol=1e-5, label=""):
    for i in range(N):
        for j in range(N):
            a = float(actual[i][j])
            e = float(expected[i][j])
            if abs(e) > 1e-10:
                if abs(a - e) / abs(e) > rtol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a}, expected {e} "
                        f"(rel err {abs(a-e)/abs(e):.2e})")
            else:
                if abs(a - e) > atol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a}, expected {e} "
                        f"(abs err {abs(a-e):.2e})")


# =============================================================================
# Tests
# =============================================================================

@cocotb.test()
async def test_identity(dut):
    """W = I → OUT = X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.eye(N, dtype=np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[identity] ")
    cocotb.log.info("PASS: identity")


@cocotb.test()
async def test_scalar_multiply(dut):
    """W = 3*I → OUT = 3*X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = 3.0 * np.eye(N, dtype=np.float32)
    X = np.ones((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i + 1)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[scalar] ")
    cocotb.log.info("PASS: scalar multiply")


@cocotb.test()
async def test_all_ones(dut):
    """W = all 1s → output elements are row sums of X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.ones((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i + 1)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[all_ones] ")
    cocotb.log.info("PASS: all ones")


@cocotb.test()
async def test_zero_weight(dut):
    """W = 0 → OUT = 0."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_matrix_close(result, expected, label="[zero_w] ")
    cocotb.log.info("PASS: zero weight")


@cocotb.test()
async def test_zero_input(dut):
    """X = 0 → OUT = 0."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.ones((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)

    result = await run_matmul(dut, mem, W, X)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_matrix_close(result, expected, label="[zero_x] ")
    cocotb.log.info("PASS: zero input")


@cocotb.test()
async def test_known_small_integers(dut):
    """Known small-integer matrices — exact in FP32."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = float((i + 1) % 4)
            X[i][j] = float((j + 1) % 4)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[small_int] ")
    cocotb.log.info("PASS: small integers")


@cocotb.test()
async def test_negative_values(dut):
    """Negative weights: W = -I → OUT = -X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = -1.0 * np.eye(N, dtype=np.float32)
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[neg] ")
    cocotb.log.info("PASS: negative values")


@cocotb.test()
async def test_random_matrices(dut):
    """Random integer matrices (range -3 to 3), 5 cases."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    num_cases = 5
    for case_idx in range(num_cases):
        await reset_dut(dut)
        mem = {}
        mem_task = cocotb.start_soon(memory_driver(dut, mem))

        W = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                      dtype=np.float32)
        X = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                      dtype=np.float32)

        result = await run_matmul(dut, mem, W, X)
        expected = (X @ W.T).astype(np.float32)
        assert_matrix_close(result, expected, rtol=1e-3,
                            label=f"[rand_{case_idx}] ")
        cocotb.log.info(f"PASS: random case {case_idx + 1}/{num_cases}")


@cocotb.test()
async def test_back_to_back(dut):
    """Two consecutive operations without reset."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    # First
    W1 = np.eye(N, dtype=np.float32)
    X1 = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)
    result1 = await run_matmul(dut, mem, W1, X1)
    expected1 = (X1 @ W1.T).astype(np.float32)
    assert_matrix_close(result1, expected1, label="[b2b_1] ")

    # Second — different matrices
    W2 = 2.0 * np.eye(N, dtype=np.float32)
    X2 = np.ones((N, N), dtype=np.float32) * 3.0
    result2 = await run_matmul(dut, mem, W2, X2)
    expected2 = (X2 @ W2.T).astype(np.float32)
    assert_matrix_close(result2, expected2, label="[b2b_2] ")

    cocotb.log.info("PASS: back-to-back")


@cocotb.test()
async def test_diagonal_weight(dut):
    """Diagonal weight with varying values: W = diag(1,2,...,N)."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.diag(np.arange(1, N + 1, dtype=np.float32))
    X = np.ones((N, N), dtype=np.float32)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[diag] ")
    cocotb.log.info("PASS: diagonal weight")


@cocotb.test()
async def test_single_element(dut):
    """Only W[0][0]=1, rest zero. Only OUT[r][0] = X[r][0] should be nonzero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    W[0][0] = 1.0
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[single_elem] ")
    cocotb.log.info("PASS: single element")


@cocotb.test()
async def test_permutation_matrix(dut):
    """W = reverse-permutation → output columns are reversed."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        W[i][N - 1 - i] = 1.0
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[perm] ")
    cocotb.log.info("PASS: permutation matrix")


@cocotb.test()
async def test_upper_triangular(dut):
    """Upper triangular W with 1s on and above diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.triu(np.ones((N, N), dtype=np.float32))
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[upper_tri] ")
    cocotb.log.info("PASS: upper triangular")


@cocotb.test()
async def test_lower_triangular(dut):
    """Lower triangular W with 1s on and below diagonal."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.tril(np.ones((N, N), dtype=np.float32))
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[lower_tri] ")
    cocotb.log.info("PASS: lower triangular")


@cocotb.test()
async def test_sparse_corners(dut):
    """Sparse W with only corner elements nonzero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    W[0][0] = 2.0
    W[0][N-1] = -1.0
    W[N-1][0] = 3.0
    W[N-1][N-1] = -2.0
    X = np.arange(1, N * N + 1, dtype=np.float32).reshape(N, N)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[sparse] ")
    cocotb.log.info("PASS: sparse corners")


@cocotb.test()
async def test_alternating_signs(dut):
    """Checkerboard +1/-1 in both W and X."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = 1.0 if (i + j) % 2 == 0 else -1.0
            X[i][j] = 1.0 if (i + j) % 2 == 0 else -1.0

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[alt_sign] ")
    cocotb.log.info("PASS: alternating signs")


@cocotb.test()
async def test_large_values(dut):
    """Larger FP32 values (powers of 2, exact in IEEE-754)."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.eye(N, dtype=np.float32) * 256.0
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(2 ** (i % 8))

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[large_val] ")
    cocotb.log.info("PASS: large values")


@cocotb.test()
async def test_single_row_input(dut):
    """Only row 0 of X is nonzero → only row 0 of output should be nonzero."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.ones((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    X[0, :] = np.arange(1, N + 1, dtype=np.float32)

    result = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[single_row] ")
    cocotb.log.info("PASS: single row input")


@cocotb.test()
async def test_triple_back_to_back(dut):
    """Three consecutive operations without reset."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    configs = [
        (np.eye(N, dtype=np.float32), np.arange(1, N*N+1, dtype=np.float32).reshape(N, N)),
        (2.0 * np.eye(N, dtype=np.float32), np.ones((N, N), dtype=np.float32) * 3.0),
        (-1.0 * np.eye(N, dtype=np.float32), np.arange(1, N*N+1, dtype=np.float32).reshape(N, N)),
    ]

    for idx, (W, X) in enumerate(configs):
        result = await run_matmul(dut, mem, W, X)
        expected = (X @ W.T).astype(np.float32)
        assert_matrix_close(result, expected, label=f"[triple_b2b_{idx}] ")

    cocotb.log.info("PASS: triple back-to-back")
