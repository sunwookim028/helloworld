// ============================================================================
// krnl_vadd_wr_mst.v — AXI4 burst write master (512-bit, HBM)
//
// Writes num_words × 512-bit words to base_addr via AXI4 burst transactions.
// Bursts are 4KB-boundary-aware (max 64 beats for 64-byte beat width).
// Data is sourced from an external FWFT FIFO.
//
// Modeled after minitpu tpu_master_axi_stream.v (same FWFT FIFO idiom):
//   WVALID and fifo_rd_en are COMBINATIONAL, matching the FWFT FIFO output.
//   This allows back-to-back W-channel beats without pipeline bubbles.
//
// FWFT FIFO connection (matches minitpu fifo4.sv):
//   WDATA    = fifo_rd_data   (combinational, valid when !fifo_empty)
//   WVALID   = !fifo_empty && state==S_W  (combinational)
//   fifo_rd_en = WVALID && M_AXI_WREADY  (combinational — same cycle as handshake)
//
//   At posedge N: handshake captures WDATA = mem[rptr_N]; rd_en fires.
//   At posedge N+1: rptr advances; WDATA = mem[rptr_N+1] available. ✓
//
// FSM: IDLE → AW → W → B → (AW again if more bursts) → DONE
// ============================================================================

`timescale 1 ns / 1 ps

module krnl_vadd_wr_mst #(
    parameter integer DATA_WIDTH = 512,
    parameter integer ADDR_WIDTH = 64
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  start,       // pulse: begin writing
    input  wire [ADDR_WIDTH-1:0] base_addr,   // byte address of first word
    input  wire [31:0]           num_words,   // total 512-bit words to write
    output reg                   done,        // asserted for one cycle when all writes complete

    // Data FIFO read port (FWFT — combinational rd_data when !empty)
    output wire                  fifo_rd_en,    // combinational: dequeue on W handshake
    input  wire [DATA_WIDTH-1:0] fifo_rd_data,
    input  wire                  fifo_empty,

    // AXI4 write master (AW + W + B channels)
    output reg                   M_AXI_AWVALID,
    output reg  [ADDR_WIDTH-1:0] M_AXI_AWADDR,
    output reg  [7:0]            M_AXI_AWLEN,    // beats - 1 (max 63 = 64 beats)
    output wire [2:0]            M_AXI_AWSIZE,   // 3'b110 = 64 bytes/beat
    output wire [1:0]            M_AXI_AWBURST,  // INCR
    output wire [3:0]            M_AXI_AWCACHE,
    output wire [2:0]            M_AXI_AWPROT,
    output wire [3:0]            M_AXI_AWQOS,
    input  wire                  M_AXI_AWREADY,

    output wire [DATA_WIDTH-1:0]   M_AXI_WDATA,    // combinational from FIFO
    output wire [(DATA_WIDTH/8)-1:0] M_AXI_WSTRB,
    output wire                  M_AXI_WLAST,     // combinational
    output wire                  M_AXI_WVALID,    // combinational: !fifo_empty in S_W
    input  wire                  M_AXI_WREADY,

    input  wire [1:0]            M_AXI_BRESP,
    input  wire                  M_AXI_BVALID,
    output wire                  M_AXI_BREADY
);

    // Static AXI4 write channel settings
    assign M_AXI_AWSIZE  = 3'b110;              // 2^6 = 64 bytes per beat (512-bit)
    assign M_AXI_AWBURST = 2'b01;               // INCR
    assign M_AXI_AWCACHE = 4'b1111;             // write-back, R/W allocate (optimal for HBM)
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWQOS   = 4'b0000;
    assign M_AXI_BREADY  = 1'b1;                // always accept write response

    // =========================================================================
    // W channel — combinational (FWFT FIFO idiom, same as minitpu AXI-Stream)
    // =========================================================================
    // WVALID: data is available when FIFO is not empty and we are in S_W
    // WDATA:  always the FIFO head (valid when !empty)
    // WLAST:  last beat of the current burst
    // fifo_rd_en: combinational dequeue — fires same cycle as W handshake so
    //             rptr advances one cycle later and new rd_data is ready. ✓
    localparam [1:0] S_IDLE = 2'd0,
                     S_AW   = 2'd1,
                     S_W    = 2'd2,
                     S_B    = 2'd3;
    reg [1:0] state;

    reg [8:0] beats_left;   // W beats remaining in current burst

    assign M_AXI_WVALID  = (state == S_W) && !fifo_empty;
    assign M_AXI_WDATA   = fifo_rd_data;
    assign M_AXI_WSTRB   = {(DATA_WIDTH/8){1'b1}};
    assign M_AXI_WLAST   = M_AXI_WVALID && (beats_left == 9'd1);
    assign fifo_rd_en    = M_AXI_WVALID && M_AXI_WREADY;

    // =========================================================================
    // Tracking registers
    // =========================================================================
    reg [ADDR_WIDTH-1:0] wr_addr;        // current burst byte address
    reg [31:0]           words_done;     // total 512-bit words written so far
    reg [8:0]            burst_len;      // current burst length in beats (1-64)

    // =========================================================================
    // 4KB-boundary-aware burst length computation
    // AXI4 bursts must not cross 4KB address boundaries.  For 64-byte beats
    // (AWSIZE=110): max beats = min(4096/64, (4096 - addr[11:0])/64) = max 64.
    // =========================================================================

    // First burst (used in S_IDLE on start): cap based on base_addr alignment
    wire [12:0] first_bytes_to_4k = 13'h1000 - {1'b0, base_addr[11:0]};
    wire [8:0]  first_beats_to_4k = first_bytes_to_4k[12:6];
    wire [8:0]  first_addr_cap    = (first_beats_to_4k < 9'd64) ? first_beats_to_4k : 9'd64;
    wire [8:0]  first_burst_len   = (num_words > {23'b0, first_addr_cap}) ?
                                     first_addr_cap : num_words[8:0];

    // Subsequent bursts (used on BVALID): cap based on next address after current burst
    wire [ADDR_WIDTH-1:0] next_addr        = wr_addr + ({23'b0, burst_len} << 6);
    wire [31:0]           next_remaining   = num_words - (words_done + {23'b0, burst_len});
    wire [12:0]           next_bytes_to_4k = 13'h1000 - {1'b0, next_addr[11:0]};
    wire [8:0]            next_beats_to_4k = next_bytes_to_4k[12:6];
    wire [8:0]            next_addr_cap    = (next_beats_to_4k < 9'd64) ? next_beats_to_4k : 9'd64;
    wire [8:0]            next_burst_len   = (next_remaining > {23'b0, next_addr_cap}) ?
                                              next_addr_cap : next_remaining[8:0];

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            wr_addr       <= {ADDR_WIDTH{1'b0}};
            words_done    <= 32'd0;
            burst_len     <= 9'd0;
            beats_left    <= 9'd0;
            done          <= 1'b0;
            M_AXI_AWVALID <= 1'b0;
            M_AXI_AWADDR  <= {ADDR_WIDTH{1'b0}};
            M_AXI_AWLEN   <= 8'd0;
        end else begin
            done <= 1'b0;  // default: pulse only

            case (state)
                // =============================================================
                // IDLE: wait for start pulse, compute first burst
                // =============================================================
                S_IDLE: begin
                    words_done <= 32'd0;
                    if (start) begin
                        if (num_words == 32'd0) begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            wr_addr   <= base_addr;
                            burst_len <= first_burst_len;
                            state     <= S_AW;
                        end
                    end
                end

                // =============================================================
                // AW: assert AWVALID, present address and burst length.
                //     Transition to W on AWREADY handshake.
                // =============================================================
                S_AW: begin
                    M_AXI_AWVALID <= 1'b1;
                    M_AXI_AWADDR  <= wr_addr;
                    M_AXI_AWLEN   <= burst_len[7:0] - 8'd1;  // AXI: length - 1
                    beats_left    <= burst_len;

                    if (M_AXI_AWVALID && M_AXI_AWREADY) begin
                        M_AXI_AWVALID <= 1'b0;
                        state         <= S_W;
                    end
                end

                // =============================================================
                // W: send WDATA beats from FIFO.
                //
                // WVALID = !fifo_empty (combinational, driven outside this block).
                // The AXI interconnect stalls naturally when FIFO drains (WVALID=0).
                // fifo_rd_en is combinational — rptr advances one cycle after each beat.
                //
                // Track beats_left: decrement on each W handshake.
                // On WLAST (last beat): transition to B to accept write response.
                // =============================================================
                S_W: begin
                    if (M_AXI_WVALID && M_AXI_WREADY) begin
                        beats_left <= beats_left - 9'd1;
                        if (M_AXI_WLAST) begin
                            // Burst complete — wait for B response
                            state <= S_B;
                        end
                    end
                end

                // =============================================================
                // B: wait for BVALID (BREADY is always 1).
                //    Advance address, compute next burst, loop or done.
                // =============================================================
                S_B: begin
                    if (M_AXI_BVALID) begin
                        words_done <= words_done + {23'b0, burst_len};
                        wr_addr    <= wr_addr + ({23'b0, burst_len} << 6); // *64 bytes

                        if ((words_done + {23'b0, burst_len}) >= num_words) begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            burst_len <= next_burst_len;
                            state     <= S_AW;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
