// ==============================================================================
// Module: dataflow_controller
// Description: Intelligent Top-Level Controller for Adaptive AI Accelerator.
//              - Supports runtime switching between Weight-Stationary (WS) and
//                Output-Stationary (OS) dataflows.
//              - Autonomous Dataflow Decision:
//                  * If K > M: Selects OS (eliminates deep-reduction psum traffic).
//                  * If M >= K: Selects WS (maximizes weight reuse across batches).
//                  * Can also be manually forced via dataflow_mode input.
//              - Drives unified systolic_array_adaptive mesh.
//              - Integrated hardware performance profiler (cycles, utilization, traffic).
// ==============================================================================

`timescale 1ns / 1ps

module dataflow_controller #(
    parameter int DATA_WIDTH    = 16,
    parameter int ACCUM_WIDTH   = 32,
    parameter int ROWS          = 4,
    parameter int COLS          = 4,
    parameter int BUFFER_VECS   = 64,
    parameter int OUT_BUF_DEPTH = 256
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Execution Command & Workload Descriptors
    input  logic                               start,
    input  logic [1:0]                         dataflow_mode, // 00: Auto-Adaptive, 01: Force WS, 10: Force OS
    input  logic [15:0]                        cfg_M,         // # of activation vectors
    input  logic [15:0]                        cfg_K,         // # of reduction steps
    input  logic [15:0]                        cfg_N,         // # of output features
    output logic                               busy,
    output logic                               done,
    output logic                               active_dataflow, // 0: WS active, 1: OS active

    // External DRAM Streaming Interface
    output logic                               dram_rd_req,
    output logic [15:0]                        dram_rd_addr,
    input  logic                               dram_rd_valid,
    input  logic signed [DATA_WIDTH-1:0]       dram_rd_data,

    output logic                               dram_wr_req,
    output logic [15:0]                        dram_wr_addr,
    output logic signed [ACCUM_WIDTH-1:0]      dram_wr_data,
    input  logic                               dram_wr_ack,

    // Performance Profiling Telemetry
    output logic [31:0]                        perf_total_cycles,
    output logic [31:0]                        perf_compute_cycles,
    output logic [31:0]                        perf_active_mac_cycles,
    output logic [31:0]                        perf_stall_cycles,
    output logic [31:0]                        perf_dram_reads,
    output logic [31:0]                        perf_dram_writes,
    output logic [15:0]                        perf_mac_util_permille
);

    // Dynamic Decision Logic
    logic auto_mode_os;
    assign auto_mode_os = (cfg_K > cfg_M); // If reduction K > batch M, choose OS

    logic selected_mode_os;
    always_comb begin
        case (dataflow_mode)
            2'b01:   selected_mode_os = 1'b0; // Force WS
            2'b10:   selected_mode_os = 1'b1; // Force OS
            default: selected_mode_os = auto_mode_os; // Adaptive Auto
        endcase
    end

    assign active_dataflow = selected_mode_os;

    // FSM State Definition
    typedef enum logic [3:0] {
        IDLE               = 4'd0,
        WS_PRELOAD_WEIGHTS = 4'd1,
        WS_PRELOAD_ACTS    = 4'd2,
        WS_COMPUTE         = 4'd3,
        OS_PRELOAD_TILES   = 4'd4,
        OS_COMPUTE         = 4'd5,
        OS_DRAIN           = 4'd6,
        DRAIN_OUTPUT_DRAM  = 4'd7,
        COMPLETE           = 4'd8
    } state_t;

    state_t current_state, next_state;

    // Local Buffers
    logic signed [DATA_WIDTH-1:0]  act_buf [0:BUFFER_VECS-1][0:ROWS-1];
    logic signed [DATA_WIDTH-1:0]  weight_buf [0:BUFFER_VECS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] out_buf [0:OUT_BUF_DEPTH-1];

    // Array Interconnect
    logic                                     sa_enable;
    logic                                     sa_weight_load;
    logic                                     sa_accum_clear;
    logic                                     sa_drain_en;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in;
    logic signed [(COLS*DATA_WIDTH)-1:0]      sa_weight_in_col;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] sa_weight_in_tile;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_drain_out;

    systolic_array_adaptive #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_systolic_core (
        .clk(clk),
        .rst_n(rst_n),
        .mode_os(selected_mode_os),
        .enable(sa_enable),
        .weight_load(sa_weight_load),
        .accum_clear(sa_accum_clear),
        .drain_en(sa_drain_en),
        .act_in_flat(sa_act_in),
        .weight_in_col_flat(sa_weight_in_col),
        .weight_in_tile_flat(sa_weight_in_tile),
        .psum_out_deskewed_flat(sa_psum_out_deskewed),
        .drain_out_flat(sa_drain_out)
    );

    // Pack weight tile for WS mode
    generate
        genvar wr, wc;
        for (wr = 0; wr < ROWS; wr++) begin : gen_w_tile_r
            for (wc = 0; wc < COLS; wc++) begin : gen_w_tile_c
                assign sa_weight_in_tile[(wr*COLS + wc)*DATA_WIDTH +: DATA_WIDTH] = weight_buf[wr][wc];
            end
        end
    endgenerate

    // Counters & Pipeline Control
    logic [15:0] word_counter;
    logic [15:0] stream_counter;
    logic [15:0] drain_counter;
    logic [15:0] total_drain_words;
    logic [15:0] out_base;

    assign busy = (current_state != IDLE) && (current_state != COMPLETE);
    assign done = (current_state == COMPLETE);
    assign dram_wr_data = out_buf[drain_counter];

    assign dram_rd_addr = 16'h1000 + perf_dram_reads[15:0];
    assign dram_wr_addr = 16'h3000 + perf_dram_writes[15:0];

    // FSM Combinational Logic
    always_comb begin
        next_state        = current_state;
        dram_rd_req       = 1'b0;
        dram_wr_req       = 1'b0;
        sa_enable         = 1'b0;
        sa_weight_load    = 1'b0;
        sa_accum_clear    = 1'b0;
        sa_drain_en       = 1'b0;

        sa_act_in         = '0;
        sa_weight_in_col  = '0;

        case (current_state)
            IDLE: begin
                if (start) begin
                    if (selected_mode_os) next_state = OS_PRELOAD_TILES;
                    else                  next_state = WS_PRELOAD_WEIGHTS;
                end
            end

            // -------------------------------------------------------------
            // Weight-Stationary (WS) Pipeline
            // -------------------------------------------------------------
            WS_PRELOAD_WEIGHTS: begin
                dram_rd_req = !(word_counter == 15 && dram_rd_valid);
                if (dram_rd_valid && word_counter == 15) begin
                    next_state = WS_PRELOAD_ACTS;
                end
            end

            WS_PRELOAD_ACTS: begin
                dram_rd_req = !(word_counter == (cfg_M * ROWS - 1) && dram_rd_valid);
                if (dram_rd_valid && word_counter == (cfg_M * ROWS - 1)) begin
                    next_state = WS_COMPUTE;
                end
            end

            WS_COMPUTE: begin
                sa_enable = 1'b1;
                if (stream_counter == 0) begin
                    sa_weight_load = 1'b1;
                end

                if (stream_counter >= 1 && stream_counter <= cfg_M) begin
                    for (int r = 0; r < ROWS; r++) begin
                        sa_act_in[r*DATA_WIDTH +: DATA_WIDTH] = act_buf[stream_counter - 1][r];
                    end
                end

                // In WS: outputs emerge between cycle 8 and (cfg_M + 8)
                if (stream_counter == (cfg_M + 8)) begin
                    next_state = DRAIN_OUTPUT_DRAM;
                end
            end

            // -------------------------------------------------------------
            // Output-Stationary (OS) Pipeline
            // -------------------------------------------------------------
            OS_PRELOAD_TILES: begin
                // In OS, preload K activation vectors and K weight vectors
                dram_rd_req = !(word_counter == (2 * cfg_K * ROWS - 1) && dram_rd_valid);
                if (dram_rd_valid && word_counter == (2 * cfg_K * ROWS - 1)) begin
                    next_state = OS_COMPUTE;
                end
            end

            OS_COMPUTE: begin
                sa_enable = 1'b1;
                if (stream_counter == 0) begin
                    sa_accum_clear = 1'b1; // Clear local accumulators
                end

                if (stream_counter >= 1 && stream_counter <= cfg_K) begin
                    for (int r = 0; r < ROWS; r++) begin
                        sa_act_in[r*DATA_WIDTH +: DATA_WIDTH]        = act_buf[stream_counter - 1][r];
                        sa_weight_in_col[r*DATA_WIDTH +: DATA_WIDTH] = weight_buf[stream_counter - 1][r];
                    end
                end

                // In OS: all K reduction steps complete by cycle (cfg_K + 6)
                if (stream_counter == (cfg_K + 6)) begin
                    next_state = OS_DRAIN;
                end
            end

            OS_DRAIN: begin
                sa_enable   = 1'b1;
                sa_drain_en = 1'b1; // Shift accumulators down vertically
                if (stream_counter == 3) begin
                    next_state = DRAIN_OUTPUT_DRAM;
                end
            end

            // -------------------------------------------------------------
            // DRAM Output Drain
            // -------------------------------------------------------------
            DRAIN_OUTPUT_DRAM: begin
                dram_wr_req = 1'b1;
                if (dram_wr_ack && (drain_counter + 1 == total_drain_words)) begin
                    next_state = COMPLETE;
                end
            end

            COMPLETE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Sequential Datapath
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_state     <= IDLE;
            word_counter      <= '0;
            stream_counter    <= '0;
            drain_counter     <= '0;
            total_drain_words <= '0;

            for (int i = 0; i < OUT_BUF_DEPTH; i++) out_buf[i] <= '0;
        end else begin
            current_state <= next_state;

            case (current_state)
                IDLE: begin
                    word_counter      <= '0;
                    stream_counter    <= '0;
                    drain_counter     <= '0;
                    total_drain_words <= '0;
                end

                WS_PRELOAD_WEIGHTS: begin
                    if (dram_rd_valid) begin
                        weight_buf[word_counter / COLS][word_counter % COLS] <= dram_rd_data;
                        if (word_counter == 15) word_counter <= '0;
                        else                    word_counter <= word_counter + 1;
                    end
                end

                WS_PRELOAD_ACTS: begin
                    if (dram_rd_valid) begin
                        act_buf[word_counter / ROWS][word_counter % ROWS] <= dram_rd_data;
                        if (word_counter == (cfg_M * ROWS - 1)) word_counter <= '0;
                        else                                    word_counter <= word_counter + 1;
                    end
                end

                WS_COMPUTE: begin
                    stream_counter <= stream_counter + 1;

                    // Latch deskewed output row
                    if (stream_counter >= 8 && stream_counter < (cfg_M + 8)) begin
                        out_base = (stream_counter - 8) * COLS;
                        out_buf[out_base + 0] <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 1] <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 2] <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 3] <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                        total_drain_words     <= total_drain_words + COLS;
                    end
                end

                OS_PRELOAD_TILES: begin
                    if (dram_rd_valid) begin
                        // First cfg_K * ROWS words: Activations
                        // Second cfg_K * ROWS words: Weights
                        if (word_counter < (cfg_K * ROWS)) begin
                            act_buf[word_counter / ROWS][word_counter % ROWS] <= dram_rd_data;
                        end else begin
                            int w_idx;
                            w_idx = word_counter - (cfg_K * ROWS);
                            weight_buf[w_idx / ROWS][w_idx % ROWS] <= dram_rd_data;
                        end

                        if (word_counter == (2 * cfg_K * ROWS - 1)) word_counter <= '0;
                        else                                        word_counter <= word_counter + 1;
                    end
                end

                OS_COMPUTE: begin
                    stream_counter <= stream_counter + 1;
                    if (stream_counter == (cfg_K + 6)) begin
                        stream_counter <= '0; // Reset counter for drain
                    end
                end

                OS_DRAIN: begin
                    stream_counter <= stream_counter + 1;
                    // Latch drained row emerging from bottom of mesh
                    if (stream_counter <= 3) begin
                        // Drain order: row 3, row 2, row 1, row 0
                        int row_idx;
                        row_idx = 3 - stream_counter;
                        out_buf[row_idx*COLS + 0] <= sa_drain_out[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[row_idx*COLS + 1] <= sa_drain_out[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[row_idx*COLS + 2] <= sa_drain_out[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[row_idx*COLS + 3] <= sa_drain_out[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                        total_drain_words         <= total_drain_words + COLS;
                    end
                end

                DRAIN_OUTPUT_DRAM: begin
                    if (dram_wr_ack) begin
                        drain_counter <= drain_counter + 1;
                    end
                end

                COMPLETE: begin
                    // Done
                end
            endcase
        end
    end

    // Performance Telemetry Profiler
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            perf_total_cycles      <= '0;
            perf_compute_cycles    <= '0;
            perf_active_mac_cycles <= '0;
            perf_stall_cycles      <= '0;
            perf_dram_reads        <= '0;
            perf_dram_writes       <= '0;
        end else if (start) begin
            perf_total_cycles      <= '0;
            perf_compute_cycles    <= '0;
            perf_active_mac_cycles <= '0;
            perf_stall_cycles      <= '0;
            perf_dram_reads        <= '0;
            perf_dram_writes       <= '0;
        end else if (busy) begin
            perf_total_cycles <= perf_total_cycles + 1;

            if (current_state == WS_COMPUTE || current_state == OS_COMPUTE) begin
                perf_compute_cycles <= perf_compute_cycles + 1;
                perf_active_mac_cycles <= perf_active_mac_cycles + (ROWS * COLS);
            end else begin
                perf_stall_cycles <= perf_stall_cycles + 1;
            end

            if (dram_rd_req && dram_rd_valid) perf_dram_reads <= perf_dram_reads + 1;
            if (dram_wr_req && dram_wr_ack)   perf_dram_writes <= perf_dram_writes + 1;
        end
    end

    always_comb begin
        if (perf_total_cycles > 0) begin
            perf_mac_util_permille = (perf_active_mac_cycles * 1000) / (perf_total_cycles * (ROWS * COLS));
        end else begin
            perf_mac_util_permille = '0;
        end
    end

endmodule
