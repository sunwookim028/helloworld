// pe.sv — Single processing element (MAC) for systolic array, BF16
// Adapted from minitpu/tpu/src/compute_tile/pe.sv

`timescale 1ns/1ps

module pe #(
    parameter DATA_WIDTH = 16
) (
    input  logic clk,
    input  logic rst_n,

    // North wires of PE (partial sum + weight input)
    input  logic [DATA_WIDTH-1:0] pe_psum_in,
    input  logic [DATA_WIDTH-1:0] pe_weight_in,
    input  logic                  pe_accept_w_in,

    // West wires of PE (activation + control)
    input  logic [DATA_WIDTH-1:0] pe_input_in,
    input  logic                  pe_valid_in,
    input  logic                  pe_switch_in,
    input  logic                  pe_enabled,

    // South wires of the PE (partial sum + weight output)
    output logic [DATA_WIDTH-1:0] pe_psum_out,
    output logic [DATA_WIDTH-1:0] pe_weight_out,

    // East wires of the PE (activation + control out)
    output logic [DATA_WIDTH-1:0] pe_input_out,
    output logic                  pe_valid_out,
    output logic                  pe_switch_out
);

    // Internal data paths (BF16)
    logic [DATA_WIDTH-1:0] mult_out;
    logic [DATA_WIDTH-1:0] mul_out_reg;          // pipeline register: mul → add
    logic [DATA_WIDTH-1:0] mac_out;
    logic [DATA_WIDTH-1:0] weight_reg_active;    // foreground weight register
    logic [DATA_WIDTH-1:0] weight_reg_inactive;  // background weight register
    logic                  valid_pipe;            // valid delayed 1 cycle to match pipeline

    // ------------------------------------------------------------------------
    // BF16 multiply: mult_out = pe_input_in * weight_reg_active
    // ------------------------------------------------------------------------
    bf16_mul mult (
        .a      ( pe_input_in        ),
        .b      ( weight_reg_active  ),
        .result ( mult_out           )
    );

    // ------------------------------------------------------------------------
    // BF16 add: mac_out = mul_out_reg + pe_psum_in
    // mul_out_reg is the registered mul result; pe_psum_in arrives 1 cycle
    // later from above (correct per systolic schedule), so inputs are aligned.
    // ------------------------------------------------------------------------
    bf16_add adder (
        .a      ( mul_out_reg  ),
        .b      ( pe_psum_in   ),
        .result ( mac_out      )
    );

    // ------------------------------------------------------------------------
    // Sequential control + register updates
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_input_out        <= '0;
            pe_psum_out         <= '0;
            pe_weight_out       <= '0;
            pe_valid_out        <= 1'b0;
            pe_switch_out       <= 1'b0;
            weight_reg_active   <= '0;
            weight_reg_inactive <= '0;
            mul_out_reg         <= '0;
            valid_pipe          <= 1'b0;
        end
        else if (!pe_enabled) begin
            pe_input_out        <= '0;
            pe_psum_out         <= '0;
            pe_weight_out       <= '0;
            pe_valid_out        <= 1'b0;
            pe_switch_out       <= 1'b0;
            weight_reg_active   <= '0;
            weight_reg_inactive <= '0;
            mul_out_reg         <= '0;
            valid_pipe          <= 1'b0;
        end
        else begin
            // Stage 1 pipeline register (always runs)
            mul_out_reg <= mult_out;
            valid_pipe  <= pe_valid_in;

            // Pass-through control signals
            pe_valid_out  <= valid_pipe;   // now 2-cycle delay: pe_valid_in → valid_pipe → pe_valid_out
            pe_switch_out <= pe_switch_in;

            // Weight register updates
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
                pe_weight_out       <= pe_weight_in;
            end
            else begin
                pe_weight_out <= '0;
            end

            // Swap active weight when switch is asserted
            if (pe_switch_in) begin
                if (pe_accept_w_in) begin
                    weight_reg_active <= pe_weight_in;
                end
                else begin
                    weight_reg_active <= weight_reg_inactive;
                end
            end

            // East propagation: 1-cycle delay (unchanged — keeps systolic schedule correct)
            if (pe_valid_in) begin
                pe_input_out <= pe_input_in;
            end else begin
                pe_input_out <= '0;
            end

            // South propagation: 2-cycle path (mul reg → add combo → psum reg)
            // valid_pipe gates stage 2; psum from above arrives 1 cycle late per
            // systolic schedule, so it aligns with mul_out_reg here.
            if (valid_pipe) begin
                pe_psum_out <= mac_out;
            end
            else begin
                pe_valid_out <= 1'b0;
                pe_psum_out  <= '0;
            end
        end
    end

endmodule
