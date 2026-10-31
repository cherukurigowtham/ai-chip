// ==============================================================================
// Testbench: memory_counter_test
// Description: RTL Hardware Verification of Performance Counters & Memory Traffic.
//              - Connects memory_controller, systolic_array_4x4, and DRAM model.
//              - Verifies hardware counters match Python/architectural predictions.
//              - Checks for duplicated transfers, buffer overwrites, and proper handshake.
// ==============================================================================

`timescale 1ns / 1ps

module memory_counter_test;

    parameter int DATA_WIDTH  = 16;
    parameter int ACCUM_WIDTH = 32;
    parameter int ROWS        = 4;
    parameter int COLS        = 4;

    logic clk;
    logic rst_n;
    logic start_gemm;
    logic done;
    logic busy;

    // DRAM Bus Signals
    logic         dram_rd_req;
    logic         dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic         dram_wr_req;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic         dram_wr_ack;

    // Interconnect Signals between Controller & Systolic Array
    logic         sa_enable;
    logic         sa_weight_load;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] sa_weight_in;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_raw;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_out;

    // Performance Counters from Controller
    logic [31:0]  perf_dram_reads;
    logic [31:0]  perf_dram_writes;
    logic [31:0]  perf_sram_reads;
    logic [31:0]  perf_sram_writes;
    logic [31:0]  perf_active_cycles;
    logic [31:0]  perf_total_cycles;

    // Verification variables
    int pass_count = 0;
    int fail_count = 0;
    int words_read_from_dram = 0;
    int words_written_to_dram = 0;

    // Golden Data Storage
    logic signed [DATA_WIDTH-1:0]  gold_weights [0:ROWS-1][0:COLS-1];
    logic signed [DATA_WIDTH-1:0]  gold_acts    [0:ROWS-1][0:ROWS-1];
    logic signed [ACCUM_WIDTH-1:0] gold_outputs [0:ROWS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] captured_out [0:ROWS-1][0:COLS-1];

    // Instantiate Memory Controller
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

    // Instantiate 4x4 Systolic Array Core
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

    // 100 MHz clock
    always #5 clk = ~clk;

    // DRAM Emulator Process
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid         <= 1'b0;
            dram_rd_data          <= '0;
            dram_wr_ack           <= 1'b0;
            words_read_from_dram  <= 0;
            words_written_to_dram <= 0;
        end else begin
            // Emulate DRAM Read with 1-cycle latency handshake
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                words_read_from_dram <= words_read_from_dram + 1;
                if (words_read_from_dram < 16) begin
                    dram_rd_data <= gold_weights[words_read_from_dram / COLS][words_read_from_dram % COLS];
                end else if (words_read_from_dram < 32) begin
                    dram_rd_data <= gold_acts[(words_read_from_dram - 16) / ROWS][(words_read_from_dram - 16) % ROWS];
                end else begin
                    dram_rd_data <= '0;
                end
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Emulate DRAM Write with handshake (transfer occurs when both req and ack are high)
            if (dram_wr_req && !dram_wr_ack) begin
                dram_wr_ack <= 1'b1;
            end else if (dram_wr_req && dram_wr_ack) begin
                if (words_written_to_dram < 16) begin
                    captured_out[words_written_to_dram / COLS][words_written_to_dram % COLS] <= dram_wr_data;
                    words_written_to_dram <= words_written_to_dram + 1;
                end
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

    initial begin
        clk        = 0;
        rst_n      = 0;
        start_gemm = 0;

        $display("\n==========================================================================");
        $display("  STARTING PHASE 9: HARDWARE PERFORMANCE COUNTER VERIFICATION TEST");
        $display("==========================================================================");

        // Initialize Golden Matrices (4x4)
        gold_weights[0][0]=2; gold_weights[0][1]=3; gold_weights[0][2]=1; gold_weights[0][3]=4;
        gold_weights[1][0]=4; gold_weights[1][1]=1; gold_weights[1][2]=3; gold_weights[1][3]=2;
        gold_weights[2][0]=1; gold_weights[2][1]=2; gold_weights[2][2]=4; gold_weights[2][3]=3;
        gold_weights[3][0]=3; gold_weights[3][1]=4; gold_weights[3][2]=2; gold_weights[3][3]=1;

        gold_acts[0][0]=1; gold_acts[0][1]=2; gold_acts[0][2]=3; gold_acts[0][3]=4;
        gold_acts[1][0]=5; gold_acts[1][1]=6; gold_acts[1][2]=7; gold_acts[1][3]=8;
        gold_acts[2][0]=2; gold_acts[2][1]=1; gold_acts[2][2]=4; gold_acts[2][3]=3;
        gold_acts[3][0]=3; gold_acts[3][1]=5; gold_acts[3][2]=2; gold_acts[3][3]=1;

        // Compute Golden Reference
        for (int i = 0; i < ROWS; i++) begin
            for (int j = 0; j < COLS; j++) begin
                gold_outputs[i][j] = 0;
                for (int k = 0; k < ROWS; k++) begin
                    gold_outputs[i][j] += 32'($signed(gold_acts[i][k])) * 32'($signed(gold_weights[k][j]));
                end
            end
        end

        // Reset system
        #20;
        @(posedge clk); #1;
        rst_n = 1;

        // Issue GEMM command to controller
        @(posedge clk); #1;
        start_gemm = 1;
        @(posedge clk); #1;
        start_gemm = 0;

        // Wait for controller done
        while (!done) begin
            @(posedge clk); #1;
        end

        @(posedge clk); #1;

        $display("\n--- Hardware Counter Report from Memory Controller ---");
        $display("  DRAM Words Read     : %0d (Expected: 32)", perf_dram_reads);
        $display("  DRAM Words Written  : %0d (Expected: 16)", perf_dram_writes);
        $display("  SRAM Words Written  : %0d (Expected: 32)", perf_sram_writes);
        $display("  SRAM Read Pulses    : %0d (Expected: 5)",  perf_sram_reads);
        $display("  Active Compute Cyc  : %0d", perf_active_cycles);
        $display("  Total Latency Cyc   : %0d", perf_total_cycles);

        // Verification Checks
        if (perf_dram_reads == 32) begin
            $display("[PASS] DRAM Reads match analytical model (16 weights + 16 acts)");
            pass_count++;
        end else begin
            $display("[FAIL] DRAM Reads mismatch! Got %0d, expected 32", perf_dram_reads);
            fail_count++;
        end

        if (perf_dram_writes == 16) begin
            $display("[PASS] DRAM Writes match analytical model (16 outputs)");
            pass_count++;
        end else begin
            $display("[FAIL] DRAM Writes mismatch! Got %0d, expected 16", perf_dram_writes);
            fail_count++;
        end

        if (perf_sram_writes == 32) begin
            $display("[PASS] SRAM Refill Writes match buffer capacity (32 words)");
            pass_count++;
        end else begin
            $display("[FAIL] SRAM Writes mismatch! Got %0d, expected 32", perf_sram_writes);
            fail_count++;
        end

        // Check numerical output
        begin : check_block
            bit matrix_correct;
            matrix_correct = 1;
            for (int i = 0; i < ROWS; i++) begin
                for (int j = 0; j < COLS; j++) begin
                    if (captured_out[i][j] !== gold_outputs[i][j]) begin
                        matrix_correct = 0;
                        $display("  Mismatch at Output [%0d,%0d]: Got %0d, Expected %0d",
                                 i, j, captured_out[i][j], gold_outputs[i][j]);
                    end
                end
            end

            if (matrix_correct) begin
                $display("[PASS] Computed output written to DRAM matches golden GEMM perfectly!");
                pass_count++;
            end else begin
                $display("[FAIL] Output mismatch detected!");
                fail_count++;
            end
        end

        $display("\n==========================================================================");
        $display("  MEMORY COUNTER TEST SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> ACTUAL MEMORY TRAFFIC VERIFICATION: 100%% SUCCESS!\n");
        end else begin
            $display(">> ACTUAL MEMORY TRAFFIC VERIFICATION: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
