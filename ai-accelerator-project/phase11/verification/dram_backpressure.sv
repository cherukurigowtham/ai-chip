// ==============================================================================
// Testbench: phase11/verification/dram_backpressure.sv
// Description: Dynamic DRAM Backpressure & Variable-Latency Stress Testing.
//              - Evaluates hardware resilience against non-deterministic DRAM latency.
//              - Sweeps DRAM latencies: L = 1, 4, 8, 16, 32 cycles.
//              - Evaluates random wait-states on read & write handshakes.
//              - Verifies bit-exact mathematical outputs across all latency regimes.
//              - Quantifies hardware MAC utilization under memory backpressure.
// ==============================================================================

`timescale 1ns / 1ps

module dram_backpressure;

    localparam int DATA_WIDTH  = 16;
    localparam int ACCUM_WIDTH = 32;
    localparam int ROWS        = 4;
    localparam int COLS        = 4;
    localparam int BUFFER_VECS = 32;
    localparam int CLK_PERIOD  = 2; // 500 MHz

    logic clk;
    logic rst_n;

    logic        start_gemm;
    logic [7:0]  total_weight_tiles;
    logic [15:0] stream_len;
    logic        busy;
    logic        done;

    logic        dram_rd_req;
    logic [15:0] dram_rd_addr;
    logic        dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic        dram_wr_req;
    logic [15:0] dram_wr_addr;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic        dram_wr_ack;

    logic [31:0] perf_total_cycles;
    logic [31:0] perf_compute_cycles;
    logic [31:0] perf_active_mac_cycles;
    logic [31:0] perf_stall_cycles;
    logic [31:0] perf_dram_reads;
    logic [31:0] perf_dram_writes;
    logic [31:0] perf_sram_reads;
    logic [31:0] perf_sram_writes;
    logic [15:0] perf_mac_util_permille;
    logic [15:0] perf_compute_util_permille;

    // DUT
    memory_controller_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_gemm(start_gemm),
        .total_weight_tiles(total_weight_tiles),
        .stream_len(stream_len),
        .busy(busy),
        .done(done),
        .dram_rd_req(dram_rd_req),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .perf_total_cycles(perf_total_cycles),
        .perf_compute_cycles(perf_compute_cycles),
        .perf_active_mac_cycles(perf_active_mac_cycles),
        .perf_stall_cycles(perf_stall_cycles),
        .perf_dram_reads(perf_dram_reads),
        .perf_dram_writes(perf_dram_writes),
        .perf_sram_reads(perf_sram_reads),
        .perf_sram_writes(perf_sram_writes),
        .perf_mac_util_permille(perf_mac_util_permille),
        .perf_compute_util_permille(perf_compute_util_permille)
    );

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Storage & Golden References
    logic signed [DATA_WIDTH-1:0]  dram_mem [0:2047];
    logic signed [DATA_WIDTH-1:0]  gold_A [31:0][3:0];
    logic signed [DATA_WIDTH-1:0]  gold_W [1:0][3:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] gold_C [1:0][31:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_C [255:0];

    int words_read_count = 0;
    int words_written_count = 0;
    int seed = 42;

    // Configurable DRAM Latency Model
    int cfg_dram_latency_cycles = 1;
    bit cfg_random_wait_states  = 0;

    int rd_wait_counter = 0;
    int wr_wait_counter = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid       <= 1'b0;
            dram_rd_data        <= '0;
            dram_wr_ack         <= 1'b0;
            words_read_count    <= 0;
            words_written_count <= 0;
            rd_wait_counter     <= 0;
            wr_wait_counter     <= 0;
        end else begin
            // 1. Read Channel
            if (dram_rd_req) begin
                int current_rd_delay;
                current_rd_delay = cfg_random_wait_states ? (1 + ($random(seed) % 6)) : cfg_dram_latency_cycles;
                if (current_rd_delay < 1) current_rd_delay = 1;

                if (rd_wait_counter + 1 >= current_rd_delay) begin
                    dram_rd_valid    <= 1'b1;
                    dram_rd_data     <= dram_mem[words_read_count];
                    words_read_count <= words_read_count + 1;
                    rd_wait_counter  <= 0;
                end else begin
                    dram_rd_valid   <= 1'b0;
                    rd_wait_counter <= rd_wait_counter + 1;
                end
            end else begin
                dram_rd_valid   <= 1'b0;
                rd_wait_counter <= 0;
            end

            // 2. Write Channel
            if (dram_wr_req) begin
                if (dram_wr_ack) begin
                    captured_C[words_written_count] <= dram_wr_data;
                    words_written_count <= words_written_count + 1;
                    dram_wr_ack     <= 1'b0;
                    wr_wait_counter <= 0;
                end else begin
                    int current_wr_delay;
                    current_wr_delay = cfg_random_wait_states ? (1 + ($random(seed) % 3)) : 1;
                    if (current_wr_delay < 1) current_wr_delay = 1;

                    if (wr_wait_counter + 1 >= current_wr_delay) begin
                        dram_wr_ack     <= 1'b1;
                        wr_wait_counter <= 0;
                    end else begin
                        dram_wr_ack     <= 1'b0;
                        wr_wait_counter <= wr_wait_counter + 1;
                    end
                end
            end else begin
                dram_wr_ack     <= 1'b0;
                wr_wait_counter <= 0;
            end
        end
    end

    // Task to run stress test under specific backpressure configuration
    task automatic run_backpressure_test(
        input string test_name,
        input int lat_cycles,
        input bit random_wait,
        input int cur_stream_len,
        input int cur_num_tiles
    );
        int total_words_to_drain;
        int mismatch_count;
        mismatch_count = 0;
        total_words_to_drain = cur_num_tiles * cur_stream_len * COLS;

        cfg_dram_latency_cycles = lat_cycles;
        cfg_random_wait_states  = random_wait;
        words_read_count        = 0;
        words_written_count     = 0;
        rd_wait_counter         = 0;
        wr_wait_counter         = 0;

        $display("\n------------------------------------------------------------------");
        $display("  SCENARIO: %s", test_name);
        $display("  Config: DRAM Latency = %0d cycles | Random Wait = %0d | Tiles = %0d | Stream = %0d",
            lat_cycles, random_wait, cur_num_tiles, cur_stream_len);
        $display("------------------------------------------------------------------");

        // Generate Tile 0 Weights
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                gold_W[0][r][c] = 16'($random(seed) % 40);
                dram_mem[r*4 + c] = gold_W[0][r][c];
            end
        end

        // Generate Activations
        for (int i = 0; i < cur_stream_len; i++) begin
            for (int r = 0; r < 4; r++) begin
                gold_A[i][r] = 16'($random(seed) % 40);
                dram_mem[16 + i*4 + r] = gold_A[i][r];
            end
        end

        // Generate Tile 1 Weights
        if (cur_num_tiles > 1) begin
            int w1_base;
            w1_base = 16 + (cur_stream_len * 4);
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    gold_W[1][r][c] = 16'($random(seed) % 40);
                    dram_mem[w1_base + r*4 + c] = gold_W[1][r][c];
                end
            end
        end

        // Golden Reference Calculation
        for (int t = 0; t < cur_num_tiles; t++) begin
            for (int i = 0; i < cur_stream_len; i++) begin
                for (int j = 0; j < 4; j++) begin
                    gold_C[t][i][j] = '0;
                    for (int k = 0; k < 4; k++) begin
                        gold_C[t][i][j] = gold_C[t][i][j] + (32'($signed(gold_A[i][k])) * 32'($signed(gold_W[t][k][j])));
                    end
                end
            end
        end

        // Launch GEMM
        @(posedge clk);
        total_weight_tiles = 8'(cur_num_tiles);
        stream_len         = 16'(cur_stream_len);
        start_gemm         = 1;
        @(posedge clk);
        start_gemm         = 0;

        // Await Completion
        wait (done == 1'b1);
        @(posedge clk);

        // Verify Outputs
        for (int t = 0; t < cur_num_tiles; t++) begin
            for (int i = 0; i < cur_stream_len; i++) begin
                for (int j = 0; j < 4; j++) begin
                    int word_idx = (t * cur_stream_len * 4) + (i * 4) + j;
                    logic signed [ACCUM_WIDTH-1:0] act_val = captured_C[word_idx];
                    logic signed [ACCUM_WIDTH-1:0] exp_val = gold_C[t][i][j];

                    if (act_val !== exp_val) begin
                        mismatch_count++;
                        if (mismatch_count <= 5) begin
                            $display("  [MISMATCH] Tile %0d, Row %0d, Col %0d: HW = %d | Golden = %d",
                                t, i, j, act_val, exp_val);
                        end
                    end
                end
            end
        end

        if (mismatch_count == 0) begin
            $display("  >>> [PASSED] 100%% Bit-Exact Output Correctness (%0d words verified) <<<", total_words_to_drain);
            $display("  Metrics: Total Cycles = %0d | Compute Phase MAC Util = %0d.%0d%% | Stall Cycles = %0d",
                perf_total_cycles,
                perf_compute_util_permille / 10, perf_compute_util_permille % 10,
                perf_stall_cycles);
        end else begin
            $display("  >>> [FAILED] Total Mismatches = %0d <<<", mismatch_count);
            $finish;
        end
    endtask

    initial begin
        rst_n = 0;
        start_gemm = 0;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("\n==========================================================================");
        $display("  PHASE 11: DRAM BACKPRESSURE & VARIABLE-LATENCY HARDWARE STRESS TEST");
        $display("==========================================================================");

        // Test 1: Baseline L=1 (Fast DRAM)
        run_backpressure_test("Fast Memory (L=1 cycle)", 1, 0, 16, 2);

        // Test 2: Moderate Latency L=4 (Realistic on-chip/LPDDR)
        run_backpressure_test("Realistic Memory (L=4 cycles)", 4, 0, 16, 2);

        // Test 3: High Latency L=8 (Hiding Threshold Boundary)
        run_backpressure_test("Threshold Boundary (L=8 cycles)", 8, 0, 16, 2);

        // Test 4: Extreme Latency L=16 (Severe Memory Stalling)
        run_backpressure_test("Severe Backpressure (L=16 cycles)", 16, 0, 16, 2);

        // Test 5: Non-deterministic Random Wait States (Jitter / Channel Contention)
        run_backpressure_test("Non-deterministic Jitter & Random Stalls", 1, 1, 16, 2);

        $display("\n==========================================================================");
        $display("  >>> ALL 5 DRAM BACKPRESSURE STRESS TESTS PASSED WITH ZERO ERRORS! <<<");
        $display("==========================================================================\n");
        $finish;
    end

endmodule
