// fp32_add.sv — IEEE-754 FP32 adder (combinational)
// Copied from minitpu/tpu/src/compute_tile/fp32_add.sv

module fp32_add #(
    parameter FORMAT = "FP32",
    parameter INT_BITS = 16,
    parameter FRAC_BITS = 16,
    parameter WIDTH = 32
    ) (
    input  logic [WIDTH-1:0] a, b,
    output logic [WIDTH-1:0] result
);

logic a_sign, b_sign, result_sign;
logic [7:0] a_exp, b_exp;
integer larger_exp_i, exp_diff_i, result_exp_i;
logic [22:0] a_mant, b_mant;
logic [23:0] a_mant_ext, b_mant_ext;
logic [24:0] sum_mant;

logic a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
logic normalize_done;
integer shift;
logic [24:0] mant_sub;
integer i;

generate
    if (FORMAT == "FP32") begin : fp32_mode
        assign a_sign = a[31];
        assign a_exp  = a[30:23];
        assign a_mant = a[22:0];

        assign b_sign = b[31];
        assign b_exp  = b[30:23];
        assign b_mant = b[22:0];

        assign a_nan  = (a_exp == 8'hFF) && (a_mant != 0);
        assign b_nan  = (b_exp == 8'hFF) && (b_mant != 0);
        assign a_inf  = (a_exp == 8'hFF) && (a_mant == 0);
        assign b_inf  = (b_exp == 8'hFF) && (b_mant == 0);
        assign a_zero = (a_exp == 8'h00) && (a_mant == 0);
        assign b_zero = (b_exp == 8'h00) && (b_mant == 0);

        always_comb begin
            // defaults to avoid latches
            result = '0;
            result_sign = 1'b0;
            a_mant_ext = '0;
            b_mant_ext = '0;
            sum_mant = '0;
            larger_exp_i = 0;
            exp_diff_i = 0;
            result_exp_i = 0;
            normalize_done = 1'b0;
            shift = 0;
            mant_sub = '0;
            if (a_nan || b_nan) begin
                result = 32'h7FC00000;  // NaN
            end
            else if (a_inf && b_inf) begin
                result = (a_sign == b_sign) ? {a_sign, 8'hFF, 23'h0} : 32'h7FC00000;
            end
            else if (a_inf) begin
                result = {a_sign, 8'hFF, 23'h0};
            end
            else if (b_inf) begin
                result = {b_sign, 8'hFF, 23'h0};
            end
            else if (a_zero && b_zero) begin
                result = {a_sign & b_sign, 8'h00, 23'h0};
            end
            else if (a_zero) begin
                result = b;
            end
            else if (b_zero) begin
                result = a;
            end
            else begin
                // fp32 addition logic
                a_mant_ext = (a_exp == 8'h00) ? {1'b0, a_mant} : {1'b1, a_mant};
                b_mant_ext = (b_exp == 8'h00) ? {1'b0, b_mant} : {1'b1, b_mant};

                // align exponents
                if (a_exp >= b_exp) begin
                    larger_exp_i = int'(a_exp);
                    exp_diff_i = int'(a_exp) - int'(b_exp);
                    b_mant_ext = b_mant_ext >> exp_diff_i;
                end else begin
                    larger_exp_i = int'(b_exp);
                    exp_diff_i = int'(b_exp) - int'(a_exp);
                    a_mant_ext = a_mant_ext >> exp_diff_i;
                end

                // add/sub mantissas
                if (a_sign == b_sign) begin
                    sum_mant = a_mant_ext + b_mant_ext;
                    result_sign = a_sign;
                end else begin
                    if (a_mant_ext >= b_mant_ext) begin
                        sum_mant = a_mant_ext - b_mant_ext;
                        result_sign = a_sign;
                    end else begin
                        sum_mant = b_mant_ext - a_mant_ext;
                        result_sign = b_sign;
                    end
                end

                // If both inputs are subnormal, keep result subnormal unless it crosses into normal range.
                if (larger_exp_i == 0) begin
                    if (sum_mant == 0) begin
                        result = 32'h00000000;
                    end
                    else if (sum_mant[23]) begin
                        // Promote to smallest normal
                        result = {result_sign, 8'h01, sum_mant[22:0]};
                    end
                    else begin
                        result = {result_sign, 8'h00, sum_mant[22:0]};
                    end
                end
                else begin
                    result_exp_i = larger_exp_i;
                    normalize_done = 1'b0;

                    if (sum_mant[24]) begin
                        sum_mant = sum_mant >> 1;
                        result_exp_i = result_exp_i + 1;
                        normalize_done = 1'b1;
                    end
                    else if (sum_mant[23]) begin
                        normalize_done = 1'b1;
                    end

                    if (!normalize_done) begin
                        for (i = 22; i >= 0; i = i - 1) begin
                            if (sum_mant[i] && !normalize_done) begin
                                sum_mant = sum_mant << (23 - i);
                                result_exp_i = result_exp_i - (23 - i);
                                normalize_done = 1'b1;
                            end
                        end
                    end

                    if (sum_mant == 0) begin
                        result = 32'h00000000;
                    end
                    else if (result_exp_i >= 255) begin
                        result = {result_sign, 8'hFF, 23'h0};
                    end
                    else if (result_exp_i <= 0) begin
                        shift = 1 - result_exp_i;
                        if (shift >= 25) begin
                            result = {result_sign, 8'h00, 23'h0};
                        end else begin
                            mant_sub = sum_mant >> shift;
                            result = {result_sign, 8'h00, mant_sub[22:0]};
                        end
                    end
                    else begin
                        result = {result_sign, result_exp_i[7:0], sum_mant[22:0]};
                    end
                end
            end
        end
    end
    else begin : fixed_point_mode
        logic [WIDTH-1:0] sum;
        logic overflow;

        assign sum = a + b;
        assign overflow = (a[WIDTH-1] == b[WIDTH-1]) && (sum[WIDTH-1] != a[WIDTH-1]);

        always_comb begin
            if (overflow) begin
                result = a[WIDTH-1] ? {1'b1, {WIDTH-1{1'b0}}} : {1'b0, {WIDTH-1{1'b1}}};
            end else begin
                result = sum;
            end
        end
    end
endgenerate

endmodule
