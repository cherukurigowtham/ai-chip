`timescale 1ns/1ps
module test_packed #(
    parameter ROWS = 4,
    parameter COLS = 4
)(
    input  logic clk,
    input  logic signed [15:0] w_in [ROWS-1:0][COLS-1:0],
    output logic signed [15:0] w_out [ROWS-1:0][COLS-1:0]
);
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_r
            for (c = 0; c < COLS; c++) begin : gen_c
                always_ff @(posedge clk) begin
                    w_out[r][c] <= w_in[r][c];
                end
            end
        end
    endgenerate
endmodule
