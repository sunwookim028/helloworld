// ============================================================================
// krnl_vadd_ctrl.v — AXI4-Lite slave for krnl_vadd RTL kernel
//
// Adapted from minitpu tpu_slave_axi_lite.v. Same state-machine structure;
// register layout replaced with Vitis ap_ctrl_hs standard layout.
//
// Register map (byte offsets, 32-bit words):
//   0x00  ap_ctrl     [0]=ap_start (RW/SC), [1]=ap_done (RO/COR), [2]=ap_idle (RO)
//   0x04  gier        (global interrupt enable, unused)
//   0x08  ip_ier      (interrupt enable, unused)
//   0x0C  ip_isr      (interrupt status, unused)
//   0x10  in1[31:0]   base address of in1 (low word)
//   0x14  in1[63:32]  base address of in1 (high word)
//   0x18  in2[31:0]   base address of in2 (low word, unused by kernel logic)
//   0x1C  in2[63:32]  base address of in2 (high word, unused by kernel logic)
//   0x20  out_r[31:0] base address of out (low word)
//   0x24  out_r[63:32]base address of out (high word)
//   0x28  size        number of 32-bit elements to process
//
// ap_ctrl_hs protocol:
//   - Host writes ap_start=1 to begin kernel execution.
//   - Hardware clears ap_start and sets ap_done when execution finishes.
//   - ap_done is sticky; it is cleared when the host reads 0x00 (COR).
//   - ap_idle reflects the idle state of the data path.
// ============================================================================

