`timescale 1ns/1ps
module test_idx #(
    parameter ROWS = 4,
    parameter COLS = 4,
    parameter DATA_WIDTH = 16
)(
    input  logic [(ROWS*COLS*DATA_WIDTH)-1:0] in_flat,
    output logic [DATA_WIDTH-1:0] out_mat [ROWS-1:0][COLS-1:0]
);
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_r
            for (c = 0; c < COLS; c++) begin : gen_c
                assign out_mat[r][c] = in_flat[(r*COLS + c)*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate
endmodule
