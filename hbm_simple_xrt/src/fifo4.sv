// ============================================================================
// fifo4.sv — Synchronous FWFT FIFO with flush
//
// First-Word-Fall-Through: rd_data is valid combinationally when !empty.
// No extra cycle delay between asserting rd_en and seeing the next word.
//
// Copied from minitpu/tpu/src/system/fifo4.sv — used unchanged.
// ============================================================================

module fifo4 #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 64   // Must be a power of 2
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             flush,     // synchronous clear (active high)

    // Write side
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,

    // Read side
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,   // FWFT: valid when !empty

    // Status
    output logic             full,
    output logic             empty,
    output logic             almost_full // asserted when count >= DEPTH-1
);

    localparam int PTR_W = $clog2(DEPTH) + 1;  // index bits + wrap bit

    // Storage
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers (index bits + wrap bit for full/empty disambiguation)
    logic [PTR_W-1:0] wptr;
    logic [PTR_W-1:0] rptr;

    // FWFT: combinational read — data valid same cycle as !empty
    assign rd_data = mem[rptr[PTR_W-2:0]];

    // Status flags
    assign empty = (wptr == rptr);
    assign full  = (wptr[PTR_W-1] != rptr[PTR_W-1]) &&
                   (wptr[PTR_W-2:0] == rptr[PTR_W-2:0]);

    // almost_full: only 1 slot remaining (or already full)
    // count = wptr - rptr (works with wrap bit for modular arithmetic)
    wire [PTR_W-1:0] count = wptr - rptr;
    assign almost_full = (count >= DEPTH - 1);

    // Write logic
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            wptr <= '0;
        end else if (wr_en && !full) begin
            mem[wptr[PTR_W-2:0]] <= wr_data;
            wptr <= wptr + 1'b1;
        end
    end

    // Read logic
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            rptr <= '0;
        end else if (rd_en && !empty) begin
            rptr <= rptr + 1'b1;
        end
    end

endmodule
