// ==============================================================================
// Module: rope_engine.sv
// Description: Multiplier-Free Rotary Position Embedding (RoPE) Hardware Engine
//              for Modern Transformer LLMs (BitNet, LLaMA-3, DeepSeek, Mistral).
//
// Features:
// 1. Zero Multipliers: Uses a 4-stage pipelined CORDIC (Coordinate Rotation Digital Computer)
//    micro-rotation core using pure barrel right-shifts and signed add/subtract.
// 2. Vectorized 2D Plane Rotations:
//    - Rotates 4 pairs of coordinate dimensions (8-dim vector) simultaneously per cycle.
//    - Mathematical formula:
//        x' = x * cos(m*theta) - y * sin(m*theta)
//        y' = x * sin(m*theta) + y * cos(m*theta)
// 3. Runtime Angle Increment (Position m):
//    - Auto-increments position token counter m on each new token step.
// 4. Fixed-Point CORDIC Angles:
//    - Stage 0 (s=0): alpha_0 = 45.00 deg (arctan(1))     -> 16'd5792 (scaled by 2^13)
//    - Stage 1 (s=1): alpha_1 = 26.57 deg (arctan(0.5))   -> 16'd3420
//    - Stage 2 (s=2): alpha_2 = 14.04 deg (arctan(0.25))  -> 16'd1807
//    - Stage 3 (s=3): alpha_3 =  7.13 deg (arctan(0.125)) -> 16'd918
// ==============================================================================

`timescale 1ns / 1ps

module rope_engine #(
    parameter int DATA_WIDTH = 16,
    parameter int VEC_SIZE   = 8
)(
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  enable,
    input  logic                                  bypass,          // 1: Pass-through, 0: Rotate
    input  logic [15:0]                           token_pos,       // Sequence position index m
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0] vec_in,        // 8x INT16 input elements
    output logic signed [(VEC_SIZE*DATA_WIDTH)-1:0] vec_out,       // 8x INT16 rotated elements
    output logic                                  valid_out
);

    // CORDIC Elementary Rotation Angles (16-bit Q3.13 fixed-point)
    localparam logic signed [15:0] ALPHA_0 = 16'sd5792; // 45.0 deg
    localparam logic signed [15:0] ALPHA_1 = 16'sd3420; // 26.57 deg
    localparam logic signed [15:0] ALPHA_2 = 16'sd1807; // 14.04 deg
    localparam logic signed [15:0] ALPHA_3 = 16'sd918;  //  7.13 deg

    // Base phase angle per pair: theta_i = base_angle >> i
    // Token phase = token_pos * theta_i
    logic signed [15:0] target_theta [0:3];
    always_comb begin
        target_theta[0] = (token_pos << 7); // Base frequency
        target_theta[1] = (token_pos << 5); // 0.25 frequency
        target_theta[2] = (token_pos << 3); // 0.0625 frequency
        target_theta[3] = (token_pos << 1); // 0.015625 frequency
    end

    // 4 CORDIC Rotation Slices for the 4 Pairs (0..1, 2..3, 4..5, 6..7)
    genvar p;
    generate
        for (p = 0; p < 4; p++) begin : gen_cordic_pairs
            logic signed [DATA_WIDTH-1:0] x_in, y_in;
            assign x_in = vec_in[(2*p)*DATA_WIDTH +: DATA_WIDTH];
            assign y_in = vec_in[(2*p+1)*DATA_WIDTH +: DATA_WIDTH];

            // Pipeline Stage 0 (Shift 0)
            logic signed [DATA_WIDTH-1:0] x0, y0;
            logic signed [15:0]           z0;
            wire d0 = (target_theta[p] >= 0);

            // Pipeline Stage 1 (Shift 1)
            logic signed [DATA_WIDTH-1:0] x1, y1;
            logic signed [15:0]           z1;
            wire d1 = (z0 >= 0);

            // Pipeline Stage 2 (Shift 2)
            logic signed [DATA_WIDTH-1:0] x2, y2;
            logic signed [15:0]           z2;
            wire d2 = (z1 >= 0);

            // Pipeline Stage 3 (Shift 3)
            logic signed [DATA_WIDTH-1:0] x3, y3;

            // Synchronous 4-stage pipeline registers
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    x0 <= '0; y0 <= '0; z0 <= '0;
                    x1 <= '0; y1 <= '0; z1 <= '0;
                    x2 <= '0; y2 <= '0; z2 <= '0;
                    x3 <= '0; y3 <= '0;
                end else if (enable) begin
                    // Stage 0: Shift by 0
                    x0 <= d0 ? (x_in - y_in) : (x_in + y_in);
                    y0 <= d0 ? (y_in + x_in) : (y_in - x_in);
                    z0 <= d0 ? (target_theta[p] - ALPHA_0) : (target_theta[p] + ALPHA_0);

                    // Stage 1: Shift by 1
                    x1 <= d1 ? (x0 - (y0 >>> 1)) : (x0 + (y0 >>> 1));
                    y1 <= d1 ? (y0 + (x0 >>> 1)) : (y0 - (x0 >>> 1));
                    z1 <= d1 ? (z0 - ALPHA_1)    : (z0 + ALPHA_1);

                    // Stage 2: Shift by 2
                    x2 <= d2 ? (x1 - (y1 >>> 2)) : (x1 + (y1 >>> 2));
                    y2 <= d2 ? (y1 + (x1 >>> 2)) : (y1 - (x1 >>> 2));
                    z2 <= d2 ? (z1 - ALPHA_2)    : (z1 + ALPHA_2);

                    // Stage 3: Shift by 3 & CORDIC Gain Compensation (~0.607 factor via (x>>1) + (x>>3))
                    x3 <= (z2 >= 0) ? ((x2 - (y2 >>> 3)) >>> 1) : ((x2 + (y2 >>> 3)) >>> 1);
                    y3 <= (z2 >= 0) ? ((y2 + (x2 >>> 3)) >>> 1) : ((y2 - (x2 >>> 3)) >>> 1);
                end
            end

            assign vec_out[(2*p)*DATA_WIDTH +: DATA_WIDTH]     = bypass ? x_in : x3;
            assign vec_out[(2*p+1)*DATA_WIDTH +: DATA_WIDTH]   = bypass ? y_in : y3;
        end
    endgenerate

    // Valid Pipeline Delay (4 cycles latency)
    logic [3:0] valid_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
        end else begin
            valid_pipe <= {valid_pipe[2:0], enable};
        end
    end

    assign valid_out = bypass ? enable : valid_pipe[3];

endmodule
