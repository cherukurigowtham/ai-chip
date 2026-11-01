// ==============================================================================
// Gate-Level Testbench: tb_accelerator_ternary_8x8_gate
// Description: Post-route gate-level verification for 8x8 accelerator_ternary_top
//              using Nangate 45nm standard cell library and back-annotated SDF
//              extracted timing from OpenROAD.
// ==============================================================================

`timescale 1ns / 1ps

module tb_accelerator_ternary_8x8_gate;

    localparam int DATA_WIDTH    = 16;
    localparam int ACCUM_WIDTH   = 32;
    localparam real CLK_PERIOD   = 2.0; // 500 MHz (2.0 ns clock period)

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

    // Instantiate Routed Gate-Level Netlist (Unparameterized 8x8 Core)
    accelerator_ternary_top dut (
        .active_dataflow(active_dataflow),
        .busy(busy),
        .clk(clk),
        .done(done),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_data(dram_rd_data),
        .dram_rd_req(dram_rd_req),
        .dram_rd_valid(dram_rd_valid),
        .dram_wr_ack(dram_wr_ack),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_req(dram_wr_req),
        .reg_addr(reg_addr),
        .reg_rd_en(reg_rd_en),
        .reg_rdata(reg_rdata),
        .reg_wdata(reg_wdata),
        .reg_wr_en(reg_wr_en),
        .rst_n(rst_n),
        .zero_skips_count(zero_skips_count)
    );

    // Constant low/high nets are driven by standard cell tie cells (LOGIC0_X1, LOGIC1_X1) inserted during synthesis.

    // SDF Timing Annotation
    initial begin
`ifdef USE_SDF
        $display("[GATE-SIM] Annotating 8x8 post-route extracted SDF timing from OpenROAD...");
        $sdf_annotate("/Users/gowthamcherukuri/Desktop/ai_chip/ai-accelerator-project/ternary/physical/openroad_8x8_run/accelerator_ternary_top.sdf", dut);
