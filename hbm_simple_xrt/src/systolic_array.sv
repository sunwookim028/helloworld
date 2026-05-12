// ============================================================================
// systolic_array.sv — Parameterized N×N weight-stationary systolic array (BF16)
//
// Generalization of minitpu's flat 4×4 systolic.sv using generate blocks.
// Same PE interface and signal flow, just parameterized for any N.
//
// Signal flow:
//   Activations: left → right (west edge inputs, one per row)
//   Weights:     top → bottom (north edge inputs, one per column)
//   Partial sums: top → bottom (accumulated, output at bottom row)
//   Switch:      pe[0][0] → right along row 0, then down each column
//   Valid:       left → right (same path as activations)
//   Accept_w:    broadcast to all PEs in a column (not pipelined)
//
// Ports use flat packed vectors for Icarus Verilog compatibility.
// ============================================================================

`timescale 1ns/1ps

module systolic_array #(
    parameter int N = 16,
    parameter int DATA_WIDTH = 16
)(
    input  logic clk,
    input  logic rst_n,

    // Left edge: activations (one per row)
    // Row r at data_in[r*DATA_WIDTH +: DATA_WIDTH]
    input  logic [N*DATA_WIDTH-1:0] data_in,
    input  logic [N-1:0]            valid_in,

    // Top edge: weights (one per column)
    // Column c at weight_in[c*DATA_WIDTH +: DATA_WIDTH]
    input  logic [N*DATA_WIDTH-1:0] weight_in,
    input  logic [N-1:0]            accept_w,

    // Switch signal (enters at top-left corner pe[0][0])
    input  logic                    switch_in,

    // Bottom edge: partial sum outputs (one per column)
    // Column c at data_out[c*DATA_WIDTH +: DATA_WIDTH]
    output logic [N*DATA_WIDTH-1:0] data_out,
    output logic [N-1:0]            valid_out
);

    // =========================================================================
    // Internal wires — flat 1D arrays indexed by (r*N + c)
    // =========================================================================
    localparam int TOTAL = N * N;

    logic [DATA_WIDTH-1:0] pe_input_out  [0:TOTAL-1];
    logic [DATA_WIDTH-1:0] pe_psum_out   [0:TOTAL-1];
    logic [DATA_WIDTH-1:0] pe_weight_out [0:TOTAL-1];
    logic                  pe_valid_out  [0:TOTAL-1];
    logic                  pe_switch_out [0:TOTAL-1];

    // =========================================================================
    // Generate N×N PE grid
    // =========================================================================
    genvar r, c;
    generate
        for (r = 0; r < N; r++) begin : gen_row
            for (c = 0; c < N; c++) begin : gen_col

                // --- West edge inputs (activations + valid) ---
                wire [DATA_WIDTH-1:0] w_input;
                wire                  w_valid;

                if (c == 0) begin : west_edge
                    assign w_input = data_in[r*DATA_WIDTH +: DATA_WIDTH];
                    assign w_valid = valid_in[r];
                end else begin : west_internal
                    assign w_input = pe_input_out[r*N + c - 1];
                    assign w_valid = pe_valid_out[r*N + c - 1];
                end

                // --- Switch routing ---
                // Row 0: left → right.  Rows > 0: top → bottom within column.
                wire w_switch;

                if (r == 0 && c == 0) begin : switch_origin
                    assign w_switch = switch_in;
                end else if (r == 0) begin : switch_row0
                    assign w_switch = pe_switch_out[c - 1];
                end else begin : switch_col
                    assign w_switch = pe_switch_out[(r-1)*N + c];
                end

                // --- North edge inputs (partial sums + weights) ---
                wire [DATA_WIDTH-1:0] w_psum;
                wire [DATA_WIDTH-1:0] w_weight;

                if (r == 0) begin : north_edge
                    assign w_psum   = {DATA_WIDTH{1'b0}};
                    assign w_weight = weight_in[c*DATA_WIDTH +: DATA_WIDTH];
                end else begin : north_internal
                    assign w_psum   = pe_psum_out[(r-1)*N + c];
                    assign w_weight = pe_weight_out[(r-1)*N + c];
                end

                // --- PE instance ---
                pe #(.DATA_WIDTH(DATA_WIDTH)) u_pe (
                    .clk           (clk),
                    .rst_n         (rst_n),
                    .pe_enabled    (1'b1),

                    .pe_input_in   (w_input),
                    .pe_valid_in   (w_valid),
                    .pe_switch_in  (w_switch),

                    .pe_psum_in    (w_psum),
                    .pe_weight_in  (w_weight),
                    .pe_accept_w_in(accept_w[c]),

                    .pe_input_out  (pe_input_out [r*N + c]),
                    .pe_valid_out  (pe_valid_out [r*N + c]),
                    .pe_switch_out (pe_switch_out[r*N + c]),
                    .pe_psum_out   (pe_psum_out  [r*N + c]),
                    .pe_weight_out (pe_weight_out[r*N + c])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Connect bottom row outputs
    // =========================================================================
    generate
        for (genvar oc = 0; oc < N; oc++) begin : gen_out
            assign data_out[oc*DATA_WIDTH +: DATA_WIDTH] = pe_psum_out[(N-1)*N + oc];
            assign valid_out[oc] = pe_valid_out[(N-1)*N + oc];
        end
    endgenerate

endmodule
