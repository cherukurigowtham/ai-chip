// ==============================================================================
// Module: pe_ws (Weight-Stationary Processing Element)
// Description: Fixed Weight-Stationary 16-bit MAC Processing Element.
//              - Weights remain stationary in local 16-bit register w_reg.
//              - Activations flow horizontally: act_in -> act_out.
//              - Partial sums accumulate vertically: psum_out = (act_in * w_reg) + psum_in.
//              - Target: Baseline reference for Weight-Stationary execution.
// ==============================================================================

`timescale 1ns / 1ps

module pe_ws #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,
    input  logic                               weight_load,
    input  logic signed [DATA_WIDTH-1:0]       weight_in,
    input  logic signed [DATA_WIDTH-1:0]       act_in,
    input  logic signed [ACCUM_WIDTH-1:0]      psum_in,
    output logic signed [DATA_WIDTH-1:0]       act_out,
    output logic signed [ACCUM_WIDTH-1:0]      psum_out
);

    // Local stationary weight register
    logic signed [DATA_WIDTH-1:0] w_reg;

    // Registered outputs
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_reg    <= '0;
            act_out  <= '0;
            psum_out <= '0;
        end else if (weight_load) begin
            w_reg <= weight_in;
        end else if (enable) begin
            act_out  <= act_in;
            psum_out <= (32'($signed(act_in)) * 32'($signed(w_reg))) + psum_in;
        end
    end

endmodule
