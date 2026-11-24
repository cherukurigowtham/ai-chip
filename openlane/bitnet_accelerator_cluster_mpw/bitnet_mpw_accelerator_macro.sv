// ==============================================================================
// Module: bitnet_mpw_accelerator_macro.sv
// Description: SkyWater Sky130 MPW Flagship Accelerator Macro (Gen-3 Silicon).
//              Integrates:
//                1. 64-PE Multi-Precision Systolic Matrix Array (8x8)
//                2. 1-Cycle 2:4 Semi-Structured Sparse Ternary Decompression Engine
//                3. Autonomous On-Chip Speculative Decoding Co-Processor (Medusa K=4)
//                4. 500 MHz 2D Mesh NoC Router with 4 Virtual Channels (VC0..VC3)
//                5. D2D UCIe 1.0/2.0 PHY & Credit-Based Link Layer (Beachfront Pins)
//                6. Autonomous On-Chip Key-Value (KV) Cache Ring Buffer
//                7. Glitch-Free Integrated Clock Gating (ICG) & DVFS Power Controller
//              Designed for Efabless Caravel / ChipIgnite User Project Area.
// ==============================================================================

`timescale 1ns / 1ps

module bitnet_mpw_accelerator_macro (
    input  wire        wb_clk_i,
    input  wire        wb_rst_i,
    input  wire        wbs_stb_i,
    input  wire        wbs_cyc_i,
    input  wire        wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_dat_i,
    input  wire [31:0] wbs_adr_i,
    output reg         wbs_ack_o,
    output reg  [31:0] wbs_dat_o,

    // Logic Analyzer & Dedicated Off-Chip Pins
    input  wire [127:0] la_data_in,
    output wire [127:0] la_data_out,
    input  wire [127:0] la_oenb,

    // External DMA Streaming Bus
    input  wire [15:0] dma_word_in,
    input  wire        dma_valid_in,
    output wire        dma_ready_out,

    // UCIe 1.0/2.0 D2D Beachfront Microbump Pins (To Partner Chiplet)
    output wire [16:0] d2d_tx_lanes,       // 16 Mainband + 1 Spare
    output wire        d2d_tx_valid,
    output wire        d2d_tx_fwd_clk,
    output wire        d2d_tx_sideband,
    input  wire [16:0] d2d_rx_lanes,
    input  wire        d2d_rx_valid,
    input  wire        d2d_rx_fwd_clk,
    input  wire        d2d_rx_sideband,

    // Status & Power Telemetry Pins
    output wire [7:0]  status_telemetry
);

    wire clk   = wb_clk_i;
    wire rst_n = ~wb_rst_i;

    // -------------------------------------------------------------------------
    // Subsystem 1: Multi-Precision Systolic Array (64 PEs, 8x8)
    // -------------------------------------------------------------------------
    reg [1:0]           precision_mode;
    reg                 array_enable;
    reg                 mode_os;
    reg                 weight_load;
    reg                 weight_bank_sel;
    reg                 accum_clear;
    reg signed [127:0]  act_in;
    reg [15:0]          weight_in;
    wire signed [255:0] accum_out;
    wire [63:0]         zero_skips;

    systolic_array_multiprecision #(
        .DATA_WIDTH(16),
        .ACCUM_WIDTH(32),
        .WEIGHT_WIDTH(2),
        .ROWS(8),
        .COLS(8)
    ) u_systolic (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .enable(array_enable),
        .mode_os(mode_os),
        .weight_load(weight_load),
        .weight_bank_sel(weight_bank_sel),
        .double_buf_en(1'b1),
        .accum_clear(accum_clear),
        .act_in(act_in),
        .weight_in(weight_in),
        .accum_out(accum_out),
        .zero_skips_vector(zero_skips)
    );

    // -------------------------------------------------------------------------
    // Subsystem 2: 2:4 Semi-Structured Sparse Ternary Decompressor & Accelerator
    // -------------------------------------------------------------------------
    reg  [1:0]  sparse_w0, sparse_w1;
    reg  [2:0]  sparse_pattern;
    wire [7:0]  sparse_decomp_w;
    wire signed [31:0] sparse_dot_result;

    sparse_2_4_ternary_decompressor #(
        .DATA_WIDTH(16),
        .ACC_WIDTH(32)
    ) u_sparse_2_4 (
        .clk(clk),
        .rst_n(rst_n),
        .w_val0(sparse_w0),
        .w_val1(sparse_w1),
        .w_pattern(sparse_pattern),
        .act_vec_4_in(act_in[63:0]),
        .decomp_weights_out(sparse_decomp_w),
        .sparse_dot_out(sparse_dot_result)
    );

    // -------------------------------------------------------------------------
    // Subsystem 3: Autonomous Speculative Decoding Co-Processor (K=4)
    // -------------------------------------------------------------------------
    reg         coproc_trigger;
    wire        coproc_busy;
    wire        coproc_done;
    wire [2:0]  committed_count;
    wire [79:0] committed_tokens;
    wire        kv_rollback_valid;
    wire [7:0]  kv_rollback_seq_len;
    wire [15:0] telemetry_speedup_q8;
    wire        noc_spec_tx_valid;
    wire [31:0] noc_spec_tx_flit;
    wire        noc_spec_tx_ready;

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
        .coproc_start(coproc_trigger),
        .hidden_state_in(act_in),
        .seq_base_in(8'd16),
        .coproc_busy(coproc_busy),
        .coproc_done(coproc_done),
        .target_verify_req(),
        .target_verify_drafts_packed(),
        .target_verify_valid(coproc_busy),
        .target_verify_tokens_packed(la_data_in[63:0]),
        .kv_rollback_valid(kv_rollback_valid),
        .kv_rollback_seq_len(kv_rollback_seq_len),
        .noc_tx_valid(noc_spec_tx_valid),
        .noc_tx_flit(noc_spec_tx_flit),
        .noc_tx_ready(noc_spec_tx_ready),
        .noc_rx_valid(1'b0),
        .noc_rx_flit(32'h0),
        .noc_rx_ready(),
        .committed_count(committed_count),
        .committed_tokens_packed(committed_tokens),
        .telemetry_total_bursts(),
        .telemetry_draft_tokens(),
        .telemetry_accepted_tokens(),
        .telemetry_emitted_tokens(),
        .telemetry_speedup_q8(telemetry_speedup_q8)
    );

    // -------------------------------------------------------------------------
    // Subsystem 4: On-Chip Autonomous KV Cache Ring Buffer
    // -------------------------------------------------------------------------
    reg         kv_append;
    wire [7:0]  kv_curr_len;
    wire        kv_full;

    kv_cache_ring_buffer #(
        .DATA_WIDTH(16),
        .VEC_SIZE(8),
        .MAX_SEQ_LEN(128)
    ) u_kv_cache (
        .clk(clk),
        .rst_n(rst_n),
        .append_valid(kv_append),
        .k_token_in(act_in),
        .v_token_in(act_in),
        .rollback_valid(kv_rollback_valid),
        .rollback_seq_len(kv_rollback_seq_len),
        .stream_start(1'b0),
        .stream_read_v(1'b0),
        .stream_valid(),
        .stream_vec_out(),
        .stream_token_idx(),
        .stream_done(),
        .current_seq_len(kv_curr_len),
        .cache_full(kv_full)
    );

    // -------------------------------------------------------------------------
    // Subsystem 5: 500 MHz 2D Mesh NoC Router with 4 Virtual Channels
    // -------------------------------------------------------------------------
    wire [4:0]   noc_in_ready;
    wire [4:0]   noc_out_valid;
    wire [159:0] noc_out_data;
    wire [31:0]  telemetry_vc0_flits;

    noc_router_2d_vc4 #(
        .NODE_X(0),
        .NODE_Y(0),
        .FLIT_WIDTH(32),
        .VC_COUNT(4),
        .FIFO_DEPTH(4)
    ) u_noc_router_vc4 (
        .clk(clk),
        .rst_n(rst_n),
        .in_flit_valid({1'b0, 1'b0, 1'b0, noc_spec_tx_valid, wbs_stb_i && (wbs_adr_i[7:0] == 8'h30)}),
        .in_flit_data_packed({{3{32'h0}}, noc_spec_tx_flit, wbs_dat_i}),
        .in_flit_ready(noc_in_ready),
        .out_flit_valid(noc_out_valid),
        .out_flit_data_packed(noc_out_data),
        .out_flit_ready(5'b11111),
        .telemetry_vc0_flits(telemetry_vc0_flits),
        .telemetry_total_flits()
    );

    assign noc_spec_tx_ready = noc_in_ready[1];

    // -------------------------------------------------------------------------
    // Subsystem 6: UCIe 1.0/2.0 D2D Link Layer & PHY (East Beachfront)
    // -------------------------------------------------------------------------
    wire [15:0] phy_tx_data, phy_rx_data;
    wire        phy_tx_val, phy_tx_rdy, phy_rx_val;
    wire [3:0]  link_tx_crd, link_rx_crd;
    wire        d2d_link_up;

    d2d_link_layer #(
        .FLIT_WIDTH(32),
        .PHY_WIDTH(16),
        .VC_COUNT(4),
        .MAX_CREDITS(4)
    ) u_d2d_link (
        .clk(clk),
        .rst_n(rst_n),
        .noc_tx_valid(noc_out_valid[2]), // East port output
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
        .LANES(16),
        .REPAIR_LANES(1),
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

    // -------------------------------------------------------------------------
    // Subsystem 7: Autonomous DVFS & Power Management Controller
    // -------------------------------------------------------------------------
    wire [1:0] pwr_state;
    wire       core_sleep_gate;

    power_management_dvfs_controller #(
        .IDLE_TIMEOUT_CYCLES(64)
    ) u_pwr_ctrl (
        .clk_ref(clk),
        .rst_n(rst_n),
        .test_mode(1'b0),
        .workload_busy(array_enable || coproc_busy),
        .dma_transferring(dma_valid_in),
        .token_wake_event(wbs_stb_i),
        .clk_compute(),
        .clk_attention(),
        .clk_dma(),
        .clk_noc(),
        .power_state_out(pwr_state),
        .sram_retention_en(),
        .core_power_gate_en(core_sleep_gate),
        .telemetry_active_cycles(),
        .telemetry_eco_cycles(),
        .telemetry_retention_cycles(),
        .telemetry_gated_cycles()
    );

    // Sticky done latch for Wishbone polling
    reg coproc_done_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coproc_done_latched <= 1'b0;
        end else if (coproc_trigger) begin
            coproc_done_latched <= 1'b0;
        end else if (coproc_done) begin
            coproc_done_latched <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Wishbone Bus Read / Write Memory Map
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wbs_ack_o       <= 1'b0;
            wbs_dat_o       <= 32'h0;
            precision_mode  <= 2'b00;
            array_enable    <= 1'b0;
            mode_os         <= 1'b1;
            weight_load     <= 1'b0;
            weight_bank_sel <= 1'b0;
            accum_clear     <= 1'b0;
            coproc_trigger  <= 1'b0;
            kv_append       <= 1'b0;
            sparse_w0       <= 2'b01;
            sparse_w1       <= 2'b10;
            sparse_pattern  <= 3'b000;
            act_in          <= '0;
            weight_in       <= '0;
        end else begin
            wbs_ack_o      <= 1'b0;
            coproc_trigger <= 1'b0;
            kv_append      <= 1'b0;

            if (wbs_stb_i && wbs_cyc_i && !wbs_ack_o) begin
                wbs_ack_o <= 1'b1;
                if (wbs_we_i) begin
                    case (wbs_adr_i[7:0])
                        8'h00: begin // Array Control
                            array_enable    <= wbs_dat_i[0];
                            mode_os         <= wbs_dat_i[1];
                            precision_mode  <= wbs_dat_i[3:2];
                            weight_bank_sel <= wbs_dat_i[4];
                            accum_clear     <= wbs_dat_i[5];
                            weight_load     <= wbs_dat_i[6];
                        end
                        8'h04: begin // Speculative Trigger
                            coproc_trigger  <= wbs_dat_i[0];
                        end
                        8'h08: begin // Weight vector
                            weight_in       <= wbs_dat_i[15:0];
                        end
                        8'h0C: begin // Low 32-bit activation
                            act_in[31:0]    <= wbs_dat_i;
                        end
                        8'h10: begin // High 32-bit activation
                            act_in[63:32]   <= wbs_dat_i;
                        end
                        8'h14: begin // 2:4 Structured Sparsity Configuration
                            sparse_w0       <= wbs_dat_i[1:0];
                            sparse_w1       <= wbs_dat_i[3:2];
                            sparse_pattern  <= wbs_dat_i[6:4];
                        end
                        8'h18: begin // KV Append
                            kv_append       <= wbs_dat_i[0];
                        end
                    endcase
                end else begin
                    case (wbs_adr_i[7:0])
                        8'h00: wbs_dat_o <= {26'h0, accum_clear, weight_bank_sel, precision_mode, mode_os, array_enable};
                        8'h04: wbs_dat_o <= {15'h0, kv_rollback_valid, 1'b0, committed_count, (coproc_done || coproc_done_latched), coproc_busy};
                        8'h08: wbs_dat_o <= {16'h0, telemetry_speedup_q8};
                        8'h0C: wbs_dat_o <= sparse_dot_result;
                        8'h10: wbs_dat_o <= accum_out[31:0];   // PE(0,0) accumulator
                        8'h14: wbs_dat_o <= accum_out[63:32];  // PE(0,1) accumulator
                        8'h18: wbs_dat_o <= {25'h0, kv_curr_len};
                        8'h20: wbs_dat_o <= zero_skips[31:0];
                        8'h24: wbs_dat_o <= {22'h0, d2d_link_up, core_sleep_gate, pwr_state, 6'h0};
                        default: wbs_dat_o <= 32'hDEADBEEF;
                    endcase
                end
            end
        end
    end

    // Status and Telemetry Pins
    assign status_telemetry = {d2d_link_up, core_sleep_gate, pwr_state, committed_count, coproc_busy};
    assign dma_ready_out    = 1'b1;
    assign la_data_out      = {accum_out[63:0], zero_skips};

endmodule