`endif
    end

    // 500 MHz Clock Generation (2.0 ns period)
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Emulated DRAM Storage
    logic [DATA_WIDTH-1:0]         dram_read_mem  [0:8191];
    logic signed [ACCUM_WIDTH-1:0] dram_write_mem [0:8191];
    int dram_rd_ptr = 0;
    int dram_wr_ptr = 0;

    // Emulated DRAM Responder (1-cycle read latency, 1-cycle write ack)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_rd_valid <= 1'b0;
            dram_rd_data  <= '0;
            dram_wr_ack   <= 1'b0;
            dram_rd_ptr   <= 0;
            dram_wr_ptr   <= 0;
        end else begin
            // Read channel
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                dram_rd_data  <= dram_read_mem[dram_rd_ptr];
                dram_rd_ptr   <= dram_rd_ptr + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Write channel (Pipelined DRAM Handshake)
            dram_wr_ack <= dram_wr_req;
            if (dram_wr_req && dram_wr_ack) begin
                dram_write_mem[dram_wr_ptr] <= dram_wr_data;
                dram_wr_ptr <= dram_wr_ptr + 1;
            end
        end
    end

    // Verification task: Host MMIO write
    task mmio_write(input [7:0] addr, input [31:0] data);
        @(negedge clk);
        reg_wr_en = 1'b1;
        reg_addr  = addr;
        reg_wdata = data;
        @(negedge clk);
        reg_wr_en = 1'b0;
    endtask

    // Bookkeeping
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;

    int signed act_mat [0:15][0:7];
    int signed w_mat   [0:15][0:7];
    int signed c_gold  [0:15][0:7];

    initial begin
        // VCD dumping disabled for 38k-cell gate simulation speed
        // $dumpfile("gate_8x8_sim.vcd");
        // $dumpvars(0, tb_accelerator_ternary_8x8_gate);

        rst_n     = 0;
        reg_wr_en = 0;
        reg_addr  = 0;
        reg_wdata = 0;
        reg_rd_en = 0;

        #20;
        @(negedge clk);
        rst_n     = 1;
        @(negedge clk);
        $display("[GATE-SIM] Released reset. rst_n=%b busy=%b", rst_n, busy);

        $display("\n===============================================================");
        $display("  STARTING 8x8 POST-ROUTE GATE-LEVEL INTEGRATION REGRESSION");
        $display("  Target Clock: 500 MHz (2.0 ns) | Mesh: 8x8 | Tech: Nangate 45nm");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Weight-Stationary 8x8 GEMM Execution
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 1] Weight-Stationary 8x8 GEMM Execution ---");

        dram_read_mem[0] = 16'h2449;
        dram_read_mem[1] = 16'h4992;
        dram_read_mem[2] = 16'h1248;
        dram_read_mem[3] = 16'h9224;
        dram_read_mem[4] = 16'h5555;
        dram_read_mem[5] = 16'haaaa;
        dram_read_mem[6] = 16'h0000;
        dram_read_mem[7] = 16'h6996;

        for (int r = 0; r < 8; r++) begin
            for (int c = 0; c < 8; c++) begin
                logic [1:0] code;
                code = dram_read_mem[r][c*2 +: 2];
                if (code == 2'b01)      w_mat[r][c] = 1;
                else if (code == 2'b10) w_mat[r][c] = -1;
                else                    w_mat[r][c] = 0;
            end
        end

        for (int m = 0; m < 8; m++) begin
            for (int k = 0; k < 8; k++) begin
                int signed val;
                val = ((m + 1) * 100) - (k * 150);
                dram_read_mem[8 + m*8 + k] = val[15:0];
                act_mat[m][k] = val;
            end
        end

        for (int m = 0; m < 8; m++) begin
            for (int n = 0; n < 8; n++) begin
                c_gold[m][n] = 0;
                for (int k = 0; k < 8; k++) begin
                    c_gold[m][n] = c_gold[m][n] + act_mat[m][k] * w_mat[k][n];
                end
            end
        end

        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        $display("[GATE-SIM] Writing MMIO registers...");
        mmio_write(8'h08, 32'd8);
        mmio_write(8'h0C, 32'd8);
        mmio_write(8'h10, 32'd8);
        mmio_write(8'h00, 32'h03); // Force WS, Start
        $display("[GATE-SIM] MMIO written. Waiting for posedge busy... current busy=%b", busy);

        @(posedge busy);
        @(negedge busy);

        total_tests++;
        if (dram_wr_ptr == 64) begin
            $display("[PASS] WS Mode wrote exact 64 output words (8x8 tile) to DRAM.");
            passed_tests++;
        end else begin
            $display("[FAIL] WS Mode expected 64 words, got %0d words.", dram_wr_ptr);
            failed_tests++;
        end

        total_tests++;
        begin
            int mismatches = 0;
            $display("[DEBUG] Expected Row 0: %0d %0d %0d %0d %0d %0d %0d %0d",
                     c_gold[0][0], c_gold[0][1], c_gold[0][2], c_gold[0][3],
                     c_gold[0][4], c_gold[0][5], c_gold[0][6], c_gold[0][7]);
            $display("[DEBUG] Actual DRAM[0..7]: %0d %0d %0d %0d %0d %0d %0d %0d",
                     dram_write_mem[0], dram_write_mem[1], dram_write_mem[2], dram_write_mem[3],
                     dram_write_mem[4], dram_write_mem[5], dram_write_mem[6], dram_write_mem[7]);
            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    int actual;
                    actual = dram_write_mem[m*8 + n];
                    if (actual !== c_gold[m][n]) begin
                        $display("[ERROR] Gate-Level Mismatch at [%0d][%0d]: expected %0d, got %0d",
                                 m, n, c_gold[m][n], actual);
                        mismatches++;
                    end
                end
            end
            if (mismatches == 0) begin
                $display("[PASS] WS 8x8 Gate-Level: 100%% BIT-EXACT MATCH across all 64 outputs!");
                passed_tests++;
            end else begin
                $display("[FAIL] WS 8x8 Gate-Level: %0d mismatches detected!", mismatches);
                failed_tests++;
            end
        end

        total_tests++;
        if (zero_skips_count > 0) begin
            $display("[INFO] Total 8x8 PE Zero-Skips tracked: %0d", zero_skips_count);
            $display("[PASS] Zero-weight skipping successfully recorded by telemetry.");
            passed_tests++;
        end else begin
            $display("[FAIL] Telemetry reported 0 zero-skips.");
            failed_tests++;
        end

        // ---------------------------------------------------------------------
        // TEST 2: Back-to-Back OS GEMM (Deep Reduction K=16, M=8, N=8)
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 2] Back-to-Back OS GEMM (Deep Reduction K=16, M=8, N=8) ---");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        for (int k = 0; k < 16; k++) begin
            for (int r = 0; r < 8; r++) begin
                int signed val;
                val = ((k + 1) * 50) - (r * 30);
                dram_read_mem[k*8 + r] = val[15:0];
                act_mat[k][r] = val;
            end
        end

        for (int k = 0; k < 16; k++) begin
            logic [15:0] w_word;
            w_word = 16'h5a5a ^ (k << 8) ^ k;
            dram_read_mem[128 + k] = w_word;
            for (int c = 0; c < 8; c++) begin
                logic [1:0] code;
                code = w_word[c*2 +: 2];
                if (code == 2'b01)      w_mat[k][c] = 1;
                else if (code == 2'b10) w_mat[k][c] = -1;
                else                    w_mat[k][c] = 0;
            end
        end

        for (int r = 0; r < 8; r++) begin
            for (int c = 0; c < 8; c++) begin
                c_gold[r][c] = 0;
                for (int k = 0; k < 16; k++) begin
                    c_gold[r][c] = c_gold[r][c] + act_mat[k][r] * w_mat[k][c];
                end
            end
        end

        mmio_write(8'h08, 32'd8);
        mmio_write(8'h0C, 32'd16);
        mmio_write(8'h10, 32'd8);
        mmio_write(8'h00, 32'h01); // Auto mode

        @(posedge busy);
        total_tests++;
        if (active_dataflow == 1'b1) begin
            $display("[PASS] Autonomous Controller dynamically selected Output-Stationary (OS) mode for K=16 > M=8!");
            passed_tests++;
        end else begin
            $display("[FAIL] Autonomous Controller failed to select OS mode.");
            failed_tests++;
        end

        @(negedge busy);
        total_tests++;
        if (dram_wr_ptr == 64) begin
            $display("[PASS] OS Mode successfully drained 64 output words (8x8 tile) to DRAM.");
            passed_tests++;
        end else begin
            $display("[FAIL] OS Mode expected 64 words, got %0d words.", dram_wr_ptr);
            failed_tests++;
        end

        total_tests++;
        begin
            int mismatches = 0;
            for (int r = 0; r < 8; r++) begin
                for (int c = 0; c < 8; c++) begin
                    int actual;
                    actual = dram_write_mem[r*8 + c];
                    if (actual !== c_gold[r][c]) begin
                        $display("[ERROR] OS Gate-Level Mismatch at [%0d][%0d]: expected %0d, got %0d",
                                 r, c, c_gold[r][c], actual);
                        mismatches++;
                    end
                end
            end
            if (mismatches == 0) begin
                $display("[PASS] OS 8x8 Gate-Level Deep-Reduction: 100%% BIT-EXACT MATCH across all 64 outputs!");
                passed_tests++;
            end else begin
                $display("[FAIL] OS 8x8 Gate-Level Deep-Reduction: %0d mismatches detected!", mismatches);
                failed_tests++;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 3: Extreme Signed Dynamic Range (+30,000 / -30,000)
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 3] Extreme Signed Dynamic Range (+30,000 / -30,000) ---");
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        for (int r = 0; r < 4; r++) dram_read_mem[r] = 16'h5555;
        for (int r = 4; r < 8; r++) dram_read_mem[r] = 16'haaaa;

        for (int m = 0; m < 8; m++) begin
            for (int k = 0; k < 4; k++) dram_read_mem[8 + m*8 + k] = 16'sd30000;
            for (int k = 4; k < 8; k++) dram_read_mem[8 + m*8 + k] = -16'sd30000;
        end

        mmio_write(8'h08, 32'd8);
        mmio_write(8'h0C, 32'd8);
        mmio_write(8'h10, 32'd8);
        mmio_write(8'h00, 32'h03);

        @(posedge busy);
        @(negedge busy);

        total_tests++;
        if (dram_write_mem[0] == 240000) begin
            $display("[PASS] Extreme Signed Range Verified: Output[0] = %0d (Expected 240,000).", dram_write_mem[0]);
            passed_tests++;
        end else begin
            $display("[FAIL] Extreme Signed Range failed: Output[0] = %0d (Expected 240,000).", dram_write_mem[0]);
            failed_tests++;
        end

        $display("\n===============================================================");
        $display("  8x8 TERNARY ACCELERATOR POST-ROUTE GATE-LEVEL SUMMARY");
        $display("  TOTAL TESTS: %0d | PASSED: %0d | FAILED: %0d", total_tests, passed_tests, failed_tests);
        $display("===============================================================\n");

        if (failed_tests == 0) begin
            $display(">> FULL 8x8 TERNARY ACCELERATOR POST-ROUTE GATE-LEVEL: SUCCESS!\n");
        end else begin
            $display(">> FULL 8x8 TERNARY ACCELERATOR POST-ROUTE GATE-LEVEL: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