`timescale 1 ns / 1 ps

module krnl_vadd_ctrl #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 7    // covers 0x00..0x28 (7 bits = 0..127)
)(
    // User ports — kernel control signals
    output wire        ap_start,
    input  wire        ap_done,
    input  wire        ap_idle,
    output wire [63:0] in1_ptr,
    output wire [63:0] in2_ptr,
    output wire [63:0] out_ptr,
    output wire [31:0] size,

    // AXI4-Lite slave interface
    input  wire                            S_AXI_ACLK,
    input  wire                            S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  S_AXI_AWADDR,
    input  wire [2:0]                      S_AXI_AWPROT,
    input  wire                            S_AXI_AWVALID,
    output wire                            S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]  S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                            S_AXI_WVALID,
    output wire                            S_AXI_WREADY,
    output wire [1:0]                      S_AXI_BRESP,
    output wire                            S_AXI_BVALID,
    input  wire                            S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  S_AXI_ARADDR,
    input  wire [2:0]                      S_AXI_ARPROT,
    input  wire                            S_AXI_ARVALID,
    output wire                            S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]  S_AXI_RDATA,
    output wire [1:0]                      S_AXI_RRESP,
    output wire                            S_AXI_RVALID,
    input  wire                            S_AXI_RREADY
);

    // =========================================================================
    // AXI4-Lite internal signals (same pattern as tpu_slave_axi_lite.v)
    // =========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg axi_awready;
    reg axi_wready;
    reg [1:0] axi_bresp;
    reg axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg axi_arready;
    reg [1:0] axi_rresp;
    reg axi_rvalid;

    // ADDR_LSB = 2 for 32-bit data width (byte → word addressing)
    // OPT_MEM_ADDR_BITS = 3 → 4-bit register index (addr[5:2]), covers 16 regs
    localparam integer ADDR_LSB          = (C_S_AXI_DATA_WIDTH/32) + 1; // = 2
    localparam integer OPT_MEM_ADDR_BITS = 3;                            // 4-bit index

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // =========================================================================
    // Register file
    // =========================================================================
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_ap_ctrl;   // 0x00 — ap_ctrl_hs
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_gier;       // 0x04
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_ip_ier;     // 0x08
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_ip_isr;     // 0x0C
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_in1_lo;     // 0x10
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_in1_hi;     // 0x14
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_in2_lo;     // 0x18
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_in2_hi;     // 0x1C
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_out_lo;     // 0x20
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_out_hi;     // 0x24
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_size;       // 0x28

    // Sticky ap_done bit (set by hardware, cleared on host read)
    reg ap_done_sticky;

    // ap_ctrl_hs bit assignments
    // reg_ap_ctrl[0] = ap_start (host write, hardware self-clear on ap_done)
    // reg_ap_ctrl[1] = ap_done  (hardware set, COR on host read of 0x00)
    // reg_ap_ctrl[2] = ap_idle  (read-only, reflects ap_idle input)
    assign ap_start = reg_ap_ctrl[0];
    assign in1_ptr  = {reg_in1_hi, reg_in1_lo};
    assign in2_ptr  = {reg_in2_hi, reg_in2_lo};
    assign out_ptr  = {reg_out_hi, reg_out_lo};
    assign size     = reg_size;

    // =========================================================================
    // Write channel — Xilinx parallel-wait pattern (replaces old state_write FSM)
    //
    // Hold AWREADY and WREADY low until both AWVALID and WVALID are present,
    // then pulse both high for one cycle.  This eliminates the race where W
    // data arrives before AW address.  Both handshakes complete simultaneously,
    // so the address is always valid when the register is written.
    // =========================================================================
    reg aw_en;  // set after BVALID handshake, prevents double-accept

    wire slv_reg_wren = axi_wready  && S_AXI_WVALID &&
                        axi_awready && S_AXI_AWVALID;

    // Read FSM state and localparams (shared Idle encoding)
    reg [1:0] state_read;
    localparam Idle  = 2'b00;
    localparam Raddr = 2'b10;
    localparam Rdata = 2'b11;

    integer byte_index;

    // AWREADY: pulse high for one cycle when both channels are valid
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                axi_awready <= 1'b1;
                aw_en       <= 1'b0;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                aw_en       <= 1'b1;
                axi_awready <= 1'b0;
            end else begin
                axi_awready <= 1'b0;
            end
        end
    end

    // Latch write address on AW handshake
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_awaddr <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
            axi_awaddr <= S_AXI_AWADDR;
    end

    // WREADY: mirrors AWREADY timing exactly
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    // BVALID: assert after both handshakes, deassert on BREADY
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else begin
            if (slv_reg_wren && ~axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b0;  // OKAY
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Register write logic
    // =========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            reg_ap_ctrl <= 32'd0;
            reg_gier    <= 32'd0;
            reg_ip_ier  <= 32'd0;
            reg_ip_isr  <= 32'd0;
            reg_in1_lo  <= 32'd0;
            reg_in1_hi  <= 32'd0;
            reg_in2_lo  <= 32'd0;
            reg_in2_hi  <= 32'd0;
            reg_out_lo  <= 32'd0;
            reg_out_hi  <= 32'd0;
            reg_size    <= 32'd0;
        end else begin
            // Self-clear ap_start when hardware signals ap_done
            if (ap_done) reg_ap_ctrl[0] <= 1'b0;

            if (slv_reg_wren) begin
                case (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
                    4'h0: // 0x00 ap_ctrl — only bit 0 (ap_start) is writable
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_ap_ctrl[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h1: // 0x04 gier
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_gier[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h2: // 0x08 ip_ier
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_ip_ier[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h3: // 0x0C ip_isr
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_ip_isr[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h4: // 0x10 in1[31:0]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_in1_lo[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h5: // 0x14 in1[63:32]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_in1_hi[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h6: // 0x18 in2[31:0]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_in2_lo[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h7: // 0x1C in2[63:32]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_in2_hi[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h8: // 0x20 out_r[31:0]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_out_lo[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'h9: // 0x24 out_r[63:32]
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_out_hi[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    4'hA: // 0x28 size
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if (S_AXI_WSTRB[byte_index])
                                reg_size[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // ap_done sticky bit — set by hardware, cleared on host read of 0x00
    // =========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            ap_done_sticky <= 1'b0;
        else if (ap_done)
            ap_done_sticky <= 1'b1;
        else if (axi_rvalid && S_AXI_RREADY &&
                 axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h0)
            ap_done_sticky <= 1'b0;  // COR: cleared on host read of ap_ctrl
    end

    // =========================================================================
    // Read state machine (identical structure to tpu_slave_axi_lite.v)
    // =========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 1'b0;
            state_read  <= Idle;
        end else begin
            case (state_read)
                Idle:
                    if (S_AXI_ARESETN == 1'b1) begin
                        state_read  <= Raddr;
                        axi_arready <= 1'b1;
                    end
                Raddr:
                    if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                        state_read  <= Rdata;
                        axi_araddr  <= S_AXI_ARADDR;
                        axi_rvalid  <= 1'b1;
                        axi_arready <= 1'b0;
                    end
                Rdata:
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        axi_rvalid  <= 1'b0;
                        axi_arready <= 1'b1;
                        state_read  <= Raddr;
                    end
            endcase
        end
    end

    // =========================================================================
    // Read data mux — ap_ctrl reflects live hardware status bits
    // =========================================================================
    wire [31:0] ap_ctrl_live = {29'b0, ap_idle, ap_done_sticky, reg_ap_ctrl[0]};

    assign S_AXI_RDATA =
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h0) ? ap_ctrl_live  :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h1) ? reg_gier      :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h2) ? reg_ip_ier    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h3) ? reg_ip_isr    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h4) ? reg_in1_lo    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h5) ? reg_in1_hi    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h6) ? reg_in2_lo    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h7) ? reg_in2_hi    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h8) ? reg_out_lo    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h9) ? reg_out_hi    :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'hA) ? reg_size      :
        32'd0;

endmodule
