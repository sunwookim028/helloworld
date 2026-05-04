"""
Cocotb test suite for matmul_top — HBM-width integration wrapper.

Tests the full pipeline:
  1. Load W from 512-bit "HBM" memory into internal w_bram  (LOAD_W)
  2. Load X into x_bram                                      (LOAD_X)
  3. Run MXU: OUT = X × W^T                                  (COMPUTE)
  4. Pack out_bram → 512-bit words → write back to "HBM"     (STORE)

HBM memory model: dict of {word_addr: 512-bit Python int}
Each 512-bit word holds ELEMS_PER_WORD = HBM_DATA_WIDTH / DATA_WIDTH elements.
  N=32 → ELEMS_PER_WORD=16, WORDS_PER_MATRIX=64
"""

import os
import struct
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

random.seed(0xCAFE_F00D)

N             = int(os.environ.get("MATMUL_N", 32))
DW            = 32
HBM_DW        = 512
ELEMS_PER_WORD = HBM_DW // DW          # 16 elements per 512-bit word
TOTAL_ELEMS   = N * N
WORDS_PER_MAT = (TOTAL_ELEMS + ELEMS_PER_WORD - 1) // ELEMS_PER_WORD

# Word-addressed HBM layout: each address = one 512-bit word
HBM_ADDR_W   = 0
HBM_ADDR_X   = WORDS_PER_MAT
HBM_ADDR_OUT = 2 * WORDS_PER_MAT

TIMEOUT_CYCLES = 200000


# =============================================================================
# FP32 helpers
# =============================================================================
def float_to_bits(val: float) -> int:
    return struct.unpack(">I", struct.pack(">f", float(val)))[0]


def bits_to_float(bits: int) -> float:
    bits = int(bits) & 0xFFFFFFFF
    return struct.unpack(">f", struct.pack(">I", bits))[0]


# =============================================================================
# Matrix packing / unpacking for 512-bit HBM words
# =============================================================================
def pack_matrix(mat: np.ndarray, base_word_addr: int, mem: dict):
    """
    Flatten NxN float32 matrix row-major, pack ELEMS_PER_WORD elements into
    each 512-bit word, write into mem at [base_word_addr .. base_word_addr+WORDS_PER_MAT-1].
    Element layout: bits[(i*DW)+:DW] holds element i within the word.
    """
    flat = mat.flatten().tolist()           # N*N floats, row-major
    for w in range(WORDS_PER_MAT):
        word_val = 0
        for i in range(ELEMS_PER_WORD):
            elem_idx = w * ELEMS_PER_WORD + i
            elem_f   = flat[elem_idx] if elem_idx < len(flat) else 0.0
            word_val |= (float_to_bits(elem_f) & 0xFFFFFFFF) << (i * DW)
        mem[base_word_addr + w] = word_val


def unpack_matrix(base_word_addr: int, mem: dict) -> np.ndarray:
    """
    Read WORDS_PER_MAT 512-bit words from mem, unpack to NxN float32 array.
    """
    flat = []
    for w in range(WORDS_PER_MAT):
        word_val = mem.get(base_word_addr + w, 0)
        for i in range(ELEMS_PER_WORD):
            bits = (word_val >> (i * DW)) & 0xFFFFFFFF
            flat.append(bits_to_float(bits))
    # slice to TOTAL_ELEMS (last word may have padding)
    flat = flat[:TOTAL_ELEMS]
    return np.array(flat, dtype=np.float32).reshape(N, N)


# =============================================================================
# HBM memory driver (handshake-based)
# =============================================================================
async def memory_driver(dut, mem: dict):
    """
    Memory driver for the handshake-based matmul_top interface.

    Timing:
      Cycle N  : DUT asserts mem_rd_en / mem_wr_en (registered output → visible)
      Cycle N+1: driver sees rd_en/wr_en, performs operation, drives responses
      Cycle N+2: DUT (in WAIT state) sees mem_rsp_valid / mem_wr_done → advances

    This matches matmul_top's wait-for-valid protocol.
    """
    last_rd_en = 0
    last_wr_en = 0
    last_addr  = 0
    while True:
        await RisingEdge(dut.clk)
        try:
            rd_en   = int(dut.mem_rd_en.value)
            wr_en   = int(dut.mem_wr_en.value)
            addr    = int(dut.mem_addr.value)
            wr_data = int(dut.mem_wr_data.value)
        except ValueError:
            rd_en = wr_en = addr = wr_data = 0

        if wr_en:
            mem[addr] = wr_data
        if rd_en:
            last_addr = addr

        # Responses based on PREVIOUS cycle's enables (1-cycle delay)
        dut.mem_rd_data.value    = mem.get(last_addr, 0)
        dut.mem_rsp_valid.value  = last_rd_en
        dut.mem_wr_done.value    = last_wr_en

        last_rd_en = rd_en
        last_wr_en = wr_en


