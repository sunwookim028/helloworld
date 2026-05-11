// bf16_mul.sv — BF16 multiplier (combinational)
//
// BF16 format: [15]sign  [14:7]exponent (bias 127, same as FP32)  [6:0]mantissa
// Identical exponent logic to fp32_mul.sv; only mantissa width changes (7 vs 23).

`timescale 1ns/1ps

module bf16_mul (
    input  [15:0] a, b,
    output reg [15:0] result
);

reg [7:0]  a_m, b_m, z_m;
reg [9:0]  a_e, b_e, z_e;
reg        a_s, b_s, z_s;
(* use_dsp = "yes" *) reg [17:0] product;  // force DSP48 for 8×8 multiply
reg        guard_bit, round_bit, sticky;

always @(*) begin
    result    = 16'h0;
    z_s       = 1'b0;
    z_e       = 10'sd0;
    product   = 18'd0;
    z_m       = 8'd0;
    guard_bit = 1'b0;
    round_bit = 1'b0;
    sticky    = 1'b0;

    a_m = {1'b0, a[6:0]};
    b_m = {1'b0, b[6:0]};
    a_e = {2'b00, a[14:7]} - 10'sd127;
    b_e = {2'b00, b[14:7]} - 10'sd127;
    a_s = a[15];
    b_s = b[15];

    if ((a_e == 128 && a_m != 0) || (b_e == 128 && b_m != 0)) begin // NaN
        result = 16'h7FC0;
    end
    else if (a_e == 128) begin // Inf A
        if (($signed(b_e) == -127) && (b_m == 0))
            result = 16'h7FC0;   // Inf * 0 = NaN
        else
            result = {a_s ^ b_s, 8'hFF, 7'h0};
    end
    else if (b_e == 128) begin // Inf B
        if (($signed(a_e) == -127) && (a_m == 0))
            result = 16'h7FC0;   // 0 * Inf = NaN
        else
            result = {a_s ^ b_s, 8'hFF, 7'h0};
    end
    else if (($signed(a_e) == -127) && (a_m == 0)) begin // A = 0
        result = {a_s ^ b_s, 8'h0, 7'h0};
    end
    else if (($signed(b_e) == -127) && (b_m == 0)) begin // B = 0
        result = {a_s ^ b_s, 8'h0, 7'h0};
    end
    else begin
        if ($signed(a_e) == -127)
            a_e = -126;
        else
            a_m[7] = 1'b1;   // set hidden bit

        if ($signed(b_e) == -127)
            b_e = -126;
        else
            b_m[7] = 1'b1;

        if (~a_m[7]) begin
            a_m = a_m << 1;
            a_e = a_e - 1;
        end
        if (~b_m[7]) begin
            b_m = b_m << 1;
            b_e = b_e - 1;
        end

        z_s     = a_s ^ b_s;
        z_e     = a_e + b_e + 1;
        product = a_m * b_m * 4;   // 18-bit result; z_m occupies [17:10]

        z_m       = product[17:10];
        guard_bit = product[9];
        round_bit = product[8];
        sticky    = (product[7:0] != 0);

        if ($signed(z_e) < -126) begin
            z_e = z_e + (-126 - $signed(z_e));
            z_m = z_m >> (-126 - $signed(z_e));
            guard_bit = z_m[0];
            round_bit = guard_bit;
            sticky = sticky | round_bit;
        end
        else if (z_m[7] == 0) begin
            z_e = z_e - 1;
            z_m = z_m << 1;
            z_m[0] = guard_bit;
            guard_bit = round_bit;
            round_bit = 1'b0;
        end
        else if (guard_bit && (round_bit | sticky | z_m[0])) begin
            z_m = z_m + 1;
            if (z_m == 8'hff)
                z_e = z_e + 1;
        end

        result[6:0]  = z_m[6:0];
        result[14:7] = z_e[7:0] + 127;
        result[15]   = z_s;

        if ($signed(z_e) == -126 && z_m[7] == 0)
            result[14:7] = 8'h0;

        if ($signed(z_e) > 127) begin
            result[6:0]  = 7'h0;
            result[14:7] = 8'hFF;
            result[15]   = z_s;
        end
    end
end

endmodule
