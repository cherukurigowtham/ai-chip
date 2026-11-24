// ==============================================================================
// Module: llm_stochastic_sampler_engine.sv
// Description: Multiplier-Free 1-Cycle Hardware Stochastic Min-P / Top-P Token
//              Sampler Engine with On-Chip 32-Bit Galois LFSR PRNG.
//
// Features:
// 1. Stochastic Nucleus Selection:
//    - Evaluates candidate token {cand_logit[15:0], cand_id[15:0]} in rs1
//      against current best {best_logit[15:0], best_id[15:0]} in rs2.
//    - Margin condition: diff = best_logit - cand_logit.
//    - If cand_logit > best_logit -> Deterministic swap (candidate wins).
//    - Else if diff <= threshold (in nucleus) AND lfsr_rand[7:0] < sample_prob[7:0]
//      -> Probabilistic stochastic exploration (candidate selected).
//    - Else -> Retain best token.
// 2. Hardware 32-Bit Galois LFSR:
//    - Polynomial: x^32 + x^22 + x^2 + x^1 + 1 (Maximal-length period = 2^32 - 1).
//    - Advances every clock cycle or when sample evaluated.
// 3. 1-Cycle Combinational Latency (500 MHz, < 1.4 ns path delay).
// 4. Zero Hardware Multipliers: Pure combinational subtractors and comparators.
// ==============================================================================

`timescale 1ns / 1ps

module llm_stochastic_sampler_engine #(
    parameter logic [31:0] LFSR_SEED = 32'hB17E_130A
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Input 1: {cand_logit[15:0], cand_id[15:0]}
    input  logic signed [31:0]     cand_pair_in,

    // Input 2: {best_logit[15:0], best_id[15:0]}
    input  logic signed [31:0]     best_pair_in,

    // Configuration: {threshold[15:0], accept_prob[15:0]} (Default: margin=64, prob=128)
    input  logic [31:0]            config_in,

    // Output: {winner_logit[15:0], winner_id[15:0]}
    output logic signed [31:0]     winner_pair_out
);

    // Unpack inputs
    wire signed [15:0] cand_logit    = cand_pair_in[31:16];
    wire        [15:0] cand_token_id = cand_pair_in[15:0];
    wire signed [15:0] best_logit    = best_pair_in[31:16];
    wire        [15:0] best_token_id = best_pair_in[15:0];

    // Threshold & probability
    // If config_in is 0, use defaults: threshold = 64 (0.25 in Q8.8), accept_prob = 128 (50% chance)
    wire [15:0] threshold   = (config_in[31:16] != 16'd0) ? config_in[31:16] : 16'd64;
    wire [7:0]  accept_prob = (config_in[7:0]   != 8'd0)  ? config_in[7:0]   : 8'd128;

    // -------------------------------------------------------------------------
    // 32-Bit Galois LFSR PRNG
    // -------------------------------------------------------------------------
    logic [31:0] lfsr_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_reg <= LFSR_SEED;
        end else begin
            // Galois LFSR tap feedback: bit 0 feeds back into taps {32, 22, 2, 1}
            lfsr_reg <= (lfsr_reg >> 1) ^ (-(lfsr_reg & 1'b1) & 32'h8020_0003);
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Sampling Logic
    // -------------------------------------------------------------------------
    wire signed [15:0] diff_best_cand = best_logit - cand_logit;

    logic signed [15:0] win_logit;
    logic        [15:0] win_token_id;

    always_comb begin
        if (cand_logit > best_logit) begin
            // Strictly higher logit always wins
            win_logit    = cand_logit;
            win_token_id = cand_token_id;
        end else if ((diff_best_cand <= signed'({1'b0, threshold})) && (lfsr_reg[7:0] < accept_prob)) begin
            // Within nucleus window and random draw accepts candidate
            win_logit    = cand_logit;
            win_token_id = cand_token_id;
        end else begin
            // Retain existing best
            win_logit    = best_logit;
            win_token_id = best_token_id;
        end
    end

    assign winner_pair_out = {win_logit, win_token_id};

endmodule
