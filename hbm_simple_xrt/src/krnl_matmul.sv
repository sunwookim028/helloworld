// ============================================================================
// krnl_matmul.sv — Vitis RTL kernel: 32×32 FP32 matrix multiply over HBM
//                  AXI4 burst DMA via krnl_vadd_rd_mst / krnl_vadd_wr_mst
//
// Computes OUT = X × W^T using the systolic array pipeline.
//
// Architecture:
//   krnl_vadd_ctrl       — AXI4-Lite slave, ap_ctrl_hs register map
//   matmul_top           — loads W/X BRAMs, drives MXU, writes out_bram
//   krnl_vadd_rd_mst ×2  — one 64-beat burst read: W (gmem0), X (gmem1)
//   krnl_vadd_wr_mst ×1  — one 64-beat burst write: OUT (gmem2)
//   fifo4 ×3             — w_rd_fifo, x_rd_fifo, wr_fifo (depth 128)
//
// Sequencer FSM:
//   IDLE → BURST_RD_W → BURST_RD_X → MT_START → MT_RUN → BURST_WR → DONE
//
// Each matrix is 32×32 FP32 = 4096 bytes = 64 × 512-bit words.
// Replaces 192 single-beat AXI transactions with 3 burst transactions.
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
    // FIFO depth > WORDS_PER_MATRIX so almost_full (fires at DEPTH-1=127)
    // never triggers during our 64-word bursts, preventing a deadlock on
    // the final beat where the slave stalls waiting for RREADY.
    localparam int FIFO_DEPTH       = 128;

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

    // Word addresses for matmul_top and routing (byte_addr >> 6, 512-bit words)
    wire [31:0] addr_w_word   = in1_ptr_w[37:6];
    wire [31:0] addr_x_word   = in2_ptr_w[37:6];
    wire [31:0] addr_out_word = out_ptr_w[37:6];

    // =========================================================================
    // FIFOs
    // =========================================================================
    logic fifo_flush;

    wire                           w_fifo_wr_en,   w_fifo_rd_en;
    wire [C_M_AXI_DATA_WIDTH-1:0] w_fifo_wr_data, w_fifo_rd_data;
    wire                           w_fifo_almost_full, w_fifo_empty;

    fifo4 #(.WIDTH(C_M_AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) u_w_rd_fifo (
        .clk(ap_clk), .rst_n(ap_rst_n), .flush(fifo_flush),
        .wr_en(w_fifo_wr_en), .wr_data(w_fifo_wr_data),
        .rd_en(w_fifo_rd_en), .rd_data(w_fifo_rd_data),
        .full(), .empty(w_fifo_empty), .almost_full(w_fifo_almost_full)
    );

    wire                           x_fifo_wr_en,   x_fifo_rd_en;
    wire [C_M_AXI_DATA_WIDTH-1:0] x_fifo_wr_data, x_fifo_rd_data;
    wire                           x_fifo_almost_full, x_fifo_empty;

    fifo4 #(.WIDTH(C_M_AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) u_x_rd_fifo (
        .clk(ap_clk), .rst_n(ap_rst_n), .flush(fifo_flush),
        .wr_en(x_fifo_wr_en), .wr_data(x_fifo_wr_data),
        .rd_en(x_fifo_rd_en), .rd_data(x_fifo_rd_data),
        .full(), .empty(x_fifo_empty), .almost_full(x_fifo_almost_full)
    );

    wire                           wr_fifo_wr_en,   wr_fifo_rd_en;
    wire [C_M_AXI_DATA_WIDTH-1:0] wr_fifo_wr_data, wr_fifo_rd_data;
    wire                           wr_fifo_empty;

    fifo4 #(.WIDTH(C_M_AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) u_wr_fifo (
        .clk(ap_clk), .rst_n(ap_rst_n), .flush(fifo_flush),
        .wr_en(wr_fifo_wr_en), .wr_data(wr_fifo_wr_data),
        .rd_en(wr_fifo_rd_en), .rd_data(wr_fifo_rd_data),
        .full(), .empty(wr_fifo_empty), .almost_full()
    );

    // =========================================================================
    // Burst read master — W (gmem0)
    // =========================================================================
    logic rd_w_start;
    wire  rd_w_done;

    krnl_vadd_rd_mst #(
        .DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDR_WIDTH (C_M_AXI_ADDR_WIDTH)
    ) u_rd_w (
        .clk              (ap_clk),
        .rst_n            (ap_rst_n),
        .start            (rd_w_start),
        .base_addr        (in1_ptr_w),
        .num_words        (WORDS_PER_MATRIX),
        .done             (rd_w_done),
        .fifo_wr_en       (w_fifo_wr_en),
        .fifo_wr_data     (w_fifo_wr_data),
        .fifo_almost_full (w_fifo_almost_full),
        .M_AXI_ARVALID    (m_axi_gmem0_arvalid),
        .M_AXI_ARADDR     (m_axi_gmem0_araddr),
        .M_AXI_ARLEN      (m_axi_gmem0_arlen),
        .M_AXI_ARSIZE     (m_axi_gmem0_arsize),
        .M_AXI_ARBURST    (m_axi_gmem0_arburst),
        .M_AXI_ARCACHE    (m_axi_gmem0_arcache),
        .M_AXI_ARPROT     (m_axi_gmem0_arprot),
        .M_AXI_ARQOS      (m_axi_gmem0_arqos),
        .M_AXI_ARREADY    (m_axi_gmem0_arready),
        .M_AXI_RDATA      (m_axi_gmem0_rdata),
        .M_AXI_RRESP      (m_axi_gmem0_rresp),
        .M_AXI_RLAST      (m_axi_gmem0_rlast),
        .M_AXI_RVALID     (m_axi_gmem0_rvalid),
        .M_AXI_RREADY     (m_axi_gmem0_rready)
    );

    // =========================================================================
    // Burst read master — X (gmem1)
    // =========================================================================
    logic rd_x_start;
    wire  rd_x_done;

    krnl_vadd_rd_mst #(
        .DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDR_WIDTH (C_M_AXI_ADDR_WIDTH)
    ) u_rd_x (
        .clk              (ap_clk),
        .rst_n            (ap_rst_n),
        .start            (rd_x_start),
        .base_addr        (in2_ptr_w),
        .num_words        (WORDS_PER_MATRIX),
        .done             (rd_x_done),
        .fifo_wr_en       (x_fifo_wr_en),
        .fifo_wr_data     (x_fifo_wr_data),
        .fifo_almost_full (x_fifo_almost_full),
        .M_AXI_ARVALID    (m_axi_gmem1_arvalid),
        .M_AXI_ARADDR     (m_axi_gmem1_araddr),
        .M_AXI_ARLEN      (m_axi_gmem1_arlen),
        .M_AXI_ARSIZE     (m_axi_gmem1_arsize),
        .M_AXI_ARBURST    (m_axi_gmem1_arburst),
        .M_AXI_ARCACHE    (m_axi_gmem1_arcache),
        .M_AXI_ARPROT     (m_axi_gmem1_arprot),
        .M_AXI_ARQOS      (m_axi_gmem1_arqos),
        .M_AXI_ARREADY    (m_axi_gmem1_arready),
        .M_AXI_RDATA      (m_axi_gmem1_rdata),
        .M_AXI_RRESP      (m_axi_gmem1_rresp),
        .M_AXI_RLAST      (m_axi_gmem1_rlast),
        .M_AXI_RVALID     (m_axi_gmem1_rvalid),
        .M_AXI_RREADY     (m_axi_gmem1_rready)
    );

    // =========================================================================
    // Burst write master — OUT (gmem2)
    // =========================================================================
    logic wr_out_start;
    wire  wr_out_done;

    krnl_vadd_wr_mst #(
        .DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDR_WIDTH (C_M_AXI_ADDR_WIDTH)
    ) u_wr_out (
        .clk           (ap_clk),
        .rst_n         (ap_rst_n),
        .start         (wr_out_start),
        .base_addr     (out_ptr_w),
        .num_words     (WORDS_PER_MATRIX),
        .done          (wr_out_done),
        .fifo_rd_en    (wr_fifo_rd_en),
        .fifo_rd_data  (wr_fifo_rd_data),
        .fifo_empty    (wr_fifo_empty),
        .M_AXI_AWVALID (m_axi_gmem2_awvalid),
        .M_AXI_AWADDR  (m_axi_gmem2_awaddr),
        .M_AXI_AWLEN   (m_axi_gmem2_awlen),
        .M_AXI_AWSIZE  (m_axi_gmem2_awsize),
        .M_AXI_AWBURST (m_axi_gmem2_awburst),
        .M_AXI_AWCACHE (m_axi_gmem2_awcache),
        .M_AXI_AWPROT  (m_axi_gmem2_awprot),
        .M_AXI_AWQOS   (m_axi_gmem2_awqos),
        .M_AXI_AWREADY (m_axi_gmem2_awready),
        .M_AXI_WDATA   (m_axi_gmem2_wdata),
        .M_AXI_WSTRB   (m_axi_gmem2_wstrb),
        .M_AXI_WLAST   (m_axi_gmem2_wlast),
        .M_AXI_WVALID  (m_axi_gmem2_wvalid),
        .M_AXI_WREADY  (m_axi_gmem2_wready),
        .M_AXI_BRESP   (m_axi_gmem2_bresp),
        .M_AXI_BVALID  (m_axi_gmem2_bvalid),
        .M_AXI_BREADY  (m_axi_gmem2_bready)
    );

    // =========================================================================
    // matmul_top
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
    // FIFO glue — bridge matmul_top's sequential memory port to preloaded FIFOs
    //
    // W reads:  matmul_top addr in [addr_w_word, addr_w_word+63] → w_rd_fifo
    // X reads:  otherwise                                        → x_rd_fifo
    // OUT writes: all → wr_fifo (burst write dispatched after mt_done)
    //
    // Timing: mem_rd_en fires, FIFO head is captured and mem_rsp_valid is
    // asserted one cycle later. FIFO rd_en is combinational so rptr advances
    // at the same posedge — the next FIFO head is ready for the next request.
    // =========================================================================
    wire [31:0] w_offs     = mt_mem_addr - addr_w_word;
    wire        is_w_range = (w_offs < WORDS_PER_MATRIX[31:0]);

    assign w_fifo_rd_en  = mt_mem_rd_en &&  is_w_range;
    assign x_fifo_rd_en  = mt_mem_rd_en && !is_w_range;
    assign wr_fifo_wr_en   = mt_mem_wr_en;
    assign wr_fifo_wr_data = mt_mem_wr_data;

    always_ff @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            mt_mem_rd_data   <= '0;
            mt_mem_rsp_valid <= 1'b0;
            mt_mem_wr_done   <= 1'b0;
        end else begin
            mt_mem_rsp_valid <= 1'b0;
            mt_mem_wr_done   <= 1'b0;
            if (mt_mem_rd_en) begin
                mt_mem_rd_data   <= is_w_range ? w_fifo_rd_data : x_fifo_rd_data;
                mt_mem_rsp_valid <= 1'b1;
            end
            if (mt_mem_wr_en)
                mt_mem_wr_done <= 1'b1;
        end
    end

    // =========================================================================
    // Kernel sequencer FSM
    // =========================================================================
    localparam [2:0] KS_IDLE       = 3'd0,
                     KS_BURST_RD_W = 3'd1,
                     KS_BURST_RD_X = 3'd2,
                     KS_MT_START   = 3'd3,
                     KS_MT_RUN     = 3'd4,
                     KS_BURST_WR   = 3'd5,
                     KS_DONE       = 3'd6;

    logic [2:0] ks_state;
    logic       ap_start_prev;
    wire        start_rise = ap_start_w && !ap_start_prev;

    assign ap_idle_w = (ks_state == KS_IDLE);

    always_ff @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            ks_state      <= KS_IDLE;
            ap_start_prev <= 1'b0;
            ap_done_w     <= 1'b0;
            mt_start      <= 1'b0;
            rd_w_start    <= 1'b0;
            rd_x_start    <= 1'b0;
            wr_out_start  <= 1'b0;
            fifo_flush    <= 1'b0;
        end else begin
            ap_start_prev <= ap_start_w;
            ap_done_w     <= 1'b0;
            mt_start      <= 1'b0;
            rd_w_start    <= 1'b0;
            rd_x_start    <= 1'b0;
            wr_out_start  <= 1'b0;
            fifo_flush    <= 1'b0;

            case (ks_state)
                KS_IDLE: if (start_rise) begin
                    fifo_flush <= 1'b1;   // clear stale FIFO state
                    rd_w_start <= 1'b1;   // both take effect next posedge;
                    ks_state   <= KS_BURST_RD_W; // FIFO clears before rd_mst writes
                end

                KS_BURST_RD_W: if (rd_w_done) begin
                    rd_x_start <= 1'b1;
                    ks_state   <= KS_BURST_RD_X;
                end

                KS_BURST_RD_X: if (rd_x_done) begin
                    ks_state <= KS_MT_START;
                end

                KS_MT_START: begin
                    mt_start <= 1'b1;
                    ks_state <= KS_MT_RUN;
                end

                KS_MT_RUN: if (mt_done) begin
                    wr_out_start <= 1'b1;
                    ks_state     <= KS_BURST_WR;
                end

                KS_BURST_WR: if (wr_out_done) begin
                    ks_state <= KS_DONE;
                end

                KS_DONE: begin
                    ap_done_w <= 1'b1;
                    ks_state  <= KS_IDLE;
                end

                default: ks_state <= KS_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Unused AXI channel tie-offs
    // =========================================================================

    // gmem0 write channels (W is read-only)
    assign m_axi_gmem0_awvalid = 1'b0;
    assign m_axi_gmem0_awaddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem0_awlen   = 8'd0;
    assign m_axi_gmem0_awsize  = 3'b110;
    assign m_axi_gmem0_awburst = 2'b01;
    assign m_axi_gmem0_awcache = 4'b0000;
    assign m_axi_gmem0_awprot  = 3'b000;
    assign m_axi_gmem0_awqos   = 4'b0000;
    assign m_axi_gmem0_wvalid  = 1'b0;
    assign m_axi_gmem0_wdata   = {C_M_AXI_DATA_WIDTH{1'b0}};
    assign m_axi_gmem0_wstrb   = {(C_M_AXI_DATA_WIDTH/8){1'b0}};
    assign m_axi_gmem0_wlast   = 1'b0;
    assign m_axi_gmem0_bready  = 1'b1;

    // gmem1 write channels (X is read-only)
    assign m_axi_gmem1_awvalid = 1'b0;
    assign m_axi_gmem1_awaddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem1_awlen   = 8'd0;
    assign m_axi_gmem1_awsize  = 3'b110;
    assign m_axi_gmem1_awburst = 2'b01;
    assign m_axi_gmem1_awcache = 4'b0000;
    assign m_axi_gmem1_awprot  = 3'b000;
    assign m_axi_gmem1_awqos   = 4'b0000;
    assign m_axi_gmem1_wvalid  = 1'b0;
    assign m_axi_gmem1_wdata   = {C_M_AXI_DATA_WIDTH{1'b0}};
    assign m_axi_gmem1_wstrb   = {(C_M_AXI_DATA_WIDTH/8){1'b0}};
    assign m_axi_gmem1_wlast   = 1'b0;
    assign m_axi_gmem1_bready  = 1'b1;

    // gmem2 read channels (OUT is write-only)
    assign m_axi_gmem2_arvalid = 1'b0;
    assign m_axi_gmem2_araddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem2_arlen   = 8'd0;
    assign m_axi_gmem2_arsize  = 3'b110;
    assign m_axi_gmem2_arburst = 2'b01;
    assign m_axi_gmem2_arcache = 4'b0000;
    assign m_axi_gmem2_arprot  = 3'b000;
    assign m_axi_gmem2_arqos   = 4'b0000;
    assign m_axi_gmem2_rready  = 1'b0;

endmodule
