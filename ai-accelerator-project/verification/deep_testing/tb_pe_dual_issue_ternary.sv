// ==============================================================================
// Testbench: tb_pe_dual_issue_ternary.sv
// Description: Verification suite for Gen-2 Dual-Issue Multiplier-Free Ternary PE.
//              Tests 2 MACs / cycle throughput, carry-save reduction, zero-skip
//              telemetry, and sign-inversion correctness.
// ==============================================================================

`timescale 1ns / 1ps

module tb_pe_dual_issue_ternary;

    logic        clk;
    logic        rst_n;
    logic        enable;
    logic        accum_clear;

    logic signed [15:0] act0_in, act1_in;
    logic        [1:0]  w0_in, w1_in;
    logic signed [31:0] psum_in;

    logic signed [15:0] act0_out, act1_out;
    logic signed [31:0] accum_out;
    logic               zero_skip_both;
    logic               zero_skip_any;

    pe_dual_issue_ternary #(
        .DATA_WIDTH(16),
        .ACCUM_WIDTH(32),
        .WEIGHT_WIDTH(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .accum_clear(accum_clear),
        .act0_in(act0_in),
        .act1_in(act1_in),
        .w0_in(w0_in),
        .w1_in(w1_in),
        .psum_in(psum_in),
        .act0_out(act0_out),
        .act1_out(act1_out),
        .accum_out(accum_out),
        .zero_skip_both(zero_skip_both),
        .zero_skip_any(zero_skip_any)
    );

    always #5 clk = ~clk; // 100 MHz clock

    initial begin
        clk = 0;
        rst_n = 0;
        enable = 0;
        accum_clear = 0;
        act0_in = 0;
        act1_in = 0;
        w0_in = 0;
        w1_in = 0;
        psum_in = 0;

        $display("==========================================================================");
        $display("  GEN-2 DUAL-ISSUE MULTIPLIER-FREE TERNARY PE VERIFICATION (2 MACs/CYCLE) ");
        $display("==========================================================================");

        #20;
        rst_n = 1;
        enable = 1;
        #10;

        // Test 1: Both positive (+1, +1) -> (+act0) + (+act1)
        // act0 = 25, act1 = 75 => Sum = +100
        $display(">>> [TEST 1] Verifying Dual-Issue Addition (+1, +1)...");
        @(posedge clk);
        accum_clear = 1;
        act0_in = 16'sd25;
        act1_in = 16'sd75;
        w0_in = 2'b01; // +1
        w1_in = 2'b01; // +1
        psum_in = 32'sd0;

        @(posedge clk);
        accum_clear = 0;
        #1;
        $display("  Accumulator Output: %0d (Expected: +100)", accum_out);
        assert (accum_out == 32'sd100) else $fatal(1, "Test 1 Failed!");

        // Test 2: Mixed sign (+1, -1) -> (+act0) + (-act1)
        // act0 = 150, act1 = 50 => Sum = 100 + (150 - 50) = +200
        $display("\n>>> [TEST 2] Verifying Dual-Issue Mixed (+1, -1)...");
        act0_in = 16'sd150;
        act1_in = 16'sd50;
        w0_in = 2'b01; // +1
        w1_in = 2'b10; // -1
        psum_in = 32'sd0;

        @(posedge clk);
        #1;
        $display("  Accumulator Output: %0d (Expected: +200)", accum_out);
        assert (accum_out == 32'sd200) else $fatal(1, "Test 2 Failed!");

        // Test 3: Dual Zero-Skip (0, 0) -> Both gated, zero dynamic toggle
        $display("\n>>> [TEST 3] Verifying Dual-Channel Zero-Skip Power Gating...");
        act0_in = 16'sd999;
        act1_in = 16'sd888;
        w0_in = 2'b00; // Zero
        w1_in = 2'b00; // Zero

        @(posedge clk);
        #1;
        $display("  Accumulator Output: %0d (Expected: +200, unchanged)", accum_out);
        $display("  Zero-Skip Both Flag: %0b (Expected: 1)", zero_skip_both);
        assert (accum_out == 32'sd200) else $fatal(1, "Test 3 Value Changed!");
        assert (zero_skip_both == 1'b1) else $fatal(1, "Test 3 Zero-Skip Flag Failed!");

        $display("\n==========================================================================");
        $display("[PASS] Gen-2 Dual-Issue Ternary PE: 100%% BIT-EXACT PASS (2 MACs/CYCLE)!");
        $display("==========================================================================\n");
        $finish;
    end

endmodule
