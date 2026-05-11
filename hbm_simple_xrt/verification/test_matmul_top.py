"""
Cocotb test suite for matmul_top — HBM-width integration wrapper (32×32 BF16).

Tests the full pipeline:
  1. Load W from 512-bit "HBM" memory into internal w_bram  (LOAD_W)
  2. Load X into x_bram                                      (LOAD_X)
  3. Run MXU: OUT = X × W^T                                  (COMPUTE)
  4. Pack out_bram → 512-bit words → write back to "HBM"     (STORE)

HBM memory model: dict of {word_addr: 512-bit Python int}
Each 512-bit word holds ELEMS_PER_WORD = HBM_DATA_WIDTH / DATA_WIDTH elements.
  N=32, DW=16 → ELEMS_PER_WORD=32, WORDS_PER_MATRIX=32
"""

import os
import struct
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

random.seed(0xCAFE_F00D)

N              = int(os.environ.get("MATMUL_N", 32))
DW             = 16   # DATA_WIDTH (BF16)
HBM_DW         = 512
ELEMS_PER_WORD = HBM_DW // DW          # 32 BF16 elements per 512-bit word
TOTAL_ELEMS    = N * N
WORDS_PER_MAT  = (TOTAL_ELEMS + ELEMS_PER_WORD - 1) // ELEMS_PER_WORD

# Word-addressed HBM layout: each address = one 512-bit word
HBM_ADDR_W   = 0
HBM_ADDR_X   = WORDS_PER_MAT
HBM_ADDR_OUT = 2 * WORDS_PER_MAT

TIMEOUT_CYCLES = 500000


# =============================================================================
# BF16 helpers
# =============================================================================
def float_to_bits(val: float) -> int:
    """Float32 → BF16 bit pattern."""
    bits32 = struct.unpack(">I", struct.pack(">f", float(val)))[0]
    return (bits32 >> 16) & 0xFFFF


def bits_to_float(bits: int) -> float:
    """BF16 bit pattern → float32."""
    bits32 = (int(bits) & 0xFFFF) << 16
    return struct.unpack(">f", struct.pack(">I", bits32))[0]


def bf16_ref(W: np.ndarray, X: np.ndarray) -> np.ndarray:
    """Reference matmul using BF16-truncated inputs computed in float32."""
    W_q = np.array([[bits_to_float(float_to_bits(W[i][j])) for j in range(N)]
                     for i in range(N)], dtype=np.float32)
    X_q = np.array([[bits_to_float(float_to_bits(X[i][j])) for j in range(N)]
                     for i in range(N)], dtype=np.float32)
    return (X_q @ W_q.T).astype(np.float32)


# =============================================================================
# Matrix packing / unpacking for 512-bit HBM words (BF16 elements)
# =============================================================================
def pack_matrix(mat: np.ndarray, base_word_addr: int, mem: dict):
    """Flatten NxN matrix row-major, pack ELEMS_PER_WORD BF16 elements per word."""
    flat = mat.flatten().tolist()
    for w in range(WORDS_PER_MAT):
        word_val = 0
        for i in range(ELEMS_PER_WORD):
            elem_idx = w * ELEMS_PER_WORD + i
            elem_f   = flat[elem_idx] if elem_idx < len(flat) else 0.0
            word_val |= (float_to_bits(elem_f) & 0xFFFF) << (i * DW)
        mem[base_word_addr + w] = word_val


def unpack_matrix(base_word_addr: int, mem: dict) -> np.ndarray:
    """Read WORDS_PER_MAT 512-bit words from mem, unpack to NxN float32 array."""
    flat = []
    for w in range(WORDS_PER_MAT):
        word_val = mem.get(base_word_addr + w, 0)
        for i in range(ELEMS_PER_WORD):
            bits = (word_val >> (i * DW)) & 0xFFFF
            flat.append(bits_to_float(bits))
    return np.array(flat[:TOTAL_ELEMS], dtype=np.float32).reshape(N, N)


