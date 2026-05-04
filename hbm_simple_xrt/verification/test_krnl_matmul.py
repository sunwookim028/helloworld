"""
Cocotb test suite for krnl_matmul — burst AXI4 kernel.

Tests the complete RTL path:
  AXI4-Lite control → kernel trigger
  AXI4 gmem0 burst slave → W matrix reads  (one 64-beat burst)
  AXI4 gmem1 burst slave → X matrix reads  (one 64-beat burst)
  AXI4 gmem2 burst slave → OUT matrix writes (one 64-beat burst)
  Output verification against numpy reference

Memory layout (word-addressed, 512-bit words = 64 bytes each):
  W   matrix: byte addr 0x0000  (word addr 0)
  X   matrix: byte addr 0x1000  (word addr 64 = WORDS_PER_MATRIX)
  OUT matrix: byte addr 0x2000  (word addr 128)
"""

import os
import struct
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

random.seed(0xABCD_1234)

N              = 32
DW             = 32
HBM_DW         = 512
ELEMS_PER_WORD = HBM_DW // DW      # 16
TOTAL_ELEMS    = N * N              # 1024
WORDS_PER_MAT  = TOTAL_ELEMS // ELEMS_PER_WORD  # 64

# Byte addresses of each matrix (page-aligned, non-overlapping)
BYTE_ADDR_W   = 0x0000
BYTE_ADDR_X   = 0x1000   # 4096 bytes = 64 words × 64 bytes
BYTE_ADDR_OUT = 0x2000

WORD_ADDR_W   = BYTE_ADDR_W   >> 6
WORD_ADDR_X   = BYTE_ADDR_X   >> 6
WORD_ADDR_OUT = BYTE_ADDR_OUT >> 6

TIMEOUT_CYCLES = 500000

# AXI4-Lite register offsets (krnl_vadd_ctrl map)
REG_CTRL     = 0x00
REG_IN1_LO   = 0x10
REG_IN1_HI   = 0x14
REG_IN2_LO   = 0x18
REG_IN2_HI   = 0x1C
REG_OUT_LO   = 0x20
REG_OUT_HI   = 0x24


# =============================================================================
# FP32 helpers
# =============================================================================
def f2b(v: float) -> int:
    return struct.unpack(">I", struct.pack(">f", float(v)))[0]


def b2f(b: int) -> float:
    return struct.unpack(">f", struct.pack(">I", int(b) & 0xFFFFFFFF))[0]


# =============================================================================
# Matrix helpers
# =============================================================================
def pack_matrix_into_mem(mat: np.ndarray, word_base: int, mem: dict):
    flat = mat.flatten().tolist()
    for w in range(WORDS_PER_MAT):
        word_val = 0
        for i in range(ELEMS_PER_WORD):
            idx = w * ELEMS_PER_WORD + i
            v   = flat[idx] if idx < len(flat) else 0.0
            word_val |= (f2b(v) & 0xFFFFFFFF) << (i * DW)
        mem[word_base + w] = word_val


def unpack_matrix_from_mem(word_base: int, mem: dict) -> np.ndarray:
    flat = []
    for w in range(WORDS_PER_MAT):
        word_val = mem.get(word_base + w, 0)
        for i in range(ELEMS_PER_WORD):
            flat.append(b2f((word_val >> (i * DW)) & 0xFFFFFFFF))
    return np.array(flat[:TOTAL_ELEMS], dtype=np.float32).reshape(N, N)


# =============================================================================
# AXI4-Lite helpers
# =============================================================================
async def axilite_write(dut, addr: int, data: int):
    dut.s_axi_control_awaddr.value  = addr
    dut.s_axi_control_awvalid.value = 1
    dut.s_axi_control_wdata.value   = data & 0xFFFFFFFF
    dut.s_axi_control_wvalid.value  = 1
    dut.s_axi_control_wstrb.value   = 0xF
    await RisingEdge(dut.ap_clk)
    while not (int(dut.s_axi_control_awready.value) and
               int(dut.s_axi_control_wready.value)):
        await RisingEdge(dut.ap_clk)
    dut.s_axi_control_awvalid.value = 0
    dut.s_axi_control_wvalid.value  = 0
    dut.s_axi_control_bready.value  = 1
    await RisingEdge(dut.ap_clk)
    while not int(dut.s_axi_control_bvalid.value):
        await RisingEdge(dut.ap_clk)
    dut.s_axi_control_bready.value = 0
    await RisingEdge(dut.ap_clk)


