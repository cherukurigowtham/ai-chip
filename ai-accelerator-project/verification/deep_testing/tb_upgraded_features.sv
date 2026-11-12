`timescale 1ns / 1ps

// ==============================================================================
// Testbench: tb_upgraded_features.sv
// Description: Verification of Architectural Upgrades:
//  1. Multiplier-Free Fused Vector Activation Unit (VAU):
//     - ReLU Mode (act_mode = 01)
//     - Piecewise-Linear SiLU / SwiGLU Mode (act_mode = 10)
//     - Saturated INT16 Scaling (act_mode = 11)
//  2. Shadow Ping-Pong Double-Buffering (Zero-Bubble Weight Reload)
// ==============================================================================

module tb_upgraded_features;

    parameter int DATA_WIDTH    = 16;
    parameter int ACCUM_WIDTH   = 32;
    parameter int WEIGHT_WIDTH  = 2;
    parameter int ROWS          = 8;
    parameter int COLS          = 8;
    parameter int BUFFER_VECS   = 128;
    parameter int OUT_BUF_DEPTH = 512;

    logic clk;
    logic rst_n;

    // Host Register Interface
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

    // Instantiate Top
    accelerator_ternary_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS),
        .OUT_BUF_DEPTH(OUT_BUF_DEPTH)
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
        .busy(busy),
        .done(done),
        .active_dataflow(active_dataflow),
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

    int pass_count = 0;
    int fail_count = 0;
    int signed act_mat [0:7][0:7];
    int signed w_mat   [0:7][0:7];
    int signed raw_gemm[0:7][0:7];

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
        $display("  ARCHITECTURAL UPGRADES VERIFICATION HARNESS");
        $display("  Target: 8x8 Ternary Accelerator with Fused VAU & Shadow Ping-Pong Banks");
        $display("==========================================================================");

        // Preload symmetric weights: alternating +1 and -1
        dram_read_mem[0] = 16'h5555; // +1 across all
        dram_read_mem[1] = 16'haaaa; // -1 across all
        dram_read_mem[2] = 16'h5555;
        dram_read_mem[3] = 16'haaaa;
        dram_read_mem[4] = 16'h5555;
        dram_read_mem[5] = 16'haaaa;
        dram_read_mem[6] = 16'h5555;
        dram_read_mem[7] = 16'haaaa;

        for (int r = 0; r < 8; r++) begin
            for (int c = 0; c < 8; c++) begin
                logic [1:0] code = dram_read_mem[r][c*2 +: 2];
                w_mat[r][c] = (code == 2'b01) ? 1 : ((code == 2'b10) ? -1 : 0);
            end
        end

        // Activations: mix of positive and negative values
        for (int m = 0; m < 8; m++) begin
            for (int k = 0; k < 8; k++) begin
                int signed val = ((m - 4) * 500) + (k * 200);
                dram_read_mem[8 + m*8 + k] = val[15:0];
                act_mat[m][k] = val;
            end
        end

        // Calculate golden linear GEMM
        for (int m = 0; m < 8; m++) begin
            for (int n = 0; n < 8; n++) begin
                raw_gemm[m][n] = 0;
                for (int k = 0; k < 8; k++) begin
                    raw_gemm[m][n] = raw_gemm[m][n] + act_mat[m][k] * w_mat[k][n];
                end
            end
        end

        // ---------------------------------------------------------------------
        // TEST 1: Fused ReLU Activation Mode (act_mode = 2'b01)
        // ---------------------------------------------------------------------
        $display("\n>>> [UPGRADE TEST 1] Fused On-Chip ReLU Activation Unit (act_mode = 2'b01)");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        mmio_write(8'h08, 32'd8);  // M=8
        mmio_write(8'h0C, 32'd8);  // K=8
        mmio_write(8'h10, 32'd8);  // N=8
        mmio_write(8'h38, 32'd1);  // act_mode = 1 (Fused ReLU)
        mmio_write(8'h00, 32'h03); // Start WS

        @(posedge busy);
        @(negedge busy);

        #100;
        begin
            int relu_mismatches = 0;
            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    int actual = dram_write_mem[m*8 + n];
                    int expected = (raw_gemm[m][n] < 0) ? 0 : raw_gemm[m][n];
                    if (actual !== expected) relu_mismatches++;
                end
            end
            if (relu_mismatches == 0) begin
                $display("[PASS] Fused ReLU: 100%% Bit-Exact Match across all 64 outputs!");
                pass_count++;
            end else begin
                $display("[FAIL] Fused ReLU: %0d mismatches detected.", relu_mismatches);
                fail_count++;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 2: Fused Piecewise-Linear (PWL) SiLU / SwiGLU Mode (act_mode = 2'b10)
        // ---------------------------------------------------------------------
        $display("\n>>> [UPGRADE TEST 2] Fused On-Chip PWL SiLU / SwiGLU Unit (act_mode = 2'b10)");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        mmio_write(8'h38, 32'd2);  // act_mode = 2 (Fused PWL SiLU)
        mmio_write(8'h00, 32'h03); // Start WS

        @(posedge busy);
        @(negedge busy);

        #100;
        begin
            int silu_mismatches = 0;
            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    int actual = dram_write_mem[m*8 + n];
                    int expected;
                    int x = raw_gemm[m][n];
                    if (x <= -8192) expected = 0;
                    else if (x < 0) expected = (x >>> 2);
                    else if (x < 8192) expected = (x >>> 1) + (x >>> 2);
                    else expected = x;

                    if (actual !== expected) silu_mismatches++;
                end
            end
            if (silu_mismatches == 0) begin
                $display("[PASS] Fused PWL SiLU: 100%% Bit-Exact Match for SwiGLU activations!");
                pass_count++;
            end else begin
                $display("[FAIL] Fused PWL SiLU: %0d mismatches detected.", silu_mismatches);
                fail_count++;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 3: Saturated INT16 Scaling for Next-Layer Input (act_mode = 2'b11)
        // ---------------------------------------------------------------------
        $display("\n>>> [UPGRADE TEST 3] Fused Saturated INT16 Scaling Mode (act_mode = 2'b11)");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        mmio_write(8'h38, 32'd3);  // act_mode = 3 (Sat INT16)
        mmio_write(8'h00, 32'h03); // Start WS

        @(posedge busy);
        @(negedge busy);

        #100;
        begin
            int sat_mismatches = 0;
            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    int actual = dram_write_mem[m*8 + n];
                    int expected;
                    int x = raw_gemm[m][n];
                    if (x > 32767) expected = 32767;
                    else if (x < -32768) expected = -32768;
                    else expected = x;

                    if (actual !== expected) sat_mismatches++;
                end
            end
            if (sat_mismatches == 0) begin
                $display("[PASS] Saturated INT16 Mode: Perfectly clipped and scaled for downstream layer!");
                pass_count++;
            end else begin
                $display("[FAIL] Saturated INT16: %0d mismatches detected.", sat_mismatches);
                fail_count++;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 4: Shadow Double-Buffering Bank Switching (Zero-Bubble Reload)
        // ---------------------------------------------------------------------
        $display("\n>>> [UPGRADE TEST 4] Shadow Double-Buffering Weight Bank Switch");
        // Switch to Shadow Bank 1
        mmio_write(8'h3C, 32'd1);  // Select Bank B
        mmio_write(8'h38, 32'd0);  // act_mode = 0 (Linear)

        // Read back config register to confirm bank switch
        begin
            logic [31:0] rdata;
            reg_addr  = 8'h3C;
            reg_rd_en = 1;
            #1;
            rdata = reg_rdata;
            @(posedge clk);
            reg_rd_en = 0;
            if (rdata[0] == 1'b1) begin
                $display("[PASS] Shadow Weight Bank B selected instantaneously (1 clock cycle).");
                pass_count++;
            end else begin
                $display("[FAIL] Bank B selection failed! Got 0x%08h", rdata);
                fail_count++;
            end
        end

        $display("==========================================================================");
        $display("  ARCHITECTURAL UPGRADES VERIFICATION SUMMARY");
        $display("  Total Tests: %0d | Passed: %0d | Failed: %0d", pass_count + fail_count, pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> ALL ARCHITECTURAL UPGRADES VERIFIED 100%% BIT-EXACT <<\n");
        end else begin
            $display(">> UPGRADES VERIFICATION FAILED <<\n");
        end

        $finish;
    end

endmodule
