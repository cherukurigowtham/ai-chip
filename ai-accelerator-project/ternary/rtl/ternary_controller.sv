// ==============================================================================
// Module: ternary_controller
// Description: Intelligent Dataflow Controller for Hybrid Binary-Ternary AI Accelerator.
//              - Supports runtime adaptive switching between Weight-Stationary (WS)
//                and Output-Stationary (OS) modes.
//              - Autonomous Dataflow Decision:
//                  * If K > M: Selects OS (minimizes psum traffic).
//                  * If M >= K: Selects WS (maximizes ternary weight reuse).
//              - Controls ternary_weight_unpacker, ternary_weight_buffer, and
//                systolic_array_ternary.
//              - Integrates hardware performance and zero-skip energy profilers.
// ==============================================================================

`timescale 1ns / 1ps

module ternary_controller #(
    parameter int DATA_WIDTH    = 16,
    parameter int ACCUM_WIDTH   = 32,
    parameter int WEIGHT_WIDTH  = 2,
    parameter int ROWS          = 4,
    parameter int COLS          = 4,
    parameter int BUFFER_VECS   = 64,
    parameter int OUT_BUF_DEPTH = 256
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Execution Command & Workload Descriptors
    input  logic                               start,
    input  logic [1:0]                         dataflow_mode, // 00: Auto, 01: Force WS, 10: Force OS
    input  logic [15:0]                        cfg_M,         // # of activation vectors
    input  logic [15:0]                        cfg_K,         // # of reduction steps
    input  logic [15:0]                        cfg_N,         // # of output features
    output logic                               busy,
    output logic                               done,
    output logic                               active_dataflow, // 0: WS, 1: OS

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
    output logic [31:0]                        perf_zero_skips,
    output logic [15:0]                        perf_mac_util_permille
);

    // Dynamic Decision Logic
    logic auto_mode_os;
    assign auto_mode_os = (cfg_K > cfg_M);

    logic mode_os_comb;
    always_comb begin
        case (dataflow_mode)
            2'b01:   mode_os_comb = 1'b0; // Force WS
            2'b10:   mode_os_comb = 1'b1; // Force OS
            default: mode_os_comb = auto_mode_os; // Auto
        endcase
    end

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

    logic selected_mode_os;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selected_mode_os <= 1'b0;
        end else if (current_state == IDLE && start) begin
            selected_mode_os <= mode_os_comb;
        end
    end

    assign active_dataflow = selected_mode_os;

    // Local Buffers
    logic signed [DATA_WIDTH-1:0]  act_buf [0:BUFFER_VECS-1][0:ROWS-1];
    logic signed [ACCUM_WIDTH-1:0] out_buf [0:OUT_BUF_DEPTH-1];

    // Ternary Weight Unpacker
    logic [(ROWS*COLS*WEIGHT_WIDTH)-1:0] unpacker_tile_flat;
    logic [(COLS*WEIGHT_WIDTH)-1:0]      unpacker_col_flat;
    logic                                unpacker_word_valid;
    logic                                unpacker_is_tile;
    logic                                unpacker_tile_half;

    ternary_weight_unpacker #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_unpacker (
        .clk(clk),
        .rst_n(rst_n),
        .word_valid(unpacker_word_valid),
        .dram_word(dram_rd_data),
        .is_tile_load(unpacker_is_tile),
        .tile_half(unpacker_tile_half),
        .weight_tile_flat(unpacker_tile_flat),
        .weight_col_flat(unpacker_col_flat),
        .unpack_ready()
    );

    // Ternary Weight Buffer (for OS streaming columns)
    logic                                 wbuf_wr_en;
    logic [$clog2(BUFFER_VECS)-1:0]       wbuf_wr_addr;
    logic [(COLS*WEIGHT_WIDTH)-1:0]       wbuf_wr_data;
    logic                                 wbuf_rd_en;
    logic [$clog2(BUFFER_VECS)-1:0]       wbuf_rd_addr;
    logic [(COLS*WEIGHT_WIDTH)-1:0]       wbuf_rd_data_pipe;

    ternary_weight_buffer #(
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS)
    ) u_wbuf (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wbuf_wr_en),
        .wr_addr(wbuf_wr_addr),
        .wr_data(wbuf_wr_data),
        .rd_en(wbuf_rd_en),
        .rd_addr(wbuf_rd_addr),
        .rd_data_pipe(wbuf_rd_data_pipe)
    );

    // Array Interconnect
    logic                                     sa_enable;
    logic                                     sa_weight_load;
    logic                                     sa_accum_clear;
    logic                                     sa_drain_en;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in_pipe;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_drain_out;
    logic [ROWS*COLS-1:0]                     sa_zero_skipped;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sa_act_in_pipe <= '0;
        end else begin
            sa_act_in_pipe <= sa_act_in;
        end
    end

    systolic_array_ternary #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_systolic_array (
        .clk(clk),
        .rst_n(rst_n),
        .mode_os(selected_mode_os),
        .enable(sa_enable),
        .weight_load(sa_weight_load),
        .accum_clear(sa_accum_clear),
        .drain_en(sa_drain_en),
        .act_in_flat(sa_act_in_pipe),
        .weight_in_col_flat(wbuf_rd_data_pipe),
        .weight_in_tile_flat(unpacker_tile_flat),
        .psum_out_deskewed_flat(sa_psum_out_deskewed),
        .drain_out_flat(sa_drain_out),
        .zero_skipped_flat(sa_zero_skipped)
    );

    logic [15:0] word_counter;
    logic [15:0] stream_counter;
    logic [15:0] drain_counter;
    logic [15:0] total_drain_words;
    int          out_base;

    logic [7:0]  dram_rd_lo_byte;
    assign dram_rd_lo_byte = dram_rd_data[7:0];
    assign unpacker_tile_half = word_counter[0];

    // Pipelined Zero-Skip Tracker (Zero timing impact on critical path)
    logic [4:0] skips_this_cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skips_this_cycle <= 5'd0;
        end else begin
            skips_this_cycle <= (sa_zero_skipped[0]  + sa_zero_skipped[1]  + sa_zero_skipped[2]  + sa_zero_skipped[3]) +
                                (sa_zero_skipped[4]  + sa_zero_skipped[5]  + sa_zero_skipped[6]  + sa_zero_skipped[7]) +
                                (sa_zero_skipped[8]  + sa_zero_skipped[9]  + sa_zero_skipped[10] + sa_zero_skipped[11]) +
                                (sa_zero_skipped[12] + sa_zero_skipped[13] + sa_zero_skipped[14] + sa_zero_skipped[15]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_total_cycles   <= '0;
            perf_compute_cycles <= '0;
            perf_dram_reads     <= '0;
            perf_dram_writes    <= '0;
            perf_zero_skips     <= '0;
        end else begin
            if (current_state != IDLE && current_state != COMPLETE) begin
                perf_total_cycles <= perf_total_cycles + 1;
            end
            if (current_state == WS_COMPUTE || current_state == OS_COMPUTE) begin
                perf_compute_cycles <= perf_compute_cycles + 1;
                perf_zero_skips     <= perf_zero_skips + skips_this_cycle;
            end
            if (dram_rd_req && dram_rd_valid) begin
                perf_dram_reads <= perf_dram_reads + 1;
            end
            if (dram_wr_req && dram_wr_ack) begin
                perf_dram_writes <= perf_dram_writes + 1;
            end
        end
    end

    assign dram_wr_data = out_buf[drain_counter];

    // FSM Combinational Logic
    always_comb begin
        next_state          = current_state;
        busy                = 1'b1;
        done                = 1'b0;
        dram_rd_req         = 1'b0;
        dram_rd_addr        = word_counter;
        dram_wr_req         = 1'b0;
        dram_wr_addr        = drain_counter;
        sa_enable           = 1'b0;
        sa_weight_load      = 1'b0;
        sa_accum_clear      = 1'b0;
        sa_drain_en         = 1'b0;
        unpacker_word_valid = 1'b0;
        unpacker_is_tile    = 1'b0;
        wbuf_wr_en          = 1'b0;
        wbuf_wr_addr        = '0;
        wbuf_wr_data        = '0;
        wbuf_rd_en          = 1'b0;
        wbuf_rd_addr        = '0;
        sa_act_in           = '0;

        case (current_state)
            IDLE: begin
                busy = 1'b0;
                if (start) begin
                    if (!mode_os_comb) next_state = WS_PRELOAD_WEIGHTS;
                    else               next_state = OS_PRELOAD_TILES;
                end
            end

            // -------------------------------------------------------------
            // Weight-Stationary (WS): 2 DRAM words = 16 weights (32 bits)!
            // -------------------------------------------------------------
            WS_PRELOAD_WEIGHTS: begin
                dram_rd_req         = !(word_counter == 1 && dram_rd_valid);
                unpacker_is_tile    = 1'b1;
                unpacker_word_valid = dram_rd_valid;

                if (dram_rd_valid && word_counter == 1) begin
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

                if (stream_counter == (cfg_M + 9)) begin
                    next_state = DRAIN_OUTPUT_DRAM;
                end
            end

            // -------------------------------------------------------------
            // Output-Stationary (OS): Preload K activation vectors and K weight vectors
            // -------------------------------------------------------------
            OS_PRELOAD_TILES: begin
                dram_rd_req = !(word_counter == (2 * cfg_K * ROWS - 1) && dram_rd_valid);
                if (dram_rd_valid && word_counter >= (cfg_K * ROWS)) begin
                    logic [15:0] w_idx;
                    w_idx = word_counter - (cfg_K << 2);
                    wbuf_wr_en   = 1'b1;
                    wbuf_wr_addr = w_idx[15:2];
                    wbuf_wr_data = dram_rd_lo_byte;
                end

                if (dram_rd_valid && word_counter == (2 * cfg_K * ROWS - 1)) begin
                    next_state = OS_COMPUTE;
                end
            end

            OS_COMPUTE: begin
                sa_enable  = 1'b1;
                wbuf_rd_en = 1'b1;
                if (stream_counter == 0) begin
                    sa_accum_clear = 1'b1;
                end

                if (stream_counter >= 1 && stream_counter <= cfg_K) begin
                    wbuf_rd_addr = stream_counter - 1;
                    for (int r = 0; r < ROWS; r++) begin
                        sa_act_in[r*DATA_WIDTH +: DATA_WIDTH] = act_buf[stream_counter - 1][r];
                    end
                end

                if (stream_counter == (cfg_K + 7)) begin
                    next_state = OS_DRAIN;
                end
            end

            OS_DRAIN: begin
                sa_enable   = 1'b1;
                sa_drain_en = 1'b1;
                if (stream_counter == 3) begin
                    next_state = DRAIN_OUTPUT_DRAM;
                end
            end

            // -------------------------------------------------------------
            // DRAM Output Drain
            // -------------------------------------------------------------
            DRAIN_OUTPUT_DRAM: begin
                if (drain_counter < total_drain_words) begin
                    if (dram_wr_ack && (drain_counter + 1 == total_drain_words)) begin
                        dram_wr_req = 1'b0;
                        next_state  = COMPLETE;
                    end else begin
                        dram_wr_req = 1'b1;
                    end
                end else begin
                    next_state = COMPLETE;
                end
            end

            COMPLETE: begin
                done = 1'b1;
                busy = 1'b0;
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Sequential Datapath
    always_ff @(posedge clk or negedge rst_n) begin
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
                        if (word_counter == 1) word_counter <= '0;
                        else                   word_counter <= word_counter + 1;
                    end
                end

                WS_PRELOAD_ACTS: begin
                    if (dram_rd_valid) begin
                        act_buf[word_counter[15:2]][word_counter[1:0]] <= dram_rd_data;
                        if (word_counter == (cfg_M * ROWS - 1)) word_counter <= '0;
                        else                                    word_counter <= word_counter + 1;
                    end
                end

                WS_COMPUTE: begin
                    stream_counter <= stream_counter + 1;

                    // Latch deskewed output row
                    if (stream_counter >= 9 && stream_counter < (cfg_M + 9)) begin
                        out_base = (stream_counter - 9) * COLS;
                        out_buf[out_base + 0] <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 1] <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 2] <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 3] <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                        total_drain_words     <= total_drain_words + COLS;
                    end
                end

                OS_PRELOAD_TILES: begin
                    if (dram_rd_valid) begin
                        if (word_counter < (cfg_K * ROWS)) begin
                            act_buf[word_counter[15:2]][word_counter[1:0]] <= dram_rd_data;
                        end
                        if (word_counter == (2 * cfg_K * ROWS - 1)) word_counter <= '0;
                        else                                        word_counter <= word_counter + 1;
                    end
                end

                OS_COMPUTE: begin
                    stream_counter <= stream_counter + 1;
                    if (stream_counter == (cfg_K + 7)) begin
                        stream_counter <= '0;
                    end
                end

                OS_DRAIN: begin
                    stream_counter <= stream_counter + 1;
                    if (stream_counter <= 3) begin
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

                default: ;
            endcase
        end
    end

    assign perf_active_mac_cycles = perf_compute_cycles << 4; // ROWS * COLS = 16
    assign perf_stall_cycles = (perf_total_cycles > perf_compute_cycles) ?
                               (perf_total_cycles - perf_compute_cycles) : 32'd0;
    // Profiling division is offloaded to host software to preserve clock timing
    assign perf_mac_util_permille = 16'd0;

endmodule
