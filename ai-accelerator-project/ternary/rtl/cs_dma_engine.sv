// ==============================================================================
// Module: cs_dma_engine.sv
// Description: Compressed Sparse Direct Memory Access (CS-DMA) Engine for BitNet.
//              Exploits natural ternary sparsity (typically 40% - 70% zero weights)
//              to cut external memory bus bandwidth by up to 2.0x (16x over FP16).
//
// Features:
// 1. Multi-Mode Decompression:
//    - MODE 00 (COMP_RAW): Uncompressed Dense 8x8 (8 words x 16-bit = 128 bits).
//    - MODE 01 (COMP_BITMAP): 64-bit Non-Zero Bitmask followed by packed non-zero
//                             ternary values. High-efficiency for random sparsity.
//    - MODE 10 (COMP_RLE): Run-Length Encoded zero-run skipping. Packs 3 entries
//                          {run_zeros[2:0], val[1:0]} per 16-bit word.
// 2. Autonomous Hardware Decompressor FSM:
//    - Decodes at line rate (1 word/cycle) into internal 8x8 tile register.
//    - Directly feeds systolic array weight buffer or stationary register.
// 3. Hardware Bandwidth & Power Telemetry:
//    - Tracks uncompressed vs. compressed bits transferred.
//    - Real-time Q8.8 compression ratio reporting.
// ==============================================================================

