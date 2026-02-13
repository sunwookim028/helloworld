// HBM Loopback Module for V80 FPGA
// Simple PCIe-to-HBM loopback test module
//
// This module provides a simple register interface accessible from PCIe
// and implements a state machine to write/read data to/from HBM memory.
//
// Register Map (AXI-Lite Slave):
//   0x00: CTRL_DATA  - Write test data here to trigger loopback
//   0x04: STATUS     - Read back data from HBM
//   0x08: STATE      - Current FSM state (for debugging)
//   0x0C: ERROR      - Error flags
//
// Operation:
//   1. Host writes test value to CTRL_DATA register
//   2. Module writes value to HBM at fixed address
//   3. Module reads value back from HBM
//   4. Module stores result in STATUS register
//   5. Host reads STATUS register to verify

module hbm_loopback #(
    parameter HBM_ADDR_WIDTH = 34,          // HBM address width
    parameter HBM_DATA_WIDTH = 256,         // HBM data width (256-bit AXI)
    parameter HBM_BASE_ADDR  = 34'h4_0000_0000  // HBM base: 0x004000000000
)(
    // Clock and Reset
    input  wire                         aclk,
    input  wire                         aresetn,
    
    // AXI-Lite Slave Interface (for PCIe host access)
    input  wire [31:0]                  s_axil_awaddr,
    input  wire                         s_axil_awvalid,
    output wire                         s_axil_awready,
    input  wire [31:0]                  s_axil_wdata,
    input  wire [3:0]                   s_axil_wstrb,
    input  wire                         s_axil_wvalid,
    output wire                         s_axil_wready,
    output wire [1:0]                   s_axil_bresp,
    output wire                         s_axil_bvalid,
    input  wire                         s_axil_bready,
    input  wire [31:0]                  s_axil_araddr,
    input  wire                         s_axil_arvalid,
    output wire                         s_axil_arready,
    output wire [31:0]                  s_axil_rdata,
    output wire [1:0]                   s_axil_rresp,
    output wire                         s_axil_rvalid,
    input  wire                         s_axil_rready,
    
    // AXI4 Master Interface (for HBM access)
    output wire [HBM_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,
    output wire                         m_axi_awvalid,
    input  wire                         m_axi_awready,
    output wire [HBM_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [HBM_DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output wire                         m_axi_wlast,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready,
    output wire [HBM_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]                   m_axi_arlen,
    output wire [2:0]                   m_axi_arsize,
    output wire [1:0]                   m_axi_arburst,
    output wire                         m_axi_arvalid,
    input  wire                         m_axi_arready,
    input  wire [HBM_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output wire                         m_axi_rready
);

    // FSM States
    localparam [2:0] IDLE       = 3'd0,
                     WRITE_ADDR = 3'd1,
                     WRITE_DATA = 3'd2,
                     WRITE_RESP = 3'd3,
                     READ_ADDR  = 3'd4,
                     READ_DATA  = 3'd5,
                     DONE       = 3'd6;

    // Internal Registers
    reg [31:0]  ctrl_data_reg;
    reg [31:0]  status_reg;
    reg [2:0]   state_reg;
    reg [31:0]  error_reg;
    
    // FSM
    reg [2:0]   current_state;
    reg [2:0]   next_state;
    
    // AXI-Lite Write
    reg         axil_awready_reg;
    reg         axil_wready_reg;
    reg         axil_bvalid_reg;
    
    // AXI-Lite Read
    reg         axil_arready_reg;
    reg [31:0]  axil_rdata_reg;
    reg         axil_rvalid_reg;
    
    // AXI4 Master signals
    reg                         axi_awvalid_reg;
    reg                         axi_wvalid_reg;
    reg                         axi_bready_reg;
    reg                         axi_arvalid_reg;
    reg                         axi_rready_reg;
    reg [HBM_DATA_WIDTH-1:0]    write_data_reg;
    
    // Trigger signal
    wire write_trigger;
    reg  write_trigger_d;
    
    assign write_trigger = (s_axil_awvalid && s_axil_awready && s_axil_awaddr[7:0] == 8'h00);
    
    //==========================================================================
    // AXI-Lite Slave Interface Logic
    //==========================================================================
    
    // Write Address Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axil_awready_reg <= 1'b0;
        else
            axil_awready_reg <= !axil_awready_reg && s_axil_awvalid && s_axil_wvalid;
    end
    
    // Write Data Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axil_wready_reg <= 1'b0;
        else
            axil_wready_reg <= !axil_wready_reg && s_axil_awvalid && s_axil_wvalid;
    end
    
    // Write Response Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axil_bvalid_reg <= 1'b0;
        else if (axil_awready_reg && axil_wready_reg)
            axil_bvalid_reg <= 1'b1;
        else if (s_axil_bready)
            axil_bvalid_reg <= 1'b0;
    end
    
    // Register Writes
    always @(posedge aclk) begin
        if (!aresetn) begin
            ctrl_data_reg <= 32'h0;
        end else if (axil_awready_reg && axil_wready_reg) begin
            case (s_axil_awaddr[7:0])
                8'h00: ctrl_data_reg <= s_axil_wdata;
                default: ;
            endcase
        end
    end
    
    // Read Address Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axil_arready_reg <= 1'b0;
        else
            axil_arready_reg <= !axil_arready_reg && s_axil_arvalid;
    end
    
    // Read Data Channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            axil_rvalid_reg <= 1'b0;
            axil_rdata_reg  <= 32'h0;
        end else if (axil_arready_reg) begin
            axil_rvalid_reg <= 1'b1;
            case (s_axil_araddr[7:0])
                8'h00: axil_rdata_reg <= ctrl_data_reg;
                8'h04: axil_rdata_reg <= status_reg;
                8'h08: axil_rdata_reg <= {29'h0, state_reg};
                8'h0C: axil_rdata_reg <= error_reg;
                default: axil_rdata_reg <= 32'hDEADDEAD;
            endcase
        end else if (s_axil_rready) begin
            axil_rvalid_reg <= 1'b0;
        end
    end
    
    assign s_axil_awready = axil_awready_reg;
    assign s_axil_wready  = axil_wready_reg;
    assign s_axil_bresp   = 2'b00;  // OKAY
    assign s_axil_bvalid  = axil_bvalid_reg;
    assign s_axil_arready = axil_arready_reg;
    assign s_axil_rdata   = axil_rdata_reg;
    assign s_axil_rresp   = 2'b00;  // OKAY
    assign s_axil_rvalid  = axil_rvalid_reg;
    
    //==========================================================================
    // FSM for HBM Write/Read
    //==========================================================================
    
    always @(posedge aclk) begin
        if (!aresetn)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end
    
    always @(posedge aclk) begin
        write_trigger_d <= write_trigger;
    end
    
    always @(*) begin
        next_state = current_state;
        case (current_state)
            IDLE: begin
                if (write_trigger && !write_trigger_d)
                    next_state = WRITE_ADDR;
            end
            WRITE_ADDR: begin
                if (m_axi_awready)
                    next_state = WRITE_DATA;
            end
            WRITE_DATA: begin
                if (m_axi_wready)
                    next_state = WRITE_RESP;
            end
            WRITE_RESP: begin
                if (m_axi_bvalid)
                    next_state = READ_ADDR;
            end
            READ_ADDR: begin
                if (m_axi_arready)
                    next_state = READ_DATA;
            end
            READ_DATA: begin
                if (m_axi_rvalid)
                    next_state = DONE;
            end
            DONE: begin
                next_state = IDLE;
            end
        endcase
    end
    
    // State register for debugging
    always @(posedge aclk) begin
        if (!aresetn)
            state_reg <= 3'h0;
        else
            state_reg <= current_state;
    end
    
    // AXI4 Write Address Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axi_awvalid_reg <= 1'b0;
        else if (current_state == WRITE_ADDR && !axi_awvalid_reg)
            axi_awvalid_reg <= 1'b1;
        else if (m_axi_awready)
            axi_awvalid_reg <= 1'b0;
    end
    
    // AXI4 Write Data Channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_wvalid_reg <= 1'b0;
            write_data_reg <= {HBM_DATA_WIDTH{1'b0}};
        end else if (current_state == WRITE_DATA && !axi_wvalid_reg) begin
            axi_wvalid_reg <= 1'b1;
            // Replicate 32-bit data across 256-bit bus for simplicity
            write_data_reg <= {{(HBM_DATA_WIDTH-32){1'b0}}, ctrl_data_reg};
        end else if (m_axi_wready) begin
            axi_wvalid_reg <= 1'b0;
        end
    end
    
    // AXI4 Write Response Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axi_bready_reg <= 1'b0;
        else if (current_state == WRITE_RESP)
            axi_bready_reg <= 1'b1;
        else
            axi_bready_reg <= 1'b0;
    end
    
    // AXI4 Read Address Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axi_arvalid_reg <= 1'b0;
        else if (current_state == READ_ADDR && !axi_arvalid_reg)
            axi_arvalid_reg <= 1'b1;
        else if (m_axi_arready)
            axi_arvalid_reg <= 1'b0;
    end
    
    // AXI4 Read Data Channel
    always @(posedge aclk) begin
        if (!aresetn)
            axi_rready_reg <= 1'b0;
        else if (current_state == READ_DATA)
            axi_rready_reg <= 1'b1;
        else
            axi_rready_reg <= 1'b0;
    end
    
    // Status Register - capture read data
    always @(posedge aclk) begin
        if (!aresetn)
            status_reg <= 32'h0;
        else if (m_axi_rvalid && axi_rready_reg)
            status_reg <= m_axi_rdata[31:0];  // Take lower 32 bits
    end
    
    // Error Register - capture AXI errors
    always @(posedge aclk) begin
        if (!aresetn)
            error_reg <= 32'h0;
        else begin
            if (m_axi_bvalid && m_axi_bresp != 2'b00)
                error_reg[0] <= 1'b1;  // Write error
            if (m_axi_rvalid && m_axi_rresp != 2'b00)
                error_reg[1] <= 1'b1;  // Read error
        end
    end
    
    //==========================================================================
    // AXI4 Master Interface Outputs
    //==========================================================================
    
    assign m_axi_awaddr  = HBM_BASE_ADDR;
    assign m_axi_awlen   = 8'h00;      // 1 beat
    assign m_axi_awsize  = 3'b101;     // 32 bytes (256 bits)
    assign m_axi_awburst = 2'b01;      // INCR
    assign m_axi_awvalid = axi_awvalid_reg;
    
    assign m_axi_wdata   = write_data_reg;
    assign m_axi_wstrb   = {(HBM_DATA_WIDTH/8){1'b1}};  // All bytes valid
    assign m_axi_wlast   = 1'b1;       // Single beat
    assign m_axi_wvalid  = axi_wvalid_reg;
    
    assign m_axi_bready  = axi_bready_reg;
    
    assign m_axi_araddr  = HBM_BASE_ADDR;
    assign m_axi_arlen   = 8'h00;      // 1 beat
    assign m_axi_arsize  = 3'b101;     // 32 bytes (256 bits)
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_arvalid = axi_arvalid_reg;
    
    assign m_axi_rready  = axi_rready_reg;

endmodule
