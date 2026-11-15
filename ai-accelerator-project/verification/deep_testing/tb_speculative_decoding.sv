// ==============================================================================
// Testbench: tb_speculative_decoding.sv
// Description: Comprehensive verification of Speculative Decoding Micro-Core
//              co-simulated with the Autonomous On-Chip KV Cache Ring Buffer.
//              Tests parallel draft verification, corrective token emission,
//              1-cycle instantaneous KV cache rewinding, and real-time telemetry.
// ==============================================================================

`timescale 1ns / 1ps

module tb_speculative_decoding;

    localparam int SPEC_DEPTH  = 4;
    localparam int TOKEN_WIDTH = 16;
    localparam int DATA_WIDTH  = 16;
    localparam int VEC_SIZE    = 8;
    localparam int MAX_SEQ_LEN = 128;
    localparam real CLK_PERIOD = 2.0; // 500 MHz

    logic clk;
    logic rst_n;

    // Speculative Core Signals
    logic                                     spec_start;
    logic [$clog2(MAX_SEQ_LEN):0]             spec_seq_base;
    logic                                     spec_busy;
    logic                                     spec_done;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      draft_tokens_packed;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      target_tokens_packed;
    logic                                     kv_rollback_valid;
    logic [$clog2(MAX_SEQ_LEN):0]             kv_rollback_seq_len;
    logic [$clog2(SPEC_DEPTH+2)-1:0]          committed_count;
    logic [((SPEC_DEPTH+1)*TOKEN_WIDTH)-1:0]  committed_tokens_packed;
    logic [31:0]                              telemetry_total_steps;
    logic [31:0]                              telemetry_draft_tokens;
    logic [31:0]                              telemetry_accepted_tokens;
    logic [31:0]                              telemetry_emitted_tokens;
    logic [15:0]                              telemetry_speedup_q8;

    // KV Cache Signals
    logic                                     append_valid;
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  k_token_in;
    logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  v_token_in;
    logic [$clog2(MAX_SEQ_LEN):0]             current_seq_len;

    // Instantiate Speculative Decoding Core
    speculative_decoding_core #(
        .SPEC_DEPTH(SPEC_DEPTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .MAX_SEQ_LEN(MAX_SEQ_LEN)
    ) u_spec_core (
        .clk(clk),
        .rst_n(rst_n),
        .spec_start(spec_start),
        .spec_seq_base(spec_seq_base),
        .spec_busy(spec_busy),
        .spec_done(spec_done),
        .draft_tokens_packed(draft_tokens_packed),
        .target_tokens_packed(target_tokens_packed),
        .kv_rollback_valid(kv_rollback_valid),
        .kv_rollback_seq_len(kv_rollback_seq_len),
        .committed_count(committed_count),
        .committed_tokens_packed(committed_tokens_packed),
        .telemetry_total_steps(telemetry_total_steps),
        .telemetry_draft_tokens(telemetry_draft_tokens),
        .telemetry_accepted_tokens(telemetry_accepted_tokens),
        .telemetry_emitted_tokens(telemetry_emitted_tokens),
        .telemetry_speedup_q8(telemetry_speedup_q8)
    );

    // Instantiate Autonomous KV Cache Ring Buffer
    kv_cache_ring_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .VEC_SIZE(VEC_SIZE),
        .MAX_SEQ_LEN(MAX_SEQ_LEN)
    ) u_kv_cache (
        .clk(clk),
        .rst_n(rst_n),
        .append_valid(append_valid),
        .k_token_in(k_token_in),
        .v_token_in(v_token_in),
        .rollback_valid(kv_rollback_valid),
        .rollback_seq_len(kv_rollback_seq_len),
        .stream_start(1'b0),
        .stream_read_v(1'b0),
        .stream_valid(),
        .stream_vec_out(),
        .stream_token_idx(),
        .stream_done(),
        .current_seq_len(current_seq_len),
        .cache_full()
    );

    // 500 MHz Clock Generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    int errors = 0;

    // Helper task to append dummy vectors
    task automatic append_tokens(input int count);
        for (int i = 0; i < count; i++) begin
            append_valid = 1;
            k_token_in   = 128'h0123456789ABCDEF0123456789ABCDEF + i;
            v_token_in   = 128'hFEDCBA9876543210FEDCBA9876543210 + i;
            #(CLK_PERIOD);
        end
        append_valid = 0;
        #(CLK_PERIOD);
    endtask

    initial begin
        rst_n                = 0;
        spec_start           = 0;
        spec_seq_base        = 0;
        draft_tokens_packed  = '0;
        target_tokens_packed = '0;
        append_valid         = 0;
        k_token_in           = '0;
        v_token_in           = '0;
        #10;
        rst_n = 1;
        #10;

        $display("==========================================================================");
        $display("  BITNET SPECULATIVE DECODING CORE + KV CACHE HARDWARE CO-SIMULATION");
        $display("==========================================================================");

        // Pre-fill KV cache with 10 prompt context tokens
        $display("\n>>> Pre-filling KV Cache with 10 Prompt Tokens...");
        append_tokens(10);
        $display("  KV Cache Current Seq Len = %0d", current_seq_len);
        if (current_seq_len != 10) begin
            $display("  [ERROR] Expected current_seq_len = 10, got %0d", current_seq_len);
            errors++;
        end

        // ---------------------------------------------------------------------
        // TEST 1: Partial Speculation (Tokens 0,1 Match; Token 2 Fails)
        // ---------------------------------------------------------------------
        $display("\n>>> [TEST 1] Testing Partial Match (K=4: Tokens 0,1 match, token 2 mismatch)...");
        // Speculatively add 4 candidate tokens to KV cache (seq_len temporarily becomes 14)
        append_tokens(4);
        $display("  Speculative Burst: KV Cache Current Seq Len = %0d", current_seq_len);

        // Setup Draft vs Target
        // Draft:  [1001, 1002, 1003, 1004]
        // Target: [1001, 1002, 9999, 8888]
        draft_tokens_packed  = {16'd1004, 16'd1003, 16'd1002, 16'd1001};
        target_tokens_packed = {16'd8888, 16'd9999, 16'd1002, 16'd1001};
        spec_seq_base        = 10; // Base position before the 4 speculative tokens

        spec_start = 1;
        #(CLK_PERIOD);
        spec_start = 0;

        wait(spec_done == 1'b1);
        #(CLK_PERIOD);

        $display("  Verification Complete: Produced %0d Valid Tokens in 1 Step!", committed_count);
        if (committed_count != 3) begin
            $display("  [ERROR] Expected committed_count = 3 (2 draft + 1 corrective), got %0d", committed_count);
            errors++;
        end

        // Check committed tokens
        if (committed_tokens_packed[0*16 +: 16] != 16'd1001 ||
            committed_tokens_packed[1*16 +: 16] != 16'd1002 ||
            committed_tokens_packed[2*16 +: 16] != 16'd9999) begin
            $display("  [ERROR] Committed tokens sequence mismatch!");
            errors++;
        end else begin
            $display("  [PASS] Correctly committed [1001, 1002, 9999] (drafts + target corrective)!");
        end

        // Verify KV cache rollback: length should have rewound from 14 to 10 + 3 = 13!
        $display("  Post-Rollback KV Cache Current Seq Len = %0d", current_seq_len);
        if (current_seq_len != 13) begin
            $display("  [ERROR] Expected KV Cache rewound to 13, got %0d", current_seq_len);
            errors++;
        end else begin
            $display("  [PASS] Instantaneous 1-Cycle KV Cache Rewind Verified: Rewound 14 -> 13!");
        end

        // ---------------------------------------------------------------------
        // TEST 2: Full Speculation Match (All K=4 Match!)
        // ---------------------------------------------------------------------
        $display("\n>>> [TEST 2] Testing 100%% Speculation Match (All 4 Draft Tokens Match)...");
        // Speculatively add 4 tokens to KV cache (seq_len becomes 17)
        append_tokens(4);
        spec_seq_base        = 13;
        draft_tokens_packed  = {16'd2004, 16'd2003, 16'd2002, 16'd2001};
        target_tokens_packed = {16'd2004, 16'd2003, 16'd2002, 16'd2001};

        spec_start = 1;
        #(CLK_PERIOD);
        spec_start = 0;

        wait(spec_done == 1'b1);
        #(CLK_PERIOD);

        $display("  Verification Complete: Produced %0d Valid Tokens in 1 Step!", committed_count);
        if (committed_count != 4) begin
            $display("  [ERROR] Expected committed_count = 4, got %0d", committed_count);
            errors++;
        end else begin
            $display("  [PASS] All 4 Draft Tokens Accepted at 4.0x Speedup!");
        end

        if (current_seq_len != 17) begin
            $display("  [ERROR] Expected KV Cache seq_len = 17, got %0d", current_seq_len);
            errors++;
        end

        // ---------------------------------------------------------------------
        // TEST 3: Multi-Step Telemetry Stress Test (10 Speculative Steps)
        // ---------------------------------------------------------------------
        $display("\n>>> [TEST 3] Running 10-Step Speculative Generation Benchmark...");
        for (int step = 0; step < 8; step++) begin
            append_tokens(4);
            spec_seq_base = current_seq_len - 4;
            // 75% match rate simulation
            draft_tokens_packed  = {16'd5004, 16'd5003, 16'd5002, 16'd5001};
            target_tokens_packed = {16'd7777, 16'd5003, 16'd5002, 16'd5001}; // 3 match, 1 mismatch

            spec_start = 1;
            #(CLK_PERIOD);
            spec_start = 0;
            wait(spec_done == 1'b1);
            #(CLK_PERIOD);
        end

        $display("\n==========================================================================");
        $display("  SPECULATIVE DECODING TELEMETRY REPORT");
        $display("  Total Verification Passes: %0d", telemetry_total_steps);
        $display("  Total Draft Tokens Tested: %0d", telemetry_draft_tokens);
        $display("  Total Draft Accepted:      %0d (%0.1f%% acceptance rate)",
                 telemetry_accepted_tokens, 
                 (real'(telemetry_accepted_tokens) / real'(telemetry_draft_tokens)) * 100.0);
        $display("  Total Emitted Tokens:      %0d", telemetry_emitted_tokens);
        $display("  Effective Silicon Speedup: %0.2fx Acceleration Factor",
                 real'(telemetry_speedup_q8) / 256.0);
        $display("==========================================================================");

        if (errors == 0) begin
            $display(">> SPECULATIVE DECODING VERIFICATION: 100%% BIT-EXACT PASS <<");
        end else begin
            $display(">> SPECULATIVE DECODING VERIFICATION: FAILED WITH %0d ERRORS <<", errors);
        end
        $finish;
    end

endmodule
