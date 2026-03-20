// ============================================================================
// matmul_top.sv — HBM-width integration wrapper for MXU
//
// Bridges a 512-bit wide memory interface (modelling HBM) to the MXU's
// 32-bit element memory port via internal BRAMs.
//
// Flow:
//   1. Load W : read WORDS_PER_MATRIX 512-bit words from HBM, unpack → w_bram
//   2. Load X : same → x_bram
//   3. Compute: MXU reads BRAMs (32-bit), runs systolic array, writes out_bram
//   4. Store  : pack out_bram → 512-bit words, write to HBM
//
// Memory interface: word-addressed (each address = one HBM_DATA_WIDTH-bit word)
// ============================================================================

`timescale 1ns/1ps

module matmul_top #(
    parameter int N               = 16,
    parameter int DATA_WIDTH      = 32,
    parameter int HBM_DATA_WIDTH  = 512,
    parameter int ADDRESS_WIDTH   = 32,
    parameter int HBM_MEM_LATENCY = 2       // >= 2 required for cocotb timing
)(
    input  logic clk,
    input  logic rst_n,

    // Control
    input  logic start,
    output logic done,

    // Matrix base addresses (word-addressed: each addr = one HBM_DATA_WIDTH word)
    input  logic [ADDRESS_WIDTH-1:0] addr_w,
    input  logic [ADDRESS_WIDTH-1:0] addr_x,
    input  logic [ADDRESS_WIDTH-1:0] addr_out,

    // HBM-width memory interface
    output logic [ADDRESS_WIDTH-1:0]  mem_addr,
    output logic [HBM_DATA_WIDTH-1:0] mem_wr_data,
    input  logic [HBM_DATA_WIDTH-1:0] mem_rd_data,
    output logic                      mem_rd_en,
    output logic                      mem_wr_en
);

    localparam int ELEMS_PER_WORD   = HBM_DATA_WIDTH / DATA_WIDTH;
    localparam int TOTAL_ELEMS      = N * N;
    localparam int WORDS_PER_MATRIX = (TOTAL_ELEMS + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD;
    localparam int WORD_IDX_BITS    = $clog2(WORDS_PER_MATRIX + 1);
    localparam int LAT_BITS         = $clog2(HBM_MEM_LATENCY + 1);

    // MXU address space: W at 0x0000, X at 0x0100, OUT at 0x0200
    // (fixed offsets large enough for up to N=16: TOTAL_ELEMS=256=0x100)
    localparam logic [15:0] MXU_BASE_W   = 16'h0000;
    localparam logic [15:0] MXU_BASE_X   = 16'h0100;
    localparam logic [15:0] MXU_BASE_OUT = 16'h0200;

    // =========================================================================
    // Internal BRAMs (register arrays)
    // =========================================================================
    logic [DATA_WIDTH-1:0] w_bram   [0:TOTAL_ELEMS-1];
    logic [DATA_WIDTH-1:0] x_bram   [0:TOTAL_ELEMS-1];
    logic [DATA_WIDTH-1:0] out_bram [0:TOTAL_ELEMS-1];

    // =========================================================================
    // MXU instance
    // =========================================================================
    logic        mxu_start, mxu_done;
    logic [15:0] mxu_mem_addr;
    logic [DATA_WIDTH-1:0] mxu_mem_req_data;
    logic [DATA_WIDTH-1:0] mxu_mem_resp_data;
    logic        mxu_mem_rd_en;
    logic        mxu_mem_wr_en;

    mxu #(
        .N             (N),
        .DATA_WIDTH    (DATA_WIDTH),
        .BANKING_FACTOR(1),
        .ADDRESS_WIDTH (16),
        .MEM_LATENCY   (2)
    ) u_mxu (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (mxu_start),
        .done          (mxu_done),
        .base_addr_w   (MXU_BASE_W),
        .base_addr_x   (MXU_BASE_X),
        .base_addr_out (MXU_BASE_OUT),
        .mem_req_addr  (mxu_mem_addr),
        .mem_req_data  (mxu_mem_req_data),
        .mem_resp_data (mxu_mem_resp_data),
        .mem_read_en   (mxu_mem_rd_en),
        .mem_write_en  (mxu_mem_wr_en)
    );

    // =========================================================================
    // BRAM read path for MXU
    //
    // Latch address on read_en (mirrors cocotb memory driver behaviour).
    // With MXU MEM_LATENCY=2:
    //   Cycle 0: MXU sets addr + rd_en  →  bram_rd_addr latches next posedge
    //   Cycle 1: bram_rd_addr = addr    →  mxu_mem_resp_data valid (comb)
    //   Cycle 2: MXU captures resp_data ✓
    // =========================================================================
    logic [15:0] bram_rd_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bram_rd_addr <= '0;
        else if (mxu_mem_rd_en)
            bram_rd_addr <= mxu_mem_addr;
    end

    always_comb begin
        if (bram_rd_addr >= MXU_BASE_OUT)
            mxu_mem_resp_data = out_bram[bram_rd_addr - MXU_BASE_OUT];
        else if (bram_rd_addr >= MXU_BASE_X)
            mxu_mem_resp_data = x_bram[bram_rd_addr - MXU_BASE_X];
        else
            mxu_mem_resp_data = w_bram[bram_rd_addr];
    end

    // =========================================================================
    // out_bram — written by MXU during compute, cleared on reset/start
    // (separate always_ff so the main FSM can own w_bram/x_bram exclusively)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < TOTAL_ELEMS; i++)
                out_bram[i] <= '0;
        end else begin
            if (start) begin
                for (int i = 0; i < TOTAL_ELEMS; i++)
                    out_bram[i] <= '0;
            end else if (mxu_mem_wr_en && mxu_mem_addr >= MXU_BASE_OUT) begin
                out_bram[mxu_mem_addr - MXU_BASE_OUT] <= mxu_mem_req_data;
            end
        end
    end

    // =========================================================================
    // Top FSM
    // =========================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_W_REQ,
        S_LOAD_W_WAIT,
        S_LOAD_X_REQ,
        S_LOAD_X_WAIT,
        S_COMPUTE_START,
        S_COMPUTE_WAIT,
        S_STORE_REQ,
        S_STORE_WAIT,
        S_DONE
    } state_t;

    state_t state;
    logic [WORD_IDX_BITS-1:0] word_idx;
    logic [LAT_BITS-1:0]      lat_cnt;
    logic [ADDRESS_WIDTH-1:0] addr_w_reg, addr_x_reg, addr_out_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            word_idx     <= '0;
            lat_cnt      <= '0;
            mem_addr     <= '0;
            mem_wr_data  <= '0;
            mem_rd_en    <= 0;
            mem_wr_en    <= 0;
            mxu_start    <= 0;
            done         <= 0;
            addr_w_reg   <= '0;
            addr_x_reg   <= '0;
            addr_out_reg <= '0;
            for (int i = 0; i < TOTAL_ELEMS; i++) begin
                w_bram[i] <= '0;
                x_bram[i] <= '0;
            end
        end else begin
            mem_rd_en <= 0;
            mem_wr_en <= 0;
            mxu_start <= 0;
            done      <= 0;

            case (state)

                // ----------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        addr_w_reg   <= addr_w;
                        addr_x_reg   <= addr_x;
                        addr_out_reg <= addr_out;
                        word_idx     <= '0;
                        state        <= S_LOAD_W_REQ;
                    end
                end

                // ----------------------------------------------------------------
                // Load W from HBM, unpack 512-bit words into w_bram
                // ----------------------------------------------------------------
                S_LOAD_W_REQ: begin
                    mem_addr  <= addr_w_reg +
                                 {{(ADDRESS_WIDTH-WORD_IDX_BITS){1'b0}}, word_idx};
                    mem_rd_en <= 1;
                    lat_cnt   <= '0;
                    state     <= S_LOAD_W_WAIT;
                end

                S_LOAD_W_WAIT: begin
                    if (lat_cnt >= HBM_MEM_LATENCY[$bits(lat_cnt)-1:0] - 1) begin
                        for (int i = 0; i < ELEMS_PER_WORD; i++) begin
                            int idx;
                            idx = int'(word_idx) * ELEMS_PER_WORD + i;
                            if (idx < TOTAL_ELEMS)
                                w_bram[idx] <= mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH];
                        end
                        if (int'(word_idx) >= WORDS_PER_MATRIX - 1) begin
                            word_idx <= '0;
                            state    <= S_LOAD_X_REQ;
                        end else begin
                            word_idx <= word_idx + 1;
                            state    <= S_LOAD_W_REQ;
                        end
                    end else begin
                        lat_cnt <= lat_cnt + 1;
                    end
                end

                // ----------------------------------------------------------------
                // Load X from HBM, unpack into x_bram
                // ----------------------------------------------------------------
                S_LOAD_X_REQ: begin
                    mem_addr  <= addr_x_reg +
                                 {{(ADDRESS_WIDTH-WORD_IDX_BITS){1'b0}}, word_idx};
                    mem_rd_en <= 1;
                    lat_cnt   <= '0;
                    state     <= S_LOAD_X_WAIT;
                end

                S_LOAD_X_WAIT: begin
                    if (lat_cnt >= HBM_MEM_LATENCY[$bits(lat_cnt)-1:0] - 1) begin
                        for (int i = 0; i < ELEMS_PER_WORD; i++) begin
                            int idx;
                            idx = int'(word_idx) * ELEMS_PER_WORD + i;
                            if (idx < TOTAL_ELEMS)
                                x_bram[idx] <= mem_rd_data[i*DATA_WIDTH +: DATA_WIDTH];
                        end
                        if (int'(word_idx) >= WORDS_PER_MATRIX - 1) begin
                            word_idx <= '0;
                            state    <= S_COMPUTE_START;
                        end else begin
                            word_idx <= word_idx + 1;
                            state    <= S_LOAD_X_REQ;
                        end
                    end else begin
                        lat_cnt <= lat_cnt + 1;
                    end
                end

                // ----------------------------------------------------------------
                // Compute: start MXU, wait for done
                // ----------------------------------------------------------------
                S_COMPUTE_START: begin
                    mxu_start <= 1;
                    state     <= S_COMPUTE_WAIT;
                end

                S_COMPUTE_WAIT: begin
                    if (mxu_done) begin
                        word_idx <= '0;
                        state    <= S_STORE_REQ;
                    end
                end

                // ----------------------------------------------------------------
                // Store output: pack out_bram → 512-bit words → HBM
                // ----------------------------------------------------------------
                S_STORE_REQ: begin
                    mem_addr <= addr_out_reg +
                                {{(ADDRESS_WIDTH-WORD_IDX_BITS){1'b0}}, word_idx};
                    for (int i = 0; i < ELEMS_PER_WORD; i++) begin
                        int idx;
                        idx = int'(word_idx) * ELEMS_PER_WORD + i;
                        if (idx < TOTAL_ELEMS)
                            mem_wr_data[i*DATA_WIDTH +: DATA_WIDTH] <= out_bram[idx];
                        else
                            mem_wr_data[i*DATA_WIDTH +: DATA_WIDTH] <= '0;
                    end
                    mem_wr_en <= 1;
                    lat_cnt   <= '0;
                    state     <= S_STORE_WAIT;
                end

                S_STORE_WAIT: begin
                    if (lat_cnt >= HBM_MEM_LATENCY[$bits(lat_cnt)-1:0] - 1) begin
                        if (int'(word_idx) >= WORDS_PER_MATRIX - 1) begin
                            state <= S_DONE;
                        end else begin
                            word_idx <= word_idx + 1;
                            state    <= S_STORE_REQ;
                        end
                    end else begin
                        lat_cnt <= lat_cnt + 1;
                    end
                end

                // ----------------------------------------------------------------
                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
