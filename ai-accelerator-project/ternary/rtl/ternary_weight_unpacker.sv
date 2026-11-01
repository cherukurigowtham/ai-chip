// ==============================================================================
// Module: ternary_weight_unpacker
// Description: Parameterized High-Throughput Ternary Weight Decoder / Unpacker.
//              - Default size: 8x8 (64 weights = 128 bits total).
//              - In Weight-Stationary (WS) Mode:
//                  * Unpacks 8 consecutive 16-bit DRAM memory words (128 bits)
//                    into the 8x8 stationary weight tile (64 weights x 2 bits).
//                  * Each 16-bit DRAM word contains 8 ternary weights = 1 full matrix row!
//              - In Output-Stationary (OS) Mode:
//                  * Unpacks 16-bit DRAM words into 8-weight parallel streaming
//                    column vectors (8 weights x 2 bits = 16 bits per cycle).
//              - Memory compression factor: 8.0x compared to 16-bit binary weights!
// ==============================================================================

`timescale 1ns / 1ps

module ternary_weight_unpacker #(
    parameter int DATA_WIDTH   = 16, // DRAM bus width (16 bits)
    parameter int WEIGHT_WIDTH = 2,  // Ternary weight width (2 bits)
    parameter int ROWS         = 8,
    parameter int COLS         = 8
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // DRAM Word Inputs
    input  logic                               word_valid,
    input  logic [DATA_WIDTH-1:0]              dram_word,
    input  logic                               is_tile_load, // 1: Loading stationary tile, 0: Streaming column
    input  logic [$clog2((ROWS*COLS*WEIGHT_WIDTH)/DATA_WIDTH)-1:0] tile_slice, // 0..7 for 8x8 tile

    // Unpacked Outputs
    output logic [(ROWS*COLS*WEIGHT_WIDTH)-1:0] weight_tile_flat, // 8x8 stationary tile (128 bits)
    output logic [(COLS*WEIGHT_WIDTH)-1:0]      weight_col_flat,  // 8-element column vector (16 bits)
    output logic                                unpack_ready
);

    localparam int TILE_WORDS = (ROWS * COLS * WEIGHT_WIDTH) / DATA_WIDTH;
    localparam int WEIGHTS_PER_WORD = DATA_WIDTH / WEIGHT_WIDTH; // 8 weights per 16-bit word

    // -------------------------------------------------------------------------
    // Stationary ROWS x COLS Weight Tile Register (64 weights x 2 bits = 128 bits)
    // -------------------------------------------------------------------------
    logic [WEIGHT_WIDTH-1:0] tile_regs [0:ROWS-1][0:COLS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    tile_regs[r][c] <= 2'b00;
                end
            end
        end else if (word_valid && is_tile_load) begin
            // Each 16-bit DRAM word carries WEIGHTS_PER_WORD (8) weights.
            // When COLS == WEIGHTS_PER_WORD (8 == 8), tile_slice directly addresses Row tile_slice!
            for (int c = 0; c < COLS; c++) begin
                if (c < WEIGHTS_PER_WORD) begin
                    tile_regs[tile_slice][c] <= dram_word[c*WEIGHT_WIDTH +: WEIGHT_WIDTH];
                end
            end
        end
    end

    // Flatten stationary tile
    genvar tr, tc;
    generate
        for (tr = 0; tr < ROWS; tr++) begin : gen_flat_tile_r
            for (tc = 0; tc < COLS; tc++) begin : gen_flat_tile_c
                assign weight_tile_flat[(tr*COLS + tc)*WEIGHT_WIDTH +: WEIGHT_WIDTH] = tile_regs[tr][tc];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Streaming Column Vector Unpacker (OS Mode)
    // For 8 columns x 2 bits = 16 bits: exactly 1 DRAM word per streaming cycle!
    // -------------------------------------------------------------------------
    logic [(COLS*WEIGHT_WIDTH)-1:0] stream_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_reg <= '0;
        end else if (word_valid && !is_tile_load) begin
            stream_reg <= dram_word[(COLS*WEIGHT_WIDTH)-1:0];
        end
    end

    assign weight_col_flat = (word_valid && !is_tile_load) ?
                             dram_word[(COLS*WEIGHT_WIDTH)-1:0] : stream_reg;

    assign unpack_ready = 1'b1;

endmodule
