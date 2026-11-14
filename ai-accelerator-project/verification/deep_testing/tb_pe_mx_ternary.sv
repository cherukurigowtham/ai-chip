// ==============================================================================
// Testbench: tb_pe_mx_ternary.sv
// Description: Verification suite for In-PE OCP Micro-Scaling (MX) Exponent Unit.
//              Tests dynamic block exponent barrel shifting (0..15 shifts),
//              outlier spike handling, and multiplier-free ternary sign inversion.
// ==============================================================================

`timescale 1ns / 1ps

module tb_pe_mx_ternary;

    logic        clk;
    logic        rst_n;
    logic        enable;
    logic        accum_clear;

    logic [3:0]  block_exp;
    logic signed [15:0] act_in;
    logic [1:0]  w_in;
    logic signed [31:0] psum_in;

    wire signed [31:0] accum_out;
    wire         zero_skipped;

    pe_mx_ternary #(
        .DATA_WIDTH(16),
        .ACCUM_WIDTH(32),
        .WEIGHT_WIDTH(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .accum_clear(accum_clear),
        .block_exp(block_exp),
        .act_in(act_in),
        .w_in(w_in),
        .psum_in(psum_in),
        .accum_out(accum_out),
        .zero_skipped(zero_skipped)
    );

    always #5 clk = ~clk; // 100 MHz clock

    initial begin
        clk = 0;
        rst_n = 0;
        enable = 0;
        accum_clear = 0;
        block_exp = 4'd0;
        act_in = 0;
        w_in = 0;
        psum_in = 0;

        $display("==========================================================================");
        $display("  IN-PE OCP MICRO-SCALING (MX) BLOCK EXPONENT UNIT VERIFICATION           ");
        $display("==========================================================================");

        #20;
        rst_n = 1;
        enable = 1;
        #10;

        // Test 1: Unshifted standard block (block_exp = 0)
        // act = +25, w = +1 => Accum = +25
        $display(">>> [TEST 1] Verifying Standard Exponent Scale (Exp = 0, << 0)...");
        @(posedge clk);
        #1;
        accum_clear = 1;
        block_exp = 4'd0; // 2^0 = 1
        act_in = 16'sd25;
        w_in = 2'b01; // +1
        psum_in = 32'sd0;

        @(posedge clk);
        #1;
        accum_clear = 0;
        $display("  Accumulator Output: %0d (Expected: +25)", accum_out);
        assert (accum_out == 32'sd25) else $fatal(1, "Test 1 Failed!");

        // Test 2: In-PE Micro-Scaling Exponent Shift (block_exp = 4 -> << 4 = x16)
        // act = +10, w = +1, exp = 4 => (10 << 4) = 160. Accum = 25 + 160 = 185
        $display("\n>>> [TEST 2] Verifying Micro-Scaling Barrel Shift (Exp = 4, << 4 = x16)...");
        block_exp = 4'd4; // 2^4 = 16
        act_in = 16'sd10;
        w_in = 2'b01; // +1

        @(posedge clk);
        #1;
        $display("  Accumulator Output: %0d (Expected: +185)", accum_out);
        assert (accum_out == 32'sd185) else $fatal(1, "Test 2 Failed!");

        // Test 3: LLM Outlier Negative Spike (block_exp = 8 -> << 8 = x256, w = -1)
        // act = +5, w = -1, exp = 8 => -(5 << 8) = -1280. Accum = 185 - 1280 = -1095
        $display("\n>>> [TEST 3] Verifying LLM Outlier Negative Spike (Exp = 8, w = -1, << 8 = x256)...");
        block_exp = 4'd8; // 2^8 = 256
        act_in = 16'sd5;
        w_in = 2'b10; // -1

        @(posedge clk);
        #1;
        $display("  Accumulator Output: %0d (Expected: -1095)", accum_out);
        assert (accum_out == -32'sd1095) else $fatal(1, "Test 3 Failed!");

        // Test 4: Zero-Skip with Micro-Scaling Header
        $display("\n>>> [TEST 4] Verifying Dynamic Zero-Skip under Micro-Scaling Block...");
        block_exp = 4'd12;
        act_in = 16'sd1234;
        w_in = 2'b00; // Zero weight

        @(posedge clk);
        #1;
        $display("  Accumulator Output: %0d (Expected: -1095, unchanged)", accum_out);
        $display("  Zero-Skip Flag: %0b (Expected: 1)", zero_skipped);
        assert (accum_out == -32'sd1095) else $fatal(1, "Test 4 Value Changed!");
        assert (zero_skipped == 1'b1) else $fatal(1, "Test 4 Zero-Skip Flag Failed!");

        $display("\n==========================================================================");
        $display("[PASS] In-PE OCP Micro-Scaling Unit: 100%% BIT-EXACT PASS!");
        $display("==========================================================================\n");
        $finish;
    end

endmodule
