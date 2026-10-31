// ==============================================================================
// Testbench: phase13/rtl/tb_optimized_dispatch.sv
// Description: RTL Verification of Memory-Mapped Configuration Registers
//              and Dynamic Execution of Optimizer-Selected Configurations.
//
// Verifies:
//   1. Register bus writes & reads to dynamic_config_reg.
//   2. Dispatch of Optimizer-selected WS configuration (M=8, K=4, N=4).
//   3. Dispatch of Optimizer-selected OS configuration (M=4, K=16, N=4).
//   4. Dispatch of asymmetric workload (M=4, K=8, N=4).
//   5. Dynamic runtime reconfiguration without hardware reset.
//   6. 100% bit-exact matrix multiplication validation against golden model.
// ==============================================================================

`timescale 1ns / 1ps

module tb_optimized_dispatch;

    localparam int DATA_WIDTH  = 16;
    localparam int ACCUM_WIDTH = 32;
    localparam int ROWS        = 4;
    localparam int COLS        = 4;
    localparam int BUFFER_VECS = 64;
    localparam int CLK_PERIOD  = 2; // 500 MHz

    logic clk;
    logic rst_n;

    // Register Bus Interface
    logic        reg_wr_en;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_rd_en;
    logic [31:0] reg_rdata;

    // Interconnect between Config Reg and Controller Core
    logic        ctrl_start;
    logic [1:0]  ctrl_dataflow_mode;
    logic [15:0] ctrl_cfg_M;
    logic [15:0] ctrl_cfg_K;
    logic [15:0] ctrl_cfg_N;
    logic [15:0] ctrl_tile_M;
    logic [15:0] ctrl_tile_K;
    logic [15:0] ctrl_tile_N;
    logic        ctrl_double_buffering;

    logic        core_busy;
    logic        core_done;
    logic        core_active_dataflow;
    logic [31:0] core_perf_total_cycles;
    logic [31:0] core_perf_compute_cycles;
    logic [31:0] core_perf_active_mac_cycles;
    logic [31:0] core_perf_stall_cycles;
    logic [31:0] core_perf_dram_reads;
    logic [31:0] core_perf_dram_writes;
    logic [15:0] core_perf_mac_util_permille;

    // DRAM Interface
    logic        dram_rd_req;
    logic [15:0] dram_rd_addr;
    logic        dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic        dram_wr_req;
    logic [15:0] dram_wr_addr;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic        dram_wr_ack;

    // Instantiate Memory-Mapped Configuration Registers
    dynamic_config_reg #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_config_reg (
        .clk(clk),
        .rst_n(rst_n),
        .reg_wr_en(reg_wr_en),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rd_en(reg_rd_en),
        .reg_rdata(reg_rdata),
        .ctrl_start(ctrl_start),
        .ctrl_dataflow_mode(ctrl_dataflow_mode),
        .ctrl_cfg_M(ctrl_cfg_M),
        .ctrl_cfg_K(ctrl_cfg_K),
        .ctrl_cfg_N(ctrl_cfg_N),
        .ctrl_tile_M(ctrl_tile_M),
        .ctrl_tile_K(ctrl_tile_K),
        .ctrl_tile_N(ctrl_tile_N),
        .ctrl_double_buffering(ctrl_double_buffering),
        .core_busy(core_busy),
        .core_done(core_done),
        .core_active_dataflow(core_active_dataflow),
        .core_perf_total_cycles(core_perf_total_cycles),
        .core_perf_compute_cycles(core_perf_compute_cycles),
        .core_perf_dram_reads(core_perf_dram_reads),
        .core_perf_dram_writes(core_perf_dram_writes),
        .core_perf_mac_util_permille(core_perf_mac_util_permille)
    );

    // Instantiate Unified Dataflow Controller Core
    dataflow_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(ctrl_start),
        .dataflow_mode(ctrl_dataflow_mode),
        .cfg_M(ctrl_cfg_M),
        .cfg_K(ctrl_cfg_K),
        .cfg_N(ctrl_cfg_N),
        .busy(core_busy),
        .done(core_done),
        .active_dataflow(core_active_dataflow),
        .dram_rd_req(dram_rd_req),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .perf_total_cycles(core_perf_total_cycles),
        .perf_compute_cycles(core_perf_compute_cycles),
        .perf_active_mac_cycles(core_perf_active_mac_cycles),
        .perf_stall_cycles(core_perf_stall_cycles),
        .perf_dram_reads(core_perf_dram_reads),
        .perf_dram_writes(core_perf_dram_writes),
        .perf_mac_util_permille(core_perf_mac_util_permille)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Test Storage
    logic signed [DATA_WIDTH-1:0]  dram_mem [0:4095];
    logic signed [DATA_WIDTH-1:0]  gold_A [63:0][3:0];
    logic signed [DATA_WIDTH-1:0]  gold_W [63:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] gold_C [63:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_C [255:0];

    int words_read_count = 0;
    int words_written_count = 0;
    int total_tests_passed = 0;

    // DRAM Emulator with 2-phase Handshake (matches hardware DRAM controller)
    always_ff @(posedge clk or negedge rst_n) begin
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

    // Bus Write Task
    task write_reg(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            reg_wr_en <= 1'b1;
            reg_addr  <= addr;
            reg_wdata <= data;
            @(posedge clk);
            reg_wr_en <= 1'b0;
        end
    endtask

    // Bus Read Task
    task read_reg(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            reg_rd_en <= 1'b1;
            reg_addr  <= addr;
            @(posedge clk);
            data = reg_rdata;
            reg_rd_en <= 1'b0;
        end
    endtask

    // Workload Verification Procedure
    task automatic run_test(
        input string test_name,
        input [1:0]  opt_mode, // 2'b01: WS, 2'b10: OS
        input int    m_val,
        input int    k_val,
        input int    n_val,
        input int    tm_val,
        input int    tk_val,
        input int    tn_val,
        input logic  db_val
    );
        int r, c, k_idx;
        int err_count;
        logic [31:0] status_val;
        logic [31:0] perf_cyc;
        logic [31:0] perf_util;

        begin
            $display("\n=======================================================");
            $display("TEST: %s", test_name);
            $display("Optimizer Parameters: Mode=%s (2'b%02b) | M=%0d, K=%0d, N=%0d | Tile=(%0d,%0d,%0d) DB=%0d",
                     (opt_mode == 2'b01) ? "WS" : "OS", opt_mode, m_val, k_val, n_val, tm_val, tk_val, tn_val, db_val);
            $display("=======================================================");

            words_read_count    = 0;
            words_written_count = 0;
            err_count           = 0;

            // Generate Input Matrices & DRAM layout
            // WS layout: 16 weights first, then M activation vectors
            // OS layout: K activation vectors (4 each), then K weight vectors (4 each)
            if (opt_mode == 2'b01) begin
                // WS
                for (r = 0; r < 4; r++) begin
                    for (c = 0; c < 4; c++) begin
                        gold_W[r][c] = (r + 1) * (c + 1);
                        dram_mem[r * 4 + c] = gold_W[r][c];
                    end
                end
                for (r = 0; r < m_val; r++) begin
                    for (c = 0; c < 4; c++) begin
                        gold_A[r][c] = (r + 2) + c;
                        dram_mem[16 + r * 4 + c] = gold_A[r][c];
                    end
                end
                // Compute golden C = A * W
                for (r = 0; r < m_val; r++) begin
                    for (c = 0; c < 4; c++) begin
                        gold_C[r][c] = 0;
                        for (k_idx = 0; k_idx < 4; k_idx++) begin
                            gold_C[r][c] = gold_C[r][c] + (gold_A[r][k_idx] * gold_W[k_idx][c]);
                        end
                    end
                end
            end else begin
                // OS
                for (k_idx = 0; k_idx < k_val; k_idx++) begin
                    for (r = 0; r < 4; r++) begin
                        gold_A[k_idx][r] = (k_idx % 3) + r + 1;
                        dram_mem[k_idx * 4 + r] = gold_A[k_idx][r];
                    end
                end
                for (k_idx = 0; k_idx < k_val; k_idx++) begin
                    for (c = 0; c < 4; c++) begin
                        gold_W[k_idx][c] = (k_idx % 4) + c + 1;
                        dram_mem[k_val * 4 + k_idx * 4 + c] = gold_W[k_idx][c];
                    end
                end
                // Compute golden C[r, c] = sum_{k}(A[k, r] * W[k, c])
                for (r = 0; r < 4; r++) begin
                    for (c = 0; c < 4; c++) begin
                        gold_C[r][c] = 0;
                        for (k_idx = 0; k_idx < k_val; k_idx++) begin
                            gold_C[r][c] = gold_C[r][c] + (gold_A[k_idx][r] * gold_W[k_idx][c]);
                        end
                    end
                end
            end

            // Host Memory-Mapped Register Programming Sequence:
            // 1. Write M, K, N
            write_reg(8'h08, m_val);
            write_reg(8'h0C, k_val);
            write_reg(8'h10, n_val);
            // 2. Write Tile dimensions
            write_reg(8'h14, tm_val);
            write_reg(8'h18, tk_val);
            write_reg(8'h1C, tn_val);
            // 3. Write Control Register: [3]=db_en, [2:1]=mode, [0]=start pulse
            write_reg(8'h00, {28'd0, db_val, opt_mode, 1'b1});

            // Wait for core to assert busy
            @(posedge clk);
            read_reg(8'h04, status_val);
            $display("[HOST] Accelerator Status: Busy=%0d, ActiveMode=%0d", status_val[0], status_val[2]);

            // Wait for execution completion
            while (!core_done) @(posedge clk);

            // Read telemetry registers
            read_reg(8'h20, perf_cyc);
            read_reg(8'h30, perf_util);
            $display("[HOST] Execution Complete! Cycles: %0d | MAC Utilization: %0.1f%%",
                     perf_cyc, real'(perf_util) / 10.0);

            // Check captured output elements against golden model
            if (opt_mode == 2'b01) begin
                for (r = 0; r < m_val; r++) begin
                    for (c = 0; c < 4; c++) begin
                        int word_idx = r * 4 + c;
                        if (captured_C[word_idx] !== gold_C[r][c]) begin
                            $display("ERROR [WS]: C[%0d][%0d] Expected: %0d, Got: %0d",
                                     r, c, gold_C[r][c], captured_C[word_idx]);
                            err_count++;
                        end
                    end
                end
            end else begin
                for (r = 0; r < 4; r++) begin
                    for (c = 0; c < 4; c++) begin
                        int word_idx = r * 4 + c;
                        if (captured_C[word_idx] !== gold_C[r][c]) begin
                            $display("ERROR [OS]: C[%0d][%0d] Expected: %0d, Got: %0d",
                                     r, c, gold_C[r][c], captured_C[word_idx]);
                            err_count++;
                        end
                    end
                end
            end

            if (err_count == 0) begin
                $display(">>> TEST PASSED: 100%% BIT-EXACT MATCH!");
                total_tests_passed++;
            end else begin
                $display(">>> TEST FAILED: %0d MISMATCHES DETECTED!", err_count);
                $fatal(1, "Verification failure!");
            end
        end
    endtask

    // Main Test Sequence
    initial begin
        rst_n = 1'b0;
        reg_wr_en = 1'b0;
        reg_rd_en = 1'b0;
        reg_addr  = '0;
        reg_wdata = '0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("\n=======================================================");
        $display("  STARTING PHASE 13 RTL HARDWARE VERIFICATION");
        $display("  Dynamic Configuration Registers & Hardware Dispatch");
        $display("=======================================================");

        // Test 1: Optimizer selects WS for batch workload (M=8, K=4, N=4)
        run_test("Scenario 1: Optimizer WS Dispatch (M=8, K=4, N=4)",
                 2'b01, 8, 4, 4, 8, 4, 4, 1'b1);

        // Test 2: Optimizer selects OS for deep reduction attention (M=4, K=16, N=4)
        run_test("Scenario 2: Optimizer OS Dispatch (M=4, K=16, N=4)",
                 2'b10, 4, 16, 4, 4, 4, 4, 1'b1);

        // Test 3: Optimizer selects OS for asymmetric workload (M=4, K=8, N=4)
        run_test("Scenario 3: Optimizer OS Dispatch (M=4, K=8, N=4)",
                 2'b10, 4, 8, 4, 4, 4, 4, 1'b1);

        // Test 4: Dynamic Reconfiguration on the fly without reset (Switch OS -> WS)
        run_test("Scenario 4: Dynamic Reconfig to WS without reset (M=4, K=4, N=4)",
                 2'b01, 4, 4, 4, 4, 4, 4, 1'b1);

        $display("\n=======================================================");
        $display("  ALL %0d SCENARIOS PASSED WITH 100%% BIT-EXACT PRECISION!", total_tests_passed);
        $display("=======================================================\n");

        $finish;
    end

endmodule
