// ==============================================================================
// Module: systolic_array_4x4
// Description: 4x4 2D Systolic Array for Weight-Stationary Matrix Multiplication.
//              - Instantiates 16 Processing Elements (pe.sv) in a 4x4 grid.
//              - Horizontal activation forwarding: PE[r, c].act_out -> PE[r, c+1].act_in.
//              - Vertical partial-sum forwarding:  PE[r, c].psum_out -> PE[r+1, c].psum_in.
//              - Built-in input skewing registers (Row r delayed by r cycles).
//              - Built-in output deskewing registers (Col c aligned by (ROWS-1-c) cycles).
//              - Supports synchronous reset, clock enable (stalling), and stationary weight latching.
// ==============================================================================

`timescale 1ns / 1ps

module systolic_array_4x4 #(
    parameter int DATA_WIDTH    = 16,
    parameter int ACCUM_WIDTH   = 32,
    parameter int ROWS          = 4,
    parameter int COLS          = 4,
    parameter bit INTERNAL_SKEW = 1'b1
)(
    input  logic                                            clk,
    input  logic                                            rst_n,        // Active-low synchronous reset
    input  logic                                            enable,       // Pipeline enable (stall control)
    input  logic                                            weight_load,  // Latch stationary weights into PEs

    // Weight input bus: 16 weights packed (PE[r][c] at index (r*COLS + c))
    input  logic signed [(ROWS*COLS*DATA_WIDTH)-1:0]        weight_in_flat,

    // Activation inputs from left boundary (Row 0..3)
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]             act_in_flat,

    // Partial sum inputs from top boundary (Col 0..3, typically 0 for fresh GEMM)
    input  logic signed [(COLS*ACCUM_WIDTH)-1:0]            psum_in_flat,

    // Raw systolic partial sum outputs emerging from bottom boundary (Row 3)
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]            psum_out_flat,

    // Deskewed partial sum outputs (aligned so all elements of output row i emerge simultaneously)
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]            psum_out_deskewed_flat,

    // Activations exiting right boundary (Row 0..3)
    output logic signed [(ROWS*DATA_WIDTH)-1:0]             act_out_flat
);

    // -------------------------------------------------------------------------
    // Internal Wires and Interconnect Meshes
    // -------------------------------------------------------------------------
    // Horizontal activation wires: act_mesh[r][c] is input to PE[r][c]
    // act_mesh[r][COLS] is output of PE[r][COLS-1]
    logic signed [DATA_WIDTH-1:0]  act_mesh [ROWS-1:0][COLS:0];

    // Vertical partial-sum wires: psum_mesh[r][c] is input to PE[r][c]
    // psum_mesh[ROWS][c] is output of PE[ROWS-1][c]
    logic signed [ACCUM_WIDTH-1:0] psum_mesh [ROWS:0][COLS-1:0];

    // Unpacked weights for each PE
    logic signed [DATA_WIDTH-1:0]  weight_matrix [ROWS-1:0][COLS-1:0];

    // Boundary unpacked signals
    logic signed [DATA_WIDTH-1:0]  act_in_raw   [ROWS-1:0];
    logic signed [DATA_WIDTH-1:0]  act_in_skewed[ROWS-1:0];
    logic signed [ACCUM_WIDTH-1:0] psum_in_unpacked [COLS-1:0];
    logic signed [ACCUM_WIDTH-1:0] psum_out_deskewed[COLS-1:0];

    // -------------------------------------------------------------------------
    // Unpack Boundary Ports
    // -------------------------------------------------------------------------
    genvar r_idx, c_idx;
    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_act
            assign act_in_raw[r_idx] = act_in_flat[(r_idx+1)*DATA_WIDTH-1 : r_idx*DATA_WIDTH];
            assign act_out_flat[(r_idx+1)*DATA_WIDTH-1 : r_idx*DATA_WIDTH] = act_mesh[r_idx][COLS];
        end

        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_psum
            assign psum_in_unpacked[c_idx] = psum_in_flat[(c_idx+1)*ACCUM_WIDTH-1 : c_idx*ACCUM_WIDTH];
            assign psum_out_flat[(c_idx+1)*ACCUM_WIDTH-1 : c_idx*ACCUM_WIDTH] = psum_mesh[ROWS][c_idx];
            assign psum_out_deskewed_flat[(c_idx+1)*ACCUM_WIDTH-1 : c_idx*ACCUM_WIDTH] = psum_out_deskewed[c_idx];
        end

        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_unpack_w_r
            for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_unpack_w_c
                assign weight_matrix[r_idx][c_idx] = weight_in_flat[(r_idx*COLS + c_idx)*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Input Skewing Logic
    // Row 0: 0 cycles delay
    // Row 1: 1 cycle delay
    // Row 2: 2 cycles delay
    // Row 3: 3 cycles delay
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] skew_r1 [0:0];
    logic signed [DATA_WIDTH-1:0] skew_r2 [0:1];
    logic signed [DATA_WIDTH-1:0] skew_r3 [0:2];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            skew_r1[0] <= '0;

            skew_r2[0] <= '0;
            skew_r2[1] <= '0;

            skew_r3[0] <= '0;
            skew_r3[1] <= '0;
            skew_r3[2] <= '0;
        end else if (enable) begin
            // Row 1 pipeline
            skew_r1[0] <= act_in_raw[1];

            // Row 2 pipeline
            skew_r2[0] <= act_in_raw[2];
            skew_r2[1] <= skew_r2[0];

            // Row 3 pipeline
            skew_r3[0] <= act_in_raw[3];
            skew_r3[1] <= skew_r3[0];
            skew_r3[2] <= skew_r3[1];
        end
    end

    generate
        if (INTERNAL_SKEW) begin : gen_skew_active
            assign act_in_skewed[0] = act_in_raw[0];
            assign act_in_skewed[1] = skew_r1[0];
            assign act_in_skewed[2] = skew_r2[1];
            assign act_in_skewed[3] = skew_r3[2];
        end else begin : gen_skew_bypass
            for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_bypass_r
                assign act_in_skewed[r_idx] = act_in_raw[r_idx];
            end
        end
    endgenerate

    // Connect left boundary inputs to PE col 0
    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_connect_left
            assign act_mesh[r_idx][0] = act_in_skewed[r_idx];
        end
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_connect_top
            assign psum_mesh[0][c_idx] = psum_in_unpacked[c_idx];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4x4 Processing Element Grid Instantiation
    // -------------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_row
            for (c = 0; c < COLS; c++) begin : gen_col
                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable(enable),
                    .weight_load(weight_load),
                    .weight_in(weight_matrix[r][c]),
                    .act_in(act_mesh[r][c]),
                    .psum_in(psum_mesh[r][c]),
                    .act_out(act_mesh[r][c+1]),
                    .psum_out(psum_mesh[r+1][c])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output Deskewing Logic
    // Col 0 emerges at cycle t = i + 3. Delay by 3 cycles.
    // Col 1 emerges at cycle t = i + 4. Delay by 2 cycles.
    // Col 2 emerges at cycle t = i + 5. Delay by 1 cycle.
    // Col 3 emerges at cycle t = i + 6. Delay by 0 cycles.
    // Result: All 4 outputs of batch row i emerge aligned in the exact same cycle!
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] deskew_c0 [0:2];
    logic signed [ACCUM_WIDTH-1:0] deskew_c1 [0:1];
    logic signed [ACCUM_WIDTH-1:0] deskew_c2 [0:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            deskew_c0[0] <= '0;
            deskew_c0[1] <= '0;
            deskew_c0[2] <= '0;

            deskew_c1[0] <= '0;
            deskew_c1[1] <= '0;

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

    assign psum_out_deskewed[0] = deskew_c0[2];
    assign psum_out_deskewed[1] = deskew_c1[1];
    assign psum_out_deskewed[2] = deskew_c2[0];
    assign psum_out_deskewed[3] = psum_mesh[ROWS][3];

endmodule
