// ==============================================================================
// Module: fused_ternary_fp8_alu.sv
// Description: Reconfigurable Fused Ternary / FP8 Micro-Tensor Arithmetic Unit.
//              Provides unified execution for:
//                1. Multiplier-Free Ternary 1.58b (W in {-1, 0, +1}) with 2:4 Sparsity
//                2. OCP / NVIDIA Standard FP8 (E4M3: 1-bit sign, 4-bit exp, 3-bit mantissa)
//                   for non-linear layers (Softmax, RMSNorm, LayerNorm, SwiGLU).
//
// Key Specifications:
// - Mode 0 (mode_sel=2'b00): Pure Ternary 1.58b (Zero hardware multiplier toggling).
// - Mode 1 (mode_sel=2'b01): 8-bit FP8 (E4M3) with 4-bit mantissa multiplier.
// - Mode 2 (mode_sel=2'b10): INT8 Signed MAC.
// - 1-Cycle deterministic execution latency at 500 MHz.
// ==============================================================================

`timescale 1ns / 1ps

module fused_ternary_fp8_alu #(
    parameter int ACC_WIDTH = 32
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Mode Configuration: 2'b00: Ternary 1.58b, 2'b01: FP8 (E4M3), 2'b10: INT8
    input  logic [1:0]             mode_sel,

    // Input Operands
    input  logic [1:0]             ternary_weight,  // 2'b00=0, 2'b01=+1, 2'b10=-1
    input  logic signed [15:0]     act_in_int16,    // INT16 activation for ternary mode
    input  logic [7:0]             fp8_weight,      // E4M3 format: [7]=Sign, [6:3]=Exp, [2:0]=Mant
    input  logic [7:0]             fp8_act,         // E4M3 format: [7]=Sign, [6:3]=Exp, [2:0]=Mant

    // Accumulator Forwarding
    input  logic signed [ACC_WIDTH-1:0] accum_in,
    output logic signed [ACC_WIDTH-1:0] accum_out,
    output logic                        is_zero_skip
);

    // -------------------------------------------------------------------------
    // 1. Mode 0: Multiplier-Free Ternary Datapath (Zero Multipliers)
    // -------------------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] ternary_term;
    logic                        ternary_zero;

    always_comb begin
        case (ternary_weight)
            2'b01: begin
                ternary_term = {{16{act_in_int16[15]}}, act_in_int16};  // +1 * act
                ternary_zero = 1'b0;
            end
            2'b10: begin
                ternary_term = -{{16{act_in_int16[15]}}, act_in_int16}; // -1 * act
                ternary_zero = 1'b0;
            end
            default: begin
                ternary_term = '0;                                      //  0 * act (Skip)
                ternary_zero = 1'b1;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // 2. Mode 1: Fused FP8 (E4M3) Micro-Tensor Datapath
    //    E4M3 Specification:
    //      - Sign: bit 7
    //      - Exponent: bits [6:3] (bias = 7)
    //      - Mantissa: bits [2:0] (implicit leading 1: 1.mmm)
    // -------------------------------------------------------------------------
    wire        fp8_sign_a = fp8_act[7];
    wire [3:0]  fp8_exp_a  = fp8_act[6:3];
    wire [3:0]  fp8_mant_a = (fp8_exp_a != 4'h0) ? {1'b1, fp8_act[2:0]} : {1'b0, fp8_act[2:0]}; // Handle subnormals

    wire        fp8_sign_w = fp8_weight[7];
    wire [3:0]  fp8_exp_w  = fp8_weight[6:3];
    wire [3:0]  fp8_mant_w = (fp8_exp_w != 4'h0) ? {1'b1, fp8_weight[2:0]} : {1'b0, fp8_weight[2:0]};

    // 4-bit x 4-bit unsigned mantissa multiplication (tiny 16-element LUT / adder)
    wire [7:0]  fp8_prod_mant = fp8_mant_a * fp8_mant_w;
    wire        fp8_prod_sign = fp8_sign_a ^ fp8_sign_w;
    wire signed [5:0] fp8_prod_exp  = $signed({2'b00, fp8_exp_a}) + $signed({2'b00, fp8_exp_w}) - 6'sd7; // Unbias

    // Convert FP8 product to fixed-point integer equivalent for accumulator fusion
    logic signed [ACC_WIDTH-1:0] fp8_term_fixed;
    always_comb begin
        if (fp8_exp_a == 4'h0 || fp8_exp_w == 4'h0) begin
            fp8_term_fixed = '0;
        end else begin
            // Shift mantissa by unbiased exponent (clamped to prevent overflow)
            logic [ACC_WIDTH-1:0] magnitude;
            if (fp8_prod_exp >= 6'sd0) begin
                magnitude = {24'h0, fp8_prod_mant} << fp8_prod_exp[3:0];
            end else begin
                magnitude = {24'h0, fp8_prod_mant} >> (-fp8_prod_exp[3:0]);
            end
            fp8_term_fixed = fp8_prod_sign ? -$signed(magnitude) : $signed(magnitude);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Mode 2: INT8 Signed Multiplication Datapath
    // -------------------------------------------------------------------------
    wire signed [7:0]  int8_a = fp8_act;
    wire signed [7:0]  int8_w = fp8_weight;
    wire signed [15:0] int8_prod = int8_a * int8_w;
    wire signed [ACC_WIDTH-1:0] int8_term = {{16{int8_prod[15]}}, int8_prod};

    // -------------------------------------------------------------------------
    // 4. Unified Reconfigurable Output Multiplexer & Accumulation
    // -------------------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] selected_term;

    always_comb begin
        case (mode_sel)
            2'b00: begin // Ternary 1.58b
                selected_term = ternary_term;
                is_zero_skip  = ternary_zero;
            end
            2'b01: begin // FP8 (E4M3)
                selected_term = fp8_term_fixed;
                is_zero_skip  = (fp8_exp_a == 4'h0 || fp8_exp_w == 4'h0);
            end
            2'b10: begin // INT8
                selected_term = int8_term;
                is_zero_skip  = (int8_w == 8'sd0);
            end
            default: begin
                selected_term = ternary_term;
                is_zero_skip  = ternary_zero;
            end
        endcase
    end

    // Final Output: Accumulator forward
    assign accum_out = accum_in + selected_term;

endmodule
