// ==============================================================================
// Module: systolic_array_ternary
// Description: Parameterized Adaptive Hybrid Binary-Ternary 2D Systolic Array Mesh.
//              - Default size: 8x8 (64 Processing Elements).
//              - Supports arbitrary ROWS and COLS via parameterized skew/deskew pipelines.
//              - In Weight-Stationary (WS) Mode (mode_os = 0):
//                  * 16-bit activations stream horizontally from left with row skewing (0..ROWS-1 delays).
//                  * 2-bit stationary weights loaded into local PE registers (ROWS*COLS*2 bits).
//                  * 32-bit partial sums accumulate vertically and emerge deskewed at bottom.
//              - In Output-Stationary (OS) Mode (mode_os = 1):
//                  * 16-bit activations stream horizontally from left with row skewing.
//                  * 2-bit weights stream vertically from top with column skewing (0..COLS-1 delays).
//                  * Accumulators remain stationary inside PEs during reduction (zero psum traffic!).
//                  * Final 32-bit outputs drained vertically in ROWS cycles upon drain_en assertion.
// ==============================================================================

`timescale 1ns / 1ps

module systolic_array_ternary #(
    parameter int DATA_WIDTH   = 16, // Activation width (16-bit)
    parameter int ACCUM_WIDTH  = 32, // Accumulator width (32-bit)
    parameter int WEIGHT_WIDTH = 2,  // Ternary weight width (2-bit)
    parameter int ROWS         = 8,  // Scaled 8x8
    parameter int COLS         = 8   // Scaled 8x8
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               mode_os,       // 0: WS, 1: OS
    input  logic                               enable,
    input  logic                               weight_load,   // WS mode: latch stationary weights
    input  logic                               accum_clear,   // OS mode: clear local accumulators
    input  logic                               drain_en,      // OS mode: shift accumulators vertically

    // Matrix Inputs
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]       act_in_flat,
    input  logic        [(COLS*WEIGHT_WIDTH)-1:0]     weight_in_col_flat, // OS mode: streaming weights
    input  logic        [(ROWS*COLS*WEIGHT_WIDTH)-1:0]weight_in_tile_flat,// WS mode: stationary tile

    // Outputs
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      psum_out_deskewed_flat,
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      drain_out_flat,
    output logic [ROWS*COLS-1:0]                      zero_skipped_flat
);

    // Unpack Inputs
    logic signed [DATA_WIDTH-1:0]   act_raw [0:ROWS-1];
    logic        [WEIGHT_WIDTH-1:0] weight_col_raw [0:COLS-1];
    logic        [WEIGHT_WIDTH-1:0] weight_tile_matrix [0:ROWS-1][0:COLS-1];

    genvar r_idx, c_idx;
    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_act
            assign act_raw[r_idx] = act_in_flat[r_idx*DATA_WIDTH +: DATA_WIDTH];
        end
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_w_col
            assign weight_col_raw[c_idx] = weight_in_col_flat[c_idx*WEIGHT_WIDTH +: WEIGHT_WIDTH];
        end
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_w_tile_r
            for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_w_tile_c
                assign weight_tile_matrix[r_idx][c_idx] =
                    weight_in_tile_flat[(r_idx*COLS + c_idx)*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Fully Parameterized Input Skewing Pipelines
    // -------------------------------------------------------------------------
    // Activation Row Skewing: Row r has r pipeline delay stages
    logic signed [DATA_WIDTH-1:0] act_skewed [0:ROWS-1];
    genvar r_skew;
    generate
        for (r_skew = 0; r_skew < ROWS; r_skew++) begin : gen_act_skew
            if (r_skew == 0) begin : gen_row0
                assign act_skewed[0] = act_raw[0];
            end else begin : gen_row_pipe
                logic signed [DATA_WIDTH-1:0] pipe [0:r_skew-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < r_skew; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= act_raw[r_skew];
                        for (int k = 1; k < r_skew; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign act_skewed[r_skew] = pipe[r_skew-1];
            end
        end
    endgenerate

    // Weight Column Skewing (Used in OS mode): Column c has c pipeline delay stages
    logic [WEIGHT_WIDTH-1:0] weight_skewed [0:COLS-1];
    genvar c_skew;
    generate
        for (c_skew = 0; c_skew < COLS; c_skew++) begin : gen_w_skew
            if (c_skew == 0) begin : gen_col0
                assign weight_skewed[0] = weight_col_raw[0];
            end else begin : gen_col_pipe
                logic [WEIGHT_WIDTH-1:0] pipe [0:c_skew-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < c_skew; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= weight_col_raw[c_skew];
                        for (int k = 1; k < c_skew; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign weight_skewed[c_skew] = pipe[c_skew-1];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 2D Mesh Interconnect
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]   act_mesh [0:ROWS-1][0:COLS];
    logic        [WEIGHT_WIDTH-1:0] weight_mesh [0:ROWS][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0]  psum_mesh [0:ROWS][0:COLS-1];
    logic                           skip_matrix [0:ROWS-1][0:COLS-1];

    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_left_bound
            assign act_mesh[r_idx][0] = act_skewed[r_idx];
        end
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_top_bound
            assign weight_mesh[0][c_idx] = weight_skewed[c_idx];
            assign psum_mesh[0][c_idx]   = '0;
        end
    endgenerate

    // Instantiate ROWS x COLS Ternary PEs (64 PEs for 8x8)
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_row
            for (c = 0; c < COLS; c++) begin : gen_col
                pe_ternary #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH),
                    .WEIGHT_WIDTH(WEIGHT_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .mode_os(mode_os),
                    .enable(enable),
                    .weight_load(weight_load),
                    .accum_clear(accum_clear),
                    .drain_en(drain_en),
                    .act_in(act_mesh[r][c]),
                    .weight_in(weight_mesh[r][c]),
                    .weight_tile_in(weight_tile_matrix[r][c]),
                    .psum_in(psum_mesh[r][c]),
                    .act_out(act_mesh[r][c+1]),
                    .weight_out(weight_mesh[r+1][c]),
                    .psum_out(psum_mesh[r+1][c]),
                    .zero_skipped(skip_matrix[r][c])
                );
                assign zero_skipped_flat[r*COLS + c] = skip_matrix[r][c];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // WS Output Deskewing Logic (Aligns all columns to emerge at the exact same cycle)
    // Column c requires (COLS - 1 - c) delay stages
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] ws_out [0:COLS-1];
    genvar c_deskew;
    generate
        for (c_deskew = 0; c_deskew < COLS; c_deskew++) begin : gen_deskew
            localparam int DELAY = COLS - 1 - c_deskew;
            if (DELAY == 0) begin : gen_deskew_zero
                assign ws_out[c_deskew] = psum_mesh[ROWS][c_deskew];
            end else begin : gen_deskew_pipe
                logic signed [ACCUM_WIDTH-1:0] pipe [0:DELAY-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < DELAY; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= psum_mesh[ROWS][c_deskew];
                        for (int k = 1; k < DELAY; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign ws_out[c_deskew] = pipe[DELAY-1];
            end
        end
    endgenerate

    generate
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_out_flat
            assign psum_out_deskewed_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = ws_out[c_idx];
            assign drain_out_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = psum_mesh[ROWS][c_idx];
        end
    endgenerate

endmodule