async def axilite_read(dut, addr: int) -> int:
    dut.s_axi_control_araddr.value  = addr
    dut.s_axi_control_arvalid.value = 1
    await RisingEdge(dut.ap_clk)
    while not int(dut.s_axi_control_arready.value):
        await RisingEdge(dut.ap_clk)
    dut.s_axi_control_arvalid.value = 0
    dut.s_axi_control_rready.value  = 1
    await RisingEdge(dut.ap_clk)
    while not int(dut.s_axi_control_rvalid.value):
        await RisingEdge(dut.ap_clk)
    val = int(dut.s_axi_control_rdata.value)
    dut.s_axi_control_rready.value = 0
    await RisingEdge(dut.ap_clk)
    return val


# =============================================================================
# AXI4 burst read slave (for gmem0 and gmem1)
#
# Handles ARLEN+1 R beats per transaction.  For our 64-word matrices with
# page-aligned addresses the rd_mst issues exactly one 64-beat burst per
# matrix, so this slave handles one AR transaction → 64 R beats → next AR.
# =============================================================================
async def axi_rd_slave(dut, arvalid, arready, araddr, arlen,
                       rvalid, rready, rdata, rlast, rresp, mem: dict):
    arready.value = 0
    rvalid.value  = 0
    rlast.value   = 0
    rresp.value   = 0
    while True:
        # AR channel: wait for ARVALID, accept, latch burst parameters
        arready.value = 1
        await RisingEdge(dut.ap_clk)
        while not int(arvalid.value):
            await RisingEdge(dut.ap_clk)
        byte_addr   = int(araddr.value)
        burst_beats = int(arlen.value) + 1   # ARLEN+1 beats
        word_base   = byte_addr >> 6
        arready.value = 0

        # R channel: send burst_beats beats, RLAST on final beat
        for beat in range(burst_beats):
            rdata.value  = mem.get(word_base + beat, 0)
            rlast.value  = 1 if beat == burst_beats - 1 else 0
            rvalid.value = 1
            await RisingEdge(dut.ap_clk)
            while not int(rready.value):
                await RisingEdge(dut.ap_clk)
        rvalid.value = 0
        rlast.value  = 0


# =============================================================================
# AXI4 burst write slave (for gmem2)
#
# Handles AWLEN+1 W beats per transaction.  The wr_mst issues one 64-beat
# burst for the output matrix.
# =============================================================================
async def axi_wr_slave(dut, awvalid, awready, awaddr, awlen,
                       wvalid, wready, wdata,
                       bvalid, bready, mem: dict):
    awready.value = 0
    wready.value  = 0
    bvalid.value  = 0
    while True:
        # AW channel
        awready.value = 1
        await RisingEdge(dut.ap_clk)
        while not int(awvalid.value):
            await RisingEdge(dut.ap_clk)
        byte_addr   = int(awaddr.value)
        burst_beats = int(awlen.value) + 1
        word_base   = byte_addr >> 6
        awready.value = 0

        # W channel: accept burst_beats beats
        wready.value = 1
        for beat in range(burst_beats):
            await RisingEdge(dut.ap_clk)
            while not int(wvalid.value):
                await RisingEdge(dut.ap_clk)
            mem[word_base + beat] = int(wdata.value)
        wready.value = 0

        # B channel
        bvalid.value = 1
        await RisingEdge(dut.ap_clk)
        while not int(bready.value):
            await RisingEdge(dut.ap_clk)
        bvalid.value = 0


