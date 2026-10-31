// ==============================================================================
// Module: pe_os (Output-Stationary Processing Element)
// Description: Fixed Output-Stationary 16-bit MAC Processing Element.
//              - Output element remains stationary in local 32-bit register accum_reg.
//              - Activations flow horizontally: act_in -> act_out.
//              - Weights flow vertically: weight_in -> weight_out.
//              - Accumulation occurs locally: accum_reg <= accum_reg + (act_in * weight_in).
//              - Zero partial sum movement during reduction steps!
//              - When drain_en is asserted, accumulated outputs shift vertically down.
// ==============================================================================

`timescale 1ns / 1ps

module pe_os #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,
    input  logic                               accum_clear,
    input  logic                               drain_en,
    input  logic signed [DATA_WIDTH-1:0]       act_in,
    input  logic signed [DATA_WIDTH-1:0]       weight_in,
    input  logic signed [ACCUM_WIDTH-1:0]      drain_in,
    output logic signed [DATA_WIDTH-1:0]       act_out,
    output logic signed [DATA_WIDTH-1:0]       weight_out,
    output logic signed [ACCUM_WIDTH-1:0]      drain_out
);

    // Local stationary accumulator register
    logic signed [ACCUM_WIDTH-1:0] accum_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            accum_reg  <= '0;
            act_out    <= '0;
            weight_out <= '0;
            drain_out  <= '0;
        end else begin
            if (accum_clear) begin
                accum_reg <= '0;
            end else if (drain_en) begin
                // Shift accumulator down vertically through the array
                drain_out <= accum_reg;
                accum_reg <= drain_in;
            end else if (enable) begin
                accum_reg  <= accum_reg + (32'($signed(act_in)) * 32'($signed(weight_in)));
                act_out    <= act_in;
                weight_out <= weight_in;
            end
        end
    end

endmodule
