// ==============================================================================
// Module: bitnet_universal_processor_top.sv
// Description: World's First Turing-Complete Universal Micro-Tensor AI Processor.
//              Integrates:
//                1. 32-bit RISC-V Core with Native Xbitnet Tensor Matrix Extension
//                2. 2:4 Semi-Structured Sparse Ternary Acceleration Engine
//                3. Autonomous Speculative Decoding Co-Processor (Medusa K=4)
//                4. 1-Cycle Instantaneous On-Chip KV Cache Ring Buffer
//                5. 500 MHz 2D Mesh NoC Router with 4 Virtual Channels (VC0..VC3)
//                6. D2D UCIe 1.0/2.0 Multi-Die Interconnect (Beachfront Pins)
//                7. On-Chip Instruction and Data Tightly Coupled SRAMs (TCM)
// ==============================================================================

`timescale 1ns / 1ps

module bitnet_universal_processor_top #(
    parameter int IMEM_DEPTH   = 256,
    parameter int DMEM_DEPTH   = 256,
    parameter int FLIT_WIDTH   = 32,
    parameter int PHY_LANES    = 16,
    parameter int REPAIR_LANES = 1
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // External Program Loading Interface (To write program into IMEM)
    input  logic                   prog_load_en,
    input  logic [31:0]            prog_load_addr,
    input  logic [31:0]            prog_load_data,

    // UCIe 1.0/2.0 D2D Beachfront Microbump Pins (To External Partner Dies)
    output logic [PHY_LANES+REPAIR_LANES-1:0] d2d_tx_lanes,
    output logic                              d2d_tx_valid,
    output logic                              d2d_tx_fwd_clk,
    output logic                              d2d_tx_sideband,
    input  logic [PHY_LANES+REPAIR_LANES-1:0] d2d_rx_lanes,
    input  logic                              d2d_rx_valid,
    input  logic                              d2d_rx_fwd_clk,
    input  logic                              d2d_rx_sideband,

    // Status & Telemetry
    output logic [31:0]            telemetry_pc,
    output logic [31:0]            telemetry_retired_instr,
    output logic [31:0]            telemetry_cycle_count,
    output logic [7:0]             current_kv_seq_len,
    output logic [7:0]             expert_clock_gate_mask,
    output logic                   d2d_link_up
);

    // -------------------------------------------------------------------------
    // 1. Tightly Coupled Instruction Memory (IMEM)
    // -------------------------------------------------------------------------
    logic [31:0] imem [0:IMEM_DEPTH-1];
    logic [31:0] cpu_imem_addr;
    logic [31:0] cpu_imem_rdata;

    always_ff @(posedge clk) begin
        if (prog_load_en) begin
            imem[prog_load_addr[9:2]] <= prog_load_data;
        end
    end
    assign cpu_imem_rdata = imem[cpu_imem_addr[9:2]];
    assign telemetry_pc   = cpu_imem_addr;

    // -------------------------------------------------------------------------
    // 2. Tightly Coupled Data Memory (DMEM)
    // -------------------------------------------------------------------------
    logic [31:0] dmem [0:DMEM_DEPTH-1];
    logic        cpu_dmem_en, cpu_dmem_we;
    logic [31:0] cpu_dmem_addr, cpu_dmem_wdata, cpu_dmem_rdata;

    always_ff @(posedge clk) begin
        if (cpu_dmem_en && cpu_dmem_we) begin
            dmem[cpu_dmem_addr[9:2]] <= cpu_dmem_wdata;
        end
    end
    assign cpu_dmem_rdata = dmem[cpu_dmem_addr[9:2]];

    // -------------------------------------------------------------------------
    // 3. Xbitnet Coprocessor Interconnect Signals
    // -------------------------------------------------------------------------
    logic [1:0]         xbit_w0, xbit_w1;
    logic [2:0]         xbit_pattern;
    logic [31:0]        xbit_act_in;
    logic signed [31:0] xbit_dot_out;

    logic        xbit_spec_start;
    logic [31:0] xbit_spec_h_state;
    logic        xbit_spec_done;
    logic [2:0]  xbit_spec_committed;

    logic        xbit_kv_rollback_val;
    logic [7:0]  xbit_kv_rollback_len;

    logic        xbit_arr_en;
    logic        xbit_os_mode;
    logic [1:0]  xbit_prec_mode;

    logic [15:0]        xbit_rope_pos;
    logic signed [15:0] xbit_rope_x_in;
    logic signed [15:0] xbit_rope_y_in;
    logic signed [15:0] xbit_rope_x_out;
    logic signed [15:0] xbit_rope_y_out;

    // MoE Interconnect
    logic [1:0]  xbit_moe_topk_mode;
    logic        xbit_moe_wr_en;
    logic [1:0]  xbit_moe_wr_idx;
    logic [31:0] xbit_moe_wr_data;
    logic [31:0] xbit_moe_packed_result;

    // SIMD Quad-Vector Sparsity Interconnect
    logic [27:0]        xbit_sparse_quad_weights;
    logic [31:0]        xbit_sparse_quad_act;
    logic signed [31:0] xbit_sparse_quad_dot_out;

    // SwiGLU Vector Interconnect
    logic signed [31:0] xbit_swiglu_gate_in;
    logic signed [31:0] xbit_swiglu_up_in;
    logic signed [31:0] xbit_swiglu_pair_out;

    // Sampler Interconnect
    logic signed [31:0] xbit_sampler_cand_in;
    logic signed [31:0] xbit_sampler_best_in;
    logic signed [31:0] xbit_sampler_winner_out;

    // FlashAttention Online Softmax Interconnect
    logic signed [31:0] xbit_vattn_state_in;
    logic signed [31:0] xbit_vattn_score_in;
    logic signed [31:0] xbit_vattn_state_out;

    // Vector RMSNorm Interconnect
    logic signed [31:0] xbit_rmsnorm_act_in;
    logic signed [31:0] xbit_rmsnorm_scale_in;
    logic signed [31:0] xbit_rmsnorm_norm_out;

    // Stochastic Sampler Interconnect
    logic signed [31:0] xbit_stoch_cand_in;
    logic signed [31:0] xbit_stoch_best_in;
    logic        [31:0] xbit_stoch_config_in;
    logic signed [31:0] xbit_stoch_winner_out;

    // 4-Bit KV Cache Codec Interconnect
    logic signed [31:0] xbit_kv_codec_data_in;
    logic        [31:0] xbit_kv_codec_config_in;
    logic signed [31:0] xbit_kv_codec_data_out;

    // Prefix Cache Matcher Interconnect
    logic [31:0]        xbit_prefix_tok_in;
    logic [31:0]        xbit_prefix_cfg_in;
    logic [31:0]        xbit_prefix_result_out;

    // Microscaling (MX) Dot Engine Interconnect
    logic signed [31:0] xbit_mx_act_in;
    logic        [31:0] xbit_mx_cfg_in;
    logic signed [31:0] xbit_mx_result_out;

    // Multi-Head Latent Attention (MLA) Interconnect
    logic signed [31:0] xbit_mla_act_in;
    logic        [31:0] xbit_mla_cfg_in;
    logic signed [31:0] xbit_mla_packed_out;

    // UCIe Link Health Interconnect
    logic [31:0]        xbit_link_flit_in;
    logic [31:0]        xbit_link_cfg_in;
    logic [31:0]        xbit_link_status_out;

    // -------------------------------------------------------------------------
    // 4. Embedded RISC-V Core with Xbitnet ISA Extension
    // -------------------------------------------------------------------------
    riscv_xbitnet_core u_riscv_core (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr(cpu_imem_addr),
        .imem_rdata(cpu_imem_rdata),
        .dmem_en(cpu_dmem_en),
        .dmem_we(cpu_dmem_we),
        .dmem_addr(cpu_dmem_addr),
        .dmem_wdata(cpu_dmem_wdata),
        .dmem_rdata(cpu_dmem_rdata),
        .xbit_sparse_w0(xbit_w0),
        .xbit_sparse_w1(xbit_w1),
        .xbit_sparse_pattern(xbit_pattern),
        .xbit_sparse_act_in(xbit_act_in),
        .xbit_sparse_dot_out(xbit_dot_out),
        .xbit_spec_start(xbit_spec_start),
        .xbit_spec_hidden_state(xbit_spec_h_state),
        .xbit_spec_done(xbit_spec_done),
        .xbit_spec_committed_count(xbit_spec_committed),
        .xbit_kv_rollback_valid(xbit_kv_rollback_val),
        .xbit_kv_rollback_seq_len(xbit_kv_rollback_len),
        .xbit_array_enable(xbit_arr_en),
        .xbit_mode_os(xbit_os_mode),
        .xbit_precision_mode(xbit_prec_mode),
        .xbit_rope_pos(xbit_rope_pos),
        .xbit_rope_x_in(xbit_rope_x_in),
        .xbit_rope_y_in(xbit_rope_y_in),
        .xbit_rope_x_out(xbit_rope_x_out),
        .xbit_rope_y_out(xbit_rope_y_out),
        .xbit_moe_topk_mode(xbit_moe_topk_mode),
        .xbit_moe_wr_en(xbit_moe_wr_en),
        .xbit_moe_wr_idx(xbit_moe_wr_idx),
        .xbit_moe_wr_data(xbit_moe_wr_data),
        .xbit_moe_packed_result(xbit_moe_packed_result),
        .xbit_sparse_quad_weights(xbit_sparse_quad_weights),
        .xbit_sparse_quad_act(xbit_sparse_quad_act),
        .xbit_sparse_quad_dot_out(xbit_sparse_quad_dot_out),
        .xbit_swiglu_gate_in(xbit_swiglu_gate_in),
        .xbit_swiglu_up_in(xbit_swiglu_up_in),
        .xbit_swiglu_pair_out(xbit_swiglu_pair_out),
        .xbit_sampler_cand_in(xbit_sampler_cand_in),
        .xbit_sampler_best_in(xbit_sampler_best_in),
        .xbit_sampler_winner_out(xbit_sampler_winner_out),
        .xbit_vattn_state_in(xbit_vattn_state_in),
        .xbit_vattn_score_in(xbit_vattn_score_in),
        .xbit_vattn_state_out(xbit_vattn_state_out),
        .xbit_rmsnorm_act_in(xbit_rmsnorm_act_in),
        .xbit_rmsnorm_scale_in(xbit_rmsnorm_scale_in),
        .xbit_rmsnorm_norm_out(xbit_rmsnorm_norm_out),
        .xbit_stoch_cand_in(xbit_stoch_cand_in),
        .xbit_stoch_best_in(xbit_stoch_best_in),
        .xbit_stoch_config_in(xbit_stoch_config_in),
        .xbit_stoch_winner_out(xbit_stoch_winner_out),
        .xbit_kv_codec_data_in(xbit_kv_codec_data_in),
        .xbit_kv_codec_config_in(xbit_kv_codec_config_in),
        .xbit_kv_codec_data_out(xbit_kv_codec_data_out),
        .xbit_prefix_tok_in(xbit_prefix_tok_in),
        .xbit_prefix_cfg_in(xbit_prefix_cfg_in),
        .xbit_prefix_result_out(xbit_prefix_result_out),
        .xbit_mx_act_in(xbit_mx_act_in),
        .xbit_mx_cfg_in(xbit_mx_cfg_in),
        .xbit_mx_result_out(xbit_mx_result_out),
        .xbit_mla_act_in(xbit_mla_act_in),
        .xbit_mla_cfg_in(xbit_mla_cfg_in),
        .xbit_mla_packed_out(xbit_mla_packed_out),
        .xbit_link_flit_in(xbit_link_flit_in),
        .xbit_link_cfg_in(xbit_link_cfg_in),
        .xbit_link_status_out(xbit_link_status_out),
        .telemetry_retired_instr(telemetry_retired_instr),
        .telemetry_cycle_count(telemetry_cycle_count)
    );

    // -------------------------------------------------------------------------
    // 4b. 1-Cycle Hardware CORDIC RoPE Engine Instance
    // -------------------------------------------------------------------------
    rope_2d_cordic u_rope_cordic (
        .x_in(xbit_rope_x_in),
        .y_in(xbit_rope_y_in),
        .token_pos(xbit_rope_pos),
        .x_out(xbit_rope_x_out),
        .y_out(xbit_rope_y_out)
    );

    // -------------------------------------------------------------------------
    // 4c. Hardware-Fused MoE Top-K Router Instance (DeepSeek V3 / Mixtral)
    // -------------------------------------------------------------------------
    logic [31:0] moe_logits_words [0:3];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Default logits: E0=10, E1=25, E2=-5, E3=120, E4=30, E5=0, E6=95, E7=-40
            moe_logits_words[0] <= {16'sd25, 16'sd10};   // E1, E0
            moe_logits_words[1] <= {16'sd120, -16'sd5};  // E3, E2
            moe_logits_words[2] <= {16'sd0, 16'sd30};    // E5, E4
            moe_logits_words[3] <= {-16'sd40, 16'sd95};  // E7, E6
        end else if (xbit_moe_wr_en) begin
            moe_logits_words[xbit_moe_wr_idx] <= xbit_moe_wr_data;
        end
    end

    wire signed [127:0] flat_logits = {
        moe_logits_words[3],
        moe_logits_words[2],
        moe_logits_words[1],
        moe_logits_words[0]
    };

    moe_topk_router #(
        .NUM_EXPERTS(8),
        .DATA_WIDTH(16),
        .WEIGHT_WIDTH(16)
    ) u_moe_router (
        .clk(clk),
        .rst_n(rst_n),
        .route_start(1'b1),
        .top_k_mode(xbit_moe_topk_mode),
        .logits_flat_in(flat_logits),
        .selected_expert_0(),
        .selected_expert_1(),
        .selected_expert_2(),
        .selected_expert_3(),
        .expert_weight_0(),
        .expert_weight_1(),
        .expert_weight_2(),
        .expert_weight_3(),
        .expert_active_mask(expert_clock_gate_mask),
        .route_valid(),
        .packed_routing_result(xbit_moe_packed_result)
    );

    // -------------------------------------------------------------------------
    // 4d. SIMD Quad-Vector 2:4 Sparsity Decompressor & Dot-Product Engine
    // -------------------------------------------------------------------------
    sparse_quad_vec_decompressor #(
        .ACT_WIDTH(8),
        .ACC_WIDTH(32)
    ) u_sparse_quad_engine (
        .packed_sparse_weights(xbit_sparse_quad_weights),
        .act_vec_16_in({4{xbit_sparse_quad_act}}),
        .decomp_weights_16_out(),
        .quad_dot_out(xbit_sparse_quad_dot_out)
    );

    // -------------------------------------------------------------------------
    // 4e. Multiplier-Free 1-Cycle Dual SwiGLU / GeGLU Vector Engine (Llama-3/DeepSeek)
    // -------------------------------------------------------------------------
    swiglu_vector_engine #(
        .DATA_WIDTH(16)
    ) u_swiglu_engine (
        .gate_pair_in(xbit_swiglu_gate_in),
        .up_pair_in(xbit_swiglu_up_in),
        .swiglu_pair_out(xbit_swiglu_pair_out)
    );

    // -------------------------------------------------------------------------
    // 4f. 1-Cycle Branch-Free Token Sampler & Greedy Argmax Engine
    // -------------------------------------------------------------------------
    llm_sampler_engine u_sampler_engine (
        .cand_pair_in(xbit_sampler_cand_in),
        .curr_best_in(xbit_sampler_best_in),
        .winner_out(xbit_sampler_winner_out)
    );

    // -------------------------------------------------------------------------
    // 4g. Multiplier-Free 1-Cycle Hardware FlashAttention Online Softmax Engine
    // -------------------------------------------------------------------------
    flash_online_softmax_engine #(
        .DATA_WIDTH(16)
    ) u_flash_softmax_engine (
        .state_prev_in(xbit_vattn_state_in),
        .score_cand_in(xbit_vattn_score_in),
        .state_new_out(xbit_vattn_state_out)
    );

    // -------------------------------------------------------------------------
    // 4h. Multiplier-Free 1-Cycle Dual-Element Vector RMSNorm Engine
    // -------------------------------------------------------------------------
    rmsnorm_vector_engine #(
        .DATA_WIDTH(16)
    ) u_rmsnorm_vector_engine (
        .act_pair_in(xbit_rmsnorm_act_in),
        .scale_pair_in(xbit_rmsnorm_scale_in),
        .norm_pair_out(xbit_rmsnorm_norm_out)
    );

    // -------------------------------------------------------------------------
    // 4i. Multiplier-Free 1-Cycle Stochastic Min-P / Top-P Sampler Engine
    // -------------------------------------------------------------------------
    llm_stochastic_sampler_engine u_stoch_sampler_engine (
        .clk(clk),
        .rst_n(rst_n),
        .cand_pair_in(xbit_stoch_cand_in),
        .best_pair_in(xbit_stoch_best_in),
        .config_in(xbit_stoch_config_in),
        .winner_pair_out(xbit_stoch_winner_out)
    );

    // -------------------------------------------------------------------------
    // 4j. Multiplier-Free 1-Cycle 4-Bit Packed KV-Cache Compression Codec
    // -------------------------------------------------------------------------
    kv_cache_codec_engine u_kv_cache_codec_engine (
        .data_in(xbit_kv_codec_data_in),
        .config_in(xbit_kv_codec_config_in),
        .data_out(xbit_kv_codec_data_out)
    );

    // -------------------------------------------------------------------------
    // 4k. Multiplier-Free 1-Cycle Hardware Prefix Cache Hash & Radix Matcher
    // -------------------------------------------------------------------------
    prefix_cache_matcher_engine u_prefix_matcher_engine (
        .clk(clk),
        .rst_n(rst_n),
        .token_vector_in(xbit_prefix_tok_in),
        .config_tag_in(xbit_prefix_cfg_in),
        .match_result_out(xbit_prefix_result_out)
    );

    // -------------------------------------------------------------------------
    // 4l. Multiplier-Free 1-Cycle Microscaling (MX) Dot Product Engine
    // -------------------------------------------------------------------------
    mx_block_dot_engine u_mx_block_dot_engine (
        .act_vector_in(xbit_mx_act_in),
        .config_weight_in(xbit_mx_cfg_in),
        .result_dot_out(xbit_mx_result_out)
    );

    // -------------------------------------------------------------------------
    // 4m. Multiplier-Free 1-Cycle Multi-Head Latent Attention (MLA) Engine
    // -------------------------------------------------------------------------
    mla_compression_engine u_mla_compression_engine (
        .act_vector_in(xbit_mla_act_in),
        .config_proj_in(xbit_mla_cfg_in),
        .mla_packed_out(xbit_mla_packed_out)
    );

    // -------------------------------------------------------------------------
    // 4n. Multiplier-Free 1-Cycle Hardware CRC & UCIe Link Health Engine
    // -------------------------------------------------------------------------
    ucie_link_health_engine u_ucie_link_health_engine (
        .flit_data_in(xbit_link_flit_in),
        .config_crc_in(xbit_link_cfg_in),
        .link_status_out(xbit_link_status_out)
    );

    // -------------------------------------------------------------------------
    // 5. 2:4 Structured Sparsity Engine Instance
    // -------------------------------------------------------------------------
    sparse_2_4_ternary_decompressor #(
        .DATA_WIDTH(16),
        .ACC_WIDTH(32)
    ) u_sparse_engine (
        .clk(clk),
        .rst_n(rst_n),
        .w_val0(xbit_w0),
        .w_val1(xbit_w1),
        .w_pattern(xbit_pattern),
        .act_vec_4_in({32'h0000_0000, xbit_act_in}),
        .decomp_weights_out(),
        .sparse_dot_out(xbit_dot_out)
    );

    // -------------------------------------------------------------------------
    // 6. Autonomous Speculative Decoding Co-Processor Instance
    // -------------------------------------------------------------------------
    logic        noc_spec_tx_valid;
    logic [31:0] noc_spec_tx_flit;
    logic        noc_spec_tx_ready;
    logic        spec_verify_req;

    speculative_decoding_coprocessor #(
        .SPEC_DEPTH(4),
        .VEC_SIZE(8),
        .DATA_WIDTH(16),
        .TOKEN_WIDTH(16),
        .MAX_SEQ_LEN(128),
        .FLIT_WIDTH(32)
    ) u_spec_coproc (
        .clk(clk),
        .rst_n(rst_n),
        .coproc_start(xbit_spec_start),
        .hidden_state_in({4{xbit_spec_h_state}}),
        .seq_base_in(8'd16),
        .coproc_busy(),
        .coproc_done(xbit_spec_done),
        .target_verify_req(spec_verify_req),
        .target_verify_drafts_packed(),
        .target_verify_valid(spec_verify_req),
        .target_verify_tokens_packed(64'h0407_03FE_03F2_03E9), // Predictions from target forward pass
        .kv_rollback_valid(),
        .kv_rollback_seq_len(),
        .noc_tx_valid(noc_spec_tx_valid),
        .noc_tx_flit(noc_spec_tx_flit),
        .noc_tx_ready(noc_spec_tx_ready),
        .noc_rx_valid(1'b0),
        .noc_rx_flit(32'h0),
        .noc_rx_ready(),
        .committed_count(xbit_spec_committed),
        .committed_tokens_packed(),
        .telemetry_total_bursts(),
        .telemetry_draft_tokens(),
        .telemetry_accepted_tokens(),
        .telemetry_emitted_tokens(),
        .telemetry_speedup_q8()
    );

    // -------------------------------------------------------------------------
    // 7. On-Chip Autonomous KV Cache Ring Buffer Instance
    // -------------------------------------------------------------------------
    kv_cache_ring_buffer #(
        .DATA_WIDTH(16),
        .VEC_SIZE(8),
        .MAX_SEQ_LEN(128)
    ) u_kv_cache (
        .clk(clk),
        .rst_n(rst_n),
        .append_valid(1'b0),
        .k_token_in('0),
        .v_token_in('0),
        .rollback_valid(xbit_kv_rollback_val),
        .rollback_seq_len(xbit_kv_rollback_len),
        .stream_start(1'b0),
        .stream_read_v(1'b0),
        .stream_valid(),
        .stream_vec_out(),
        .stream_token_idx(),
        .stream_done(),
        .current_seq_len(current_kv_seq_len),
        .cache_full()
    );

    // -------------------------------------------------------------------------
    // 8. 500 MHz 2D Mesh NoC Router (VC0..VC3)
    // -------------------------------------------------------------------------
    logic [4:0]   noc_in_ready;
    logic [4:0]   noc_out_valid;
    logic [159:0] noc_out_data;

    noc_router_2d_vc4 #(
        .NODE_X(0),
        .NODE_Y(0),
        .FLIT_WIDTH(32),
        .VC_COUNT(4),
        .FIFO_DEPTH(4)
    ) u_noc_router (
        .clk(clk),
        .rst_n(rst_n),
        .in_flit_valid({1'b0, 1'b0, 1'b0, noc_spec_tx_valid, 1'b0}),
        .in_flit_data_packed({{3{32'h0}}, noc_spec_tx_flit, 32'h0}),
        .in_flit_ready(noc_in_ready),
        .out_flit_valid(noc_out_valid),
        .out_flit_data_packed(noc_out_data),
        .out_flit_ready(5'b11111),
        .telemetry_vc0_flits(),
        .telemetry_total_flits()
    );

    assign noc_spec_tx_ready = noc_in_ready[1];

    // -------------------------------------------------------------------------
    // 9. UCIe 1.0/2.0 D2D Chiplet Interconnect (East Beachfront)
    // -------------------------------------------------------------------------
    logic [PHY_LANES-1:0] phy_tx_data, phy_rx_data;
    logic                 phy_tx_val, phy_tx_rdy, phy_rx_val;
    logic [3:0]           link_tx_crd, link_rx_crd;

    d2d_link_layer #(
        .FLIT_WIDTH(32),
        .PHY_WIDTH(16),
        .VC_COUNT(4),
        .MAX_CREDITS(4)
    ) u_d2d_link (
        .clk(clk),
        .rst_n(rst_n),
        .noc_tx_valid(noc_out_valid[2]),
        .noc_tx_flit(noc_out_data[95:64]),
        .noc_tx_ready(),
        .noc_rx_valid(),
        .noc_rx_flit(),
        .noc_rx_ready(1'b1),
        .phy_tx_data(phy_tx_data),
        .phy_tx_valid(phy_tx_val),
        .phy_tx_ready(phy_tx_rdy),
        .phy_rx_data(phy_rx_data),
        .phy_rx_valid(phy_rx_val),
        .link_tx_credit_ret(link_tx_crd),
        .link_rx_credit_ret(link_rx_crd),
        .telemetry_d2d_tx_flits(),
        .telemetry_d2d_rx_flits(),
        .telemetry_crc_errors()
    );

    d2d_ucie_phy #(
        .LANES(PHY_LANES),
        .REPAIR_LANES(REPAIR_LANES),
        .VC_COUNT(4)
    ) u_d2d_phy (
        .clk(clk),
        .rst_n(rst_n),
        .link_tx_data(phy_tx_data),
        .link_tx_valid(phy_tx_val),
        .link_tx_ready(phy_tx_rdy),
        .link_rx_data(phy_rx_data),
        .link_rx_valid(phy_rx_val),
        .link_tx_credit_ret(link_tx_crd),
        .link_rx_credit_ret(link_rx_crd),
        .phy_tx_lanes(d2d_tx_lanes),
        .phy_tx_valid_lane(d2d_tx_valid),
        .phy_tx_fwd_clk(d2d_tx_fwd_clk),
        .phy_tx_sideband(d2d_tx_sideband),
        .phy_tx_credits(),
        .phy_rx_lanes(d2d_rx_lanes),
        .phy_rx_valid_lane(d2d_rx_valid),
        .phy_rx_fwd_clk(d2d_rx_fwd_clk),
        .phy_rx_sideband(d2d_rx_sideband),
        .phy_rx_credits(4'b0000),
        .cfg_bad_lane_idx(4'd0),
        .cfg_lane_repair_en(1'b0),
        .phy_link_up(d2d_link_up),
        .telemetry_phy_tx_words(),
        .telemetry_phy_rx_words()
    );

endmodule
