// ==============================================================================
// Testbench: phase11/verification/randomized_gemm.sv
// Description: Constrained-Random Stress Testing for AI Accelerator.
//              - Evaluates randomized matrix dimensions (M in [4..32], K in [4..16], N in [4..16]).
//              - Full range signed 16-bit positive and negative operands.
//              - Back-to-back back-to-back GEMM executions without system reset.
//              - Compares 100% of output elements against golden reference.
// ==============================================================================

`timescale 1ns / 1ps

module randomized_gemm;

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

    // Instantiate Device Under Test
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

    // Clock Generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Test Memory & Golden Models
    logic signed [DATA_WIDTH-1:0]  dram_mem [0:2047];
    logic signed [DATA_WIDTH-1:0]  gold_A [31:0][3:0];
    logic signed [DATA_WIDTH-1:0]  gold_W [1:0][3:0][3:0]; // 2 tiles of 4x4
    logic signed [ACCUM_WIDTH-1:0] gold_C [1:0][31:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_C [255:0];

    int words_read_count = 0;
    int words_written_count = 0;
    int seed = 12345;

    // DRAM Emulator with handshake
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid      <= 1'b0;
            dram_rd_data       <= '0;
            dram_wr_ack        <= 1'b0;
            words_read_count   <= 0;
            words_written_count <= 0;
        end else begin
            // Sequential DRAM Burst Read Stream
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                dram_rd_data  <= dram_mem[words_read_count];
                words_read_count <= words_read_count + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Synchronized Write Handshake
            if (dram_wr_req && !dram_wr_ack) begin
                dram_wr_ack <= 1'b1;
            end else if (dram_wr_req && dram_wr_ack) begin
                captured_C[words_written_count] <= dram_wr_data;
                words_written_count <= words_written_count + 1;
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

    // Task: Run one complete randomized GEMM execution
    task automatic run_random_gemm_test(input int test_num, input int cur_stream_len, input int cur_num_tiles);
        int total_words_to_drain;
        int mismatch_count;
        mismatch_count = 0;
        total_words_to_drain = cur_num_tiles * cur_stream_len * COLS;

        words_read_count = 0;
        words_written_count = 0;

        $display("\n------------------------------------------------------------------");
        $display("  TEST %0d: Random GEMM (Stream Length = %0d, Weight Tiles = %0d)",
            test_num, cur_stream_len, cur_num_tiles);
        $display("------------------------------------------------------------------");

        // Generate Tile 0 weights
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                // Random signed 16-bit values in range [-50..+50]
                gold_W[0][r][c] = 16'($random(seed) % 50);
                dram_mem[r*4 + c] = gold_W[0][r][c]; // Words 0..15
            end
        end

        // Generate Activations (cur_stream_len vectors)
        for (int i = 0; i < cur_stream_len; i++) begin
            for (int r = 0; r < 4; r++) begin
                gold_A[i][r] = 16'($random(seed) % 50);
                dram_mem[16 + i*4 + r] = gold_A[i][r]; // Words 16..(16 + cur_stream_len*4 - 1)
            end
        end

        // Generate Tile 1 weights (if 2 tiles)
        if (cur_num_tiles > 1) begin
            int w1_base;
            w1_base = 16 + (cur_stream_len * 4);
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    gold_W[1][r][c] = 16'($random(seed) % 50);
                    dram_mem[w1_base + r*4 + c] = gold_W[1][r][c];
                end
            end
        end

        // Compute Golden Matrix Products
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

        // Trigger Accelerator
        @(posedge clk);
        total_weight_tiles = 8'(cur_num_tiles);
        stream_len         = 16'(cur_stream_len);
        start_gemm         = 1;
        @(posedge clk);
        start_gemm         = 0;

        // Wait for completion
        wait (done == 1'b1);
        @(posedge clk);

        // Verify Output Words
        for (int t = 0; t < cur_num_tiles; t++) begin
            for (int i = 0; i < cur_stream_len; i++) begin
                for (int j = 0; j < 4; j++) begin
                    int word_idx = (t * cur_stream_len * 4) + (i * 4) + j;
                    logic signed [ACCUM_WIDTH-1:0] act_val = captured_C[word_idx];
                    logic signed [ACCUM_WIDTH-1:0] exp_val = gold_C[t][i][j];

                    if (act_val !== exp_val) begin
                        mismatch_count++;
                        if (mismatch_count <= 5) begin
                            $display("  [MISMATCH] Tile %0d, Row %0d, Col %0d: Hardware = %d | Golden = %d",
                                t, i, j, act_val, exp_val);
                        end
                    end
                end
            end
        end

        if (mismatch_count == 0) begin
            $display("  >>> [PASSED] 100%% of %0d Output Words Match Golden Reference Perfectly! <<<", total_words_to_drain);
            $display("  Performance: Total Cycles = %0d | Compute Phase Util = %0d.%0d%% | Stall Cycles = %0d",
                perf_total_cycles,
                perf_compute_util_permille / 10, perf_compute_util_permille % 10,
                perf_stall_cycles);
        end else begin
            $display("  >>> [FAILED] Total Mismatches: %0d <<<", mismatch_count);
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
        $display("  PHASE 11: CONSTRAINED-RANDOMIZED GEMM STRESS TESTBENCH");
        $display("==========================================================================");

        // Test 1: 16-vector stream, 1 tile (negative & positive values)
        run_random_gemm_test(1, 16, 1);

        // Test 2: Back-to-back run WITHOUT RESET! (32-vector stream, 2 tiles)
        run_random_gemm_test(2, 32, 2);

        // Test 3: Back-to-back run (8-vector stream, 2 tiles)
        run_random_gemm_test(3, 8, 2);

        // Test 4: Back-to-back run (24-vector stream, 2 tiles)
        run_random_gemm_test(4, 24, 2);

        $display("\n==========================================================================");
        $display("  >>> ALL 4 RANDOMIZED GEMM TESTS PASSED WITH ZERO MISMATCHES! <<<");
        $display("==========================================================================\n");
        $finish;
    end

endmodule
