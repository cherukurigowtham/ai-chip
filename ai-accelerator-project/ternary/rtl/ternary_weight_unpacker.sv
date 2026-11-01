// ==============================================================================
// Module: ternary_weight_unpacker
// Description: High-throughput Ternary Weight Decoder / Unpacker.
//              - Unpacks 16-bit DRAM memory words into 2-bit ternary weights.
//              - In Weight-Stationary (WS) Mode:
//                  * Unpacks two 16-bit DRAM words (32 bits total) into the
//                    complete 4x4 stationary weight tile (16 weights x 2 bits).
//              - In Output-Stationary (OS) Mode:
//                  * Unpacks 16-bit DRAM words into 4-weight parallel streaming
//                    column vectors (4 weights x 2 bits = 8 bits per vector).
//              - Memory compression factor: 8.0x compared to 16-bit binary weights!
// ==============================================================================

`timescale 1ns / 1ps

module ternary_weight_unpacker #(
    parameter int DATA_WIDTH   = 16, // DRAM bus width (16 bits)
    parameter int WEIGHT_WIDTH = 2,  // Ternary weight width (2 bits)
    parameter int ROWS         = 4,
    parameter int COLS         = 4
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // DRAM Word Inputs
    input  logic                               word_valid,
    input  logic [DATA_WIDTH-1:0]              dram_word,
    input  logic                               is_tile_load, // 1: Loading stationary tile, 0: Streaming column
    input  logic                               tile_half,    // 0: Low 8 weights (Rows 0-1), 1: High 8 weights (Rows 2-3)

    // Unpacked Outputs
    output logic [(ROWS*COLS*WEIGHT_WIDTH)-1:0] weight_tile_flat, // 4x4 stationary tile (32 bits)
    output logic [(COLS*WEIGHT_WIDTH)-1:0]      weight_col_flat,  // 4-element column vector (8 bits)
    output logic                                unpack_ready
);

    // -------------------------------------------------------------------------
    // Stationary 4x4 Weight Tile Register (16 weights x 2 bits = 32 bits total)
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
            if (!tile_half) begin
                // Low 8 weights: Row 0 and Row 1
                tile_regs[0][0] <= dram_word[1:0];
                tile_regs[0][1] <= dram_word[3:2];
                tile_regs[0][2] <= dram_word[5:4];
                tile_regs[0][3] <= dram_word[7:6];
                tile_regs[1][0] <= dram_word[9:8];
                tile_regs[1][1] <= dram_word[11:10];
                tile_regs[1][2] <= dram_word[13:12];
                tile_regs[1][3] <= dram_word[15:14];
            end else begin
                // High 8 weights: Row 2 and Row 3
                tile_regs[2][0] <= dram_word[1:0];
                tile_regs[2][1] <= dram_word[3:2];
                tile_regs[2][2] <= dram_word[5:4];
                tile_regs[2][3] <= dram_word[7:6];
                tile_regs[3][0] <= dram_word[9:8];
                tile_regs[3][1] <= dram_word[11:10];
                tile_regs[3][2] <= dram_word[13:12];
                tile_regs[3][3] <= dram_word[15:14];
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
    // Decodes 8-bit columns directly using continuous assigns
    // -------------------------------------------------------------------------
    logic [15:0] stream_buf;
    logic        col_phase;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_buf <= '0;
            col_phase  <= 1'b0;
        end else if (word_valid && !is_tile_load) begin
            stream_buf <= dram_word;
            col_phase  <= 1'b0;
        end else begin
            col_phase  <= ~col_phase;
        end
    end

    // Continuous assignment avoids simulator always_comb slicing warnings
    assign weight_col_flat[1:0] = col_phase ? stream_buf[9:8]   : stream_buf[1:0];
    assign weight_col_flat[3:2] = col_phase ? stream_buf[11:10] : stream_buf[3:2];
    assign weight_col_flat[5:4] = col_phase ? stream_buf[13:12] : stream_buf[5:4];
    assign weight_col_flat[7:6] = col_phase ? stream_buf[15:14] : stream_buf[7:6];

    assign unpack_ready = 1'b1;

endmodule