# =============================================================================
# HBM memory driver (handshake-based)
# =============================================================================
async def memory_driver(dut, mem: dict):
    """
    Memory driver for the handshake-based matmul_top interface.
    1-cycle read latency: mem_rsp_valid / mem_wr_done asserted the cycle after
    mem_rd_en / mem_wr_en are seen.
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

        dut.mem_rd_data.value   = mem.get(last_addr, 0)
        dut.mem_rsp_valid.value = last_rd_en
        dut.mem_wr_done.value   = last_wr_en

        last_rd_en = rd_en
        last_wr_en = wr_en


# =============================================================================
# Test helpers
# =============================================================================
async def reset_dut(dut):
    dut.rst_n.value         = 0
    dut.start.value         = 0
    dut.addr_w.value        = HBM_ADDR_W
    dut.addr_x.value        = HBM_ADDR_X
    dut.addr_out.value      = HBM_ADDR_OUT
    dut.mem_rd_data.value   = 0
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

    await RisingEdge(dut.clk)
    return unpack_matrix(HBM_ADDR_OUT, mem)


def assert_matrix_close(actual, expected, rtol=0.02, atol=1e-3, label=""):
    for i in range(N):
        for j in range(N):
            a = float(actual[i][j])
            e = float(expected[i][j])
            if abs(e) > 1e-6:
                if abs(a - e) / abs(e) > rtol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                        f"(rel err {abs(a-e)/abs(e):.2e})")
            else:
                if abs(a - e) > atol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                        f"(abs err {abs(a-e):.2e})")


def small_x():
    return (np.arange(TOTAL_ELEMS, dtype=np.float32) % 4 + 1).reshape(N, N)


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
    X = small_x()

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, bf16_ref(W, X), label="[identity] ")
    cocotb.log.info("PASS: identity")


@cocotb.test()
async def test_zero_weight(dut):
    """W = 0 → OUT = 0."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    X = small_x()

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, np.zeros((N, N), dtype=np.float32), label="[zero_w] ")
    cocotb.log.info("PASS: zero weight")


@cocotb.test()
async def test_small_integers(dut):
    """Known small-integer matrices — exact in BF16."""
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
    assert_matrix_close(result, bf16_ref(W, X), label="[small_int] ")
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
    X = small_x()

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, bf16_ref(W, X), label="[neg] ")
    cocotb.log.info("PASS: negative values")


@cocotb.test()
async def test_scalar_multiply(dut):
    """W = 4*I → OUT = 4*X. Exercises word-boundary alignment in HBM packing."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = 4.0 * np.eye(N, dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        X[i, :] = float(i % 4 + 1)

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, bf16_ref(W, X), label="[scalar] ")
    cocotb.log.info("PASS: scalar multiply")


@cocotb.test()
async def test_diagonal_weight(dut):
    """Diagonal weight with small exact values."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.diag(np.array([float(i % 4 + 1) for i in range(N)], dtype=np.float32))
    X = np.ones((N, N), dtype=np.float32)

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, bf16_ref(W, X), label="[diag] ")
    cocotb.log.info("PASS: diagonal weight")


@cocotb.test()
async def test_random_matrices(dut):
    """Random small-integer matrices (range -3..3), 3 cases."""
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

        result = await run_matmul(dut, mem, W, X)
        assert_matrix_close(result, bf16_ref(W, X), label=f"[rand_{case_idx}] ")
        cocotb.log.info(f"PASS: random case {case_idx + 1}/3")


@cocotb.test()
async def test_back_to_back(dut):
    """Two consecutive operations without reset — verifies BRAM cleared between runs."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W1 = np.eye(N, dtype=np.float32)
    X1 = small_x()
    result1 = await run_matmul(dut, mem, W1, X1)
    assert_matrix_close(result1, bf16_ref(W1, X1), label="[b2b_1] ")

    W2 = 2.0 * np.eye(N, dtype=np.float32)
    X2 = np.ones((N, N), dtype=np.float32) * 3.0
    result2 = await run_matmul(dut, mem, W2, X2)
    assert_matrix_close(result2, bf16_ref(W2, X2), label="[b2b_2] ")

    cocotb.log.info("PASS: back-to-back")


@cocotb.test()
async def test_hbm_word_boundary(dut):
    """
    Only the last BF16 slot of each 512-bit HBM word is nonzero.
    Targets the MSB extraction path: bits[(ELEMS_PER_WORD-1)*DW +: DW].
    """
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    mem = {}
    cocotb.start_soon(memory_driver(dut, mem))

    W = np.zeros((N, N), dtype=np.float32)
    for k in range(ELEMS_PER_WORD - 1, TOTAL_ELEMS, ELEMS_PER_WORD):
        row = k // N
        col = k % N
        if row < N and col < N:
            W[row][col] = 1.0

    X = small_x()

    result = await run_matmul(dut, mem, W, X)
    assert_matrix_close(result, bf16_ref(W, X), label="[hbm_boundary] ")
    cocotb.log.info("PASS: HBM word boundary")
