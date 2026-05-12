// bf16_add.sv — BF16 adder (combinational)
//
// BF16 format: [15]sign  [14:7]exponent (bias 127, same as FP32)  [6:0]mantissa
// Identical exponent/special-case logic to fp32_add.sv; mantissa is 7 bits vs 23.

`timescale 1ns/1ps

module bf16_add (
    input  logic [15:0] a, b,
    output logic [15:0] result
);

logic a_sign, b_sign, result_sign;
logic [7:0] a_exp, b_exp;
integer larger_exp_i, exp_diff_i, result_exp_i;
logic [6:0] a_mant, b_mant;
logic [7:0] a_mant_ext, b_mant_ext;  // 1 hidden bit + 7 mantissa bits
logic [8:0] sum_mant;                  // carry bit + 8 bits

logic a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
logic normalize_done;
integer shift;
logic [8:0] mant_sub;
integer i;

assign a_sign = a[15];
assign a_exp  = a[14:7];
assign a_mant = a[6:0];

assign b_sign = b[15];
assign b_exp  = b[14:7];
assign b_mant = b[6:0];

assign a_nan  = (a_exp == 8'hFF) && (a_mant != 0);
assign b_nan  = (b_exp == 8'hFF) && (b_mant != 0);
assign a_inf  = (a_exp == 8'hFF) && (a_mant == 0);
assign b_inf  = (b_exp == 8'hFF) && (b_mant == 0);
assign a_zero = (a_exp == 8'h00) && (a_mant == 0);
assign b_zero = (b_exp == 8'h00) && (b_mant == 0);

always_comb begin
    // defaults to avoid latches
    result       = '0;
    result_sign  = 1'b0;
    a_mant_ext   = '0;
    b_mant_ext   = '0;
    sum_mant     = '0;
    larger_exp_i = 0;
    exp_diff_i   = 0;
    result_exp_i = 0;
    normalize_done = 1'b0;
    shift        = 0;
    mant_sub     = '0;

    if (a_nan || b_nan) begin
        result = 16'h7FC0;
    end
    else if (a_inf && b_inf) begin
        result = (a_sign == b_sign) ? {a_sign, 8'hFF, 7'h0} : 16'h7FC0;
    end
    else if (a_inf) begin
        result = {a_sign, 8'hFF, 7'h0};
    end
    else if (b_inf) begin
        result = {b_sign, 8'hFF, 7'h0};
    end
    else if (a_zero && b_zero) begin
        result = {a_sign & b_sign, 8'h00, 7'h0};
    end
    else if (a_zero) begin
        result = b;
    end
    else if (b_zero) begin
        result = a;
    end
    else begin
        // Attach hidden bit (1 for normal, 0 for subnormal)
        a_mant_ext = (a_exp == 8'h00) ? {1'b0, a_mant} : {1'b1, a_mant};
        b_mant_ext = (b_exp == 8'h00) ? {1'b0, b_mant} : {1'b1, b_mant};

        // Align exponents — shift smaller mantissa right
        if (a_exp >= b_exp) begin
            larger_exp_i = int'(a_exp);
            exp_diff_i   = int'(a_exp) - int'(b_exp);
            b_mant_ext   = b_mant_ext >> exp_diff_i;
        end else begin
            larger_exp_i = int'(b_exp);
            exp_diff_i   = int'(b_exp) - int'(a_exp);
            a_mant_ext   = a_mant_ext >> exp_diff_i;
        end

        // Add or subtract mantissas
        if (a_sign == b_sign) begin
            sum_mant    = a_mant_ext + b_mant_ext;
            result_sign = a_sign;
        end else begin
            if (a_mant_ext >= b_mant_ext) begin
                sum_mant    = a_mant_ext - b_mant_ext;
                result_sign = a_sign;
            end else begin
                sum_mant    = b_mant_ext - a_mant_ext;
                result_sign = b_sign;
            end
        end

        // Both inputs subnormal
        if (larger_exp_i == 0) begin
            if (sum_mant == 0) begin
                result = 16'h0000;
            end
            else if (sum_mant[7]) begin
                result = {result_sign, 8'h01, sum_mant[6:0]};
            end
            else begin
                result = {result_sign, 8'h00, sum_mant[6:0]};
            end
        end
        else begin
            result_exp_i   = larger_exp_i;
            normalize_done = 1'b0;

            if (sum_mant[8]) begin          // carry out of addition → shift right
                sum_mant     = sum_mant >> 1;
                result_exp_i = result_exp_i + 1;
                normalize_done = 1'b1;
            end
            else if (sum_mant[7]) begin     // hidden bit already set → normalized
                normalize_done = 1'b1;
            end

            if (!normalize_done) begin
                for (i = 6; i >= 0; i = i - 1) begin
                    if (sum_mant[i] && !normalize_done) begin
                        sum_mant     = sum_mant << (7 - i);
                        result_exp_i = result_exp_i - (7 - i);
                        normalize_done = 1'b1;
                    end
                end
            end

            if (sum_mant == 0) begin
                result = 16'h0000;
            end
            else if (result_exp_i >= 255) begin
                result = {result_sign, 8'hFF, 7'h0};
            end
            else if (result_exp_i <= 0) begin
                shift = 1 - result_exp_i;
                if (shift >= 9) begin
                    result = {result_sign, 8'h00, 7'h0};
                end else begin
                    mant_sub = sum_mant >> shift;
                    result   = {result_sign, 8'h00, mant_sub[6:0]};
                end
            end
            else begin
                result = {result_sign, result_exp_i[7:0], sum_mant[6:0]};
            end
        end
    end
end

endmodule