# =============================================================================
# DUT reset
# =============================================================================
async def reset_dut(dut):
    dut.ap_rst_n.value = 0
    # AXI-Lite defaults
    dut.s_axi_control_awvalid.value = 0
    dut.s_axi_control_wvalid.value  = 0
    dut.s_axi_control_bready.value  = 0
    dut.s_axi_control_arvalid.value = 0
    dut.s_axi_control_rready.value  = 0
    dut.s_axi_control_awaddr.value  = 0
    dut.s_axi_control_wdata.value   = 0
    dut.s_axi_control_wstrb.value   = 0
    dut.s_axi_control_araddr.value  = 0
    # AXI4 slave inputs (gmem0 — rd slave)
    dut.m_axi_gmem0_arready.value = 0
    dut.m_axi_gmem0_rvalid.value  = 0
    dut.m_axi_gmem0_rdata.value   = 0
    dut.m_axi_gmem0_rresp.value   = 0
    dut.m_axi_gmem0_rlast.value   = 0
    # AXI4 slave inputs (gmem1 — rd slave)
    dut.m_axi_gmem1_arready.value = 0
    dut.m_axi_gmem1_rvalid.value  = 0
    dut.m_axi_gmem1_rdata.value   = 0
    dut.m_axi_gmem1_rresp.value   = 0
    dut.m_axi_gmem1_rlast.value   = 0
    # AXI4 slave inputs (gmem2 — wr slave)
    dut.m_axi_gmem2_awready.value = 0
    dut.m_axi_gmem2_wready.value  = 0
    dut.m_axi_gmem2_bresp.value   = 0
    dut.m_axi_gmem2_bvalid.value  = 0
    # Tie off unused gmem0/gmem1 write-channel inputs
    dut.m_axi_gmem0_awready.value = 0
    dut.m_axi_gmem0_wready.value  = 0
    dut.m_axi_gmem0_bresp.value   = 0
    dut.m_axi_gmem0_bvalid.value  = 0
    dut.m_axi_gmem1_awready.value = 0
    dut.m_axi_gmem1_wready.value  = 0
    dut.m_axi_gmem1_bresp.value   = 0
    dut.m_axi_gmem1_bvalid.value  = 0
    # Tie off unused gmem2 read-channel inputs
    dut.m_axi_gmem2_arready.value = 0
    dut.m_axi_gmem2_rvalid.value  = 0
    dut.m_axi_gmem2_rdata.value   = 0
    dut.m_axi_gmem2_rresp.value   = 0
    dut.m_axi_gmem2_rlast.value   = 0
    await RisingEdge(dut.ap_clk)
    await RisingEdge(dut.ap_clk)
    dut.ap_rst_n.value = 1
    await RisingEdge(dut.ap_clk)


def start_slaves(dut, mem):
    cocotb.start_soon(axi_rd_slave(
        dut,
        dut.m_axi_gmem0_arvalid, dut.m_axi_gmem0_arready,
        dut.m_axi_gmem0_araddr,  dut.m_axi_gmem0_arlen,
        dut.m_axi_gmem0_rvalid,  dut.m_axi_gmem0_rready,
        dut.m_axi_gmem0_rdata,   dut.m_axi_gmem0_rlast,
        dut.m_axi_gmem0_rresp,   mem))
    cocotb.start_soon(axi_rd_slave(
        dut,
        dut.m_axi_gmem1_arvalid, dut.m_axi_gmem1_arready,
        dut.m_axi_gmem1_araddr,  dut.m_axi_gmem1_arlen,
        dut.m_axi_gmem1_rvalid,  dut.m_axi_gmem1_rready,
        dut.m_axi_gmem1_rdata,   dut.m_axi_gmem1_rlast,
        dut.m_axi_gmem1_rresp,   mem))
    cocotb.start_soon(axi_wr_slave(
        dut,
        dut.m_axi_gmem2_awvalid, dut.m_axi_gmem2_awready,
        dut.m_axi_gmem2_awaddr,  dut.m_axi_gmem2_awlen,
        dut.m_axi_gmem2_wvalid,  dut.m_axi_gmem2_wready,
        dut.m_axi_gmem2_wdata,
        dut.m_axi_gmem2_bvalid,  dut.m_axi_gmem2_bready,
        mem))


