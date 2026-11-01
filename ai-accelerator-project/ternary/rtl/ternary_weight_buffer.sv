// ==============================================================================
// Module: ternary_weight_buffer
// Description: Compact On-Chip SRAM / Register File for Ternary Weights.
//              - In Output-Stationary (OS) Mode:
//                  * Buffers up to BUFFER_VECS streaming weight column vectors.
//                  * Each vector is 4 elements x 2 bits = 8 bits wide (8.0x smaller
//                    than 64-bit binary weight vectors!).
//                  * Pipelined read path for 500 MHz static timing closure.
//              - In Weight-Stationary (WS) Mode:
//                  * Holds the 32-bit unpacked 4x4 stationary tile directly.
// ==============================================================================

`timescale 1ns / 1ps

module ternary_weight_buffer #(
    parameter int WEIGHT_WIDTH = 2,
    parameter int COLS         = 4,
    parameter int BUFFER_VECS  = 64
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Write Port (from Unpacker / DRAM)
    input  logic                               wr_en,
    input  logic [$clog2(BUFFER_VECS)-1:0]     wr_addr,
    input  logic [(COLS*WEIGHT_WIDTH)-1:0]     wr_data,

    // Read Port (to Systolic Array)
    input  logic                               rd_en,
    input  logic [$clog2(BUFFER_VECS)-1:0]     rd_addr,
    output logic [(COLS*WEIGHT_WIDTH)-1:0]     rd_data_pipe
);

    // 8-bit wide storage per vector (vs 64-bit in binary baseline)
    localparam int VEC_WIDTH = COLS * WEIGHT_WIDTH;
    logic [VEC_WIDTH-1:0] mem [0:BUFFER_VECS-1];

    // Synchronous Write
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // Registered Read Path (Eliminates SRAM Mux delay from Systolic Array critical path)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data_pipe <= '0;
        end else if (rd_en) begin
            rd_data_pipe <= mem[rd_addr];
        end
    end

endmodule
