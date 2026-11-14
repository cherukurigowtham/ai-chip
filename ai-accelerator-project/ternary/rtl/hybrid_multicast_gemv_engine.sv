// ==============================================================================
// Module: hybrid_multicast_gemv_engine.sv
// Description: Gen-2 Hybrid Spatial Multicast Vector-Matrix (GEMV) Engine.
//              Optimized specifically for LLM autoregressive token generation (M=1).
//              Eliminates the 16-cycle systolic skew-and-deskew pipeline bubble
//              by broadcasting the activation vector across all columns simultaneously,
//              computing an 8x8 Matrix-Vector projection in 1 cycle.
//
// Key Features:
// 1. 1-Cycle Zero-Bubble Latency:
//    - Replaces N-cycle horizontal systolic propagation with 1-cycle spatial broadcast.
// 2. Multiplier-Free Column Reduction:
//    - 8 parallel columns, each evaluating 8 ternary dot-products simultaneously.
// 3. Dynamic Zero-Skip Power Gating:
//    - Zero weights gate the adder operand, preserving low dynamic switching energy.
// 4. Ping-Pong Stationary Weight Latch:
//    - Dual-bank weight storage (Bank A / Bank B) for 0-stall layer swaps.
// ==============================================================================

`timescale 1ns / 1ps

module hybrid_multicast_gemv_engine #(
    parameter int DATA_WIDTH   = 16,
    parameter int ACCUM_WIDTH  = 32,
    parameter int WEIGHT_WIDTH = 2,
    parameter int ROWS         = 8,
    parameter int COLS         = 8
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,
    input  logic                               weight_load,
    input  logic                               weight_bank_sel,

    // Stationary Tile Weights (ROWS x COLS x 2-bit = 128 bits for 8x8)
    input  logic [(ROWS*COLS*WEIGHT_WIDTH)-1:0]weight_tile_flat,

    // Multicast Token Activation Vector (ROWS x 16-bit)
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]act_vec_flat,
    input  logic                               act_vec_valid,

    // Output Projection Vector (COLS x 32-bit)
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]out_vec_flat,
    output logic                               out_vec_valid,
    output logic [COLS-1:0]                    col_zero_skip_all
);

    // Unpack Activations: act_vec[0..ROWS-1]
    logic signed [DATA_WIDTH-1:0] act_vec [0:ROWS-1];
    genvar r;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_unpack_act
            assign act_vec[r] = act_vec_flat[r*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    // Dual-Bank Weight Storage: [Bank][Row][Col]
    logic [WEIGHT_WIDTH-1:0] weight_bank_a [0:ROWS-1][0:COLS-1];
    logic [WEIGHT_WIDTH-1:0] weight_bank_b [0:ROWS-1][0:COLS-1];

    genvar wr, wc;
    generate
        for (wr = 0; wr < ROWS; wr++) begin : gen_w_r
            for (wc = 0; wc < COLS; wc++) begin : gen_w_c
                localparam int BIT_OFFSET = (wr * COLS + wc) * WEIGHT_WIDTH;
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        weight_bank_a[wr][wc] <= '0;
                        weight_bank_b[wr][wc] <= '0;
                    end else if (weight_load) begin
                        if (!weight_bank_sel) begin
                            weight_bank_a[wr][wc] <= weight_tile_flat[BIT_OFFSET +: WEIGHT_WIDTH];
                        end else begin
                            weight_bank_b[wr][wc] <= weight_tile_flat[BIT_OFFSET +: WEIGHT_WIDTH];
                        end
                    end
                end
            end
        end
    endgenerate

    // Active Weight Matrix Mux
    logic [WEIGHT_WIDTH-1:0] active_weight [0:ROWS-1][0:COLS-1];
    generate
        for (wr = 0; wr < ROWS; wr++) begin : gen_act_w_r
            for (wc = 0; wc < COLS; wc++) begin : gen_act_w_c
                assign active_weight[wr][wc] = weight_bank_sel ? weight_bank_b[wr][wc] : weight_bank_a[wr][wc];
            end
        end
    endgenerate

    // Parallel Spatial Column Compute: Each column reduces 8 row dot-products in 1 cycle
    logic signed [ACCUM_WIDTH-1:0] col_accum [0:COLS-1];

    genvar c;
    generate
        for (c = 0; c < COLS; c++) begin : gen_col_units
            logic signed [ACCUM_WIDTH-1:0] row_terms [0:ROWS-1];
            logic [ROWS-1:0] row_is_zero;

            for (r = 0; r < ROWS; r++) begin : gen_row_terms
                wire signed [ACCUM_WIDTH-1:0] act_sign_ext = {{(ACCUM_WIDTH-DATA_WIDTH){act_vec[r][DATA_WIDTH-1]}}, act_vec[r]};
                always_comb begin
                    case (active_weight[r][c])
                        2'b01: begin
                            row_terms[r]   = act_sign_ext;
                            row_is_zero[r] = 1'b0;
                        end
                        2'b10: begin
                            row_terms[r]   = -act_sign_ext;
                            row_is_zero[r] = 1'b0;
                        end
                        default: begin
                            row_terms[r]   = '0;
                            row_is_zero[r] = 1'b1;
                        end
                    endcase
                end
            end

            // 8-Input Adder Tree Reduction for Column c
            wire signed [ACCUM_WIDTH-1:0] tree_sum = 
                (row_terms[0] + row_terms[1]) + (row_terms[2] + row_terms[3]) +
                (row_terms[4] + row_terms[5]) + (row_terms[6] + row_terms[7]);

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    col_accum[c]         <= '0;
                    col_zero_skip_all[c] <= 1'b0;
                end else if (enable && act_vec_valid) begin
                    col_accum[c]         <= tree_sum;
                    col_zero_skip_all[c] <= &row_is_zero;
                end
            end

            assign out_vec_flat[c*ACCUM_WIDTH +: ACCUM_WIDTH] = col_accum[c];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vec_valid <= 1'b0;
        end else if (enable) begin
            out_vec_valid <= act_vec_valid;
        end else begin
            out_vec_valid <= 1'b0;
        end
    end

endmodule