# =============================================================================
# Run a single matmul via the kernel
# =============================================================================
async def run_kernel_matmul(dut, W: np.ndarray, X: np.ndarray, mem: dict) -> np.ndarray:
    pack_matrix_into_mem(W, WORD_ADDR_W,   mem)
    pack_matrix_into_mem(X, WORD_ADDR_X,   mem)
    for i in range(WORDS_PER_MAT):
        mem[WORD_ADDR_OUT + i] = 0

    await axilite_write(dut, REG_IN1_LO, BYTE_ADDR_W   & 0xFFFFFFFF)
    await axilite_write(dut, REG_IN1_HI, BYTE_ADDR_W   >> 32)
    await axilite_write(dut, REG_IN2_LO, BYTE_ADDR_X   & 0xFFFFFFFF)
    await axilite_write(dut, REG_IN2_HI, BYTE_ADDR_X   >> 32)
    await axilite_write(dut, REG_OUT_LO, BYTE_ADDR_OUT & 0xFFFFFFFF)
    await axilite_write(dut, REG_OUT_HI, BYTE_ADDR_OUT >> 32)
    await axilite_write(dut, REG_CTRL, 0x1)

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.ap_clk)
        ctrl = await axilite_read(dut, REG_CTRL)
        if ctrl & 0x2:
            break
    else:
        raise cocotb.result.TestFailure(
            f"Timeout after {TIMEOUT_CYCLES} cycles waiting for ap_done")

    await RisingEdge(dut.ap_clk)
    return unpack_matrix_from_mem(WORD_ADDR_OUT, mem)


def assert_close(actual, expected, rtol=1e-4, atol=1e-5, label=""):
    for i in range(N):
        for j in range(N):
            a, e = float(actual[i][j]), float(expected[i][j])
            rel  = abs(a - e) / abs(e) if abs(e) > 1e-10 else abs(a - e)
            if rel > rtol and abs(a - e) > atol:
                raise AssertionError(
                    f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                    f"(rel {rel:.2e})")


# =============================================================================
# Tests
# =============================================================================

@cocotb.test()
async def test_identity(dut):
    """W = I → OUT = X through the full burst AXI kernel path."""
    clock = Clock(dut.ap_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    start_slaves(dut, mem)

    W = np.eye(N, dtype=np.float32)
    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_kernel_matmul(dut, W, X, mem)
    expected = (X @ W.T).astype(np.float32)
    assert_close(result, expected, label="[identity] ")
    cocotb.log.info("PASS: identity")


@cocotb.test()
async def test_zero_weight(dut):
    """W = 0 → OUT = 0."""
    clock = Clock(dut.ap_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    start_slaves(dut, mem)

    W = np.zeros((N, N), dtype=np.float32)
    X = np.arange(1, TOTAL_ELEMS + 1, dtype=np.float32).reshape(N, N)

    result   = await run_kernel_matmul(dut, W, X, mem)
    expected = np.zeros((N, N), dtype=np.float32)
    assert_close(result, expected, label="[zero_w] ")
    cocotb.log.info("PASS: zero weight")


@cocotb.test()
async def test_small_integers(dut):
    """Small-integer W and X — exact in FP32."""
    clock = Clock(dut.ap_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    start_slaves(dut, mem)

    W = np.zeros((N, N), dtype=np.float32)
    X = np.zeros((N, N), dtype=np.float32)
    for i in range(N):
        for j in range(N):
            W[i][j] = float((i + 1) % 4)
            X[i][j] = float((j + 1) % 4)

    result   = await run_kernel_matmul(dut, W, X, mem)
    expected = (X @ W.T).astype(np.float32)
    assert_close(result, expected, label="[small_int] ")
    cocotb.log.info("PASS: small integers")


@cocotb.test()
async def test_random(dut):
    """Random small-integer matrices, 2 back-to-back runs."""
    clock = Clock(dut.ap_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    start_slaves(dut, mem)

    for case in range(2):
        W = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                     dtype=np.float32)
        X = np.array([[random.randint(-3, 3) for _ in range(N)] for _ in range(N)],
                     dtype=np.float32)
        result   = await run_kernel_matmul(dut, W, X, mem)
        expected = (X @ W.T).astype(np.float32)
        assert_close(result, expected, rtol=1e-3, label=f"[rand_{case}] ")
        cocotb.log.info(f"PASS: random case {case + 1}/2")
