// ============================================================================
// krnl_vadd_rd_mst.v — AXI4 burst read master (512-bit, HBM)
//
// Reads num_words × 512-bit words from base_addr via AXI4 burst transactions.
// Bursts are 4KB-boundary-aware (max 64 beats for 64-byte beat width).
// Data is written into an external FIFO (wr_en / wr_data / fifo_almost_full).
//
// Modeled after tpu_master_axi_stream.v: clean state-based FSM, explicit
// BRAM-latency commentary style replaced with AXI4 read-latency commentary.
//
// FSM: IDLE → AR → R → (AR again if more bursts) → DONE
//
// AXI4 read timing:
//   AR state: ARVALID=1, wait for ARREADY handshake, then go to R.
//   R  state: RREADY=1 when FIFO not almost-full, capture RDATA on handshake.
//             On RLAST, compute next burst or transition to DONE.
// ============================================================================

`timescale 1 ns / 1 ps

module krnl_vadd_rd_mst #(
    parameter integer DATA_WIDTH = 512,
    parameter integer ADDR_WIDTH = 64
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  start,       // pulse: begin reading
    input  wire [ADDR_WIDTH-1:0] base_addr,   // byte address of first word
    input  wire [31:0]           num_words,   // total 512-bit words to read
    output reg                   done,        // asserted for one cycle when all reads complete

    // Data FIFO write port
    output reg                   fifo_wr_en,
    output reg  [DATA_WIDTH-1:0] fifo_wr_data,
    input  wire                  fifo_almost_full,

    // AXI4 read master (AR + R channels)
    output reg                   M_AXI_ARVALID,
    output reg  [ADDR_WIDTH-1:0] M_AXI_ARADDR,
    output reg  [7:0]            M_AXI_ARLEN,    // beats - 1 (max 63 = 64 beats)
    output wire [2:0]            M_AXI_ARSIZE,   // 3'b110 = 64 bytes/beat
    output wire [1:0]            M_AXI_ARBURST,  // INCR
    output wire [3:0]            M_AXI_ARCACHE,
    output wire [2:0]            M_AXI_ARPROT,
    output wire [3:0]            M_AXI_ARQOS,
    input  wire                  M_AXI_ARREADY,

    input  wire [DATA_WIDTH-1:0] M_AXI_RDATA,
    input  wire [1:0]            M_AXI_RRESP,
    input  wire                  M_AXI_RLAST,
    input  wire                  M_AXI_RVALID,
    output wire                  M_AXI_RREADY
);

    // Static AXI4 read channel settings
    assign M_AXI_ARSIZE  = 3'b110;          // 2^6 = 64 bytes per beat (512-bit)
    assign M_AXI_ARBURST = 2'b01;           // INCR
    assign M_AXI_ARCACHE = 4'b1111;         // write-back, R/W allocate (optimal for HBM)
    assign M_AXI_ARPROT  = 3'b000;
    assign M_AXI_ARQOS   = 4'b0000;

    // R channel: accept data whenever FIFO has room
    assign M_AXI_RREADY  = (state == S_R) && !fifo_almost_full;

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam [1:0] S_IDLE = 2'd0,
                     S_AR   = 2'd1,
                     S_R    = 2'd2,
                     S_DONE = 2'd3;

    reg [1:0] state;

    // =========================================================================
    // Tracking registers
    // =========================================================================
    reg [ADDR_WIDTH-1:0] rd_addr;        // current burst byte address
    reg [31:0]           words_done;     // total 512-bit words read so far
    reg [8:0]            burst_len;      // current burst length in beats (1-64)
    reg [8:0]            beats_left;     // R beats remaining in current burst

    // =========================================================================
    // 4KB-boundary-aware burst length computation
    // AXI4 bursts must not cross 4KB address boundaries.  For 64-byte beats
    // (ARSIZE=110): max beats = min(4096/64, (4096 - addr[11:0])/64) = max 64.
    // =========================================================================

    // First burst (used in S_IDLE on start): cap based on base_addr alignment
    wire [12:0] first_bytes_to_4k = 13'h1000 - {1'b0, base_addr[11:0]};
    wire [8:0]  first_beats_to_4k = first_bytes_to_4k[12:6];
    wire [8:0]  first_addr_cap    = (first_beats_to_4k < 9'd64) ? first_beats_to_4k : 9'd64;
    wire [8:0]  first_burst_len   = (num_words > {23'b0, first_addr_cap}) ?
                                     first_addr_cap : num_words[8:0];

    // Subsequent bursts (used on RLAST): cap based on next address after current burst
    wire [ADDR_WIDTH-1:0] next_addr        = rd_addr + ({23'b0, burst_len} << 6);
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
            state        <= S_IDLE;
            rd_addr      <= {ADDR_WIDTH{1'b0}};
            words_done   <= 32'd0;
            burst_len    <= 9'd0;
            beats_left   <= 9'd0;
            done         <= 1'b0;
            M_AXI_ARVALID <= 1'b0;
            M_AXI_ARADDR  <= {ADDR_WIDTH{1'b0}};
            M_AXI_ARLEN   <= 8'd0;
            fifo_wr_en    <= 1'b0;
            fifo_wr_data  <= {DATA_WIDTH{1'b0}};
        end else begin
            // Defaults (pulsed signals)
            done         <= 1'b0;
            fifo_wr_en   <= 1'b0;

            case (state)
                // =============================================================
                // IDLE: wait for start pulse, compute first burst
                // =============================================================
                S_IDLE: begin
                    words_done <= 32'd0;
                    if (start) begin
                        if (num_words == 32'd0) begin
                            state <= S_DONE;
                        end else begin
                            rd_addr   <= base_addr;
                            burst_len <= first_burst_len;
                            state     <= S_AR;
                        end
                    end
                end

                // =============================================================
                // AR: assert ARVALID, present address and burst length.
                //     Transition to R on ARREADY handshake.
                // =============================================================
                S_AR: begin
                    M_AXI_ARVALID <= 1'b1;
                    M_AXI_ARADDR  <= rd_addr;
                    M_AXI_ARLEN   <= burst_len[7:0] - 8'd1;  // AXI: length - 1
                    beats_left    <= burst_len;

                    if (M_AXI_ARVALID && M_AXI_ARREADY) begin
                        M_AXI_ARVALID <= 1'b0;
                        state         <= S_R;
                    end
                end

                // =============================================================
                // R: collect RDATA beats, write to FIFO.
                //    RREADY is driven combinationally (!fifo_almost_full).
                //    On RLAST: advance address, compute next burst, loop or done.
                // =============================================================
                S_R: begin
                    if (M_AXI_RVALID && M_AXI_RREADY) begin
                        fifo_wr_en   <= 1'b1;
                        fifo_wr_data <= M_AXI_RDATA;
                        beats_left   <= beats_left - 9'd1;

                        if (M_AXI_RLAST) begin
                            // Burst complete
                            words_done <= words_done + {23'b0, burst_len};
                            rd_addr    <= rd_addr + ({23'b0, burst_len} << 6); // *64 bytes

                            if ((words_done + {23'b0, burst_len}) >= num_words) begin
                                state <= S_DONE;
                            end else begin
                                // Prepare next burst
                                burst_len <= next_burst_len;
                                state     <= S_AR;
                            end
                        end
                    end
                end

                // =============================================================
                // DONE: pulse done, return to IDLE
                // =============================================================
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
