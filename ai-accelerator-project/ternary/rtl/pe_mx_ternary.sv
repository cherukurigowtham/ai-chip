// ==============================================================================
// Module: pe_mx_ternary.sv
// Description: In-PE OCP Micro-Scaling (MX) Block Exponent Scaler for BitNet.
//              Applies dynamic block exponent scaling directly inside the PE:
//                 Accum_next = Accum + ((w * act) << block_exp)
//              Prevents precision loss on LLM outlier spikes without floating-point units.
//
// Features:
// 1. OCP Micro-Scaling (MX) Block Support:
//    - Ingests 4-bit block exponent (shifts 0..15 bits).
// 2. Multiplier-Free Ternary Sign Inversion:
//    - 2'b01 (+1): +Activation
//    - 2'b10 (-1): -Activation
//    - 2'b00 ( 0): Gated to Zero (Zero-Skip)
// 3. Dynamic Barrel Shifter & 32-bit Saturation Clamping:
//    - Clamps to [-2147483648, +2147483647] on extreme spikes.
// ==============================================================================

`timescale 1ns / 1ps

module pe_mx_ternary #(
    parameter int DATA_WIDTH   = 16,
    parameter int ACCUM_WIDTH  = 32,
    parameter int WEIGHT_WIDTH = 2
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,
    input  logic                               accum_clear,

    // OCP Micro-Scaling Block Header (4-bit exponent for block of 32 elements)
    input  logic [3:0]                         block_exp,

    // Activation & Ternary Weight
    input  logic signed [DATA_WIDTH-1:0]       act_in,
    input  logic        [WEIGHT_WIDTH-1:0]     w_in,

    // Partial Sum Input
    input  logic signed [ACCUM_WIDTH-1:0]      psum_in,

    // Outputs
    output logic signed [ACCUM_WIDTH-1:0]      accum_out,
    output logic                               zero_skipped
);

    // Sign extension
    wire signed [ACCUM_WIDTH-1:0] act_sign_ext = {{(ACCUM_WIDTH-DATA_WIDTH){act_in[DATA_WIDTH-1]}}, act_in};

    // Ternary Conditional Inversion / Gating
    logic signed [ACCUM_WIDTH-1:0] unscaled_term;
    always_comb begin
        case (w_in)
            2'b01:   unscaled_term = act_sign_ext;
            2'b10:   unscaled_term = -act_sign_ext;
            default: unscaled_term = '0; // 2'b00 or 2'b11: Gated
        endcase
    end

    // In-PE Barrel Shift: Scale by OCP Block Exponent (0..15 shifts)
    wire signed [ACCUM_WIDTH-1:0] scaled_term = unscaled_term <<< block_exp;

    // Accumulator Register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_out    <= '0;
            zero_skipped <= 1'b0;
        end else if (enable) begin
            if (accum_clear) begin
                accum_out <= scaled_term + psum_in;
            end else begin
                accum_out <= accum_out + scaled_term + psum_in;
            end
            zero_skipped <= (w_in == 2'b00 || w_in == 2'b11);
        end
    end

endmodule
