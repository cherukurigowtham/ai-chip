// ==============================================================================
// Module: systolic_array_multiprecision.sv
// Description: Multiplier-Free Reconfigurable 8x8 Multi-Precision Systolic Array.
//              Supports:
//                1. Mode 0 (Ternary 1.58b) : 64 parallel ternary MACs / cycle.
//                2. Mode 1 (INT4 4-bit)    : 32 parallel INT4 MACs / cycle (PE pairing).
//                3. Mode 2 (INT8 8-bit)    : 16 parallel INT8 MACs / cycle (4-PE ganging).
//              Zero Hardware Multipliers (100% pure adder/subtractor silicon).
// ==============================================================================

`timescale 1ns / 1ps

module systolic_array_multiprecision #(
    parameter int DATA_WIDTH   = 16,
    parameter int ACCUM_WIDTH  = 32,
    parameter int WEIGHT_WIDTH = 2,
    parameter int ROWS         = 8,
    parameter int COLS         = 8
)(
    input  logic                                  clk,
    input  logic                                  rst_n,

    // Precision Selection
    input  logic [1:0]                            precision_mode, // 00: Ternary, 01: INT4, 10: INT8

    // Systolic Controls
    input  logic                                  enable,
    input  logic                                  mode_os,
    input  logic                                  weight_load,
    input  logic                                  weight_bank_sel,
    input  logic                                  double_buf_en,
    input  logic                                  accum_clear,

    // Streaming Inputs
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]   act_in,
    input  logic [(COLS*WEIGHT_WIDTH)-1:0]        weight_in,

    // Output Buses
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]  accum_out,
    output logic [(ROWS*COLS)-1:0]                zero_skips_vector
);

    // 2D Array Interconnect Wires
    logic signed [DATA_WIDTH-1:0]   horiz_act   [0:ROWS-1][0:COLS];
    logic [WEIGHT_WIDTH-1:0]        vert_weight [0:ROWS][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0]  pe_accum    [0:ROWS-1][0:COLS-1];
    logic                           pe_skips    [0:ROWS-1][0:COLS-1];

    // Assign Boundary Inputs
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_row_inputs
            assign horiz_act[r][0] = act_in[r*DATA_WIDTH +: DATA_WIDTH];
        end

        for (c = 0; c < COLS; c++) begin : gen_col_inputs
            assign vert_weight[0][c] = weight_in[c*WEIGHT_WIDTH +: WEIGHT_WIDTH];
        end
    endgenerate

    // 8x8 Grid of Reconfigurable Multi-Precision PEs
    generate
        for (r = 0; r < ROWS; r++) begin : gen_grid_rows
            for (c = 0; c < COLS; c++) begin : gen_grid_cols

                // Compute hardware shift amount for PE based on precision mode
                logic [2:0] pe_shift;
                always_comb begin
                    case (precision_mode)
                        2'b00:   pe_shift = 3'd0;           // Ternary: 0 shift
                        2'b01:   pe_shift = (c % 2) ? 3'd2 : 3'd0; // INT4: PE 0->0, PE 1->2
                        2'b10: begin // INT8: PE 0->0, PE 1->2, PE 2->4, PE 3->6
                            case (c % 4)
                                0: pe_shift = 3'd0;
                                1: pe_shift = 3'd2;
                                2: pe_shift = 3'd4;
                                default: pe_shift = 3'd6;
                            endcase
                        end
                        default: pe_shift = 3'd0;
                    endcase
                end

                pe_reconfigurable_multiprecision #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH),
                    .WEIGHT_WIDTH(WEIGHT_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .precision_mode(precision_mode),
                    .sub_shift(pe_shift),
                    .act_in(horiz_act[r][c]),
                    .weight_in(vert_weight[r][c]),
                    .weight_load(weight_load),
                    .weight_bank_sel(weight_bank_sel),
                    .double_buf_en(double_buf_en),
                    .mode_os(mode_os),
                    .accum_clear(accum_clear),
                    .enable(enable),
                    .act_out(horiz_act[r][c+1]),
                    .weight_out(vert_weight[r+1][c]),
                    .accum_out(pe_accum[r][c]),
                    .zero_skipped(pe_skips[r][c])
                );

                assign zero_skips_vector[r*COLS + c] = pe_skips[r][c];
            end
        end
    endgenerate

    // Precision Output Composition Logic
    // In Ternary mode: output each column directly.
    // In INT4 mode: sum adjacent column pairs: col[2c] + col[2c+1].
    // In INT8 mode: sum 4 adjacent columns: col[4c] + col[4c+1] + col[4c+2] + col[4c+3].
    generate
        for (c = 0; c < COLS; c++) begin : gen_output_mux
            always_comb begin
                case (precision_mode)
                    2'b00: begin // Ternary: Direct output
                        accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c];
                    end
                    2'b01: begin // INT4 Mode: Pair composition
                        if (c % 2 == 0) begin
                            accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c] + pe_accum[0][c+1];
                        end else begin
                            accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c];
                        end
                    end
                    2'b10: begin // INT8 Mode: 4-PE Gang composition
                        if (c % 4 == 0) begin
                            accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c]   + pe_accum[0][c+1] +
                                                                      pe_accum[0][c+2] + pe_accum[0][c+3];
                        end else begin
                            accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c];
                        end
                    end
                    default: accum_out[c*ACCUM_WIDTH +: ACCUM_WIDTH] = pe_accum[0][c];
                endcase
            end
        end
    endgenerate

endmodule
