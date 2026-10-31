// ==============================================================================
// Module: activation_buffer
// Description: On-chip Activation SRAM Scratchpad & Streaming Buffer.
//              - Stages matrix A activations fetched from DRAM.
//              - Streams ROWS elements (e.g. 4 signed 16-bit words) per clock cycle
//                into systolic array input skew registers.
//              - Reuses cached activations across multiple weight tiles without DRAM re-fetching.
// ==============================================================================

`timescale 1ns / 1ps

module activation_buffer #(
    parameter int DATA_WIDTH = 16,
    parameter int ROWS       = 4,
    parameter int BUFFER_VECS= 16 // Holds up to 16 activation vectors (16 x 4 = 64 words)
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Refill Interface from DRAM
    input  logic                                     dram_wr_en,
    input  logic [$clog2(BUFFER_VECS)-1:0]           vec_wr_addr,
    input  logic [$clog2(ROWS)-1:0]                  word_wr_addr,
    input  logic signed [DATA_WIDTH-1:0]             dram_wr_data,

    // Streaming Read Interface to Systolic Array
    input  logic                                     stream_rd_en,
    input  logic [$clog2(BUFFER_VECS)-1:0]           vec_rd_addr,
    output logic signed [(ROWS*DATA_WIDTH)-1:0]      act_vec_out,
    output logic                                     vec_valid
);

    // Internal 2D storage array
    logic signed [DATA_WIDTH-1:0] mem [BUFFER_VECS-1:0][ROWS-1:0];

    // Synchronous refill from DRAM
    always_ff @(posedge clk) begin
        if (dram_wr_en) begin
            mem[vec_wr_addr][word_wr_addr] <= dram_wr_data;
        end
    end

    // Synchronous read of a full activation vector (ROWS words) to systolic array
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            act_vec_out <= '0;
            vec_valid   <= 1'b0;
        end else if (stream_rd_en) begin
            for (int r = 0; r < ROWS; r++) begin
                act_vec_out[r*DATA_WIDTH +: DATA_WIDTH] <= mem[vec_rd_addr][r];
            end
            vec_valid <= 1'b1;
        end else begin
            vec_valid <= 1'b0;
        end
    end

endmodule
