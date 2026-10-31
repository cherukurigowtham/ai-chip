// ==============================================================================
// Module: pe_adaptive (Reconfigurable / Adaptive Processing Element)
// Description: Unified Dual-Mode PE supporting runtime switching between:
//              1. Weight-Stationary (WS) Mode (mode_os = 0):
//                 - Local weight register w_reg holds stationary weight.
//                 - Activations flow horizontally.
//                 - Partial sums flow vertically: psum_out = (act_in * w_reg) + psum_in.
//              2. Output-Stationary (OS) Mode (mode_os = 1):
//                 - Local accumulator accum_reg holds stationary output element.
//                 - Activations flow horizontally, weights flow vertically.
//                 - Local accumulation: accum_reg <= accum_reg + (act_in * weight_in).
//                 - Zero partial sum movement across the array during reduction!
//                 - When drain_en is asserted, completed outputs shift out vertically.
// ==============================================================================

`timescale 1ns / 1ps

module pe_adaptive #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               mode_os,      // 0: Weight-Stationary, 1: Output-Stationary
    input  logic                               enable,
    input  logic                               weight_load,  // WS only: latch stationary weight
    input  logic                               accum_clear,  // OS only: clear local accumulator
    input  logic                               drain_en,     // OS only: shift accumulator vertically

    input  logic signed [DATA_WIDTH-1:0]       act_in,
    input  logic signed [DATA_WIDTH-1:0]       weight_in,
    input  logic signed [ACCUM_WIDTH-1:0]      psum_in,

    output logic signed [DATA_WIDTH-1:0]       act_out,
    output logic signed [DATA_WIDTH-1:0]       weight_out,
    output logic signed [ACCUM_WIDTH-1:0]      psum_out
);

    // Internal Registers
    logic signed [DATA_WIDTH-1:0]  w_reg;
    logic signed [ACCUM_WIDTH-1:0] accum_reg;
    logic signed [ACCUM_WIDTH-1:0] psum_out_ws;

    // Unified Arithmetic Datapath
    logic signed [DATA_WIDTH-1:0]  mult_op_b;
    logic signed [ACCUM_WIDTH-1:0] adder_op_b;
    logic signed [ACCUM_WIDTH-1:0] mult_product;
    logic signed [ACCUM_WIDTH-1:0] adder_result;

    // In WS: multiply act_in * w_reg; In OS: multiply act_in * weight_in
    assign mult_op_b     = mode_os ? weight_in : w_reg;
    assign mult_product  = $signed(act_in) * $signed(mult_op_b);

    // In WS: add mult_product + psum_in; In OS: add mult_product + accum_reg
    assign adder_op_b    = mode_os ? accum_reg : psum_in;
    assign adder_result  = mult_product + adder_op_b;

    // Output selection: in OS, accumulator drives psum_out directly for 1-cycle vertical shift
    assign psum_out = mode_os ? accum_reg : psum_out_ws;

    // Sequential Logic
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_reg       <= '0;
            accum_reg   <= '0;
            act_out     <= '0;
            weight_out  <= '0;
            psum_out_ws <= '0;
        end else if (mode_os) begin
            // -------------------------------------------------------------
            // Output-Stationary (OS) Operation
            // -------------------------------------------------------------
            if (accum_clear) begin
                accum_reg <= '0;
            end else if (drain_en) begin
                // Shift accumulator vertically directly from psum_in
                accum_reg <= psum_in;
            end else if (enable) begin
                accum_reg  <= adder_result;
                act_out    <= act_in;
                weight_out <= weight_in;
            end
        end else begin
            // -------------------------------------------------------------
            // Weight-Stationary (WS) Operation
            // -------------------------------------------------------------
            if (weight_load) begin
                w_reg <= weight_in;
            end else if (enable) begin
                act_out     <= act_in;
                psum_out_ws <= adder_result;
            end
        end
    end

endmodule
