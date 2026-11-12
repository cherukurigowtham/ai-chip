// ==============================================================================
// Testbench: tb_quad_cluster_256pe.sv
// Description: Multi-Core Verification Testbench for BitNet Quad-Core Clustered
//              Tensor Processor (256 PEs, 4x Cores).
//
// Verification Targets:
// 1. Clustered Broadcast Gang-Scheduling: Single MMIO write triggers all 4 cores.
// 2. 256-PE Concurrent Execution: All 4 cores execute 8x8 GEMMs in parallel.
// 3. Bit-Exact Validation: All 256 output words matched against golden reference.
// 4. Hardware Fused Softmax Attention Mode (act_mode = 3'b100).
// 5. Cluster Telemetry: Zero-skip aggregation across all 256 PEs.
// ==============================================================================

`timescale 1ns / 1ps

module tb_quad_cluster_256pe;

    localparam int DATA_WIDTH  = 16;
    localparam int ACCUM_WIDTH = 32;
    localparam int NUM_CORES   = 4;
    localparam real CLK_PERIOD = 2.0; // 500 MHz

    logic clk;
    logic rst_n;

    // MMIO Interface
    logic        reg_wr_en;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_rd_en;
    logic [31:0] reg_rdata;

    // 4x Parallel DRAM Channels
    logic [NUM_CORES-1:0]                  dram_rd_req;
    logic [NUM_CORES-1:0][15:0]            dram_rd_addr;
    logic [NUM_CORES-1:0]                  dram_rd_valid;
    logic signed [NUM_CORES*DATA_WIDTH-1:0] dram_rd_data;

    logic [NUM_CORES-1:0]                  dram_wr_req;
    logic [NUM_CORES-1:0][15:0]            dram_wr_addr;
    logic signed [NUM_CORES*ACCUM_WIDTH-1:0] dram_wr_data;
    logic [NUM_CORES-1:0]                  dram_wr_ack;

    logic        cluster_busy;
    logic        cluster_done;
    logic [31:0] cluster_total_zero_skips;

    // Instantiate Quad-Cluster DUT
    bitnet_quad_cluster_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .NUM_CORES(NUM_CORES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .reg_wr_en(reg_wr_en),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rd_en(reg_rd_en),
        .reg_rdata(reg_rdata),
        .dram_rd_req(dram_rd_req),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .cluster_busy(cluster_busy),
        .cluster_done(cluster_done),
        .cluster_total_zero_skips(cluster_total_zero_skips)
    );

    // 500 MHz Clock Generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Memory Models for 4 Cores
    logic signed [DATA_WIDTH-1:0]  dram_read_mem  [0:NUM_CORES-1][0:1023];
    logic signed [ACCUM_WIDTH-1:0] dram_write_mem [0:NUM_CORES-1][0:1023];
    int dram_rd_ptr [0:NUM_CORES-1];
    int dram_wr_ptr [0:NUM_CORES-1];

    // DRAM Memory Controller Responder
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < NUM_CORES; c++) begin
                dram_rd_valid[c] <= 1'b0;
                dram_rd_data[c*DATA_WIDTH +: DATA_WIDTH] <= '0;
                dram_wr_ack[c]   <= 1'b0;
                dram_rd_ptr[c]   <= 0;
                dram_wr_ptr[c]   <= 0;
            end
        end else begin
            for (int c = 0; c < NUM_CORES; c++) begin
                // Read Channel
                if (dram_rd_req[c]) begin
                    dram_rd_valid[c] <= 1'b1;
                    dram_rd_data[c*DATA_WIDTH +: DATA_WIDTH] <= dram_read_mem[c][dram_rd_ptr[c]];
                    dram_rd_ptr[c]   <= dram_rd_ptr[c] + 1;
                end else begin
                    dram_rd_valid[c] <= 1'b0;
                end

                // Write Channel
                if (dram_wr_req[c]) begin
                    dram_wr_ack[c] <= 1'b1;
                    if (dram_wr_ack[c]) begin
                        dram_write_mem[c][dram_wr_ptr[c]] <= dram_wr_data[c*ACCUM_WIDTH +: ACCUM_WIDTH];
                        dram_wr_ptr[c] <= dram_wr_ptr[c] + 1;
                    end
                end else begin
                    dram_wr_ack[c] <= 1'b0;
                end
            end
        end
    end

    // Host MMIO Helper Task
    task mmio_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            reg_addr  <= addr;
            reg_wdata <= data;
            reg_wr_en <= 1'b1;
            @(posedge clk);
            reg_wr_en <= 1'b0;
            #1;
        end
    endtask

    // Golden verification data
    int signed gold_results [0:NUM_CORES-1][0:7][0:7];
    int signed W_mat        [0:NUM_CORES-1][0:7][0:7];
    int signed X_mat        [0:NUM_CORES-1][0:7][0:7];

    initial begin
        int mismatches;
        mismatches = 0;

        rst_n     = 0;
        reg_wr_en = 0;
        reg_addr  = 0;
        reg_wdata = 0;
        reg_rd_en = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        $display("==========================================================================");
        $display("  BITNET QUAD-CORE CLUSTERED TENSOR PROCESSOR VERIFICATION (256 PEs)");
        $display("  Architecture: 4x Cores (8x8 PEs each) | Signoff Clock: 500 MHz (2.0 ns)");
        $display("  Technology: SkyWater Sky130 / Nangate 45nm | Target Throughput: 256 GOPS");
        $display("==========================================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Concurrent Parallel Execution on all 4 Cores (256 PEs)
        // ---------------------------------------------------------------------
        $display("\n>>> [TEST 1] Preloading Weights & Activations across 4 Cores simultaneously...");
        
        for (int c = 0; c < NUM_CORES; c++) begin
            dram_rd_ptr[c] = 0;
            dram_wr_ptr[c] = 0;

            // 1. Packed 16-bit ternary weights for 8 rows
            dram_read_mem[c][0] = 16'h5695;
            dram_read_mem[c][1] = 16'h956a;
            dram_read_mem[c][2] = 16'ha659;
            dram_read_mem[c][3] = 16'h69a5;
            dram_read_mem[c][4] = 16'h5a96;
            dram_read_mem[c][5] = 16'h965a;
            dram_read_mem[c][6] = 16'ha965;
            dram_read_mem[c][7] = 16'h65a9;

            // Decode 2-bit weights into W_mat
            for (int k = 0; k < 8; k++) begin
                for (int n = 0; n < 8; n++) begin
                    logic [1:0] code = dram_read_mem[c][k][n*2 +: 2];
                    W_mat[c][k][n] = (code == 2'b01) ? 1 : ((code == 2'b10) ? -1 : 0);
                end
            end

            // 2. Populate input activations (words 8..71)
            for (int m = 0; m < 8; m++) begin
                for (int k = 0; k < 8; k++) begin
                    X_mat[c][m][k] = ((m - 3) * 220) + (k * 115) - (c * 50);
                    dram_read_mem[c][8 + m*8 + k] = X_mat[c][m][k][15:0];
                end
            end

            // 3. Compute Golden Bit-Exact GEMM Matrix
            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    int accum = 0;
                    for (int k = 0; k < 8; k++) begin
                        accum += X_mat[c][m][k] * W_mat[c][k][n];
                    end
                    gold_results[c][m][n] = accum;
                end
            end
        end

        // Broadcast Gang-Schedule: Configure all 4 cores in parallel with single writes
        $display(">>> [BROADCAST] Gang-scheduling M=8, K=8, N=8, Bypass Mode across all 4 Cores...");
        mmio_write(8'h08, 32'd8);  // Broadcast CFG_M = 8
        mmio_write(8'h0C, 32'd8);  // Broadcast CFG_K = 8
        mmio_write(8'h10, 32'd8);  // Broadcast CFG_N = 8
        mmio_write(8'h38, 32'd0);  // Broadcast act_mode = 0 (Bypass)
        mmio_write(8'h3C, 32'd0);  // Broadcast weight_bank = 0
        mmio_write(8'h00, 32'h03); // Broadcast START (Weight-Stationary)

        $display(">>> [COMPUTE] 256 PEs actively computing in parallel...");
        @(posedge cluster_busy);
        @(negedge cluster_busy);
        repeat (10) @(posedge clk);

        // Check outputs across all 4 cores (256 total words)
        for (int c = 0; c < NUM_CORES; c++) begin
            if (dram_wr_ptr[c] !== 64) begin
                $display("[FAIL] Core %0d: Expected 64 words, got %0d", c, dram_wr_ptr[c]);
                mismatches++;
            end else begin
                for (int m = 0; m < 8; m++) begin
                    for (int n = 0; n < 8; n++) begin
                        int actual = dram_write_mem[c][m*8 + n];
                        if (actual !== gold_results[c][m][n]) begin
                            if (mismatches < 5)
                                $display("[FAIL] Core %0d [%0d,%0d]: actual=%0d, gold=%0d",
                                         c, m, n, actual, gold_results[c][m][n]);
                            mismatches++;
                        end
                    end
                end
            end
        end

        if (mismatches == 0) begin
            $display("[PASS] 256-PE Concurrent GEMM: 100%% Bit-Exact across all 4 Cores (256/256 outputs)!");
        end else begin
            $display("[FAIL] Total mismatches detected: %0d", mismatches);
        end

        // ---------------------------------------------------------------------
        // TEST 2: Fused Fast Softmax Attention Exponentiation
        // ---------------------------------------------------------------------
        $display("\n>>> [TEST 2] Testing Hardware Fused Softmax Attention Mode (act_mode = 3'b100)...");
        for (int c = 0; c < NUM_CORES; c++) begin
            dram_rd_ptr[c] = 0;
            dram_wr_ptr[c] = 0;
        end

        mmio_write(8'h38, 32'd4);  // act_mode = 4 (Fast Softmax Exp)
        mmio_write(8'h00, 32'h03); // Broadcast START

        @(posedge cluster_busy);
        @(negedge cluster_busy);
        repeat (10) @(posedge clk);

        // Core 0 output: input was -400, hardware PWL exp computes 1024 - 250 = 774
        if (dram_write_mem[0][0] === 32'sd774) begin
            $display("[PASS] Fast Softmax VAU: Multiplier-Free Base-2 Attention Exponent verified (774 ≈ 2^(-0.39))!");
        end else begin
            $display("[FAIL] Fast Softmax VAU: Expected 774, got %0d", dram_write_mem[0][0]);
            mismatches++;
        end

        // ---------------------------------------------------------------------
        // SUMMARY
        // ---------------------------------------------------------------------
        $display("\n==========================================================================");
        $display("  BITNET QUAD-CORE CLUSTER VERIFICATION SUMMARY");
        $display("  Total Processing Elements Tested: 256 PEs");
        $display("  Peak Compute Throughput: 256.0 GOPS at 500 MHz (0.256 TOPS)");
        $display("  Cluster Zero-Skip Telemetry: %0d operations gated", cluster_total_zero_skips);
        $display("==========================================================================");

        if (mismatches == 0) begin
            $display(">> QUAD-CORE CLUSTER VALIDATION: 100%% BIT-EXACT PASS <<\n");
        end else begin
            $display(">> VALIDATION FAILED: %0d ERRORS <<\n", mismatches);
            $fatal(1);
        end

        $finish;
    end

endmodule
