"""
Cocotb test suite for krnl_matmul — burst AXI4 kernel (16×16 BF16).

Tests the complete RTL path:
  AXI4-Lite control → kernel trigger
  AXI4 gmem0 burst slave → W matrix reads  (one 8-beat burst)
  AXI4 gmem1 burst slave → X matrix reads  (one 8-beat burst)
  AXI4 gmem2 burst slave → OUT matrix writes (one 8-beat burst)
  Output verification against numpy BF16 reference

Memory layout (word-addressed, 512-bit words = 64 bytes each):
  W   matrix: byte addr 0x0000  (word addr 0,  8 words = 512 bytes)
  X   matrix: byte addr 0x1000  (word addr 64, 8 words — page-aligned)
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

N              = int(os.environ.get("KRNL_N", 16))
DW             = 16   # BF16
HBM_DW         = 512
ELEMS_PER_WORD = HBM_DW // DW      # 32 BF16 elements per 512-bit word
TOTAL_ELEMS    = N * N              # 256
WORDS_PER_MAT  = TOTAL_ELEMS // ELEMS_PER_WORD  # 8

# Byte addresses of each matrix (page-aligned, non-overlapping)
BYTE_ADDR_W   = 0x0000
BYTE_ADDR_X   = 0x1000   # page-aligned; matrix is 8 words × 64 bytes = 512 bytes
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
# BF16 helpers
# =============================================================================
def float_to_bits(val: float) -> int:
    """Float32 → BF16 bit pattern (upper 16 bits of float32)."""
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
# Matrix helpers
# =============================================================================
def pack_matrix_into_mem(mat: np.ndarray, word_base: int, mem: dict):
    flat = mat.flatten().tolist()
    for w in range(WORDS_PER_MAT):
        word_val = 0
        for i in range(ELEMS_PER_WORD):
            idx = w * ELEMS_PER_WORD + i
            v   = flat[idx] if idx < len(flat) else 0.0
            word_val |= (float_to_bits(v) & 0xFFFF) << (i * DW)
        mem[word_base + w] = word_val


def unpack_matrix_from_mem(word_base: int, mem: dict) -> np.ndarray:
    flat = []
    for w in range(WORDS_PER_MAT):
        word_val = mem.get(word_base + w, 0)
        for i in range(ELEMS_PER_WORD):
            flat.append(bits_to_float((word_val >> (i * DW)) & 0xFFFF))
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
# Handles ARLEN+1 R beats per transaction.  For our 32-word matrices the
# rd_mst issues exactly one 32-beat burst per matrix.
# =============================================================================
async def axi_rd_slave(dut, arvalid, arready, araddr, arlen,
                       rvalid, rready, rdata, rlast, rresp, mem: dict):
    arready.value = 0
    rvalid.value  = 0
    rlast.value   = 0
    rresp.value   = 0
    while True:
        arready.value = 1
        await RisingEdge(dut.ap_clk)
        while not int(arvalid.value):
            await RisingEdge(dut.ap_clk)
        byte_addr   = int(araddr.value)
        burst_beats = int(arlen.value) + 1
        word_base   = byte_addr >> 6
        arready.value = 0

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
# =============================================================================
async def axi_wr_slave(dut, awvalid, awready, awaddr, awlen,
                       wvalid, wready, wdata,
                       bvalid, bready, mem: dict):
    awready.value = 0
    wready.value  = 0
    bvalid.value  = 0
    while True:
        awready.value = 1
        await RisingEdge(dut.ap_clk)
        while not int(awvalid.value):
            await RisingEdge(dut.ap_clk)
        byte_addr   = int(awaddr.value)
        burst_beats = int(awlen.value) + 1
        word_base   = byte_addr >> 6
        awready.value = 0

        wready.value = 1
        for beat in range(burst_beats):
            await RisingEdge(dut.ap_clk)
            while not int(wvalid.value):
                await RisingEdge(dut.ap_clk)
            mem[word_base + beat] = int(wdata.value)
        wready.value = 0

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
    dut.s_axi_control_awvalid.value = 0
    dut.s_axi_control_wvalid.value  = 0
    dut.s_axi_control_bready.value  = 0
    dut.s_axi_control_arvalid.value = 0
    dut.s_axi_control_rready.value  = 0
    dut.s_axi_control_awaddr.value  = 0
    dut.s_axi_control_wdata.value   = 0
    dut.s_axi_control_wstrb.value   = 0
    dut.s_axi_control_araddr.value  = 0
    dut.m_axi_gmem0_arready.value = 0
    dut.m_axi_gmem0_rvalid.value  = 0
    dut.m_axi_gmem0_rdata.value   = 0
    dut.m_axi_gmem0_rresp.value   = 0
    dut.m_axi_gmem0_rlast.value   = 0
    dut.m_axi_gmem1_arready.value = 0
    dut.m_axi_gmem1_rvalid.value  = 0
    dut.m_axi_gmem1_rdata.value   = 0
    dut.m_axi_gmem1_rresp.value   = 0
    dut.m_axi_gmem1_rlast.value   = 0
    dut.m_axi_gmem2_awready.value = 0
    dut.m_axi_gmem2_wready.value  = 0
    dut.m_axi_gmem2_bresp.value   = 0
    dut.m_axi_gmem2_bvalid.value  = 0
    dut.m_axi_gmem0_awready.value = 0
    dut.m_axi_gmem0_wready.value  = 0
    dut.m_axi_gmem0_bresp.value   = 0
    dut.m_axi_gmem0_bvalid.value  = 0
    dut.m_axi_gmem1_awready.value = 0
    dut.m_axi_gmem1_wready.value  = 0
    dut.m_axi_gmem1_bresp.value   = 0
    dut.m_axi_gmem1_bvalid.value  = 0
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


def assert_close(actual, expected, rtol=0.05, atol=0.5, label=""):
    for i in range(N):
        for j in range(N):
            a, e = float(actual[i][j]), float(expected[i][j])
            if abs(e) > 1e-6:
                if abs(a - e) / abs(e) > rtol:
                    raise AssertionError(
                        f"{label}[{i}][{j}]: got {a:.6g}, expected {e:.6g} "
                        f"(rel {abs(a-e)/abs(e):.2e})")
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
    """W = I → OUT = X through the full burst AXI kernel path."""
    clock = Clock(dut.ap_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    start_slaves(dut, mem)

    W = np.eye(N, dtype=np.float32)
    X = small_x()

    result = await run_kernel_matmul(dut, W, X, mem)
    assert_close(result, bf16_ref(W, X), label="[identity] ")
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
    X = small_x()

    result = await run_kernel_matmul(dut, W, X, mem)
    assert_close(result, np.zeros((N, N), dtype=np.float32), label="[zero_w] ")
    cocotb.log.info("PASS: zero weight")


@cocotb.test()
async def test_small_integers(dut):
    """Small-integer W and X — exact in BF16."""
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

    result = await run_kernel_matmul(dut, W, X, mem)
    assert_close(result, bf16_ref(W, X), label="[small_int] ")
    cocotb.log.info("PASS: small integers")


@cocotb.test()
async def test_random(dut):
    """Random small-integer matrices (-3..3), 2 back-to-back runs."""
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
        result = await run_kernel_matmul(dut, W, X, mem)
        assert_close(result, bf16_ref(W, X), label=f"[rand_{case}] ")
        cocotb.log.info(f"PASS: random case {case + 1}/2")
