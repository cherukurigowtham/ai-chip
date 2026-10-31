// ==============================================================================
// Module: pe (Processing Element)
// Description: 16-bit signed Processing Element for Weight-Stationary Systolic Array.
//              - Stores stationary weight in local register.
//              - Multiplies 16-bit signed activation by stationary weight.
//              - Accumulates with 32-bit signed incoming partial sum.
//              - Forwards activation horizontally to right neighbor.
//              - Forwards accumulated partial sum vertically to bottom neighbor.
// ==============================================================================

`timescale 1ns / 1ps

module pe #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32
)(
    input  logic                          clk,
    input  logic                          rst_n,        // Active-low synchronous reset
    input  logic                          enable,       // Pipeline clock enable
    input  logic                          weight_load,  // Load enable for stationary weight
    input  logic signed [DATA_WIDTH-1:0]  weight_in,    // Weight operand to latch
    input  logic signed [DATA_WIDTH-1:0]  act_in,       // Incoming activation from left
    input  logic signed [ACCUM_WIDTH-1:0] psum_in,      // Incoming partial sum from top
    output logic signed [DATA_WIDTH-1:0]  act_out,      // Registered activation to right
    output logic signed [ACCUM_WIDTH-1:0] psum_out      // Registered partial sum to bottom
);

    // Internal registers
    logic signed [DATA_WIDTH-1:0]  weight_reg;
    logic signed [ACCUM_WIDTH-1:0] mult_product;

    // Signed multiplication: 16-bit x 16-bit -> 32-bit signed product
    always_comb begin
        mult_product = act_in * weight_reg;
    end

    // Synchronous state updates
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_reg <= '0;
            act_out    <= '0;
            psum_out   <= '0;
        end else if (enable) begin
            // Latch weight when weight_load is asserted
            if (weight_load) begin
                weight_reg <= weight_in;
            end

            // Forward activation horizontally
            act_out <= act_in;

            // Compute and forward partial sum vertically
            psum_out <= psum_in + mult_product;
        end
    end

endmodule
