// ==============================================================================
// Module: llm_sampler_engine.sv
// Description: Multiplier-Free 1-Cycle Hardware Token Sampler & Greedy Argmax Engine.
//              Performs instantaneous branch-free candidate comparison and
//              tracks running maximum logit/token_id with 0 branch misprediction penalties.
//
// Key Specifications:
// 1. Single-Instruction Candidate Evaluation:
//    - cand_pair_in: {cand_logit[15:0], cand_token_id[15:0]} in rs1
//    - curr_best_in: {best_logit[15:0], best_token_id[15:0]} in rs2
//    - winner_out:   {winner_logit[15:0], winner_token_id[15:0]} in rd
// 2. 1-Cycle Deterministic Latency (500 MHz).
// 3. Zero Branch Penalties: Eliminates conditional branches and pipeline flushes!
// ==============================================================================

`timescale 1ns / 1ps

module llm_sampler_engine (
    input  logic signed [31:0] cand_pair_in,
    input  logic signed [31:0] curr_best_in,
    output logic signed [31:0] winner_out
);

    wire signed [15:0] cand_logit    = cand_pair_in[31:16];
    wire [15:0]        cand_token_id = cand_pair_in[15:0];

    wire signed [15:0] best_logit    = curr_best_in[31:16];
    wire [15:0]        best_token_id = curr_best_in[15:0];

    logic signed [15:0] win_logit;
    logic [15:0]        win_token_id;

    always_comb begin
        if (cand_logit > best_logit) begin
            win_logit    = cand_logit;
            win_token_id = cand_token_id;
        end else begin
            win_logit    = best_logit;
            win_token_id = best_token_id;
        end
    end

    assign winner_out = {win_logit, win_token_id};

endmodule
