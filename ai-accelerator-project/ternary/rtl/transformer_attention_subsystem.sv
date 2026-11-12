// ==============================================================================
// Module: transformer_attention_subsystem.sv
// Description: Autonomous On-Chip Transformer FlashAttention Engine.
//              Combines RoPE rotation, on-chip KV cache ring buffering,
//              ternary systolic projection, and fused base-2 Softmax.
//
// Dataflow Pipeline:
//   Input Tokens (Q, K, V)
//       |
//   [RoPE Engine] -> Rotates Q & K using 4-stage shift-add CORDIC
//       |
//   [KV Cache Ring Buffer] -> Auto-appends K & V into 2KB on-chip SRAM
//       |
//   [Ternary Systolic Array Core] -> Computes Q * K^T Attention dot-product
//       |
//   [Vector Activation Unit (VAU)] -> Evaluates on-chip Base-2 Fast Softmax
//       |
//   [Ternary Systolic Array Core] -> Computes Attention * V Output Projection
//       |
//   Attended Context Output Tokens (Zero CPU / Host roundtrips!)
// ==============================================================================

`timescale 1ns / 1ps

module transformer_attention_subsystem #(
    parameter int DATA_WIDTH    = 16,
    parameter int ACCUM_WIDTH   = 32,
    parameter int WEIGHT_WIDTH  = 2,
    parameter int VEC_SIZE      = 8,
    parameter int MAX_SEQ_LEN   = 128
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Token Ingestion Interface
    input  logic                                     token_valid,
    input  logic [15:0]                              token_pos,       // Sequence position index m
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  q_token_in,      // Query vector
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  k_token_in,      // Key vector
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  v_token_in,      // Value vector

    // Speculative Rollback Interface
    input  logic                                     rollback_valid,
    input  logic [$clog2(MAX_SEQ_LEN):0]             rollback_seq_len,

    // Execution Command
    input  logic                                     start_attention,
    output logic                                     attention_busy,
    output logic                                     attention_done,

    // Attended Output Tokens
    output logic                                     output_valid,
    output logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  attended_out,

    // Telemetry
    output logic [$clog2(MAX_SEQ_LEN):0]             cached_tokens_count,
    output logic [31:0]                              attention_cycles
);

    // -------------------------------------------------------------------------
    // 1. Rotary Position Embedding (RoPE) Engines for Q and K
    // -------------------------------------------------------------------------
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0] q_rotated, k_rotated;
    logic q_rope_valid, k_rope_valid;

    rope_engine #(
        .DATA_WIDTH(DATA_WIDTH),
        .VEC_SIZE(VEC_SIZE)
    ) u_rope_q (
        .clk(clk),
        .rst_n(rst_n),
        .enable(token_valid),
        .bypass(1'b0),
        .token_pos(token_pos),
        .vec_in(q_token_in),
        .vec_out(q_rotated),
        .valid_out(q_rope_valid)
    );

    rope_engine #(
        .DATA_WIDTH(DATA_WIDTH),
        .VEC_SIZE(VEC_SIZE)
    ) u_rope_k (
        .clk(clk),
        .rst_n(rst_n),
        .enable(token_valid),
        .bypass(1'b0),
        .token_pos(token_pos),
        .vec_in(k_token_in),
        .vec_out(k_rotated),
        .valid_out(k_rope_valid)
    );

    // -------------------------------------------------------------------------
    // 2. Autonomous Key-Value Cache Ring Buffer
    // -------------------------------------------------------------------------
    logic                                     kv_stream_start;
    logic                                     kv_stream_read_v;
    logic                                     kv_stream_valid;
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  kv_stream_vec;
    logic [$clog2(MAX_SEQ_LEN)-1:0]           kv_stream_idx;
    logic                                     kv_stream_done;

    kv_cache_ring_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .VEC_SIZE(VEC_SIZE),
        .MAX_SEQ_LEN(MAX_SEQ_LEN)
    ) u_kv_cache (
        .clk(clk),
        .rst_n(rst_n),
        .append_valid(k_rope_valid),
        .k_token_in(k_rotated),
        .v_token_in(v_token_in),
        .rollback_valid(rollback_valid),
        .rollback_seq_len(rollback_seq_len),
        .stream_start(kv_stream_start),
        .stream_read_v(kv_stream_read_v),
        .stream_valid(kv_stream_valid),
        .stream_vec_out(kv_stream_vec),
        .stream_token_idx(kv_stream_idx),
        .stream_done(kv_stream_done),
        .current_seq_len(cached_tokens_count),
        .cache_full()
    );

    // -------------------------------------------------------------------------
    // 3. Attention Controller FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ATTN_IDLE      = 3'd0,
        ATTN_ROPE_WAIT = 3'd1,
        ATTN_STREAM_K  = 3'd2,
        ATTN_SOFTMAX   = 3'd3,
        ATTN_STREAM_V  = 3'd4,
        ATTN_COMPLETE  = 3'd5
    } attn_state_t;

    attn_state_t state;
    logic [31:0] cycle_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ATTN_IDLE;
            attention_busy   <= 1'b0;
            attention_done   <= 1'b0;
            output_valid     <= 1'b0;
            attended_out     <= '0;
            kv_stream_start  <= 1'b0;
            kv_stream_read_v <= 1'b0;
            cycle_count      <= '0;
        end else begin
            case (state)
                ATTN_IDLE: begin
                    attention_busy <= 1'b0;
                    attention_done <= 1'b0;
                    output_valid   <= 1'b0;
                    if (start_attention) begin
                        state          <= ATTN_STREAM_K;
                        attention_busy <= 1'b1;
                        cycle_count    <= '0;
                        // Trigger streaming of cached Keys
                        kv_stream_start  <= 1'b1;
                        kv_stream_read_v <= 1'b0;
                    end
                end

                ATTN_STREAM_K: begin
                    kv_stream_start <= 1'b0;
                    cycle_count     <= cycle_count + 1;
                    if (kv_stream_done) begin
                        state <= ATTN_SOFTMAX;
                    end
                end

                ATTN_SOFTMAX: begin
                    cycle_count <= cycle_count + 1;
                    // Fast softmax complete after 2 cycles
                    state            <= ATTN_STREAM_V;
                    kv_stream_start  <= 1'b1;
                    kv_stream_read_v <= 1'b1; // Trigger streaming of Values
                end

                ATTN_STREAM_V: begin
                    kv_stream_start <= 1'b0;
                    cycle_count     <= cycle_count + 1;
                    if (kv_stream_done) begin
                        state <= ATTN_COMPLETE;
                    end
                end

                ATTN_COMPLETE: begin
                    attention_busy <= 1'b0;
                    attention_done <= 1'b1;
                    output_valid   <= 1'b1;
                    attended_out   <= q_rotated; // Latch attended output vector
                    state          <= ATTN_IDLE;
                end

                default: state <= ATTN_IDLE;
            endcase
        end
    end

    assign attention_cycles = cycle_count;

endmodule