`timescale 1ns / 1ps

module cs_dma_engine #(
    parameter int DATA_WIDTH   = 16,
    parameter int WEIGHT_WIDTH = 2,
    parameter int ROWS         = 8,
    parameter int COLS         = 8
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Configuration
    input  logic [1:0]                         comp_mode,       // 00: RAW, 01: BITMAP, 10: RLE
    input  logic                               tile_start,      // Start loading a new tile
    output logic                               tile_busy,
    output logic                               tile_done,

    // External Memory DMA Streaming Interface
    output logic                               dma_req,
    input  logic                               dma_ack,
    input  logic [DATA_WIDTH-1:0]              dma_word_in,

    // Decompressed Tile Output to Systolic Core
    output logic [(ROWS*COLS*WEIGHT_WIDTH)-1:0] decomp_tile_flat,
    output logic                                decomp_tile_valid,

    // Hardware Telemetry
    output logic [31:0]                        telemetry_raw_bits,
    output logic [31:0]                        telemetry_comp_bits,
    output logic [15:0]                        telemetry_ratio_q8
);

    localparam int TOTAL_WEIGHTS = ROWS * COLS;          // 64 weights
    localparam int TOTAL_BITS    = TOTAL_WEIGHTS * WEIGHT_WIDTH; // 128 bits

    typedef enum logic [2:0] {
        IDLE        = 3'd0,
        STREAM_RAW  = 3'd1,
        BM_READ_MASK= 3'd2,
        BM_READ_VALS= 3'd3,
        RLE_STREAM  = 3'd4,
        DONE_PULSE  = 3'd5
    } state_t;

    state_t state;

    // Tile reconstruction registers
    logic [WEIGHT_WIDTH-1:0] tile_matrix [0:TOTAL_WEIGHTS-1];

    // Bitmap mode state registers
    logic [TOTAL_WEIGHTS-1:0] nz_bitmap;
    logic [2:0]              mask_words_read;
    logic [6:0]              bm_fill_idx;
    logic [6:0]              bm_val_idx;
    logic [6:0]              total_nonzeros;

    // RLE mode state registers
    logic [6:0]              rle_curr_pos;

    // Raw mode counter
    logic [3:0]              raw_word_count;

    // Telemetry registers
    logic [31:0] reg_raw_bits;
    logic [31:0] reg_comp_bits;

    assign telemetry_raw_bits  = reg_raw_bits;
    assign telemetry_comp_bits = reg_comp_bits;

    // Compression ratio in Q8.8: (raw_bits * 256) / comp_bits
    logic [31:0] ratio_calc;
    assign ratio_calc = (reg_comp_bits > 0) ? ((reg_raw_bits << 8) / reg_comp_bits) : 32'h0100;
    assign telemetry_ratio_q8 = ratio_calc[15:0];

    // Flatten unpacked tile
    genvar w;
    generate
        for (w = 0; w < TOTAL_WEIGHTS; w++) begin : gen_flat
            assign decomp_tile_flat[w*WEIGHT_WIDTH +: WEIGHT_WIDTH] = tile_matrix[w];
        end
    endgenerate

    // Temporary computation signals for procedural blocks
    logic [TOTAL_WEIGHTS-1:0] full_bm;
    integer                   nz_cnt;
    integer                   running_nz;
    integer                   curr_pos_step;

    // -------------------------------------------------------------------------
    // CS-DMA Decompression Controller FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            tile_busy           <= 1'b0;
            tile_done           <= 1'b0;
            decomp_tile_valid   <= 1'b0;
            dma_req             <= 1'b0;
            raw_word_count      <= '0;
            mask_words_read     <= '0;
            nz_bitmap           <= '0;
            bm_fill_idx         <= '0;
            bm_val_idx          <= '0;
            total_nonzeros      <= '0;
            rle_curr_pos        <= '0;
            reg_raw_bits        <= '0;
            reg_comp_bits       <= '0;
            for (int i = 0; i < TOTAL_WEIGHTS; i++) begin
                tile_matrix[i] <= '0;
            end
        end else begin
            tile_done         <= 1'b0;
            decomp_tile_valid <= 1'b0;

            case (state)
                IDLE: begin
                    dma_req <= 1'b0;
                    if (tile_start) begin
                        tile_busy <= 1'b1;
                        for (int i = 0; i < TOTAL_WEIGHTS; i++) begin
                            tile_matrix[i] <= '0;
                        end

                        case (comp_mode)
                            2'b00: begin // RAW DENSE
                                state          <= STREAM_RAW;
                                raw_word_count <= '0;
                                dma_req        <= 1'b1;
                            end
                            2'b01: begin // BITMAP
                                state           <= BM_READ_MASK;
                                mask_words_read <= '0;
                                nz_bitmap       <= '0;
                                bm_fill_idx     <= '0;
                                bm_val_idx      <= '0;
                                total_nonzeros  <= '0;
                                dma_req         <= 1'b1;
                            end
                            2'b10: begin // RLE
                                state        <= RLE_STREAM;
                                rle_curr_pos <= '0;
                                dma_req      <= 1'b1;
                            end
                            default: begin
                                state          <= STREAM_RAW;
                                raw_word_count <= '0;
                                dma_req        <= 1'b1;
                            end
                        endcase
                    end
                end

                // -------------------------------------------------------------
                // 1. RAW DENSE MODE (8 words x 16-bit)
                // -------------------------------------------------------------
                STREAM_RAW: begin
                    if (dma_ack) begin
                        reg_raw_bits  <= reg_raw_bits + 16;
                        reg_comp_bits <= reg_comp_bits + 16;

                        for (int j = 0; j < 8; j++) begin
                            tile_matrix[raw_word_count * 8 + j] <= dma_word_in[j*2 +: 2];
                        end

                        if (raw_word_count == 4'd7) begin
                            dma_req <= 1'b0;
                            state   <= DONE_PULSE;
                        end else begin
                            raw_word_count <= raw_word_count + 1'b1;
                            dma_req        <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 2. BITMAP MODE: Phase A - Read 64-bit Non-Zero Mask (4 words)
                // -------------------------------------------------------------
                BM_READ_MASK: begin
                    if (dma_ack) begin
                        reg_comp_bits <= reg_comp_bits + 16;
                        nz_bitmap[mask_words_read*16 +: 16] <= dma_word_in;

                        if (mask_words_read == 3'd3) begin
                            // All 64 mask bits received. Count non-zeros.
                            full_bm = {dma_word_in, nz_bitmap[47:0]};
                            nz_cnt = 0;
                            for (int k = 0; k < TOTAL_WEIGHTS; k++) begin
                                if (full_bm[k]) nz_cnt = nz_cnt + 1;
                            end
                            total_nonzeros <= nz_cnt[6:0];
                            bm_fill_idx    <= 0;
                            bm_val_idx     <= 0;

                            if (nz_cnt == 0) begin
                                // Entire tile is zero!
                                dma_req <= 1'b0;
                                reg_raw_bits <= reg_raw_bits + TOTAL_BITS;
                                state   <= DONE_PULSE;
                            end else begin
                                state   <= BM_READ_VALS;
                                dma_req <= 1'b1;
                            end
                        end else begin
                            mask_words_read <= mask_words_read + 1'b1;
                            dma_req         <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 2. BITMAP MODE: Phase B - Stream non-zero values into mask positions
                // -------------------------------------------------------------
                BM_READ_VALS: begin
                    if (dma_ack) begin
                        reg_comp_bits <= reg_comp_bits + 16;
                        
                        // Unpack up to 8 non-zeros from 16-bit word
                        for (int v = 0; v < 8; v++) begin
                            if ((bm_val_idx + v) < total_nonzeros) begin
                                // Find corresponding '1' bit in nz_bitmap
                                running_nz = 0;
                                for (int b = 0; b < TOTAL_WEIGHTS; b++) begin
                                    if (nz_bitmap[b]) begin
                                        if (running_nz == (bm_val_idx + v)) begin
                                            tile_matrix[b] <= dma_word_in[v*2 +: 2];
                                        end
                                        running_nz = running_nz + 1;
                                    end
                                end
                            end
                        end

                        if ((bm_val_idx + 8) >= total_nonzeros) begin
                            dma_req      <= 1'b0;
                            reg_raw_bits <= reg_raw_bits + TOTAL_BITS;
                            state        <= DONE_PULSE;
                        end else begin
                            bm_val_idx <= bm_val_idx + 8;
                            dma_req    <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 3. RLE MODE: 3 tokens per 16-bit word {run[2:0], val[1:0]} (15 bits)
                // -------------------------------------------------------------
                RLE_STREAM: begin
                    if (dma_ack) begin
                        curr_pos_step = rle_curr_pos;
                        reg_comp_bits <= reg_comp_bits + 16;

                        for (int e = 0; e < 3; e++) begin
                            logic [2:0] zero_run;
                            logic [1:0] w_val;
                            w_val    = dma_word_in[e*5 +: 2];
                            zero_run = dma_word_in[e*5 + 2 +: 3];

                            if (w_val != 2'b00) begin
                                curr_pos_step = curr_pos_step + zero_run;
                                if (curr_pos_step < TOTAL_WEIGHTS) begin
                                    tile_matrix[curr_pos_step] <= w_val;
                                    curr_pos_step = curr_pos_step + 1;
                                end
                            end
                        end

                        rle_curr_pos <= curr_pos_step[6:0];

                        // End-of-tile marker or full matrix filled
                        if (dma_word_in[15] == 1'b1 || curr_pos_step >= TOTAL_WEIGHTS) begin
                            dma_req      <= 1'b0;
                            reg_raw_bits <= reg_raw_bits + TOTAL_BITS;
                            state        <= DONE_PULSE;
                        end else begin
                            dma_req      <= 1'b1;
                        end
                    end
                end

                DONE_PULSE: begin
                    tile_busy         <= 1'b0;
                    tile_done         <= 1'b1;
                    decomp_tile_valid <= 1'b1;
                    state             <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
