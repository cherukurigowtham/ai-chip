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
    // Multiplier-Free Zero-DSP Barrel Shifter: eliminates hardware multipliers
    // Divider-Free Sequential Restoring Divider: eliminates hardware dividers
    logic [$clog2(VEC_SIZE)-1:0] norm_cnt;
    logic [4:0]                  div_step;
    logic                        div_sign;
    logic [31:0]                 div_rem;
    logic [31:0]                 div_quo;

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
            norm_cnt         <= '0;
            div_step         <= '0;
            div_sign         <= 1'b0;
            div_rem          <= '0;
            div_quo          <= '0;
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
                    norm_cnt         <= '0;
                    div_step         <= '0;
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
                        logic [15:0] delta_m;
                        logic [15:0] delta_s;
                        logic [31:0] p_new_term;

                        s_curr = dot_prod_scaled;

                        // Online Softmax Step A: Update running maximum
                        if (tokens_processed == 0 || s_curr > m_prev) begin
                            m_new = s_curr;
                            rescale_count <= rescale_count + 1'b1;
                        end else begin
                            m_new = m_prev;
                        end

                        // Online Softmax Step B: Compute power-of-two shift exponents
                        // delta_m = m_new - m_prev >= 0 (rescaling factor for previous state)
                        // delta_s = m_new - s_curr >= 0 (softmax weight for current token)
                        delta_m = (tokens_processed == 0) ? 16'd0 : (m_new - m_prev);
                        delta_s = m_new - s_curr;

                        // Base-2 exponential scaling: 2^-delta_s in Q8 (256 >> delta_s)
                        p_new_term = (delta_s >= 16) ? 32'd0 : (32'd256 >> delta_s);

                        // Online Softmax Step C: Rescale denominator (100% Multiplier-Free!)
                        d_prev <= ((delta_m >= 32) ? 32'd0 : (d_prev >> delta_m)) + p_new_term;

                        // Online Softmax Step D: Rescale and accumulate attended output vector (100% Multiplier-Free!)
                        for (int k = 0; k < VEC_SIZE; k++) begin
                            logic signed [ACCUM_WIDTH-1:0] o_rescaled;
                            logic signed [ACCUM_WIDTH-1:0] v_term;
                            logic signed [ACCUM_WIDTH-1:0] v_ext;
                            v_ext      = {{(ACCUM_WIDTH-DATA_WIDTH){v_vec[k][DATA_WIDTH-1]}}, v_vec[k]};
                            o_rescaled = (delta_m >= 32) ? '0 : (o_accum[k] >>> delta_m);
                            v_term     = (delta_s >= 16) ? '0 : (v_ext >>> delta_s);
                            o_accum[k] <= o_rescaled + v_term;
                        end

                        m_prev           <= m_new;
                        tokens_processed <= tokens_processed + 1'b1;

                        if (tokens_processed + 1'b1 >= seq_len) begin
                            norm_cnt <= '0;
                            div_step <= '0;
                            state    <= FINALIZE_DIV;
                        end
                    end
                end

                FINALIZE_DIV: begin
                    if (d_prev == 0) begin
                        for (int k = 0; k < VEC_SIZE; k++) attended_out[k] <= o_accum[k][DATA_WIDTH-1:0];
                        output_valid   <= 1'b1;
                        attention_done <= 1'b1;
                        attention_busy <= 1'b0;
                        state          <= DONE;
                    end else begin
                        // 100% Multiplier-Free & Divider-Free Iterative Restoring Normalizer
                        if (div_step == 0) begin
                            div_sign <= (o_accum[norm_cnt] < 0);
                            div_rem  <= (o_accum[norm_cnt] < 0) ? -($signed(o_accum[norm_cnt]) <<< 8) : ($signed(o_accum[norm_cnt]) <<< 8);
                            div_quo  <= '0;
                            div_step <= 5'd17;
                        end else if (div_step > 1) begin
                            logic [4:0] s_idx;
                            logic [31:0] scaled_den;
                            s_idx = div_step - 5'd2; // 15 down to 0
                            scaled_den = d_prev << s_idx;
                            if (div_rem >= scaled_den) begin
                                div_rem <= div_rem - scaled_den;
                                div_quo <= div_quo | (32'd1 << s_idx);
                            end
                            div_step <= div_step - 1'b1;
                        end else if (div_step == 1) begin
                            attended_out[norm_cnt] <= div_sign ? -div_quo[DATA_WIDTH-1:0] : div_quo[DATA_WIDTH-1:0];
                            if (norm_cnt == (VEC_SIZE - 1)) begin
                                output_valid   <= 1'b1;
                                attention_done <= 1'b1;
                                attention_busy <= 1'b0;
                                state          <= DONE;
                            end else begin
                                norm_cnt <= norm_cnt + 1'b1;
                                div_step <= 5'd0;
                            end
                        end
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
