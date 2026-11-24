// ==============================================================================
// Module: speculative_decoding_coprocessor.sv
// Description: On-Chip Autonomous Speculative Decoding Co-Processor for BitNet LLM.
//              Couples a 1-bit / 1.58-bit Ternary Draft Engine with the 64-PE Target
//              Model over the 2D Mesh NoC using High-Priority Virtual Channel 1 (VC1).
//
// Key Features:
// 1. Zero-Multiplier Medusa / DeepSeek-MTP Draft Engine:
//    - Predicts K=4 speculative tokens from hidden state in 2 cycles.
// 2. High-Priority NoC VC1 Interconnect:
//    - Dispatches speculative candidate tokens and rollback requests over NoC VC1 (2'b01).
//    - Guarantees zero head-of-line blocking against bulk weight DMA (VC2) or telemetry (VC3).
// 3. 1-Cycle Autonomous KV Cache Rollback:
//    - Instantly prunes invalid speculative keys/values upon first draft token divergence.
// 4. Hardware Telemetry & Q8.8 Acceleration Profiler:
//    - Real-time hardware tracking of effective speedup ratio (e.g. 2.75x speedup).
// ==============================================================================

`timescale 1ns / 1ps

module speculative_decoding_coprocessor #(
    parameter int SPEC_DEPTH   = 4,   // K=4 speculative draft tokens
    parameter int VEC_SIZE     = 8,   // Activation dimension D=8
    parameter int DATA_WIDTH   = 16,  // INT16 activation precision
    parameter int TOKEN_WIDTH  = 16,  // Vocabulary token ID width
    parameter int MAX_SEQ_LEN  = 128, // Max KV cache sequence length
    parameter int FLIT_WIDTH   = 32   // NoC Flit Width
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Control Interface
    input  logic                                     coproc_start,
    input  logic signed [(VEC_SIZE*DATA_WIDTH)-1:0]  hidden_state_in,  // Target model last hidden state
    input  logic [$clog2(MAX_SEQ_LEN):0]             seq_base_in,      // Starting KV cache length
    output logic                                     coproc_busy,
    output logic                                     coproc_done,

    // Primary Target Compute Core Interface (For Parallel Forward Verification)
    output logic                                     target_verify_req,
    output logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      target_verify_drafts_packed,
    input  logic                                     target_verify_valid,
    input  logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      target_verify_tokens_packed, // Predictions from target forward pass

    // Direct KV Cache Ring Buffer Rollback Interface
    output logic                                     kv_rollback_valid,
    output logic [$clog2(MAX_SEQ_LEN):0]             kv_rollback_seq_len,

    // NoC VC1 Interface (High-Priority Speculative Interconnect)
    output logic                                     noc_tx_valid,
    output logic [FLIT_WIDTH-1:0]                    noc_tx_flit,
    input  logic                                     noc_tx_ready,

    input  logic                                     noc_rx_valid,
    input  logic [FLIT_WIDTH-1:0]                    noc_rx_flit,
    output logic                                     noc_rx_ready,

    // Committed Output Token Stream
    output logic [$clog2(SPEC_DEPTH+2)-1:0]          committed_count,
    output logic [((SPEC_DEPTH+1)*TOKEN_WIDTH)-1:0]  committed_tokens_packed,

    // Telemetry & Hardware Profiler
    output logic [31:0]                              telemetry_total_bursts,
    output logic [31:0]                              telemetry_draft_tokens,
    output logic [31:0]                              telemetry_accepted_tokens,
    output logic [31:0]                              telemetry_emitted_tokens,
    output logic [15:0]                              telemetry_speedup_q8
);

    localparam logic [1:0] NOC_VC1_SPEC = 2'b01; // High-Priority Speculative VC

    // -------------------------------------------------------------------------
    // 1. Speculative Draft Engine Instance (K=4 in 2 Cycles)
    // -------------------------------------------------------------------------
    logic                                draft_start;
    logic                                draft_valid;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0] draft_tokens_packed;
    logic                                draft_busy;

    draft_token_engine #(
        .SPEC_DEPTH(SPEC_DEPTH),
        .VEC_SIZE(VEC_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .VOCAB_CAND(4)
    ) u_draft_engine (
        .clk(clk),
        .rst_n(rst_n),
        .draft_start(draft_start),
        .hidden_state_in(hidden_state_in),
        .draft_valid(draft_valid),
        .draft_tokens_packed(draft_tokens_packed),
        .draft_busy(draft_busy)
    );

    // -------------------------------------------------------------------------
    // 2. Parallel Verification & 1-Cycle Rollback Core Instance
    // -------------------------------------------------------------------------
    logic                                     core_start;
    logic [$clog2(MAX_SEQ_LEN):0]             core_seq_base;
    logic                                     core_busy;
    logic                                     core_done;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      core_draft_packed;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0]      core_target_packed;

    speculative_decoding_core #(
        .SPEC_DEPTH(SPEC_DEPTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .MAX_SEQ_LEN(MAX_SEQ_LEN)
    ) u_verify_core (
        .clk(clk),
        .rst_n(rst_n),
        .spec_start(core_start),
        .spec_seq_base(core_seq_base),
        .spec_busy(core_busy),
        .spec_done(core_done),
        .draft_tokens_packed(core_draft_packed),
        .target_tokens_packed(core_target_packed),
        .kv_rollback_valid(kv_rollback_valid),
        .kv_rollback_seq_len(kv_rollback_seq_len),
        .committed_count(committed_count),
        .committed_tokens_packed(committed_tokens_packed),
        .telemetry_total_steps(telemetry_total_bursts),
        .telemetry_draft_tokens(telemetry_draft_tokens),
        .telemetry_accepted_tokens(telemetry_accepted_tokens),
        .telemetry_emitted_tokens(telemetry_emitted_tokens),
        .telemetry_speedup_q8(telemetry_speedup_q8)
    );

    // -------------------------------------------------------------------------
    // 3. Co-Processor Orchestration FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE          = 3'd0,
        ST_DRAFT_GEN     = 3'd1,
        ST_NOC_DISPATCH  = 3'd2,
        ST_TARGET_VERIFY = 3'd3,
        ST_EVAL_COMMIT   = 3'd4,
        ST_DONE          = 3'd5
    } coproc_state_t;

    coproc_state_t state;
    logic [(SPEC_DEPTH*TOKEN_WIDTH)-1:0] latched_draft_tokens;
    logic [$clog2(MAX_SEQ_LEN):0]        latched_seq_base;

    assign target_verify_drafts_packed = latched_draft_tokens;
    assign core_draft_packed           = latched_draft_tokens;

    // NoC flit packing for VC1:
    // [31:30]=Type 00, [29:28]=DestX 01, [27:26]=DestY 00, [25:24]=VC1 (01), [23:0]=Tokens 0 & 1
    logic noc_tx_valid_r;
    logic [FLIT_WIDTH-1:0] noc_tx_flit_r;
    assign noc_tx_valid = noc_tx_valid_r;
    assign noc_tx_flit  = noc_tx_flit_r;
    assign noc_rx_ready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            coproc_busy          <= 1'b0;
            coproc_done          <= 1'b0;
            draft_start          <= 1'b0;
            core_start           <= 1'b0;
            core_seq_base        <= '0;
            core_target_packed   <= '0;
            target_verify_req    <= 1'b0;
            latched_draft_tokens <= '0;
            latched_seq_base     <= '0;
            noc_tx_valid_r       <= 1'b0;
            noc_tx_flit_r        <= '0;
        end else begin
            draft_start    <= 1'b0;
            core_start     <= 1'b0;
            coproc_done    <= 1'b0;
            noc_tx_valid_r <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (coproc_start) begin
                        coproc_busy      <= 1'b1;
                        draft_start      <= 1'b1;
                        latched_seq_base <= seq_base_in;
                        state            <= ST_DRAFT_GEN;
                    end else begin
                        coproc_busy <= 1'b0;
                    end
                end

                ST_DRAFT_GEN: begin
                    // Draft engine takes 2 cycles to compute logits and argmax
                    if (draft_valid) begin
                        latched_draft_tokens <= draft_tokens_packed;
                        // Dispatch tokens over NoC VC1 to target core
                        noc_tx_flit_r  <= {2'b00, 2'b01, 2'b00, NOC_VC1_SPEC, 8'hAA, draft_tokens_packed[15:0]};
                        noc_tx_valid_r <= 1'b1;
                        state          <= ST_NOC_DISPATCH;
                    end
                end

                ST_NOC_DISPATCH: begin
                    if (noc_tx_ready || !noc_tx_valid_r) begin
                        target_verify_req <= 1'b1;
                        state             <= ST_TARGET_VERIFY;
                    end
                end

                ST_TARGET_VERIFY: begin
                    // Wait for 64-PE target model parallel forward pass
                    if (target_verify_valid) begin
                        target_verify_req  <= 1'b0;
                        core_target_packed <= target_verify_tokens_packed;
                        core_seq_base      <= latched_seq_base;
                        core_start         <= 1'b1;
                        state              <= ST_EVAL_COMMIT;
                    end
                end

                ST_EVAL_COMMIT: begin
                    // Verification core performs prefix match and 1-cycle rollback
                    if (core_done) begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    coproc_busy <= 1'b0;
                    coproc_done <= 1'b1;
                    state       <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
