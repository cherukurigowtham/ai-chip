// =============================================================================
// Module: prefix_cache_matcher_engine.sv
// Description: Multiplier-Free 1-Cycle Hardware Prefix Cache Hash & Radix Matcher
//              Engine for the BitNet-130 Universal Micro-Tensor AI Processor.
//
// Functionality:
//   Accelerates LLM multi-turn prefix caching and prompt reuse (vLLM / SGLang
//   radix-cache style). In software, matching an active prefix sequence against
//   a radix tree consumes thousands of CPU instructions and branch flushes.
//
//   This engine executes in 1 cycle:
//   1. Computes a parallel 32-bit Galois rolling hash over 4 incoming tokens.
//   2. Performs a parallel Content-Addressable Memory (CAM) match across 8
//      on-chip prefix cache lines.
//   3. Supports MATCH (mode=0) to return physical page pointer on hit,
//      and COMMIT/UPDATE (mode=1) to register new prompt prefix sequences.
//
// Silicon Target: 500 MHz (2.0 ns) | Process: SkyWater Sky130 / Nangate 45nm
// Multiplier Usage: ZERO (100% Galois XOR folding and parallel comparators)
// =============================================================================

`timescale 1ns/1ps

module prefix_cache_matcher_engine (
    input  logic        clk,
    input  logic        rst_n,

    // Token Vector In (Four 8-bit packed tokens or one 32-bit token ID / hash)
    input  logic [31:0] token_vector_in,

    // Control & Tag Config:
    //   [31:24]: Command mode (8'h00: MATCH, 8'h01: COMMIT, 8'h02: INVALIDATE_ALL)
    //   [23:16]: Target CAM line index (0..7) for commit
    //   [15:0] : Physical Page / Block ID (for commit)
    input  logic [31:0] config_tag_in,

    // Match / Status Result Output:
    //   [31]   : Prefix Cache HIT (1'b1 = Hit, 1'b0 = Miss)
    //   [30:28]: Matched CAM line index (0..7)
    //   [27:16]: Reserved (12'b0)
    //   [15:0] : Physical Page / Block ID of cached KV prefix
    output logic [31:0] match_result_out
);

    // -------------------------------------------------------------------------
    // 1. Galois 32-Bit Rolling Hash Generator (1-Cycle Combination Folding)
    // -------------------------------------------------------------------------
    logic [7:0] tok0, tok1, tok2, tok3;
    assign tok0 = token_vector_in[7:0];
    assign tok1 = token_vector_in[15:8];
    assign tok2 = token_vector_in[23:16];
    assign tok3 = token_vector_in[31:24];

    logic [31:0] h0, h1, h2, h3;
    assign h0 = {tok3, 24'h0} ^ 32'h04C11DB7;
    assign h1 = {h0[23:0], h0[31:24]} ^ {tok2, 24'hA55A55};
    assign h2 = {h1[15:0], h1[31:16]} ^ {tok1, 24'h3C3C3C};
    assign h3 = {h2[7:0],  h2[31:8]}   ^ {tok0, 24'hF0F0F0};

    logic [31:0] computed_hash;
    assign computed_hash = h3 ^ 32'h1F83D9AB;

    // -------------------------------------------------------------------------
    // 2. 8-Entry On-Chip Prefix Cache CAM (Separate arrays for robust EDA tool support)
    // -------------------------------------------------------------------------
    logic        cam_valid    [0:7];
    logic [31:0] cam_tag_hash [0:7];
    logic [15:0] cam_page_id  [0:7];

    // Decode control fields
    logic [7:0]  cmd_mode;
    logic [2:0]  target_cam_idx;
    logic [15:0] commit_page_id;

    assign cmd_mode       = config_tag_in[31:24];
    assign target_cam_idx = config_tag_in[18:16];
    assign commit_page_id = config_tag_in[15:0];

    // -------------------------------------------------------------------------
    // 3. Parallel 1-Cycle Associative Match Logic
    // -------------------------------------------------------------------------
    logic [7:0]  line_match_vector;
    logic        hit_any;
    logic [2:0]  hit_idx;
    logic [15:0] hit_page_id;

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            line_match_vector[i] = cam_valid[i] && (cam_tag_hash[i] == computed_hash);
        end

        // Priority encoder across 8 CAM lines
        hit_any     = |line_match_vector;
        hit_idx     = 3'd0;
        hit_page_id = 16'd0;

        if (line_match_vector[0]) begin
            hit_idx     = 3'd0;
            hit_page_id = cam_page_id[0];
        end else if (line_match_vector[1]) begin
            hit_idx     = 3'd1;
            hit_page_id = cam_page_id[1];
        end else if (line_match_vector[2]) begin
            hit_idx     = 3'd2;
            hit_page_id = cam_page_id[2];
        end else if (line_match_vector[3]) begin
            hit_idx     = 3'd3;
            hit_page_id = cam_page_id[3];
        end else if (line_match_vector[4]) begin
            hit_idx     = 3'd4;
            hit_page_id = cam_page_id[4];
        end else if (line_match_vector[5]) begin
            hit_idx     = 3'd5;
            hit_page_id = cam_page_id[5];
        end else if (line_match_vector[6]) begin
            hit_idx     = 3'd6;
            hit_page_id = cam_page_id[6];
        end else if (line_match_vector[7]) begin
            hit_idx     = 3'd7;
            hit_page_id = cam_page_id[7];
        end
    end

    // Combinational Output Formatting
    always_comb begin
        if (cmd_mode == 8'h00) begin
            // MATCH MODE: Return hit flag, hit index, and physical page ID
            match_result_out = {hit_any, 3'b0, 12'h0, hit_page_id};
            if (hit_any) begin
                match_result_out[30:28] = hit_idx;
            end
        end else if (cmd_mode == 8'h01) begin
            // COMMIT ACK: Return computed hash of committed token vector
            match_result_out = computed_hash;
        end else begin
            // Default / Status
            match_result_out = {hit_any, 3'b0, 12'h0, 16'h0000};
        end
    end

    // -------------------------------------------------------------------------
    // 4. Sequential CAM Line Update (Commit / Invalidate)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 8; k++) begin
                cam_valid[k]    <= 1'b0;
                cam_tag_hash[k] <= 32'h0;
                cam_page_id[k]  <= 16'h0;
            end
        end else begin
            if (cmd_mode == 8'h01) begin
                // COMMIT MODE: Register hash and page ID into specified CAM line
                cam_valid[target_cam_idx]    <= 1'b1;
                cam_tag_hash[target_cam_idx] <= computed_hash;
                cam_page_id[target_cam_idx]  <= commit_page_id;
            end else if (cmd_mode == 8'h02) begin
                // INVALIDATE ALL MODE: Flush all prefix tags
                for (int m = 0; m < 8; m++) begin
                    cam_valid[m] <= 1'b0;
                end
            end
        end
    end

endmodule
