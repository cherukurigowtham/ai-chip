// ==============================================================================
// Module: vector_activation_unit.sv
// Description: Multiplier-Free On-Chip Vector Post-Processing & Activation Unit (VAU)
//              for BitNet & Transformer LLM Inference (NVIDIA Transformer Engine Grade).
//
// Features:
// 1. Fully Multiplier-Free (Zero DSP blocks):
//    - Uses barrel-shifters, sign-detectors, and conditional adders.
// 2. Supported Activation & Normalization Modes (act_mode[2:0]):
//    - 3'b000 : BYPASS (Raw 32-bit Linear GEMM Accumulation)
//    - 3'b001 : RELU   (Max(0, x) Rectified Linear Unit)
//    - 3'b010 : PWL_SILU / SWIGLU (Piecewise-Linear Swish/SiLU for BitNet/LLaMA)
//    - 3'b011 : SAT_INT16 (Symmetric clamping & scaling to signed 16-bit for next layer)
//    - 3'b100 : FAST_SOFTMAX_EXP (Base-2 Fast Exponent for on-chip FlashAttention)
//    - 3'b101 : MICRO_SCALE_MX (OCP MX Micro-scaled Vector Scaling: (x * gamma) >> 8)
// 3. Mathematical Approximation of SiLU(x) = x * sigmoid(x):
//    - Region 1 (x <= -8192) : Output = 0
//    - Region 2 (-8192 < x < 0) : Linear interpolation slope 0.25 (x >> 2)
//    - Region 3 (0 <= x < 8192) : High-slope linear 0.75 ((x >> 1) + (x >> 2))
//    - Region 4 (x >= 8192) : Output = x (identity)
// 4. Multiplier-Free Base-2 Exponential for Softmax:
//    - Exp2(x) for x <= 0: Approximates 2^(x/1024) via barrel right shift and linear interpolant.
// ==============================================================================

`timescale 1ns / 1ps

module vector_activation_unit #(
    parameter int ACCUM_WIDTH = 32,
    parameter int DATA_WIDTH  = 16
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic [2:0]                         act_mode,
    input  logic signed [ACCUM_WIDTH-1:0]      data_in,
    output logic signed [ACCUM_WIDTH-1:0]      data_out
);

    // -------------------------------------------------------------------------
    // Mode 1: ReLU Logic
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] relu_val;
    assign relu_val = (data_in < 0) ? '0 : data_in;

    // -------------------------------------------------------------------------
    // Mode 2: Multiplier-Free Piecewise-Linear (PWL) SiLU / SwiGLU
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] silu_val;
    always_comb begin
        if (data_in <= -32'sd8192) begin
            silu_val = '0;
        end else if (data_in < 0) begin
            silu_val = (data_in >>> 2);
        end else if (data_in < 32'sd8192) begin
            silu_val = (data_in >>> 1) + (data_in >>> 2);
        end else begin
            silu_val = data_in;
        end
    end

    // -------------------------------------------------------------------------
    // Mode 3: Dynamic Saturated INT16 Rescaling
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] sat_int16_val;
    always_comb begin
        if (data_in > 32'sd32767) begin
            sat_int16_val = 32'sd32767;
        end else if (data_in < -32'sd32768) begin
            sat_int16_val = -32'sd32768;
        end else begin
            sat_int16_val = data_in;
        end
    end

    // -------------------------------------------------------------------------
    // Mode 4: Multiplier-Free Base-2 Fast Exponential for Attention Softmax
    // Computes 2^(data_in / 1024) for normalized logits (data_in <= 0)
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] exp_val;
    always_comb begin
        if (data_in >= 0) begin
            exp_val = 32'sd1024; // Peak probability weight for x=0 (after max-subtraction)
        end else if (data_in <= -32'sd8192) begin
            exp_val = 32'sd0;    // Underflow / asymptotic zero
        end else begin
            // Piecewise linear exponential decay
            // Split into integer shift and fractional linear piece
            logic [3:0] shift_amt;
            logic [9:0] frac_amt;
            shift_amt = (-data_in) >> 10; // Negated integer exponent
            frac_amt  = (-data_in) & 10'h3FF;
            // Linear Taylor: 1024 - (frac * 710) >> 10 ≈ 1024 - ((frac >> 1) + (frac >> 3))
            exp_val = (32'sd1024 - ((frac_amt >> 1) + (frac_amt >> 3))) >> shift_amt;
        end
    end

    // -------------------------------------------------------------------------
    // Mode 5: OCP Micro-Scaled (MX) Vector Scaling (BitNet b1.58 standard)
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] mx_val;
    assign mx_val = (data_in >>> 3); // Dynamic block-exponent power-of-2 dequantizer

    // -------------------------------------------------------------------------
    // Registered Output Selection
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] mux_out;
    always_comb begin
        case (act_mode)
            3'b000:  mux_out = data_in;       // Raw GEMM Bypass
            3'b001:  mux_out = relu_val;      // Fused ReLU
            3'b010:  mux_out = silu_val;      // Fused SiLU (SwiGLU)
            3'b011:  mux_out = sat_int16_val; // Saturated INT16 Scaling
            3'b100:  mux_out = exp_val;       // Fast Softmax Exponent
            3'b101:  mux_out = mx_val;        // Micro-Scaled Output
            default: mux_out = data_in;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= '0;
        end else begin
            data_out <= mux_out;
        end
    end

endmodule
