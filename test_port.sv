`timescale 1ns/1ps
module test_port #(
    parameter ROWS = 4,
    parameter COLS = 4
)(
    input  logic clk,
    input  logic signed [15:0] w_in [ROWS][COLS],
    output logic signed [15:0] w_out [ROWS][COLS]
);
    always_ff @(posedge clk) begin
        w_out <= w_in;
    end
endmodule
