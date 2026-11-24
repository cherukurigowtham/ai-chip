// ==============================================================================
// Module: sparse_2_4_ternary_decompressor.sv
// Description: Hardware 2:4 Semi-Structured Sparse Ternary Decompressor & Matrix Engine.
//              Implements NVIDIA Ampere/Hopper/Blackwell-style 2:4 structured sparsity
//              for ternary weights (W in {-1, 0, +1}).
//
// Key Specifications:
// 1. 2:4 Structured Sparsity Model:
//    - In every contiguous group of 4 weights, exactly 2 are non-zero ({-1, +1})
//      and exactly 2 are zero (0).
//    - Reduces effective storage to 50% non-zero weights and doubles compute density!
// 2. Ultra-Fast Combinational Decompression:
//    - Reconstructs full 4-element ternary vector from:
//        * 2 non-zero weights: w_val0, w_val1 (2 bits each: 2'b01=+1, 2'b10=-1)
//        * 3-bit pattern index (idx in 0..5):
//            3'b000: positions {0, 1}
//            3'b001: positions {0, 2}
//            3'b010: positions {0, 3}
//            3'b011: positions {1, 2}
//            3'b100: positions {1, 3}
//            3'b101: positions {2, 3}
// 3. 1-Cycle Spatial Dot-Product Accelerator:
//    - Computes 4-element inner product with INT16 activations in 1 cycle:
//        Dot = (w_val0 * act[pos0]) + (w_val1 * act[pos1])
//    - Requires ONLY 2 add/sub operations instead of 4 (50% arithmetic reduction)!
// ==============================================================================

`timescale 1ns / 1ps

module sparse_2_4_ternary_decompressor #(
    parameter int DATA_WIDTH = 16, // INT16 activation width
    parameter int ACC_WIDTH  = 32  // INT32 accumulator width
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Compressed 2:4 Weight Input (7 bits per 4-weight group)
    input  logic [1:0]                               w_val0,      // Non-zero weight 0 (2'b01=+1, 2'b10=-1)
    input  logic [1:0]                               w_val1,      // Non-zero weight 1 (2'b01=+1, 2'b10=-1)
    input  logic [2:0]                               w_pattern,   // 3-bit sparsity pattern code (0..5)

    // 4-Element Activation Vector
    input  logic signed [(4*DATA_WIDTH)-1:0]         act_vec_4_in,

    // Decompressed 4-Weight Vector (For diagnostic / standard PE fallback)
    output logic [7:0]                               decomp_weights_out, // 4 weights x 2 bits

    // 1-Cycle Sparse Dot Product Output
    output logic signed [ACC_WIDTH-1:0]              sparse_dot_out
);

    // Unpack 4 activations
    logic signed [DATA_WIDTH-1:0] act [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : gen_unpack_act
            assign act[i] = act_vec_4_in[i*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 1. Combinational Decompression: Pattern Index to 4 Ternary Weights
    // -------------------------------------------------------------------------
    logic [1:0] w_rec [0:3];
    logic [1:0] pos0, pos1;

    always_comb begin
        // Defaults
        w_rec[0] = 2'b00;
        w_rec[1] = 2'b00;
        w_rec[2] = 2'b00;
        w_rec[3] = 2'b00;
        pos0     = 2'd0;
        pos1     = 2'd1;

        case (w_pattern)
            3'b000: begin // Positions {0, 1}
                w_rec[0] = w_val0;
                w_rec[1] = w_val1;
                pos0     = 2'd0;
                pos1     = 2'd1;
            end
            3'b001: begin // Positions {0, 2}
                w_rec[0] = w_val0;
                w_rec[2] = w_val1;
                pos0     = 2'd0;
                pos1     = 2'd2;
            end
            3'b010: begin // Positions {0, 3}
                w_rec[0] = w_val0;
                w_rec[3] = w_val1;
                pos0     = 2'd0;
                pos1     = 2'd3;
            end
            3'b011: begin // Positions {1, 2}
                w_rec[1] = w_val0;
                w_rec[2] = w_val1;
                pos0     = 2'd1;
                pos1     = 2'd2;
            end
            3'b100: begin // Positions {1, 3}
                w_rec[1] = w_val0;
                w_rec[3] = w_val1;
                pos0     = 2'd1;
                pos1     = 2'd3;
            end
            3'b101: begin // Positions {2, 3}
                w_rec[2] = w_val0;
                w_rec[3] = w_val1;
                pos0     = 2'd2;
                pos1     = 2'd3;
            end
            default: begin
                w_rec[0] = w_val0;
                w_rec[1] = w_val1;
                pos0     = 2'd0;
                pos1     = 2'd1;
            end
        endcase
    end

    assign decomp_weights_out = {w_rec[3], w_rec[2], w_rec[1], w_rec[0]};

    // -------------------------------------------------------------------------
    // 2. High-Efficiency Sparse Dot Product (Only 2 Operations!)
    // -------------------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] term0, term1;

    always_comb begin
        // Term 0
        case (w_val0)
            2'b01:   term0 = {{16{act[pos0][DATA_WIDTH-1]}}, act[pos0]};      // +1 * act
            2'b10:   term0 = -{{16{act[pos0][DATA_WIDTH-1]}}, act[pos0]};     // -1 * act
            default: term0 = '0;
        endcase

        // Term 1
        case (w_val1)
            2'b01:   term1 = {{16{act[pos1][DATA_WIDTH-1]}}, act[pos1]};      // +1 * act
            2'b10:   term1 = -{{16{act[pos1][DATA_WIDTH-1]}}, act[pos1]};     // -1 * act
            default: term1 = '0;
        endcase

        // Sum of the 2 active terms (2 zero positions are completely bypassed!)
        sparse_dot_out = term0 + term1;
    end

endmodule
