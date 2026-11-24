// ==============================================================================
// Module: sparse_quad_vec_decompressor.sv
// Description: SIMD Quad-Vector 2:4 Structured Sparsity Decompressor & Dot-Product Engine.
//              Processes 4 parallel 2:4 groups (16 vector elements total, 8 active ops)
//              in a single clock cycle with zero hardware multipliers.
//
// Key Architecture:
// 1. Quad-Group 2:4 Parallelism:
//    - 4 independent 4-element groups (Groups 0..3).
//    - Each group: 2 non-zero ternary weights (2b each = 4b) + 3b pattern index = 7b.
//    - Total compressed weights: 4 x 7 = 28 bits (packed into rs2[27:0]).
// 2. High-Throughput SIMD Dot Product:
//    - Inputs 16 vector elements (e.g. INT8 / INT16 activations).
//    - Decompresses 16 ternary weights in parallel combinationally.
//    - Computes 8 non-zero signed ternary additions/subtractions in 1 cycle.
//    - Outputs full 32-bit accumulated result into rd in 1 cycle.
// ==============================================================================

`timescale 1ns / 1ps

module sparse_quad_vec_decompressor #(
    parameter int ACT_WIDTH = 8,   // INT8 activations
    parameter int ACC_WIDTH = 32   // INT32 accumulator
)(
    // Compressed 28-bit weights for 4 groups (each 7 bits: [6:4]=pattern, [3:2]=w1, [1:0]=w0)
    input  logic [27:0]                                 packed_sparse_weights,

    // 16-element activation vector (16 * 8b = 128b) or 4-channel broadcast (4 * 8b = 32b)
    input  logic signed [(16*ACT_WIDTH)-1:0]           act_vec_16_in,

    // Decompressed 16-weight ternary vector (16 * 2b = 32b) for diagnostics
    output logic [31:0]                                 decomp_weights_16_out,

    // 1-Cycle Accumulated 16-Element Dot Product
    output logic signed [ACC_WIDTH-1:0]                 quad_dot_out
);

    // Group-level intermediate signals
    logic [7:0]                 group_decomp_w [0:3];
    logic signed [ACC_WIDTH-1:0] group_dot      [0:3];

    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : gen_quad_groups
            wire [1:0] w0       = packed_sparse_weights[g*7 + 0 +: 2];
            wire [1:0] w1       = packed_sparse_weights[g*7 + 2 +: 2];
            wire [2:0] pattern  = packed_sparse_weights[g*7 + 4 +: 3];
            wire signed [(4*ACT_WIDTH)-1:0] act_group = act_vec_16_in[g*(4*ACT_WIDTH) +: (4*ACT_WIDTH)];

            logic signed [ACT_WIDTH-1:0] act0, act1, act2, act3;
            assign act0 = act_group[0*ACT_WIDTH +: ACT_WIDTH];
            assign act1 = act_group[1*ACT_WIDTH +: ACT_WIDTH];
            assign act2 = act_group[2*ACT_WIDTH +: ACT_WIDTH];
            assign act3 = act_group[3*ACT_WIDTH +: ACT_WIDTH];

            logic [1:0] w_rec [0:3];
            logic signed [ACT_WIDTH-1:0] op0_val, op1_val;

            always_comb begin
                w_rec[0] = 2'b00;
                w_rec[1] = 2'b00;
                w_rec[2] = 2'b00;
                w_rec[3] = 2'b00;
                op0_val  = act0;
                op1_val  = act1;

                case (pattern)
                    3'b000: begin // {0, 1}
                        w_rec[0] = w0; w_rec[1] = w1;
                        op0_val  = act0; op1_val = act1;
                    end
                    3'b001: begin // {0, 2}
                        w_rec[0] = w0; w_rec[2] = w1;
                        op0_val  = act0; op1_val = act2;
                    end
                    3'b010: begin // {0, 3}
                        w_rec[0] = w0; w_rec[3] = w1;
                        op0_val  = act0; op1_val = act3;
                    end
                    3'b011: begin // {1, 2}
                        w_rec[1] = w0; w_rec[2] = w1;
                        op0_val  = act1; op1_val = act2;
                    end
                    3'b100: begin // {1, 3}
                        w_rec[1] = w0; w_rec[3] = w1;
                        op0_val  = act1; op1_val = act3;
                    end
                    3'b101: begin // {2, 3}
                        w_rec[2] = w0; w_rec[3] = w1;
                        op0_val  = act2; op1_val = act3;
                    end
                    default: begin
                        w_rec[0] = w0; w_rec[1] = w1;
                        op0_val  = act0; op1_val = act1;
                    end
                endcase
            end

            assign group_decomp_w[g] = {w_rec[3], w_rec[2], w_rec[1], w_rec[0]};

            // 1-cycle multiplier-free ternary MAC: +val, -val, or 0
            logic signed [ACC_WIDTH-1:0] term0, term1;
            always_comb begin
                case (w0)
                    2'b01:   term0 = {{24{op0_val[ACT_WIDTH-1]}}, op0_val};
                    2'b10:   term0 = -{{24{op0_val[ACT_WIDTH-1]}}, op0_val};
                    default: term0 = '0;
                endcase

                case (w1)
                    2'b01:   term1 = {{24{op1_val[ACT_WIDTH-1]}}, op1_val};
                    2'b10:   term1 = -{{24{op1_val[ACT_WIDTH-1]}}, op1_val};
                    default: term1 = '0;
                endcase

                group_dot[g] = term0 + term1;
            end
        end
    endgenerate

    // Pack decompressed weights
    assign decomp_weights_16_out = {group_decomp_w[3], group_decomp_w[2], group_decomp_w[1], group_decomp_w[0]};

    // Parallel adder tree reduction across all 4 groups (16 elements, 8 active ops)
    assign quad_dot_out = group_dot[0] + group_dot[1] + group_dot[2] + group_dot[3];

endmodule
