// ==============================================================================
// Gate-Level Testbench: tb_accelerator_ternary_top_gate
// Description: Post-route gate-level verification with Nangate 45nm standard cells
//              and back-annotated SDF extracted timing for accelerator_ternary_top.
// ==============================================================================

`timescale 1ns / 1ps

module tb_accelerator_ternary_top_gate;

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

    // Instantiate Routed Gate-Level Netlist (Unparameterized)
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

    // Tie-low constant net resolution for un-driven synthesis zero_ net in simulation
    assign dut.\u_ternary_controller/u_systolic_array/zero_ = 1'b0;

    // SDF Timing Annotation
    initial begin
`ifdef USE_SDF
        $display("[GATE-SIM] Annotating post-route extracted SDF timing from OpenROAD...");
        $sdf_annotate("/Users/gowthamcherukuri/Desktop/ai_chip/ai-accelerator-project/ternary/physical/openroad_run/accelerator_ternary_top.sdf", dut);
`endif
    end

    // 500 MHz Clock Generation (2.0 ns period)
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Emulated DRAM Storage
    logic [DATA_WIDTH-1:0]         dram_read_mem  [0:4095];
    logic signed [ACCUM_WIDTH-1:0] dram_write_mem [0:4095];
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

            // Write channel
            if (dram_wr_req) begin
                dram_wr_ack   <= 1'b1;
                dram_write_mem[dram_wr_ptr] <= dram_wr_data;
                $display("[DRAM WR] ptr=%0d data=%0d (hex %h) at t=%0t", dram_wr_ptr, dram_wr_data, dram_wr_data, $time);
                dram_wr_ptr   <= dram_wr_ptr + 1;
            end else begin
                dram_wr_ack   <= 1'b0;
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
        $display("[DEBUG MMIO] Wrote addr=0x%02h data=0x%08h at t=%0t", addr, data, $time);
    endtask

    // Verification bookkeeping
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;

    initial begin
        $dumpfile("gate_sim.vcd");
        $dumpvars(0, tb_accelerator_ternary_top_gate);

        rst_n     = 0;
        reg_wr_en = 0;
        reg_addr  = 0;
        reg_wdata = 0;
        reg_rd_en = 0;

        #(CLK_PERIOD * 10);
        @(posedge clk); #0.1;
        rst_n = 1;

        $display("\n===============================================================");
        $display("  STARTING POST-ROUTE GATE-LEVEL INTEGRATION REGRESSION");
        $display("  Target Clock: 500 MHz (2.0 ns) | Mesh: 4x4 | Tech: Nangate 45nm");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Weight-Stationary (WS) 4x4 Matrix Multiplication
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 1] Weight-Stationary 4x4 GEMM Execution ---");

        // 1. Pack 16 ternary weights into two 16-bit DRAM words:
        dram_read_mem[0] = 16'h2449;
        dram_read_mem[1] = 16'h4992;

        // 2. Activations (4 vectors x 4 elements = 16 words)
        dram_read_mem[2]  = 16'sd100;
        dram_read_mem[3]  = -16'sd200;
        dram_read_mem[4]  = 16'sd300;
        dram_read_mem[5]  = -16'sd400;

        dram_read_mem[6]  = -16'sd500;
        dram_read_mem[7]  = 16'sd600;
        dram_read_mem[8]  = -16'sd700;
        dram_read_mem[9]  = 16'sd800;

        dram_read_mem[10] = 16'sd1000;
        dram_read_mem[11] = -16'sd1500;
        dram_read_mem[12] = 16'sd2000;
        dram_read_mem[13] = -16'sd2500;

        dram_read_mem[14] = 16'sd3000;
        dram_read_mem[15] = 16'sd4000;
        dram_read_mem[16] = -16'sd5000;
        dram_read_mem[17] = -16'sd6000;

        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        // Program MMIO: M=4 (0x08), K=4 (0x0C), N=4 (0x10), Control=0x03 (Force WS, Start)
        mmio_write(8'h08, 32'd4);
        mmio_write(8'h0C, 32'd4);
        mmio_write(8'h10, 32'd4);
        mmio_write(8'h00, 32'h03);

        @(posedge busy);
        @(negedge busy);

        if (dram_wr_ptr == 16) begin
            $display("[PASS] WS Mode wrote exact 16 output words to DRAM.");
            passed_tests++;
        end else begin
            $display("[FAIL] Expected 16 outputs, got %0d", dram_wr_ptr);
            failed_tests++;
        end
        total_tests++;

        $display("[INFO] Total PE Zero-Skips tracked: %0d", zero_skips_count);
        if (zero_skips_count > 0) begin
            $display("[PASS] Zero-weight skipping successfully recorded by telemetry.");
            passed_tests++;
        end else begin
            $display("[FAIL] Zero-skips counter is 0.");
            failed_tests++;
        end
        total_tests++;

        // ---------------------------------------------------------------------
        // TEST 2: Back-to-Back Output-Stationary (OS) GEMM Execution
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 2] Back-to-Back OS GEMM (Deep Reduction K=8, M=4) ---");

        for (int i = 0; i < 64; i++) begin
            dram_read_mem[i] = 16'sd10 * (i + 1);
        end
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        // Program MMIO: M=4 (0x08), K=8 (0x0C), N=4 (0x10), Control=0x01 (Auto Mode, Start)
        mmio_write(8'h08, 32'd4);
        mmio_write(8'h0C, 32'd8);
        mmio_write(8'h10, 32'd4);
        mmio_write(8'h00, 32'h01); // Start pulse with Auto Mode

        @(posedge busy);
        if (active_dataflow == 1'b1) begin
            $display("[PASS] Autonomous Controller dynamically selected Output-Stationary (OS) mode for K > M!");
            passed_tests++;
        end else begin
            $display("[FAIL] Autonomous Controller failed to select OS mode (active_dataflow = %b)", active_dataflow);
            failed_tests++;
        end
        total_tests++;

        @(negedge busy);

        if (dram_wr_ptr == 16) begin
            $display("[PASS] OS Mode successfully drained and wrote 16 output words to DRAM.");
            passed_tests++;
        end else begin
            $display("[FAIL] Expected 16 outputs, got %0d", dram_wr_ptr);
            failed_tests++;
        end
        total_tests++;

        // ---------------------------------------------------------------------
        // TEST 3: Extreme Signed Range & Accumulator Headroom
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 3] Extreme Signed Dynamic Range (+30,000 / -30,000) ---");
        dram_read_mem[0] = 16'h5555; // All weights = +1 (01010101_01010101)
        dram_read_mem[1] = 16'h5555;
        for (int i = 2; i < 18; i++) begin
            dram_read_mem[i] = 16'sd30000;
        end
        dram_rd_ptr = 0;
        dram_wr_ptr = 0;

        mmio_write(8'h08, 32'd4);
        mmio_write(8'h0C, 32'd4);
        mmio_write(8'h10, 32'd4);
        mmio_write(8'h00, 32'h03); // Force WS, Start

        @(posedge busy);
        @(negedge busy);

        $display("[DEBUG TEST 3] dram_wr_ptr = %0d, dram_write_mem[0] = %h (%0d)", dram_wr_ptr, dram_write_mem[0], dram_write_mem[0]);

        if (dram_write_mem[0] == 32'sd120000) begin
            $display("[PASS] Extreme Signed Range Verified: Output[0] = %0d (Expected 120,000).", dram_write_mem[0]);
            passed_tests++;
        end else begin
            $display("[FAIL] Accumulator signed mismatch: got %0d, expected 120000", dram_write_mem[0]);
            failed_tests++;
        end
        total_tests++;

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("  ACCELERATOR POST-ROUTE GATE-LEVEL VERIFICATION SUMMARY");
        $display("  TOTAL TESTS: %0d | PASSED: %0d | FAILED: %0d", total_tests, passed_tests, failed_tests);
        $display("===============================================================\n");

        if (failed_tests == 0) begin
            $display(">> FULL 4x4 TERNARY ACCELERATOR POST-ROUTE GATE-LEVEL: SUCCESS!\n");
        end else begin
            $display(">> FULL 4x4 TERNARY ACCELERATOR POST-ROUTE GATE-LEVEL: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
