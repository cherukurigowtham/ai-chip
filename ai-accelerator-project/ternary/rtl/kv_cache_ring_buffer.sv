// ==============================================================================
// Module: kv_cache_ring_buffer.sv
// Description: Autonomous On-Chip Key-Value (KV) Cache Ring Buffer for LLM Generation.
//              Eliminates the "Memory Wall" by storing past token Keys and Values
//              directly on-chip, serving Attention heads without off-chip DRAM roundtrips.
//
// Key Capabilities:
// 1. Dual Ring Buffers:
//    - Key Cache (K-Cache): Stores up to MAX_SEQ_LEN Key vectors (8-dim INT16).
//    - Value Cache (V-Cache): Stores up to MAX_SEQ_LEN Value vectors (8-dim INT16).
// 2. Autonomous Token Appending:
//    - Automatically latches new token vector (K_t, V_t) on append_valid.
//    - Auto-increments sequence length and circular write pointer.
// 3. High-Speed Burst Streaming Readout:
//    - When trigger_stream is asserted, bursts all 0..seq_len cached vectors into
//      the systolic cluster for QK^T attention scoring at 1 vector per cycle.
// 4. Memory Footprint:
//    - 128 vectors x 8 dimensions x 16-bit = 2048 bytes (2 KB SRAM on-chip).
// ==============================================================================

`timescale 1ns / 1ps

module kv_cache_ring_buffer #(
    parameter int DATA_WIDTH  = 16,
    parameter int VEC_SIZE    = 8,
    parameter int MAX_SEQ_LEN = 128
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Token Append Interface (Write new token K, V into cache)
    input  logic                                     append_valid,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  k_token_in,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  v_token_in,

    // Speculative Rollback Interface (1-Cycle Instantaneous Cache Rewind)
    input  logic                                     rollback_valid,
    input  logic [$clog2(MAX_SEQ_LEN):0]             rollback_seq_len,

    // Stream Readout Interface (Feeds Systolic Core for Attention)
    input  logic                                     stream_start,
    input  logic                                     stream_read_v,   // 0: Stream K, 1: Stream V
    output logic                                     stream_valid,
    output logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  stream_vec_out,
    output logic [$clog2(MAX_SEQ_LEN)-1:0]           stream_token_idx,
    output logic                                     stream_done,

    // Status and Telemetry
    output logic [$clog2(MAX_SEQ_LEN):0]             current_seq_len,
    output logic                                     cache_full
);

    localparam int ADDR_WIDTH = $clog2(MAX_SEQ_LEN);

    // Dual On-Chip SRAM Arrays
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0] k_cache [0:MAX_SEQ_LEN-1];
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0] v_cache [0:MAX_SEQ_LEN-1];

    logic [ADDR_WIDTH:0]  seq_counter;
    logic [ADDR_WIDTH-1:0] write_ptr;
    logic [ADDR_WIDTH-1:0] read_ptr;
    logic                 streaming_active;

    assign current_seq_len = seq_counter;
    assign cache_full      = (seq_counter >= MAX_SEQ_LEN);

    // -------------------------------------------------------------------------
    // Token Append Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_counter <= '0;
            write_ptr   <= '0;
        end else if (rollback_valid) begin
            seq_counter <= rollback_seq_len;
            write_ptr   <= rollback_seq_len[ADDR_WIDTH-1:0];
        end else if (append_valid && !cache_full) begin
            k_cache[write_ptr] <= k_token_in;
            v_cache[write_ptr] <= v_token_in;
            write_ptr          <= write_ptr + 1;
            seq_counter        <= seq_counter + 1;
        end
    end

    // -------------------------------------------------------------------------
    // High-Speed Burst Streaming Readout
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            streaming_active <= 1'b0;
            read_ptr         <= '0;
            stream_valid     <= 1'b0;
            stream_done      <= 1'b0;
            stream_vec_out   <= '0;
            stream_token_idx <= '0;
        end else begin
            if (stream_start && (seq_counter > 0)) begin
                streaming_active <= 1'b1;
                read_ptr         <= '0;
                stream_valid     <= 1'b1;
                stream_done      <= 1'b0;
                stream_token_idx <= '0;
                stream_vec_out   <= stream_read_v ? v_cache[0] : k_cache[0];
            end else if (streaming_active) begin
                if (read_ptr + 1 < seq_counter[ADDR_WIDTH-1:0]) begin
                    read_ptr         <= read_ptr + 1;
                    stream_valid     <= 1'b1;
                    stream_token_idx <= read_ptr + 1;
                    stream_vec_out   <= stream_read_v ? v_cache[read_ptr + 1] : k_cache[read_ptr + 1];
                end else begin
                    streaming_active <= 1'b0;
                    stream_valid     <= 1'b0;
                    stream_done      <= 1'b1;
                end
            end else begin
                stream_valid <= 1'b0;
                stream_done  <= 1'b0;
            end
        end
    end

endmodule
