// ============================================================================
// krnl_vadd.sv — RTL kernel top-level for HBM Data Mover
//
// Replaces the HLS C krnl_vadd.cpp with equivalent RTL.
// Functional equivalence: reads num_words 512-bit words from in1, writes to out.
//   num_words = size / 16  (size is in 32-bit elements; one 512-bit word = 16)
//
// Architecture:
//   krnl_vadd_ctrl   — AXI4-Lite slave, ap_ctrl_hs register map
//   krnl_vadd_rd_mst — AXI4 burst read master  → fifo4 → krnl_vadd_wr_mst
//   krnl_vadd_wr_mst — AXI4 burst write master
//   fifo4            — 512-bit FWFT FIFO (depth=64, from minitpu)
//
// Vitis port naming conventions (required for kernel.xml / shell auto-connect):
//   ap_clk, ap_rst_n                                       — clock / reset
//   s_axi_control_*                                        — AXI4-Lite slave
//   m_axi_gmem0_* (in1), m_axi_gmem1_* (in2), m_axi_gmem2_* (out_r) — AXI4 masters
//
// in2 (m_axi_gmem1) is never accessed by the kernel logic (same as HLS original);
// its port is present for XRT interface compatibility and is tied inactive.
// ============================================================================

`timescale 1 ns / 1 ps

module krnl_vadd #(
    parameter integer C_S_AXI_CTRL_DATA_WIDTH = 32,
    parameter integer C_S_AXI_CTRL_ADDR_WIDTH = 7,
    parameter integer C_M_AXI_DATA_WIDTH      = 512,
    parameter integer C_M_AXI_ADDR_WIDTH      = 64
)(
    // Global clock and reset
    input  wire ap_clk,
    input  wire ap_rst_n,

    // AXI4-Lite control slave (s_axi_control)
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_control_awaddr,
    input  wire [2:0]                          s_axi_control_awprot,
    input  wire                                s_axi_control_awvalid,
    output wire                                s_axi_control_awready,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_control_wdata,
    input  wire [(C_S_AXI_CTRL_DATA_WIDTH/8)-1:0] s_axi_control_wstrb,
    input  wire                                s_axi_control_wvalid,
    output wire                                s_axi_control_wready,
    output wire [1:0]                          s_axi_control_bresp,
    output wire                                s_axi_control_bvalid,
    input  wire                                s_axi_control_bready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_control_araddr,
    input  wire [2:0]                          s_axi_control_arprot,
    input  wire                                s_axi_control_arvalid,
    output wire                                s_axi_control_arready,
    output wire [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_control_rdata,
    output wire [1:0]                          s_axi_control_rresp,
    output wire                                s_axi_control_rvalid,
    input  wire                                s_axi_control_rready,

    // AXI4 master — gmem0 (in1, READ only)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem0_araddr,
    output wire [7:0]                          m_axi_gmem0_arlen,
    output wire [2:0]                          m_axi_gmem0_arsize,
    output wire [1:0]                          m_axi_gmem0_arburst,
    output wire [3:0]                          m_axi_gmem0_arcache,
    output wire [2:0]                          m_axi_gmem0_arprot,
    output wire [3:0]                          m_axi_gmem0_arqos,
    output wire                                m_axi_gmem0_arvalid,
    input  wire                                m_axi_gmem0_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem0_rdata,
    input  wire [1:0]                          m_axi_gmem0_rresp,
    input  wire                                m_axi_gmem0_rlast,
    input  wire                                m_axi_gmem0_rvalid,
    output wire                                m_axi_gmem0_rready,
    // gmem0 write channels — tied off (read-only port)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem0_awaddr,
    output wire [7:0]                          m_axi_gmem0_awlen,
    output wire [2:0]                          m_axi_gmem0_awsize,
    output wire [1:0]                          m_axi_gmem0_awburst,
    output wire [3:0]                          m_axi_gmem0_awcache,
    output wire [2:0]                          m_axi_gmem0_awprot,
    output wire [3:0]                          m_axi_gmem0_awqos,
    output wire                                m_axi_gmem0_awvalid,
    input  wire                                m_axi_gmem0_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem0_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0]  m_axi_gmem0_wstrb,
    output wire                                m_axi_gmem0_wlast,
    output wire                                m_axi_gmem0_wvalid,
    input  wire                                m_axi_gmem0_wready,
    input  wire [1:0]                          m_axi_gmem0_bresp,
    input  wire                                m_axi_gmem0_bvalid,
    output wire                                m_axi_gmem0_bready,

    // AXI4 master — gmem1 (in2, UNUSED — tied inactive)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem1_araddr,
    output wire [7:0]                          m_axi_gmem1_arlen,
    output wire [2:0]                          m_axi_gmem1_arsize,
    output wire [1:0]                          m_axi_gmem1_arburst,
    output wire [3:0]                          m_axi_gmem1_arcache,
    output wire [2:0]                          m_axi_gmem1_arprot,
    output wire [3:0]                          m_axi_gmem1_arqos,
    output wire                                m_axi_gmem1_arvalid,
    input  wire                                m_axi_gmem1_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem1_rdata,
    input  wire [1:0]                          m_axi_gmem1_rresp,
    input  wire                                m_axi_gmem1_rlast,
    input  wire                                m_axi_gmem1_rvalid,
    output wire                                m_axi_gmem1_rready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem1_awaddr,
    output wire [7:0]                          m_axi_gmem1_awlen,
    output wire [2:0]                          m_axi_gmem1_awsize,
    output wire [1:0]                          m_axi_gmem1_awburst,
    output wire [3:0]                          m_axi_gmem1_awcache,
    output wire [2:0]                          m_axi_gmem1_awprot,
    output wire [3:0]                          m_axi_gmem1_awqos,
    output wire                                m_axi_gmem1_awvalid,
    input  wire                                m_axi_gmem1_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem1_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0]  m_axi_gmem1_wstrb,
    output wire                                m_axi_gmem1_wlast,
    output wire                                m_axi_gmem1_wvalid,
    input  wire                                m_axi_gmem1_wready,
    input  wire [1:0]                          m_axi_gmem1_bresp,
    input  wire                                m_axi_gmem1_bvalid,
    output wire                                m_axi_gmem1_bready,

    // AXI4 master — gmem2 (out_r, WRITE only)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem2_awaddr,
    output wire [7:0]                          m_axi_gmem2_awlen,
    output wire [2:0]                          m_axi_gmem2_awsize,
    output wire [1:0]                          m_axi_gmem2_awburst,
    output wire [3:0]                          m_axi_gmem2_awcache,
    output wire [2:0]                          m_axi_gmem2_awprot,
    output wire [3:0]                          m_axi_gmem2_awqos,
    output wire                                m_axi_gmem2_awvalid,
    input  wire                                m_axi_gmem2_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem2_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0]  m_axi_gmem2_wstrb,
    output wire                                m_axi_gmem2_wlast,
    output wire                                m_axi_gmem2_wvalid,
    input  wire                                m_axi_gmem2_wready,
    input  wire [1:0]                          m_axi_gmem2_bresp,
    input  wire                                m_axi_gmem2_bvalid,
    output wire                                m_axi_gmem2_bready,
    // gmem2 read channels — tied off (write-only port)
    output wire [C_M_AXI_ADDR_WIDTH-1:0]      m_axi_gmem2_araddr,
    output wire [7:0]                          m_axi_gmem2_arlen,
    output wire [2:0]                          m_axi_gmem2_arsize,
    output wire [1:0]                          m_axi_gmem2_arburst,
    output wire [3:0]                          m_axi_gmem2_arcache,
    output wire [2:0]                          m_axi_gmem2_arprot,
    output wire [3:0]                          m_axi_gmem2_arqos,
    output wire                                m_axi_gmem2_arvalid,
    input  wire                                m_axi_gmem2_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]      m_axi_gmem2_rdata,
    input  wire [1:0]                          m_axi_gmem2_rresp,
    input  wire                                m_axi_gmem2_rlast,
    input  wire                                m_axi_gmem2_rvalid,
    output wire                                m_axi_gmem2_rready
);

    // =========================================================================
    // Control signals from AXI-Lite register file
    // =========================================================================
    wire        ap_start_w;
    wire        ap_done_w;
    wire        ap_idle_w;
    wire [63:0] in1_ptr_w;
    wire [63:0] in2_ptr_w;   // registered but not used by masters
    wire [63:0] out_ptr_w;
    wire [31:0] size_w;

    // num_words = size / 16 (512-bit words from 32-bit element count)
    wire [31:0] num_words_w = size_w >> 4;

    // =========================================================================
    // Top-level FSM: IDLE → RUN, pulse ap_done when both masters finish
    // =========================================================================
    localparam [0:0] S_IDLE = 1'b0, S_RUN = 1'b1;
    reg fsm_state;

    // Rising-edge detector on ap_start
    reg ap_start_prev;
    wire start_rise = ap_start_w && !ap_start_prev;

    // Done latches (set by master done pulses, cleared on next start)
    reg rd_done_latch, wr_done_latch;

    // Master start/done signals
    reg  start_masters;  // one-cycle pulse to both masters
    wire rd_done_pulse;
    wire wr_done_pulse;

    // ap_done to ctrl: one-cycle pulse when both masters complete
    reg ap_done_reg;
    assign ap_done_w = ap_done_reg;
    assign ap_idle_w = (fsm_state == S_IDLE);

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            fsm_state    <= S_IDLE;
            ap_start_prev <= 1'b0;
            rd_done_latch <= 1'b0;
            wr_done_latch <= 1'b0;
            start_masters <= 1'b0;
            ap_done_reg   <= 1'b0;
        end else begin
            ap_start_prev <= ap_start_w;
            start_masters <= 1'b0;   // default: no pulse
            ap_done_reg   <= 1'b0;   // default: no pulse

            // Latch master done pulses regardless of state
            if (rd_done_pulse) rd_done_latch <= 1'b1;
            if (wr_done_pulse) wr_done_latch <= 1'b1;

            case (fsm_state)
                S_IDLE: begin
                    if (start_rise) begin
                        // Clear latches, fire start pulse, move to RUN
                        rd_done_latch <= 1'b0;
                        wr_done_latch <= 1'b0;
                        start_masters <= 1'b1;
                        fsm_state     <= S_RUN;
                    end
                end

                S_RUN: begin
                    // Wait for both masters to complete
                    // Account for rd_done_pulse and wr_done_pulse arriving this cycle
                    if ((rd_done_latch || rd_done_pulse) &&
                        (wr_done_latch || wr_done_pulse)) begin
                        ap_done_reg <= 1'b1;
                        fsm_state   <= S_IDLE;
                    end
                end

                default: fsm_state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Data FIFO — 512-bit FWFT FIFO between rd_mst and wr_mst (depth=64)
    // =========================================================================
    wire                       fifo_wr_en;
    wire [C_M_AXI_DATA_WIDTH-1:0] fifo_wr_data;
    wire                       fifo_rd_en;
    wire [C_M_AXI_DATA_WIDTH-1:0] fifo_rd_data;
    wire                       fifo_full;
    wire                       fifo_empty;
    wire                       fifo_almost_full;

    fifo4 #(.WIDTH(C_M_AXI_DATA_WIDTH), .DEPTH(64)) u_fifo (
        .clk         (ap_clk),
        .rst_n       (ap_rst_n),
        .flush       (1'b0),
        .wr_en       (fifo_wr_en),
        .wr_data     (fifo_wr_data),
        .rd_en       (fifo_rd_en),
        .rd_data     (fifo_rd_data),
        .full        (fifo_full),
        .empty       (fifo_empty),
        .almost_full (fifo_almost_full)
    );

    // =========================================================================
    // AXI4-Lite control slave
    // =========================================================================
    krnl_vadd_ctrl #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_CTRL_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_CTRL_ADDR_WIDTH)
    ) u_ctrl (
        .ap_start        (ap_start_w),
        .ap_done         (ap_done_w),
        .ap_idle         (ap_idle_w),
        .in1_ptr         (in1_ptr_w),
        .in2_ptr         (in2_ptr_w),
        .out_ptr         (out_ptr_w),
        .size            (size_w),
        .S_AXI_ACLK      (ap_clk),
        .S_AXI_ARESETN   (ap_rst_n),
        .S_AXI_AWADDR    (s_axi_control_awaddr),
        .S_AXI_AWPROT    (s_axi_control_awprot),
        .S_AXI_AWVALID   (s_axi_control_awvalid),
        .S_AXI_AWREADY   (s_axi_control_awready),
        .S_AXI_WDATA     (s_axi_control_wdata),
        .S_AXI_WSTRB     (s_axi_control_wstrb),
        .S_AXI_WVALID    (s_axi_control_wvalid),
        .S_AXI_WREADY    (s_axi_control_wready),
        .S_AXI_BRESP     (s_axi_control_bresp),
        .S_AXI_BVALID    (s_axi_control_bvalid),
        .S_AXI_BREADY    (s_axi_control_bready),
        .S_AXI_ARADDR    (s_axi_control_araddr),
        .S_AXI_ARPROT    (s_axi_control_arprot),
        .S_AXI_ARVALID   (s_axi_control_arvalid),
        .S_AXI_ARREADY   (s_axi_control_arready),
        .S_AXI_RDATA     (s_axi_control_rdata),
        .S_AXI_RRESP     (s_axi_control_rresp),
        .S_AXI_RVALID    (s_axi_control_rvalid),
        .S_AXI_RREADY    (s_axi_control_rready)
    );

    // =========================================================================
    // AXI4 burst read master — gmem0 (in1)
    // =========================================================================
    krnl_vadd_rd_mst #(
        .DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDR_WIDTH (C_M_AXI_ADDR_WIDTH)
    ) u_rd_mst (
        .clk              (ap_clk),
        .rst_n            (ap_rst_n),
        .start            (start_masters),
        .base_addr        (in1_ptr_w),
        .num_words        (num_words_w),
        .done             (rd_done_pulse),
        .fifo_wr_en       (fifo_wr_en),
        .fifo_wr_data     (fifo_wr_data),
        .fifo_almost_full (fifo_almost_full),
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

    // gmem0 write channels — not used (read-only master)
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

    // =========================================================================
    // AXI4 burst write master — gmem2 (out_r)
    // =========================================================================
    krnl_vadd_wr_mst #(
        .DATA_WIDTH (C_M_AXI_DATA_WIDTH),
        .ADDR_WIDTH (C_M_AXI_ADDR_WIDTH)
    ) u_wr_mst (
        .clk           (ap_clk),
        .rst_n         (ap_rst_n),
        .start         (start_masters),
        .base_addr     (out_ptr_w),
        .num_words     (num_words_w),
        .done          (wr_done_pulse),
        .fifo_rd_en    (fifo_rd_en),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_empty    (fifo_empty),
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

    // gmem2 read channels — not used (write-only master)
    assign m_axi_gmem2_arvalid = 1'b0;
    assign m_axi_gmem2_araddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem2_arlen   = 8'd0;
    assign m_axi_gmem2_arsize  = 3'b110;
    assign m_axi_gmem2_arburst = 2'b01;
    assign m_axi_gmem2_arcache = 4'b1111;
    assign m_axi_gmem2_arprot  = 3'b000;
    assign m_axi_gmem2_arqos   = 4'b0000;
    assign m_axi_gmem2_rready  = 1'b0;

    // =========================================================================
    // gmem1 (in2) — present for XRT interface compatibility, entirely inactive
    // =========================================================================
    assign m_axi_gmem1_arvalid = 1'b0;
    assign m_axi_gmem1_araddr  = {C_M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem1_arlen   = 8'd0;
    assign m_axi_gmem1_arsize  = 3'b110;
    assign m_axi_gmem1_arburst = 2'b01;
    assign m_axi_gmem1_arcache = 4'b1111;
    assign m_axi_gmem1_arprot  = 3'b000;
    assign m_axi_gmem1_arqos   = 4'b0000;
    assign m_axi_gmem1_rready  = 1'b0;
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

endmodule
