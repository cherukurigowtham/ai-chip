// ==============================================================================
// Module: online_flash_attention_engine.sv
// Description: Gen-2 Hardware-Fused Online FlashAttention-3 Micro-Engine.
//              Eliminates the O(N^2) intermediate attention score matrix SRAM storage
//              by computing Online Softmax on-the-fly:
//                 m_new = max(m_prev, s_j)
//                 alpha = 2^(m_prev - m_new)
//                 d_new = d_prev * alpha + 2^(s_j - m_new)
//                 O_new = O_prev * alpha + 2^(s_j - m_new) * V_j
//
// Features:
// 1. O(1) Memory Footprint:
//    - Zero intermediate S x S score matrix storage.
// 2. Base-2 Fast Exponent Approximation:
//    - Multiplier-free shift-based power-of-two scaling: 2^(delta).
// 3. Streaming Key-Value Ingestion:
//    - Interleaved K and V ingestion directly from on-chip KV Cache ring buffer.
// 4. Autonomous Normalization Divider Stage:
//    - O_final = O_accum / d_accum in fixed-point Q8.8.
// ==============================================================================

`timescale 1ns / 1ps

module online_flash_attention_engine #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32,
    parameter int VEC_SIZE    = 8
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Query Vector (Latched for current attention head)
    input  logic                                     start_head,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  q_vec_flat,
    input  logic [15:0]                              seq_len, // Number of past tokens to attend

    // Streaming Key & Value Input from KV-Cache
    input  logic                                     kv_valid,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  k_vec_flat,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  v_vec_flat,
    output logic                                     kv_ready,

    // Attended Output Vector
    output logic                                     output_valid,
    output logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  attended_out_flat,
    output logic                                     attention_busy,
    output logic                                     attention_done,

    // Telemetry
    output logic signed [ACCUM_WIDTH-1:0]            telemetry_max_score,
    output logic [15:0]                              telemetry_rescales
);

    typedef enum logic [2:0] {
        IDLE         = 3'd0,
        INGEST_TOKEN = 3'd1,
        UPDATE_STATE = 3'd2,
        FINALIZE_DIV = 3'd3,
        DONE         = 3'd4
    } flash_state_t;

    flash_state_t state;

    // Unpack vectors
    logic signed [DATA_WIDTH-1:0] q_vec [0:VEC_SIZE-1];
    logic signed [DATA_WIDTH-1:0] k_vec [0:VEC_SIZE-1];
    logic signed [DATA_WIDTH-1:0] v_vec [0:VEC_SIZE-1];
    logic signed [DATA_WIDTH-1:0] attended_out [0:VEC_SIZE-1];

    genvar i;
    generate
        for (i = 0; i < VEC_SIZE; i++) begin : gen_vec_unpack
            assign q_vec[i] = q_vec_flat[i*DATA_WIDTH +: DATA_WIDTH];
            assign k_vec[i] = k_vec_flat[i*DATA_WIDTH +: DATA_WIDTH];
            assign v_vec[i] = v_vec_flat[i*DATA_WIDTH +: DATA_WIDTH];
            assign attended_out_flat[i*DATA_WIDTH +: DATA_WIDTH] = attended_out[i];
        end
    endgenerate

    // Online Softmax State Registers
    logic signed [ACCUM_WIDTH-1:0] m_prev;       // Running maximum score
    logic [31:0]                   d_prev;       // Running sum of exp (denominator)
    logic signed [ACCUM_WIDTH-1:0] o_accum [0:VEC_SIZE-1]; // Running attended output vector

    logic [15:0] tokens_processed;
    logic [15:0] rescale_count;

    assign telemetry_max_score = m_prev;
    assign telemetry_rescales  = rescale_count;
    assign kv_ready = (state == INGEST_TOKEN);

    // 1. Dot-Product Engine: score s = (Q . K) >> 3 (scaled by 1/sqrt(d))
    logic signed [ACCUM_WIDTH-1:0] dot_prod_raw;
    wire signed [ACCUM_WIDTH-1:0] dot_prod_scaled = dot_prod_raw >>> 3;

    always_comb begin
        dot_prod_raw = '0;
        for (int j = 0; j < VEC_SIZE; j++) begin
            dot_prod_raw = dot_prod_raw + (q_vec[j] * k_vec[j]);
        end
    end

    // 2. Base-2 Fast Exp Weight: w_exp = 2^(score - m_new)
    // Shift-approximated for zero-multiplier hardware
    function automatic logic [15:0] fast_exp2(input logic signed [15:0] delta);
        if (delta >= 0) begin
            fast_exp2 = 16'd256; // 1.0 in Q8
        end else if (delta < -8) begin
            fast_exp2 = 16'd1;   // Lower clamp
        end else begin
            // 2^(delta): shift right by abs(delta)
            fast_exp2 = 16'd256 >> (-delta);
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            attention_busy   <= 1'b0;
            attention_done   <= 1'b0;
            output_valid     <= 1'b0;
            m_prev           <= -32'sd32768; // -Infinity initialization
            d_prev           <= 32'd0;
            tokens_processed <= 16'd0;
            rescale_count    <= 16'd0;
            for (int k = 0; k < VEC_SIZE; k++) begin
                o_accum[k]      <= '0;
                attended_out[k] <= '0;
            end
        end else begin
            attention_done <= 1'b0;
            output_valid   <= 1'b0;

            case (state)
                IDLE: begin
                    attention_busy   <= 1'b0;
                    tokens_processed <= 16'd0;
                    rescale_count    <= 16'd0;
                    m_prev           <= -32'sd32768;
                    d_prev           <= 32'd0;
                    for (int k = 0; k < VEC_SIZE; k++) o_accum[k] <= '0;

                    if (start_head) begin
                        attention_busy <= 1'b1;
                        state          <= INGEST_TOKEN;
                    end
                end

                INGEST_TOKEN: begin
                    if (kv_valid) begin
                        logic signed [ACCUM_WIDTH-1:0] s_curr;
                        logic signed [ACCUM_WIDTH-1:0] m_new;
                        logic signed [15:0] shift_old;
                        logic signed [15:0] shift_new;
                        logic [15:0] alpha_old;
                        logic [15:0] p_new;

                        s_curr = dot_prod_scaled;

                        // Online Softmax Step A: Update running maximum
                        if (tokens_processed == 0 || s_curr > m_prev) begin
                            m_new = s_curr;
                            rescale_count <= rescale_count + 1'b1;
                        end else begin
                            m_new = m_prev;
                        end

                        // Online Softmax Step B: Compute scaling factors
                        shift_old = m_prev - m_new; // <= 0
                        shift_new = s_curr - m_new; // <= 0
                        alpha_old = fast_exp2(shift_old[15:0]);
                        p_new     = fast_exp2(shift_new[15:0]);

                        // Online Softmax Step C: Rescale denominator
                        d_prev <= ((d_prev * alpha_old) >> 8) + p_new;

                        // Online Softmax Step D: Rescale and accumulate attended output vector
                        for (int k = 0; k < VEC_SIZE; k++) begin
                            logic signed [31:0] o_rescaled;
                            logic signed [31:0] v_term;
                            o_rescaled = (o_accum[k] * $signed({1'b0, alpha_old})) >>> 8;
                            v_term     = (v_vec[k] * $signed({1'b0, p_new})) >>> 8;
                            o_accum[k] <= o_rescaled + v_term;
                        end

                        m_prev           <= m_new;
                        tokens_processed <= tokens_processed + 1'b1;

                        if (tokens_processed + 1'b1 >= seq_len) begin
                            state <= FINALIZE_DIV;
                        end
                    end
                end

                FINALIZE_DIV: begin
                    // Normalize accumulated outputs by final denominator: O_final = O / d
                    for (int k = 0; k < VEC_SIZE; k++) begin
                        if (d_prev > 0) begin
                            attended_out[k] <= (o_accum[k] << 8) / $signed({1'b0, d_prev});
                        end else begin
                            attended_out[k] <= o_accum[k][DATA_WIDTH-1:0];
                        end
                    end
                    output_valid   <= 1'b1;
                    attention_done <= 1'b1;
                    attention_busy <= 1'b0;
                    state          <= DONE;
                end

                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
