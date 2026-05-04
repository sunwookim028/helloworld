// ============================================================================
// krnl_matmul.sv — Vitis RTL kernel: 32×32 FP32 matrix multiply over HBM
//
// Computes OUT = X × W^T using the systolic array pipeline.
//
// Architecture:
//   krnl_vadd_ctrl  — AXI4-Lite slave, ap_ctrl_hs register map
//     Register reuse: in1_ptr = W byte addr, in2_ptr = X byte addr,
//                     out_ptr = OUT byte addr  (size register ignored)
//   matmul_top      — loads W/X, drives MXU, writes output to internal BRAM
//   AXI bridge      — converts matmul_top's sequential memory port to AXI4:
//                       gmem0 → W reads, gmem1 → X reads, gmem2 → OUT writes
//
// Host usage:
//   krnl_matmul(bo_W, bo_X, bo_out)   — no size argument
//   Each BO must be 32*32*4 = 4096 bytes (one 32×32 FP32 matrix).
//   XRT allocates page-aligned buffers, satisfying the 4KB alignment
//   requirement for single-burst AXI4 transactions.
// ============================================================================

`timescale 1 ns / 1 ps

module krnl_matmul #(
    parameter integer C_S_AXI_CTRL_DATA_WIDTH = 32,
    parameter integer C_S_AXI_CTRL_ADDR_WIDTH = 7,
    parameter integer C_M_AXI_DATA_WIDTH      = 512,
    parameter integer C_M_AXI_ADDR_WIDTH      = 64,
    parameter integer N                       = 32,
    parameter integer DATA_WIDTH              = 32
)(
    input  wire ap_clk,
    input  wire ap_rst_n,

    // AXI4-Lite control slave (s_axi_control)
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]      s_axi_control_awaddr,
    input  wire [2:0]                               s_axi_control_awprot,
    input  wire                                     s_axi_control_awvalid,
    output wire                                     s_axi_control_awready,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]      s_axi_control_wdata,
    input  wire [(C_S_AXI_CTRL_DATA_WIDTH/8)-1:0]  s_axi_control_wstrb,
    input  wire                                     s_axi_control_wvalid,
    output wire                                     s_axi_control_wready,
    output wire [1:0]                               s_axi_control_bresp,
    output wire                                     s_axi_control_bvalid,
    input  wire                                     s_axi_control_bready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]      s_axi_control_araddr,
    input  wire [2:0]                               s_axi_control_arprot,
    input  wire                                     s_axi_control_arvalid,
    output wire                                     s_axi_control_arready,
    output wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]      s_axi_control_rdata,
    output wire [1:0]                               s_axi_control_rresp,
    output wire                                     s_axi_control_rvalid,
    input  wire                                     s_axi_control_rready,

    // AXI4 master — gmem0 (W matrix, read only)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem0_araddr,
    output wire [7:0]                         m_axi_gmem0_arlen,
    output wire [2:0]                         m_axi_gmem0_arsize,
    output wire [1:0]                         m_axi_gmem0_arburst,
    output wire [3:0]                         m_axi_gmem0_arcache,
    output wire [2:0]                         m_axi_gmem0_arprot,
    output wire [3:0]                         m_axi_gmem0_arqos,
    output wire                               m_axi_gmem0_arvalid,
    input  wire                               m_axi_gmem0_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem0_rdata,
    input  wire [1:0]                         m_axi_gmem0_rresp,
    input  wire                               m_axi_gmem0_rlast,
    input  wire                               m_axi_gmem0_rvalid,
    output wire                               m_axi_gmem0_rready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem0_awaddr,
    output wire [7:0]                         m_axi_gmem0_awlen,
    output wire [2:0]                         m_axi_gmem0_awsize,
    output wire [1:0]                         m_axi_gmem0_awburst,
    output wire [3:0]                         m_axi_gmem0_awcache,
    output wire [2:0]                         m_axi_gmem0_awprot,
    output wire [3:0]                         m_axi_gmem0_awqos,
    output wire                               m_axi_gmem0_awvalid,
    input  wire                               m_axi_gmem0_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem0_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_gmem0_wstrb,
    output wire                               m_axi_gmem0_wlast,
    output wire                               m_axi_gmem0_wvalid,
    input  wire                               m_axi_gmem0_wready,
    input  wire [1:0]                         m_axi_gmem0_bresp,
    input  wire                               m_axi_gmem0_bvalid,
    output wire                               m_axi_gmem0_bready,

    // AXI4 master — gmem1 (X matrix, read only)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem1_araddr,
    output wire [7:0]                         m_axi_gmem1_arlen,
    output wire [2:0]                         m_axi_gmem1_arsize,
    output wire [1:0]                         m_axi_gmem1_arburst,
    output wire [3:0]                         m_axi_gmem1_arcache,
    output wire [2:0]                         m_axi_gmem1_arprot,
    output wire [3:0]                         m_axi_gmem1_arqos,
    output wire                               m_axi_gmem1_arvalid,
    input  wire                               m_axi_gmem1_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem1_rdata,
    input  wire [1:0]                         m_axi_gmem1_rresp,
    input  wire                               m_axi_gmem1_rlast,
    input  wire                               m_axi_gmem1_rvalid,
    output wire                               m_axi_gmem1_rready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem1_awaddr,
    output wire [7:0]                         m_axi_gmem1_awlen,
    output wire [2:0]                         m_axi_gmem1_awsize,
    output wire [1:0]                         m_axi_gmem1_awburst,
    output wire [3:0]                         m_axi_gmem1_awcache,
    output wire [2:0]                         m_axi_gmem1_awprot,
    output wire [3:0]                         m_axi_gmem1_awqos,
    output wire                               m_axi_gmem1_awvalid,
    input  wire                               m_axi_gmem1_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem1_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_gmem1_wstrb,
    output wire                               m_axi_gmem1_wlast,
    output wire                               m_axi_gmem1_wvalid,
    input  wire                               m_axi_gmem1_wready,
    input  wire [1:0]                         m_axi_gmem1_bresp,
    input  wire                               m_axi_gmem1_bvalid,
    output wire                               m_axi_gmem1_bready,

    // AXI4 master — gmem2 (output matrix, write only)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem2_awaddr,
    output wire [7:0]                         m_axi_gmem2_awlen,
    output wire [2:0]                         m_axi_gmem2_awsize,
    output wire [1:0]                         m_axi_gmem2_awburst,
    output wire [3:0]                         m_axi_gmem2_awcache,
    output wire [2:0]                         m_axi_gmem2_awprot,
    output wire [3:0]                         m_axi_gmem2_awqos,
    output wire                               m_axi_gmem2_awvalid,
    input  wire                               m_axi_gmem2_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem2_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_gmem2_wstrb,
    output wire                               m_axi_gmem2_wlast,
    output wire                               m_axi_gmem2_wvalid,
    input  wire                               m_axi_gmem2_wready,
    input  wire [1:0]                         m_axi_gmem2_bresp,
    input  wire                               m_axi_gmem2_bvalid,
    output wire                               m_axi_gmem2_bready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_gmem2_araddr,
    output wire [7:0]                         m_axi_gmem2_arlen,
    output wire [2:0]                         m_axi_gmem2_arsize,
    output wire [1:0]                         m_axi_gmem2_arburst,
    output wire [3:0]                         m_axi_gmem2_arcache,
    output wire [2:0]                         m_axi_gmem2_arprot,
    output wire [3:0]                         m_axi_gmem2_arqos,
    output wire                               m_axi_gmem2_arvalid,
    input  wire                               m_axi_gmem2_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_gmem2_rdata,
    input  wire [1:0]                         m_axi_gmem2_rresp,
    input  wire                               m_axi_gmem2_rlast,
    input  wire                               m_axi_gmem2_rvalid,
    output wire                               m_axi_gmem2_rready
);

    localparam int ELEMS_PER_WORD   = C_M_AXI_DATA_WIDTH / DATA_WIDTH; // 16
    localparam int TOTAL_ELEMS      = N * N;                            // 1024
    localparam int WORDS_PER_MATRIX = TOTAL_ELEMS / ELEMS_PER_WORD;    // 64

    // =========================================================================
    // AXI4-Lite control slave
    // =========================================================================
    wire        ap_start_w;
    logic       ap_done_w;
    wire        ap_idle_w;
    wire [63:0] in1_ptr_w;   // W matrix byte address
    wire [63:0] in2_ptr_w;   // X matrix byte address
    wire [63:0] out_ptr_w;   // OUT matrix byte address
    wire [31:0] size_w;      // unused

    krnl_vadd_ctrl #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_CTRL_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_CTRL_ADDR_WIDTH)
    ) u_ctrl (
        .ap_start      (ap_start_w),
        .ap_done       (ap_done_w),
        .ap_idle       (ap_idle_w),
        .in1_ptr       (in1_ptr_w),
        .in2_ptr       (in2_ptr_w),
        .out_ptr       (out_ptr_w),
        .size          (size_w),
        .S_AXI_ACLK    (ap_clk),
        .S_AXI_ARESETN (ap_rst_n),
        .S_AXI_AWADDR  (s_axi_control_awaddr),
        .S_AXI_AWPROT  (s_axi_control_awprot),
        .S_AXI_AWVALID (s_axi_control_awvalid),
        .S_AXI_AWREADY (s_axi_control_awready),
        .S_AXI_WDATA   (s_axi_control_wdata),
        .S_AXI_WSTRB   (s_axi_control_wstrb),
        .S_AXI_WVALID  (s_axi_control_wvalid),
        .S_AXI_WREADY  (s_axi_control_wready),
        .S_AXI_BRESP   (s_axi_control_bresp),
        .S_AXI_BVALID  (s_axi_control_bvalid),
        .S_AXI_BREADY  (s_axi_control_bready),
        .S_AXI_ARADDR  (s_axi_control_araddr),
        .S_AXI_ARPROT  (s_axi_control_arprot),
        .S_AXI_ARVALID (s_axi_control_arvalid),
        .S_AXI_ARREADY (s_axi_control_arready),
        .S_AXI_RDATA   (s_axi_control_rdata),
        .S_AXI_RRESP   (s_axi_control_rresp),
        .S_AXI_RVALID  (s_axi_control_rvalid),
        .S_AXI_RREADY  (s_axi_control_rready)
    );

    // Word addresses: byte_addr >> 6 (512-bit word = 64 bytes)
    // Take bits [37:6] of the 64-bit pointer → 32-bit word address
    wire [31:0] addr_w_word   = in1_ptr_w[37:6];
    wire [31:0] addr_x_word   = in2_ptr_w[37:6];
    wire [31:0] addr_out_word = out_ptr_w[37:6];

    // =========================================================================
    // matmul_top instance
    // =========================================================================
    logic        mt_start;
    wire         mt_done;
    wire  [31:0] mt_mem_addr;
    wire  [C_M_AXI_DATA_WIDTH-1:0] mt_mem_wr_data;
    logic [C_M_AXI_DATA_WIDTH-1:0] mt_mem_rd_data;
    wire         mt_mem_rd_en;
    wire         mt_mem_wr_en;
    logic        mt_mem_rsp_valid;
    logic        mt_mem_wr_done;

    matmul_top #(
        .N              (N),
        .DATA_WIDTH     (DATA_WIDTH),
        .HBM_DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDRESS_WIDTH  (32)
    ) u_mt (
        .clk           (ap_clk),
        .rst_n         (ap_rst_n),
        .start         (mt_start),
        .done          (mt_done),
        .addr_w        (addr_w_word),
        .addr_x        (addr_x_word),
        .addr_out      (addr_out_word),
        .mem_addr      (mt_mem_addr),
        .mem_wr_data   (mt_mem_wr_data),
        .mem_rd_data   (mt_mem_rd_data),
        .mem_rd_en     (mt_mem_rd_en),
        .mem_wr_en     (mt_mem_wr_en),
        .mem_rsp_valid (mt_mem_rsp_valid),
        .mem_wr_done   (mt_mem_wr_done)
    );

    // =========================================================================
    // Kernel top FSM
    // =========================================================================
    localparam logic [1:0] KS_IDLE = 2'd0, KS_RUN = 2'd1, KS_DONE = 2'd2;
    logic [1:0]  ks_state;
    logic        ap_start_prev;
    wire         start_rise = ap_start_w && !ap_start_prev;

    assign ap_idle_w = (ks_state == KS_IDLE);

    always_ff @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            ks_state      <= KS_IDLE;
            ap_start_prev <= 1'b0;
            ap_done_w     <= 1'b0;
            mt_start      <= 1'b0;
        end else begin
            ap_start_prev <= ap_start_w;
            ap_done_w     <= 1'b0;
            mt_start      <= 1'b0;

            case (ks_state)
                KS_IDLE: if (start_rise) begin
                    mt_start <= 1'b1;
                    ks_state <= KS_RUN;
                end

                KS_RUN: if (mt_done) ks_state <= KS_DONE;

                KS_DONE: begin
                    ap_done_w <= 1'b1;
                    ks_state  <= KS_IDLE;
                end

                default: ks_state <= KS_IDLE;
            endcase
        end
    end

    // =========================================================================
    // AXI bridge FSM
    //
    // Converts matmul_top's one-at-a-time memory requests to AXI4 single-beat
    // transactions:
    //   Reads : gmem0 (W range) or gmem1 (X range)
    //   Writes: gmem2 (OUT)
    //
    // Routing: if (mt_mem_addr - addr_w_word) < WORDS_PER_MATRIX → gmem0 (W)
    //          else                                               → gmem1 (X)
    // =========================================================================
    localparam logic [2:0] BR_IDLE  = 3'd0,
                           BR_RD_AR = 3'd1,
                           BR_RD_R  = 3'd2,
                           BR_WR_AW = 3'd3,
                           BR_WR_W  = 3'd4,
                           BR_WR_B  = 3'd5;

    logic [2:0]  br_state;
    logic        br_use_gmem0;
    logic [C_M_AXI_ADDR_WIDTH-1:0] br_byte_addr;
    logic [C_M_AXI_DATA_WIDTH-1:0] br_wr_latch;

    // AXI output registers
    logic        g0_arvalid_r, g1_arvalid_r;
    logic [C_M_AXI_ADDR_WIDTH-1:0] g0_araddr_r, g1_araddr_r;
    logic        g0_rready_r,  g1_rready_r;
    logic        g2_awvalid_r, g2_wvalid_r, g2_bready_r;
    logic [C_M_AXI_ADDR_WIDTH-1:0] g2_awaddr_r;
    logic [C_M_AXI_DATA_WIDTH-1:0] g2_wdata_r;

    // Byte address of matmul_top's current request (word_addr << 6)
    wire [C_M_AXI_ADDR_WIDTH-1:0] mt_byte_addr =
        {{(C_M_AXI_ADDR_WIDTH-38){1'b0}}, mt_mem_addr, 6'b0};

    // Address routing: W range check in unsigned 32-bit arithmetic
    wire [31:0] w_offs    = mt_mem_addr - addr_w_word;
    wire        is_w_range = (w_offs < WORDS_PER_MATRIX[31:0]);

    always_ff @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            br_state        <= BR_IDLE;
            br_use_gmem0    <= 1'b0;
            br_byte_addr    <= '0;
            br_wr_latch     <= '0;
            g0_arvalid_r    <= 1'b0;  g1_arvalid_r <= 1'b0;
            g0_araddr_r     <= '0;    g1_araddr_r  <= '0;
            g0_rready_r     <= 1'b0;  g1_rready_r  <= 1'b0;
            g2_awvalid_r    <= 1'b0;  g2_wvalid_r  <= 1'b0;
            g2_bready_r     <= 1'b0;
            g2_awaddr_r     <= '0;    g2_wdata_r   <= '0;
            mt_mem_rsp_valid <= 1'b0;
            mt_mem_wr_done  <= 1'b0;
            mt_mem_rd_data  <= '0;
        end else begin
            mt_mem_rsp_valid <= 1'b0;
            mt_mem_wr_done   <= 1'b0;

            case (br_state)

                BR_IDLE: begin
                    if (mt_mem_rd_en) begin
                        br_use_gmem0 <= is_w_range;
                        br_byte_addr <= mt_byte_addr;
                        br_state     <= BR_RD_AR;
                    end else if (mt_mem_wr_en) begin
                        br_byte_addr <= mt_byte_addr;
                        br_wr_latch  <= mt_mem_wr_data;
                        br_state     <= BR_WR_AW;
                    end
                end

                // ── Read: AR channel ──────────────────────────────────────
                BR_RD_AR: begin
                    if (br_use_gmem0) begin
                        g0_arvalid_r <= 1'b1;
                        g0_araddr_r  <= br_byte_addr;
                        if (g0_arvalid_r && m_axi_gmem0_arready) begin
                            g0_arvalid_r <= 1'b0;
                            br_state     <= BR_RD_R;
                        end
                    end else begin
                        g1_arvalid_r <= 1'b1;
                        g1_araddr_r  <= br_byte_addr;
                        if (g1_arvalid_r && m_axi_gmem1_arready) begin
                            g1_arvalid_r <= 1'b0;
                            br_state     <= BR_RD_R;
                        end
                    end
                end

                // ── Read: R channel ───────────────────────────────────────
                BR_RD_R: begin
                    if (br_use_gmem0) begin
                        g0_rready_r <= 1'b1;
                        if (g0_rready_r && m_axi_gmem0_rvalid) begin
                            mt_mem_rd_data   <= m_axi_gmem0_rdata;
                            mt_mem_rsp_valid <= 1'b1;
                            g0_rready_r      <= 1'b0;
                            br_state         <= BR_IDLE;
                        end
                    end else begin
                        g1_rready_r <= 1'b1;
                        if (g1_rready_r && m_axi_gmem1_rvalid) begin
                            mt_mem_rd_data   <= m_axi_gmem1_rdata;
                            mt_mem_rsp_valid <= 1'b1;
                            g1_rready_r      <= 1'b0;
                            br_state         <= BR_IDLE;
                        end
                    end
                end

                // ── Write: AW channel ─────────────────────────────────────
                BR_WR_AW: begin
                    g2_awvalid_r <= 1'b1;
                    g2_awaddr_r  <= br_byte_addr;
                    if (g2_awvalid_r && m_axi_gmem2_awready) begin
                        g2_awvalid_r <= 1'b0;
                        br_state     <= BR_WR_W;
                    end
                end

                // ── Write: W channel ──────────────────────────────────────
                BR_WR_W: begin
                    g2_wvalid_r <= 1'b1;
                    g2_wdata_r  <= br_wr_latch;
                    if (g2_wvalid_r && m_axi_gmem2_wready) begin
                        g2_wvalid_r <= 1'b0;
                        g2_bready_r <= 1'b1;
                        br_state    <= BR_WR_B;
                    end
                end

                // ── Write: B channel ──────────────────────────────────────
                BR_WR_B: begin
                    g2_bready_r <= 1'b1;
                    if (g2_bready_r && m_axi_gmem2_bvalid) begin
                        mt_mem_wr_done <= 1'b1;
                        g2_bready_r    <= 1'b0;
                        br_state       <= BR_IDLE;
                    end
                end

                default: br_state <= BR_IDLE;
            endcase
        end
    end

    // =========================================================================
    // AXI port assignments
    // =========================================================================

    // gmem0 — W reads
    assign m_axi_gmem0_arvalid = g0_arvalid_r;
    assign m_axi_gmem0_araddr  = g0_araddr_r;
    assign m_axi_gmem0_arlen   = 8'd0;
    assign m_axi_gmem0_arsize  = 3'b110;
    assign m_axi_gmem0_arburst = 2'b01;
    assign m_axi_gmem0_arcache = 4'b1111;
    assign m_axi_gmem0_arprot  = 3'b000;
    assign m_axi_gmem0_arqos   = 4'b0000;
    assign m_axi_gmem0_rready  = g0_rready_r;
    assign m_axi_gmem0_awvalid = 1'b0;
    assign m_axi_gmem0_awaddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem0_awlen   = 8'd0;
    assign m_axi_gmem0_awsize  = 3'b110;
    assign m_axi_gmem0_awburst = 2'b01;
    assign m_axi_gmem0_awcache = 4'b1111;
    assign m_axi_gmem0_awprot  = 3'b000;
    assign m_axi_gmem0_awqos   = 4'b0000;
    assign m_axi_gmem0_wvalid  = 1'b0;
    assign m_axi_gmem0_wdata   = {C_M_AXI_DATA_WIDTH{1'b0}};
    assign m_axi_gmem0_wstrb   = {(C_M_AXI_DATA_WIDTH/8){1'b0}};
    assign m_axi_gmem0_wlast   = 1'b0;
    assign m_axi_gmem0_bready  = 1'b1;

    // gmem1 — X reads
    assign m_axi_gmem1_arvalid = g1_arvalid_r;
    assign m_axi_gmem1_araddr  = g1_araddr_r;
    assign m_axi_gmem1_arlen   = 8'd0;
    assign m_axi_gmem1_arsize  = 3'b110;
    assign m_axi_gmem1_arburst = 2'b01;
    assign m_axi_gmem1_arcache = 4'b1111;
    assign m_axi_gmem1_arprot  = 3'b000;
    assign m_axi_gmem1_arqos   = 4'b0000;
    assign m_axi_gmem1_rready  = g1_rready_r;
    assign m_axi_gmem1_awvalid = 1'b0;
    assign m_axi_gmem1_awaddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem1_awlen   = 8'd0;
    assign m_axi_gmem1_awsize  = 3'b110;
    assign m_axi_gmem1_awburst = 2'b01;
    assign m_axi_gmem1_awcache = 4'b1111;
    assign m_axi_gmem1_awprot  = 3'b000;
    assign m_axi_gmem1_awqos   = 4'b0000;
    assign m_axi_gmem1_wvalid  = 1'b0;
    assign m_axi_gmem1_wdata   = {C_M_AXI_DATA_WIDTH{1'b0}};
    assign m_axi_gmem1_wstrb   = {(C_M_AXI_DATA_WIDTH/8){1'b0}};
    assign m_axi_gmem1_wlast   = 1'b0;
    assign m_axi_gmem1_bready  = 1'b1;

    // gmem2 — OUT writes
    assign m_axi_gmem2_awvalid = g2_awvalid_r;
    assign m_axi_gmem2_awaddr  = g2_awaddr_r;
    assign m_axi_gmem2_awlen   = 8'd0;
    assign m_axi_gmem2_awsize  = 3'b110;
    assign m_axi_gmem2_awburst = 2'b01;
    assign m_axi_gmem2_awcache = 4'b1111;
    assign m_axi_gmem2_awprot  = 3'b000;
    assign m_axi_gmem2_awqos   = 4'b0000;
    assign m_axi_gmem2_wvalid  = g2_wvalid_r;
    assign m_axi_gmem2_wdata   = g2_wdata_r;
    assign m_axi_gmem2_wstrb   = {(C_M_AXI_DATA_WIDTH/8){1'b1}};
    assign m_axi_gmem2_wlast   = g2_wvalid_r;
    assign m_axi_gmem2_bready  = g2_bready_r;
    assign m_axi_gmem2_arvalid = 1'b0;
    assign m_axi_gmem2_araddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem2_arlen   = 8'd0;
    assign m_axi_gmem2_arsize  = 3'b110;
    assign m_axi_gmem2_arburst = 2'b01;
    assign m_axi_gmem2_arcache = 4'b1111;
    assign m_axi_gmem2_arprot  = 3'b000;
    assign m_axi_gmem2_arqos   = 4'b0000;
    assign m_axi_gmem2_rready  = 1'b0;

endmodule