# =============================================================================
# Test helpers
# =============================================================================
async def reset_dut(dut):
    dut.rst_n.value       = 0
    dut.start.value       = 0
    dut.addr_w.value      = HBM_ADDR_W
    dut.addr_x.value      = HBM_ADDR_X
    dut.addr_out.value    = HBM_ADDR_OUT
    dut.mem_rd_data.value = 0
    dut.mem_rsp_valid.value = 0
    dut.mem_wr_done.value   = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_matmul(dut, mem: dict, W: np.ndarray, X: np.ndarray) -> np.ndarray:
    """Pack W/X into HBM mem, pulse start, wait for done, unpack and return output."""
    pack_matrix(W, HBM_ADDR_W, mem)
    pack_matrix(X, HBM_ADDR_X, mem)

    dut.addr_w.value   = HBM_ADDR_W
    dut.addr_x.value   = HBM_ADDR_X
    dut.addr_out.value = HBM_ADDR_OUT

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk)
        try:
            if int(dut.done.value):
                break
        except ValueError:
            pass
    else:
        raise cocotb.result.TestFailure(
            f"Timeout after {TIMEOUT_CYCLES} cycles waiting for done")

    # Give one extra cycle for output to settle
    await RisingEdge(dut.clk)
    return unpack_matrix(HBM_ADDR_OUT, mem)


def assert_matrix_close(actual, expected, rtol=1e-4, atol=1e-5, label=""):
    for i in range(N):
        for j in range(N):
            a = float(actual[i][j])
            e = float(expected[i][j])
            if abs(e) > 1e-10:
                if abs(a - e) / abs(e) > rtol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                        f"(rel err {abs(a-e)/abs(e):.2e})")
            else:
                if abs(a - e) > atol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                        f"(abs err {abs(a-e):.2e})")


# =============================================================================
# Tests
# =============================================================================

@cocotb.test()
async def test_identity(dut):
    """W = I → OUT = X. Validates end-to-end HBM load/store + compute."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.eye(N, dtype=np.float32)
    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[identity] ")
    cocotb.log.info("PASS: identity")


@cocotb.test()
async def test_zero_weight(dut):
    """W = 0 → OUT = 0. Verifies BRAM clear on start and zero output store."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_matmul(dut, mem, W, X)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_matrix_close(result, expected, label="[zero_w] ")
    cocotb.log.info("PASS: zero weight")


@cocotb.test()
async def test_small_integers(dut):
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

    result   = await run_matmul(dut, mem, W, X)
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
    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[neg] ")
    cocotb.log.info("PASS: negative values")


@cocotb.test()
async def test_scalar_multiply(dut):
    """W = k*I → OUT = k*X. Exercises word-boundary alignment in HBM packing."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = 5.0 * np.eye(N, dtype=np.float32)
    X = np.ones((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i + 1)

    result   = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[scalar] ")
    cocotb.log.info("PASS: scalar multiply")


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

    result   = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[diag] ")
    cocotb.log.info("PASS: diagonal weight")


@cocotb.test()
async def test_random_matrices(dut):
    """Random integer matrices (range -3..3), 3 consecutive cases."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    for case_idx in range(3):
        await reset_dut(dut)
        mem = {}
        cocotb.start_soon(memory_driver(dut, mem))

        W = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                     dtype=np.float32)
        X = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                     dtype=np.float32)

        result   = await run_matmul(dut, mem, W, X)
        expected = (X @ W.T).astype(np.float32)
        assert_matrix_close(result, expected, rtol=1e-3,
                            label=f"[rand_{case_idx}] ")
        cocotb.log.info(f"PASS: random case {case_idx + 1}/3")


@cocotb.test()
async def test_back_to_back(dut):
    """Two consecutive operations without reset — verifies BRAM cleared between runs."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    # First: identity
    W1 = np.eye(N, dtype=np.float32)
    X1 = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)
    result1   = await run_matmul(dut, mem, W1, X1)
    expected1 = (X1 @ W1.T).astype(np.float32)
    assert_matrix_close(result1, expected1, label="[b2b_1] ")

    # Second: scaled identity with different X
    W2 = 2.0 * np.eye(N, dtype=np.float32)
    X2 = np.ones((N, N), dtype=np.float32) * 7.0
    result2   = await run_matmul(dut, mem, W2, X2)
    expected2 = (X2 @ W2.T).astype(np.float32)
    assert_matrix_close(result2, expected2, label="[b2b_2] ")

    cocotb.log.info("PASS: back-to-back")


@cocotb.test()
async def test_hbm_word_boundary(dut):
    """
    Only element ELEMS_PER_WORD-1 (the last, highest-bit field) of each 512-bit
    HBM word is nonzero. Targets the MSB extraction path in the unpack logic:
    mem_rd_data[(ELEMS_PER_WORD-1)*DATA_WIDTH +: DATA_WIDTH] = bits [480:511].
    """
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    # Set element ELEMS_PER_WORD-1 (last slot, bits [480:511]) of each HBM word to 1.
    # This specifically tests that the high-bit field of each 512-bit word is correctly
    # extracted during unpack (i*DATA_WIDTH +: DATA_WIDTH for i=ELEMS_PER_WORD-1).
    for k in range(ELEMS_PER_WORD - 1, TOTAL_ELEMS, ELEMS_PER_WORD):
        row = k // N
        col = k % N
        if row < N and col < N:
            W[row][col] = 1.0

    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_matmul(dut, mem, W, X)
    expected = (X @ W.T).astype(np.float32)
    assert_matrix_close(result, expected, label="[hbm_boundary] ")
    cocotb.log.info("PASS: HBM word boundary")
