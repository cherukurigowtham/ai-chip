// ==============================================================================
// Module: systolic_array_adaptive
// Description: 4x4 Adaptive 2D Systolic Mesh with Dual-Mode (WS/OS) Runtime Control.
//              - In Weight-Stationary (WS) Mode (mode_os = 0):
//                  * Activations stream from left with row skewing (0, 1, 2, 3).
//                  * Stationary weights loaded into local PE registers.
//                  * Partial sums accumulate vertically and emerge deskewed at bottom.
//              - In Output-Stationary (OS) Mode (mode_os = 1):
//                  * Activations stream from left with row skewing (0, 1, 2, 3).
//                  * Weights stream from top with column skewing (0, 1, 2, 3).
//                  * Accumulators remain stationary inside PEs during reduction (zero psum traffic!).
//                  * Final outputs drained vertically in 4 cycles upon assertion of drain_en.
// ==============================================================================

`timescale 1ns / 1ps

module systolic_array_adaptive #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32,
    parameter int ROWS        = 4,
    parameter int COLS        = 4
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               mode_os,       // 0: WS, 1: OS
    input  logic                               enable,
    input  logic                               weight_load,   // WS mode: latch stationary weights
    input  logic                               accum_clear,   // OS mode: clear local accumulators
    input  logic                               drain_en,      // OS mode: shift accumulators vertically

    // Matrix Inputs (Unskewed parallel vectors)
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]       act_in_flat,
    input  logic signed [(COLS*DATA_WIDTH)-1:0]       weight_in_col_flat, // OS mode: streaming weights
    input  logic signed [(ROWS*COLS*DATA_WIDTH)-1:0]  weight_in_tile_flat,// WS mode: stationary tile

    // Outputs
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      psum_out_deskewed_flat,
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      drain_out_flat
);

    // Unpack Inputs
    logic signed [DATA_WIDTH-1:0]  act_raw [0:ROWS-1];
    logic signed [DATA_WIDTH-1:0]  weight_col_raw [0:COLS-1];
    logic signed [DATA_WIDTH-1:0]  weight_tile_matrix [0:ROWS-1][0:COLS-1];

    genvar r_idx, c_idx;
    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_act
            assign act_raw[r_idx] = act_in_flat[r_idx*DATA_WIDTH +: DATA_WIDTH];
        end
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_w_col
            assign weight_col_raw[c_idx] = weight_in_col_flat[c_idx*DATA_WIDTH +: DATA_WIDTH];
        end
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_w_tile_r
            for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_w_tile_c
                assign weight_tile_matrix[r_idx][c_idx] =
                    weight_in_tile_flat[(r_idx*COLS + c_idx)*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Input Skewing Pipelines
    // -------------------------------------------------------------------------
    // Activation Row Skewing:
    // Row 0: 0 cycles delay
    // Row 1: 1 cycle delay
    // Row 2: 2 cycles delay
    // Row 3: 3 cycles delay
    logic signed [DATA_WIDTH-1:0] act_skewed [0:ROWS-1];
    logic signed [DATA_WIDTH-1:0] skew_act_r1 [0:0];
    logic signed [DATA_WIDTH-1:0] skew_act_r2 [0:1];
    logic signed [DATA_WIDTH-1:0] skew_act_r3 [0:2];

    // Weight Column Skewing (Used in OS mode):
    // Col 0: 0 cycles delay
    // Col 1: 1 cycle delay
    // Col 2: 2 cycles delay
    // Col 3: 3 cycles delay
    logic signed [DATA_WIDTH-1:0] weight_skewed [0:COLS-1];
    logic signed [DATA_WIDTH-1:0] skew_w_c1 [0:0];
    logic signed [DATA_WIDTH-1:0] skew_w_c2 [0:1];
    logic signed [DATA_WIDTH-1:0] skew_w_c3 [0:2];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            skew_act_r1[0] <= '0;
            skew_act_r2[0] <= '0; skew_act_r2[1] <= '0;
            skew_act_r3[0] <= '0; skew_act_r3[1] <= '0; skew_act_r3[2] <= '0;

            skew_w_c1[0] <= '0;
            skew_w_c2[0] <= '0; skew_w_c2[1] <= '0;
            skew_w_c3[0] <= '0; skew_w_c3[1] <= '0; skew_w_c3[2] <= '0;
        end else if (enable) begin
            // Activation skewing
            skew_act_r1[0] <= act_raw[1];
            skew_act_r2[0] <= act_raw[2];
            skew_act_r2[1] <= skew_act_r2[0];
            skew_act_r3[0] <= act_raw[3];
            skew_act_r3[1] <= skew_act_r3[0];
            skew_act_r3[2] <= skew_act_r3[1];

            // Weight column skewing (OS mode)
            skew_w_c1[0] <= weight_col_raw[1];
            skew_w_c2[0] <= weight_col_raw[2];
            skew_w_c2[1] <= skew_w_c2[0];
            skew_w_c3[0] <= weight_col_raw[3];
            skew_w_c3[1] <= skew_w_c3[0];
            skew_w_c3[2] <= skew_w_c3[1];
        end
    end

    assign act_skewed[0] = act_raw[0];
    assign act_skewed[1] = skew_act_r1[0];
    assign act_skewed[2] = skew_act_r2[1];
    assign act_skewed[3] = skew_act_r3[2];

    assign weight_skewed[0] = weight_col_raw[0];
    assign weight_skewed[1] = skew_w_c1[0];
    assign weight_skewed[2] = skew_w_c2[1];
    assign weight_skewed[3] = skew_w_c3[2];

    // -------------------------------------------------------------------------
    // 2D PE Mesh Interconnect
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]  act_mesh [0:ROWS-1][0:COLS];
    logic signed [DATA_WIDTH-1:0]  weight_mesh [0:ROWS][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] psum_mesh [0:ROWS][0:COLS-1];

    generate
        // Left boundary inputs
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_left_bound
            assign act_mesh[r_idx][0] = act_skewed[r_idx];
        end
        // Top boundary inputs
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_top_bound
            assign weight_mesh[0][c_idx] = weight_skewed[c_idx];
            assign psum_mesh[0][c_idx]   = '0; // 0 for WS top psum or OS drain top input
        end
    endgenerate

    // Instantiate 16 Adaptive PEs (Phase 20 Interconnect-Aware Direct Connections)
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_row
            for (c = 0; c < COLS; c++) begin : gen_col
                pe_adaptive #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
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
                    .psum_out(psum_mesh[r+1][c])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // WS Output Deskewing Logic (Aligns columns 0..3 to the same cycle)
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] deskew_c0 [0:2];
    logic signed [ACCUM_WIDTH-1:0] deskew_c1 [0:1];
    logic signed [ACCUM_WIDTH-1:0] deskew_c2 [0:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            deskew_c0[0] <= '0; deskew_c0[1] <= '0; deskew_c0[2] <= '0;
            deskew_c1[0] <= '0; deskew_c1[1] <= '0;
            deskew_c2[0] <= '0;
        end else if (enable) begin
            deskew_c0[0] <= psum_mesh[ROWS][0];
            deskew_c0[1] <= deskew_c0[0];
            deskew_c0[2] <= deskew_c0[1];

            deskew_c1[0] <= psum_mesh[ROWS][1];
            deskew_c1[1] <= deskew_c1[0];

            deskew_c2[0] <= psum_mesh[ROWS][2];
        end
    end

    // Deskewed WS outputs
    logic signed [ACCUM_WIDTH-1:0] ws_out [0:COLS-1];
    assign ws_out[0] = deskew_c0[2];
    assign ws_out[1] = deskew_c1[1];
    assign ws_out[2] = deskew_c2[0];
    assign ws_out[3] = psum_mesh[ROWS][3];

    generate
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_out_flat
            assign psum_out_deskewed_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = ws_out[c_idx];
            // In OS mode, row outputs emerge directly from psum_mesh[ROWS] during drain
            assign drain_out_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = psum_mesh[ROWS][c_idx];
        end
    endgenerate

endmodule
