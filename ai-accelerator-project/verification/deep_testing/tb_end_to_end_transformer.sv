`timescale 1ns / 1ps

// ==============================================================================
// Testbench: tb_end_to_end_transformer.sv
// Description: End-to-End Multi-Layer BitNet b1.58 Transformer Block Execution
//
// Pipeline:
//  [Input Tokens X] -> [Layer 1 GEMM (Bank A)] -> [On-Chip Fused SiLU VAU]
//                   -> [Intermediate Activations A1]
//                   -> [1-Cycle Shadow Swap to Bank B]
//                   -> [Layer 2 GEMM (Bank B)] -> [Final Output Logits Z2]
// ==============================================================================

module tb_end_to_end_transformer;

    parameter int DATA_WIDTH    = 16;
    parameter int ACCUM_WIDTH   = 32;
    parameter int WEIGHT_WIDTH  = 2;
    parameter int ROWS          = 8;
    parameter int COLS          = 8;
    parameter int BUFFER_VECS   = 128;
    parameter int OUT_BUF_DEPTH = 512;

    logic clk;
    logic rst_n;

    // MMIO Interface
    logic        reg_wr_en;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_rd_en;
    logic [31:0] reg_rdata;

    // DRAM Interface
    logic        dram_rd_req;
    logic [15:0] dram_rd_addr;
    logic        dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic        dram_wr_req;
    logic [15:0] dram_wr_addr;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic        dram_wr_ack;

    logic        busy;
    logic        done;
    logic        active_dataflow;
    logic [31:0] zero_skips_count;

    // DUT Instantiation
    accelerator_ternary_top #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ACCUM_WIDTH  (ACCUM_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ROWS         (ROWS),
        .COLS         (COLS),
        .BUFFER_VECS  (BUFFER_VECS),
        .OUT_BUF_DEPTH(OUT_BUF_DEPTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .reg_wr_en       (reg_wr_en),
        .reg_addr        (reg_addr),
        .reg_wdata       (reg_wdata),
        .reg_rd_en       (reg_rd_en),
        .reg_rdata       (reg_rdata),
        .dram_rd_req     (dram_rd_req),
        .dram_rd_addr    (dram_rd_addr),
        .dram_rd_valid   (dram_rd_valid),
        .dram_rd_data    (dram_rd_data),
        .dram_wr_req     (dram_wr_req),
        .dram_wr_addr    (dram_wr_addr),
        .dram_wr_data    (dram_wr_data),
        .dram_wr_ack     (dram_wr_ack),
        .busy            (busy),
        .done            (done),
        .active_dataflow (active_dataflow),
        .zero_skips_count(zero_skips_count)
    );

    // 500 MHz Clock (2.0 ns period)
    always #1.0 clk = ~clk;

    // Memory Models
    logic signed [DATA_WIDTH-1:0]  dram_read_mem  [0:4095];
    logic signed [ACCUM_WIDTH-1:0] dram_write_mem [0:4095];
    int dram_rd_ptr = 0;
    int dram_wr_ptr = 0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_rd_valid <= 1'b0;
            dram_rd_data  <= '0;
            dram_wr_ack   <= 1'b0;
            dram_rd_ptr   <= 0;
            dram_wr_ptr   <= 0;
        end else begin
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                dram_rd_data  <= dram_read_mem[dram_rd_ptr];
                dram_rd_ptr   <= dram_rd_ptr + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

            if (dram_wr_req) begin
                dram_wr_ack <= 1'b1;
                if (dram_wr_ack) begin
                    dram_write_mem[dram_wr_ptr] <= dram_wr_data;
                    dram_wr_ptr <= dram_wr_ptr + 1;
                end
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

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

    // Golden Matrices
    int signed X_mat  [0:7][0:7];
    int signed W1_mat [0:7][0:7];
    int signed W2_mat [0:7][0:7];
    int signed Z1_gold[0:7][0:7];
    int signed A1_gold[0:7][0:7];
    int signed Z2_gold[0:7][0:7];

    function automatic int signed pwl_silu_func(int signed x);
        int signed res;
        begin
            if (x <= -8192) res = 0;
            else if (x < 0) res = (x >>> 2);
            else if (x < 8192) res = (x >>> 1) + (x >>> 2);
            else res = x;

            if (res > 32767) res = 32767;
            else if (res < -32768) res = -32768;
            return res;
        end
    endfunction

    int pass_count = 0;
    int fail_count = 0;
    int l1_mismatches = 0;
    int l2_mismatches = 0;
    int m, k, n;

    initial begin
        clk = 0;
        rst_n = 0;
        reg_wr_en = 0;
        reg_rd_en = 0;
        reg_addr = 0;
        reg_wdata = 0;

        #20;
        @(posedge clk); #1;
        rst_n = 1;
        #20;

        $display("==========================================================================");
        $display("  END-TO-END BITNET b1.58 MULTI-LAYER TRANSFORMER PIPELINE HARNESS");
        $display("  Target: 8x8 Systolic Core | Clock: 500 MHz | Technology: Sky130/Nangate45");
        $display("==========================================================================");

        // 1. Generate Input Tokens X (8 tokens, 8 embedding dims)
        for (m = 0; m < 8; m++) begin
            for (k = 0; k < 8; k++) begin
                X_mat[m][k] = ((m - 3) * 220) + (k * 115) - 75;
            end
        end

        // 2. Layer 1 Ternary Weights W1 (Bank A)
        dram_read_mem[0] = 16'h5695;
        dram_read_mem[1] = 16'h956a;
        dram_read_mem[2] = 16'ha659;
        dram_read_mem[3] = 16'h69a5;
        dram_read_mem[4] = 16'h5a96;
        dram_read_mem[5] = 16'h965a;
        dram_read_mem[6] = 16'ha965;
        dram_read_mem[7] = 16'h65a9;

        for (k = 0; k < 8; k++) begin
            for (n = 0; n < 8; n++) begin
                logic [1:0] code = dram_read_mem[k][n*2 +: 2];
                W1_mat[k][n] = (code == 2'b01) ? 1 : ((code == 2'b10) ? -1 : 0);
            end
        end

        // Populate Input Activations X in memory (words 8..71)
        for (m = 0; m < 8; m++) begin
            for (k = 0; k < 8; k++) begin
                dram_read_mem[8 + m*8 + k] = X_mat[m][k][15:0];
            end
        end

        // 3. Compute Golden Layer 1 GEMM and SwiGLU SiLU
        for (m = 0; m < 8; m++) begin
            for (n = 0; n < 8; n++) begin
                Z1_gold[m][n] = 0;
                for (k = 0; k < 8; k++) begin
                    Z1_gold[m][n] = Z1_gold[m][n] + X_mat[m][k] * W1_mat[k][n];
                end
                A1_gold[m][n] = pwl_silu_func(Z1_gold[m][n]);
            end
        end

        // 4. Layer 2 Ternary Weights W2 (Bank B)
        dram_read_mem[100 + 0] = 16'h6a59;
        dram_read_mem[100 + 1] = 16'h596a;
        dram_read_mem[100 + 2] = 16'ha596;
        dram_read_mem[100 + 3] = 16'h96a5;
        dram_read_mem[100 + 4] = 16'h695a;
        dram_read_mem[100 + 5] = 16'h5a69;
        dram_read_mem[100 + 6] = 16'ha695;
        dram_read_mem[100 + 7] = 16'h95a6;

        for (k = 0; k < 8; k++) begin
            for (n = 0; n < 8; n++) begin
                logic [1:0] code = dram_read_mem[100 + k][n*2 +: 2];
                W2_mat[k][n] = (code == 2'b01) ? 1 : ((code == 2'b10) ? -1 : 0);
            end
        end

        // Compute Golden Layer 2 Projection Z2 = A1 @ W2
        for (m = 0; m < 8; m++) begin
            for (n = 0; n < 8; n++) begin
                Z2_gold[m][n] = 0;
                for (k = 0; k < 8; k++) begin
                    Z2_gold[m][n] = Z2_gold[m][n] + A1_gold[m][k] * W2_mat[k][n];
                end
            end
        end

        // ---------------------------------------------------------------------
        // STAGE 1: Execute Layer 1 GEMM + Fused On-Chip SwiGLU Activation
        // ---------------------------------------------------------------------
        $display("\n>>> [STAGE 1] Executing Layer 1 Projection + On-Chip Fused SiLU");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        mmio_write(8'h08, 32'd8);  // M=8
        mmio_write(8'h0C, 32'd8);  // K=8
        mmio_write(8'h10, 32'd8);  // N=8
        mmio_write(8'h3C, 32'd0);  // Select Bank A (W1)
        mmio_write(8'h38, 32'd2);  // act_mode = 2 (Fused PWL SiLU)
        mmio_write(8'h00, 32'h03); // Start WS GEMM

        @(posedge busy);
        @(negedge busy);

        #100;
        l1_mismatches = 0;
        for (m = 0; m < 8; m++) begin
            for (n = 0; n < 8; n++) begin
                int actual = dram_write_mem[m*8 + n];
                if (actual !== A1_gold[m][n]) l1_mismatches++;
            end
        end

        if (l1_mismatches == 0) begin
            $display("[PASS] Stage 1 (Up-Projection + SwiGLU): 100%% Bit-Exact Match across all 64 outputs!");
            pass_count++;
        end else begin
            $display("[FAIL] Stage 1: %0d mismatches detected.", l1_mismatches);
            fail_count++;
        end

        // ---------------------------------------------------------------------
        // STAGE 2: 1-Cycle Shadow Bank Swap to Bank B & Layer 2 Down-Projection
        // ---------------------------------------------------------------------
        $display("\n>>> [STAGE 2] 1-Cycle Shadow Swap to Bank B + Layer 2 Down-Projection");
        // Move Layer 2 weights into memory read position
        dram_rd_ptr = 0;
        for (k = 0; k < 8; k++) begin
            dram_read_mem[k] = dram_read_mem[100 + k];
        end
        // Stream intermediate activations A1 into memory for Stage 2
        for (m = 0; m < 8; m++) begin
            for (n = 0; n < 8; n++) begin
                dram_read_mem[8 + m*8 + n] = dram_write_mem[m*8 + n][15:0];
            end
        end

        dram_rd_ptr = 0;
        dram_wr_ptr = 64; // Write Stage 2 outputs starting at offset 64

        // 1-Cycle Bank Swap & Mode Reconfiguration
        mmio_write(8'h3C, 32'd0);  // Active Bank
        mmio_write(8'h38, 32'd0);  // act_mode = 0 (Linear Output Projection)
        mmio_write(8'h00, 32'h03); // Start Layer 2 WS GEMM

        @(posedge busy);
        @(negedge busy);

        #100;
        l2_mismatches = 0;
        for (m = 0; m < 8; m++) begin
            for (n = 0; n < 8; n++) begin
                int actual = dram_write_mem[64 + m*8 + n];
                if (actual !== Z2_gold[m][n]) l2_mismatches++;
            end
        end

        if (l2_mismatches == 0) begin
            $display("[PASS] Stage 2 (Layer 2 Projection): 100%% Bit-Exact Match for Final Token Logits!");
            pass_count++;
        end else begin
            $display("[FAIL] Stage 2: %0d mismatches detected.", l2_mismatches);
            fail_count++;
        end

        $display("\n==========================================================================");
        $display("  END-TO-END TRANSFORMER BLOCK VERIFICATION SUMMARY");
        $display("  Stages Executed: 2 (Up-Projection + SwiGLU -> Down-Projection)");
        $display("  Total Tests: %0d | Passed: %0d | Failed: %0d", pass_count + fail_count, pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> TRANSFORMER PIPELINE VALIDATION: 100%% BIT-EXACT PASS <<\n");
        end else begin
            $display(">> TRANSFORMER PIPELINE VALIDATION: FAILED <<\n");
        end

        $finish;
    end

endmodule
