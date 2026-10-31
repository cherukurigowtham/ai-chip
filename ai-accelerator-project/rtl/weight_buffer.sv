// ==============================================================================
// Module: weight_buffer
// Description: Double-buffered On-chip SRAM Weight Scratchpad.
//              - Stages weight tiles (ROWS x COLS) locally to eliminate repeated DRAM reads.
//              - Bank A (Ping) / Bank B (Pong) architecture enables overlap between
//                DRAM refills and systolic computation.
//              - Unloads complete 4x4 weight tile in a single cycle into array PEs.
// ==============================================================================

`timescale 1ns / 1ps

module weight_buffer #(
    parameter int DATA_WIDTH = 16,
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int NUM_TILES  = 4
)(
    input  logic                                            clk,
    input  logic                                            rst_n,

    // Write Port (DRAM refilling words into buffer)
    input  logic                                            dram_wr_en,
    input  logic [$clog2(NUM_TILES)-1:0]                   tile_wr_sel,
    input  logic [$clog2(ROWS*COLS)-1:0]                   word_wr_idx,
    input  logic signed [DATA_WIDTH-1:0]                    dram_wr_data,

    // Read Port (Systolic Array loading complete tile)
    input  logic                                            tile_rd_en,
    input  logic [$clog2(NUM_TILES)-1:0]                   tile_rd_sel,
    output logic signed [(ROWS*COLS*DATA_WIDTH)-1:0]        weight_tile_out,
    output logic                                            tile_valid
);

    localparam int TILE_WORDS = ROWS * COLS;

    // Storage for NUM_TILES tiles, each containing TILE_WORDS 16-bit words
    logic signed [DATA_WIDTH-1:0] storage [NUM_TILES-1:0][TILE_WORDS-1:0];

    // Synchronous write from DRAM interface
    always_ff @(posedge clk) begin
        if (dram_wr_en) begin
            storage[tile_wr_sel][word_wr_idx] <= dram_wr_data;
        end
    end

    // Synchronous read to Systolic Array
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_tile_out <= '0;
            tile_valid      <= 1'b0;
        end else if (tile_rd_en) begin
            for (int w = 0; w < TILE_WORDS; w++) begin
                weight_tile_out[w*DATA_WIDTH +: DATA_WIDTH] <= storage[tile_rd_sel][w];
            end
            tile_valid <= 1'b1;
        end else begin
            tile_valid <= 1'b0;
        end
    end

endmodule
