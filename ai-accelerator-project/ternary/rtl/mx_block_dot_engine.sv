// =============================================================================
// Module: mx_block_dot_engine.sv
// Description: Multiplier-Free 1-Cycle Microscaling (MX-FP / Block Floating Point)
//              Vector Dot-Product Engine for the BitNet-130 Universal Processor.
//
// Functionality:
//   Accelerates OCP Microscaling (MX) formats used in frontier 2026 models
//   (DeepSeek V3, Llama 3.3, MXFP4, MXFP6, MXINT8).
//
//   Operates on a 4-element block vector:
//   - rs1: Four signed 8-bit activations {x3, x2, x1, x0}
//   - rs2: Shared block exponent scale E (2^E) + ternary / INT4 weights
//
//   Computation:
//     Sum = sum_{i=0..3} (x_i * w_i)
//     Result = (Sum << E) or (Sum >>> E) with 32-bit signed saturation.
//
// Silicon Target: 500 MHz (2.0 ns) | Process: SkyWater Sky130 / Nangate 45nm
// Multiplier Usage: ZERO (Multiplexers, shift-adds, barrel shift, saturation)
// =============================================================================

`timescale 1ns/1ps

module mx_block_dot_engine (
    // Four 8-bit signed activations packed into rs1
    input  logic signed [31:0] act_vector_in,

    // Exponent scale factor + Weights packed into rs2:
    //   [31:28]: Shared Block Scale Exponent E (0..15)
    //   [25]   : Weight mode: 1'b0 = Ternary {-1,0,+1}, 1'b1 = 4-bit signed INT4
    //   [24]   : Direction:   1'b0 = Scale Up (<< E),   1'b1 = Scale Down (>>> E)
    //   [15:0] : Packed weights:
    //            If Ternary: w0=[1:0], w1=[3:2], w2=[5:4], w3=[7:6]
    //            If INT4:    w0=[3:0], w1=[7:4], w2=[11:8], w3=[15:12]
    input  logic        [31:0] config_weight_in,

    // Scaled 32-bit signed dot product output
    output logic signed [31:0] result_dot_out
);

    // -------------------------------------------------------------------------
    // 1. Unpack Inputs & Configuration
    // -------------------------------------------------------------------------
    logic signed [7:0]  x0, x1, x2, x3;
    assign x0 = act_vector_in[7:0];
    assign x1 = act_vector_in[15:8];
    assign x2 = act_vector_in[23:16];
    assign x3 = act_vector_in[31:24];

    logic [3:0]  scale_exp;
    logic        scale_down;
    logic        mode_int4;

    assign scale_exp   = config_weight_in[31:28];
    assign mode_int4   = config_weight_in[25];
    assign scale_down  = config_weight_in[24];

    // -------------------------------------------------------------------------
    // 2. Multiplier-Free Partial Product Generation
    // -------------------------------------------------------------------------
    logic signed [15:0] prod0, prod1, prod2, prod3;

    // Helper function for multiplier-free INT4 x INT8 signed product
    // w in [-8..+7]: w = w[0] + 2*w[1] + 4*w[2] - 8*w[3]
    function automatic logic signed [15:0] calc_int4_prod(
        input logic signed [7:0] act,
        input logic        [3:0] wgt
    );
        logic signed [15:0] ext_act;
        logic signed [15:0] p;
        ext_act = {{8{act[7]}}, act};
        p = 16'sd0;
        if (wgt[0]) p = p + ext_act;
        if (wgt[1]) p = p + (ext_act <<< 1);
        if (wgt[2]) p = p + (ext_act <<< 2);
        if (wgt[3]) p = p - (ext_act <<< 3);
        calc_int4_prod = p;
    endfunction

    always_comb begin
        if (!mode_int4) begin
            // Ternary Mode: w in {00: 0, 01: +1, 10: -1}
            case (config_weight_in[1:0])
                2'b01:   prod0 = {{8{x0[7]}}, x0};
                2'b10:   prod0 = -{{8{x0[7]}}, x0};
                default: prod0 = 16'sd0;
            endcase

            case (config_weight_in[3:2])
                2'b01:   prod1 = {{8{x1[7]}}, x1};
                2'b10:   prod1 = -{{8{x1[7]}}, x1};
                default: prod1 = 16'sd0;
            endcase

            case (config_weight_in[5:4])
                2'b01:   prod2 = {{8{x2[7]}}, x2};
                2'b10:   prod2 = -{{8{x2[7]}}, x2};
                default: prod2 = 16'sd0;
            endcase

            case (config_weight_in[7:6])
                2'b01:   prod3 = {{8{x3[7]}}, x3};
                2'b10:   prod3 = -{{8{x3[7]}}, x3};
                default: prod3 = 16'sd0;
            endcase
        end else begin
            // INT4 Mode: 4-bit signed shift-and-add
            prod0 = calc_int4_prod(x0, config_weight_in[3:0]);
            prod1 = calc_int4_prod(x1, config_weight_in[7:4]);
            prod2 = calc_int4_prod(x2, config_weight_in[11:8]);
            prod3 = calc_int4_prod(x3, config_weight_in[15:12]);
        end
    end

    // -------------------------------------------------------------------------
    // 3. Parallel Reduction Tree & Exponent Microscaling
    // -------------------------------------------------------------------------
    logic signed [17:0] raw_sum;
    assign raw_sum = prod0 + prod1 + prod2 + prod3;

    logic signed [35:0] ext_sum;
    assign ext_sum = {{18{raw_sum[17]}}, raw_sum};

    logic signed [35:0] scaled_sum;

    always_comb begin
        if (scale_down) begin
            // Attenuation: Arithmetic right shift by scale_exp
            scaled_sum = ext_sum >>> scale_exp;
        end else begin
            // Amplification: Arithmetic left shift by scale_exp
            scaled_sum = ext_sum <<< scale_exp;
        end
    end

    // -------------------------------------------------------------------------
    // 4. 32-Bit Signed Saturation Clamp
    // -------------------------------------------------------------------------
    always_comb begin
        if (scaled_sum > 36'sh0_7FFF_FFFF) begin
            result_dot_out = 32'sh7FFF_FFFF;
        end else if (scaled_sum < -36'sh0_8000_0000) begin
            result_dot_out = 32'sh8000_0000;
        end else begin
            result_dot_out = scaled_sum[31:0];
        end
    end

endmodule
