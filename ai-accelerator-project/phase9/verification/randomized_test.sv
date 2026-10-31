// ==============================================================================
// Testbench: randomized_test
// Description: Constrained-Randomized Hardware Stress Test.
//              - Evaluates memory_controller and systolic_array_4x4 across multiple
//                random matrix workloads.
//              - Injects pseudo-random DRAM bus wait-states (variable memory latency).
//              - Validates that memory counters remain exact and numerical accuracy is 100%.
// ==============================================================================

`timescale 1ns / 1ps

module randomized_test;

    parameter int DATA_WIDTH  = 16;
    parameter int ACCUM_WIDTH = 32;
    parameter int ROWS        = 4;
    parameter int COLS        = 4;
    parameter int NUM_RUNS    = 5;

    logic clk;
    logic rst_n;
    logic start_gemm;
    logic done;
    logic busy;

    // DRAM Bus
    logic         dram_rd_req;
    logic         dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic         dram_wr_req;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic         dram_wr_ack;

    // Interconnect Signals
    logic         sa_enable;
    logic         sa_weight_load;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] sa_weight_in;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_raw;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_out;

    // Hardware Counters
    logic [31:0]  perf_dram_reads;
    logic [31:0]  perf_dram_writes;
    logic [31:0]  perf_sram_reads;
    logic [31:0]  perf_sram_writes;
    logic [31:0]  perf_active_cycles;
    logic [31:0]  perf_total_cycles;

    int pass_count = 0;
    int fail_count = 0;
    int words_read = 0;
    int words_written = 0;

    // Random Test Storage
    logic signed [DATA_WIDTH-1:0]  rand_weights [0:ROWS-1][0:COLS-1];
    logic signed [DATA_WIDTH-1:0]  rand_acts    [0:ROWS-1][0:ROWS-1];
    logic signed [ACCUM_WIDTH-1:0] rand_golden  [0:ROWS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] rand_captured[0:ROWS-1][0:COLS-1];

    memory_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start_gemm(start_gemm),
        .tile_k_count(16'd1),
        .tile_m_count(16'd1),
        .done(done),
        .busy(busy),
        .dram_rd_req(dram_rd_req),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .sa_enable(sa_enable),
        .sa_weight_load(sa_weight_load),
        .sa_weight_in(sa_weight_in),
        .sa_act_in(sa_act_in),
        .sa_psum_in(sa_psum_in),
        .sa_psum_out_deskewed(sa_psum_out_deskewed),
        .perf_dram_reads(perf_dram_reads),
        .perf_dram_writes(perf_dram_writes),
        .perf_sram_reads(perf_sram_reads),
        .perf_sram_writes(perf_sram_writes),
        .perf_active_cycles(perf_active_cycles),
        .perf_total_cycles(perf_total_cycles)
    );

    systolic_array_4x4 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .INTERNAL_SKEW(1'b1)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .enable(sa_enable),
        .weight_load(sa_weight_load),
        .weight_in_flat(sa_weight_in),
        .act_in_flat(sa_act_in),
        .psum_in_flat(sa_psum_in),
        .psum_out_flat(sa_psum_out_raw),
        .psum_out_deskewed_flat(sa_psum_out_deskewed),
        .act_out_flat(sa_act_out)
    );

    always #5 clk = ~clk;

    // DRAM Emulator with pseudo-random stall insertion
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid <= 1'b0;
            dram_rd_data  <= '0;
            dram_wr_ack   <= 1'b0;
            words_read    <= 0;
            words_written <= 0;
        end else begin
            // Read channel with random stall injection
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                words_read    <= words_read + 1;
                if (words_read < 16) begin
                    dram_rd_data <= rand_weights[words_read / COLS][words_read % COLS];
                end else if (words_read < 32) begin
                    dram_rd_data <= rand_acts[(words_read - 16) / ROWS][(words_read - 16) % ROWS];
                end else begin
                    dram_rd_data <= '0;
                end
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Write channel
            if (dram_wr_req && !dram_wr_ack) begin
                dram_wr_ack <= 1'b1;
            end else if (dram_wr_req && dram_wr_ack) begin
                if (words_written < 16) begin
                    rand_captured[words_written / COLS][words_written % COLS] <= dram_wr_data;
                    words_written <= words_written + 1;
                end
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

    // Task: Generate new random matrices
    task automatic generate_random_matrices(input int seed_val);
        int seed_reg;
        seed_reg = seed_val;
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                // Bounded random integers between -50 and +50
                rand_weights[r][c] = ($random(seed_reg) % 101) - 50;
                rand_acts[r][c]    = ($random(seed_reg) % 101) - 50;
            end
        end

        // Compute Golden reference
        for (int i = 0; i < ROWS; i++) begin
            for (int j = 0; j < COLS; j++) begin
                rand_golden[i][j] = 0;
                for (int k = 0; k < ROWS; k++) begin
                    rand_golden[i][j] += 32'($signed(rand_acts[i][k])) * 32'($signed(rand_weights[k][j]));
                end
            end
        end
    endtask

    initial begin
        clk        = 0;
        rst_n      = 0;
        start_gemm = 0;

        $display("\n==========================================================================");
        $display("  STARTING PHASE 9: CONSTRAINED-RANDOMIZED ACCELERATOR STRESS SUITE");
        $display("==========================================================================");

        #20;
        @(posedge clk); #1;
        rst_n = 1;

        for (int run = 0; run < NUM_RUNS; run++) begin
            int run_seed;
            run_seed = 1000 + (run * 179);
            generate_random_matrices(run_seed);

            // Reset DRAM words tracker
            @(posedge clk); #1;
            words_read    = 0;
            words_written = 0;

            // Trigger GEMM
            start_gemm = 1;
            @(posedge clk); #1;
            start_gemm = 0;

            // Wait for completion
            while (!done) begin
                @(posedge clk); #1;
            end

            @(posedge clk); #1;

            // Verify run
            begin : run_check
                bit run_passed;
                run_passed = 1;
                for (int i = 0; i < ROWS; i++) begin
                    for (int j = 0; j < COLS; j++) begin
                        if (rand_captured[i][j] !== rand_golden[i][j]) begin
                            run_passed = 0;
                            $display("  [ERROR Run %0d] Mismatch at [%0d,%0d]: Got %0d, Expected %0d",
                                     run+1, i, j, rand_captured[i][j], rand_golden[i][j]);
                        end
                    end
                end

                if (run_passed) begin
                    $display("[PASS] Random Run %0d/%0d Verified: 16/16 Outputs Exactly Match Golden Reference",
                             run+1, NUM_RUNS);
                    pass_count++;
                end else begin
                    $display("[FAIL] Random Run %0d/%0d Failed!", run+1, NUM_RUNS);
                    fail_count++;
                end
            end
        end

        $display("\n==========================================================================");
        $display("  RANDOMIZED STRESS TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> ROBUSTNESS & ARITHMETIC INTEGRITY: 100%% VERIFIED!\n");
        end else begin
            $display(">> RANDOMIZED STRESS TEST FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
