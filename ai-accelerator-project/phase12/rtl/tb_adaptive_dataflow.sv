// ==============================================================================
// Testbench: phase12/rtl/tb_adaptive_dataflow.sv
// Description: Comprehensive RTL Verification for Adaptive Dataflow AI Accelerator.
//              - Verifies Weight-Stationary (WS) execution mode.
//              - Verifies Output-Stationary (OS) execution mode.
//              - Verifies Autonomous Adaptive Mode Selection (K > M -> OS; M >= K -> WS).
//              - Evaluates seamless runtime dataflow switching without hardware reset.
//              - 100% bit-exact validation of matrix multiplication outputs against golden model.
// ==============================================================================

`timescale 1ns / 1ps

module tb_adaptive_dataflow;

    localparam int DATA_WIDTH  = 16;
    localparam int ACCUM_WIDTH = 32;
    localparam int ROWS        = 4;
    localparam int COLS        = 4;
    localparam int BUFFER_VECS = 64;
    localparam int CLK_PERIOD  = 2; // 500 MHz

    logic clk;
    logic rst_n;

    logic        start;
    logic [1:0]  dataflow_mode;
    logic [15:0] cfg_M;
    logic [15:0] cfg_K;
    logic [15:0] cfg_N;
    logic        busy;
    logic        done;
    logic        active_dataflow;

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
    logic [15:0] perf_mac_util_permille;

    // Instantiate DUT
    dataflow_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .dataflow_mode(dataflow_mode),
        .cfg_M(cfg_M),
        .cfg_K(cfg_K),
        .cfg_N(cfg_N),
        .busy(busy),
        .done(done),
        .active_dataflow(active_dataflow),
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
        .perf_mac_util_permille(perf_mac_util_permille)
    );

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Test Storage & Models
    logic signed [DATA_WIDTH-1:0]  dram_mem [0:4095];
    logic signed [DATA_WIDTH-1:0]  gold_A [63:0][3:0];
    logic signed [DATA_WIDTH-1:0]  gold_W [63:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] gold_C [63:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_C [255:0];

    int words_read_count = 0;
    int words_written_count = 0;
    int seed = 777;

    // DRAM Emulator with handshake
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid       <= 1'b0;
            dram_rd_data        <= '0;
            dram_wr_ack         <= 1'b0;
            words_read_count    <= 0;
            words_written_count <= 0;
        end else begin
            // Read Channel
            if (dram_rd_req) begin
                dram_rd_valid    <= 1'b1;
                dram_rd_data     <= dram_mem[words_read_count];
                words_read_count <= words_read_count + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Write Channel
            if (dram_wr_req && !dram_wr_ack) begin
                dram_wr_ack <= 1'b1;
            end else if (dram_wr_req && dram_wr_ack) begin
                captured_C[words_written_count] <= dram_wr_data;
                words_written_count             <= words_written_count + 1;
                dram_wr_ack                     <= 1'b0;
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

    // Task to run one GEMM test under specified mode
    task automatic run_test(
        input string test_title,
        input [1:0]  mode,
        input int    in_M,
        input int    in_K,
        input int    in_N
    );
        int total_output_words;
        int mismatch_count;
        mismatch_count = 0;
        total_output_words = (mode == 2'b10 || (mode == 2'b00 && in_K > in_M)) ? (4 * 4) : (in_M * 4);

        words_read_count    = 0;
        words_written_count = 0;

        $display("\n------------------------------------------------------------------");
        $display("  TEST: %s", test_title);
        $display("  Dimensions: M = %0d, K = %0d, N = %0d | Config Mode = %0b", in_M, in_K, in_N, mode);
        $display("------------------------------------------------------------------");

        if (mode == 2'b01 || (mode == 2'b00 && in_M >= in_K)) begin
            // -------------------------------------------------------------
            // Weight-Stationary Memory Layout
            // Words 0..15: 4x4 Weight Tile
            // Words 16..(16 + in_M*4 - 1): in_M Activation Vectors
            // -------------------------------------------------------------
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    gold_W[r][c] = 16'($random(seed) % 30);
                    dram_mem[r*4 + c] = gold_W[r][c];
                end
            end

            for (int i = 0; i < in_M; i++) begin
                for (int r = 0; r < 4; r++) begin
                    gold_A[i][r] = 16'($random(seed) % 30);
                    dram_mem[16 + i*4 + r] = gold_A[i][r];
                end
            end

            // Calculate Golden C = A x W
            for (int i = 0; i < in_M; i++) begin
                for (int j = 0; j < 4; j++) begin
                    gold_C[i][j] = '0;
                    for (int k = 0; k < 4; k++) begin
                        gold_C[i][j] = gold_C[i][j] + (32'($signed(gold_A[i][k])) * 32'($signed(gold_W[k][j])));
                    end
                end
            end
        end else begin
            // -------------------------------------------------------------
            // Output-Stationary Memory Layout
            // Words 0..(in_K*4 - 1): in_K Activation Vectors (4 words each)
            // Words (in_K*4)..(2*in_K*4 - 1): in_K Weight Vectors (4 words each)
            // -------------------------------------------------------------
            for (int k = 0; k < in_K; k++) begin
                for (int r = 0; r < 4; r++) begin
                    gold_A[k][r] = 16'($random(seed) % 30);
                    dram_mem[k*4 + r] = gold_A[k][r];
                end
            end

            for (int k = 0; k < in_K; k++) begin
                for (int c = 0; c < 4; c++) begin
                    gold_W[k][c] = 16'($random(seed) % 30);
                    dram_mem[(in_K*4) + k*4 + c] = gold_W[k][c];
                end
            end

            // Calculate Golden 4x4 output: C[r, c] = sum_k (A[k, r] * W[k, c])
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    gold_C[r][c] = '0;
                    for (int k = 0; k < in_K; k++) begin
                        gold_C[r][c] = gold_C[r][c] + (32'($signed(gold_A[k][r])) * 32'($signed(gold_W[k][c])));
                    end
                end
            end
        end

        // Trigger Accelerator
        @(posedge clk);
        cfg_M         = 16'(in_M);
        cfg_K         = 16'(in_K);
        cfg_N         = 16'(in_N);
        dataflow_mode = mode;
        start         = 1;
        @(posedge clk);
        start         = 0;

        // Wait for Completion
        wait (done == 1'b1);
        @(posedge clk);

        $display("  Telemetry: Selected Dataflow = %s | Total Cycles = %0d | Compute MAC Util = %0d.%0d%%",
            active_dataflow ? "Output-Stationary (OS)" : "Weight-Stationary (WS)",
            perf_total_cycles,
            perf_mac_util_permille / 10, perf_mac_util_permille % 10);

        // Verify Outputs
        if (mode == 2'b01 || (mode == 2'b00 && in_M >= in_K)) begin
            for (int i = 0; i < in_M; i++) begin
                for (int j = 0; j < 4; j++) begin
                    int word_idx = i*4 + j;
                    logic signed [ACCUM_WIDTH-1:0] act_val = captured_C[word_idx];
                    logic signed [ACCUM_WIDTH-1:0] exp_val = gold_C[i][j];

                    if (act_val !== exp_val) begin
                        mismatch_count++;
                        if (mismatch_count <= 5) begin
                            $display("  [MISMATCH] Row %0d, Col %0d: HW = %d | Golden = %d",
                                i, j, act_val, exp_val);
                        end
                    end
                end
            end
        end else begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int word_idx = r*4 + c;
                    logic signed [ACCUM_WIDTH-1:0] act_val = captured_C[word_idx];
                    logic signed [ACCUM_WIDTH-1:0] exp_val = gold_C[r][c];

                    if (act_val !== exp_val) begin
                        mismatch_count++;
                        if (mismatch_count <= 5) begin
                            $display("  [MISMATCH] PE(%0d, %0d): HW = %d | Golden = %d",
                                r, c, act_val, exp_val);
                        end
                    end
                end
            end
        end

        if (mismatch_count == 0) begin
            $display("  >>> [PASSED] 100%% Bit-Exact Output Correctness (%0d words matched)! <<<", total_output_words);
        end else begin
            $display("  >>> [FAILED] Total Mismatches: %0d <<<", mismatch_count);
            $finish;
        end
    endtask

    initial begin
        rst_n = 0;
        start = 0;
        dataflow_mode = 0;
        cfg_M = 0; cfg_K = 0; cfg_N = 0;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("\n==========================================================================");
        $display("  PHASE 12: ADAPTIVE DATAFLOW SYSTEMVERILOG HARDWARE VERIFICATION");
        $display("==========================================================================");

        // Test 1: Forced Weight-Stationary (WS) Mode: M=16, K=4, N=4
        run_test("Forced Weight-Stationary (WS) Mode", 2'b01, 16, 4, 4);

        // Test 2: Forced Output-Stationary (OS) Mode: M=4, K=16, N=4
        run_test("Forced Output-Stationary (OS) Mode", 2'b10, 4, 16, 4);

        // Test 3: Auto-Adaptive Decision: Batch Inference (M=24, K=4 -> chooses WS)
        run_test("Auto-Adaptive: Batch Inference (M=24, K=4 -> WS)", 2'b00, 24, 4, 4);

        // Test 4: Auto-Adaptive Decision: Deep Reduction / Attention (M=4, K=24 -> chooses OS)
        run_test("Auto-Adaptive: Deep Reduction (M=4, K=24 -> OS)", 2'b00, 4, 24, 4);

        // Test 5: Back-to-Back Switch (OS -> WS) WITHOUT HARDWARE RESET!
        run_test("Back-to-Back Run: Deep Reduction (M=4, K=32 -> OS)", 2'b00, 4, 32, 4);
        run_test("Back-to-Back Run: Large Batch (M=32, K=4 -> WS)", 2'b00, 32, 4, 4);

        $display("\n==========================================================================");
        $display("  >>> ALL 6 ADAPTIVE DATAFLOW TESTS PASSED WITH ZERO MISMATCHES! <<<");
        $display("==========================================================================\n");
        $finish;
    end

endmodule
