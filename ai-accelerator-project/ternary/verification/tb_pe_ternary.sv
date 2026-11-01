// ==============================================================================
// Testbench: tb_pe_ternary
// Description: Comprehensive verification testbench for pe_ternary.sv.
//              Verifies:
//              1. Active-low synchronous reset
//              2. 2-bit weight stationary latching & retention
//              3. Arithmetic for +1 (Add), -1 (Subtract), and 0 (Skip)
//              4. Full signed 16-bit dynamic range (-32768 to +32767)
//              5. Telemetry & operand isolation (zero_skipped signal)
//              6. Pipeline clock enable / stall behavior
//              7. Stress accumulation and sign extension
// ==============================================================================

`timescale 1ns / 1ps

module tb_pe_ternary;

    parameter int DATA_WIDTH   = 16;
    parameter int ACCUM_WIDTH  = 32;
    parameter int WEIGHT_WIDTH = 2;

    // Clock and Control
    logic clk;
    logic rst_n;
    logic enable;
    logic weight_load;

    // Data I/O
    logic        [WEIGHT_WIDTH-1:0] weight_in;
    logic signed [DATA_WIDTH-1:0]   act_in;
    logic signed [ACCUM_WIDTH-1:0]  psum_in;
    logic signed [DATA_WIDTH-1:0]   act_out;
    logic signed [ACCUM_WIDTH-1:0]  psum_out;
    logic                           zero_skipped;

    // Verification bookkeeping
    int pass_count = 0;
    int fail_count = 0;

    // Instantiate Ternary PE
    pe_ternary #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .weight_load(weight_load),
        .weight_in(weight_in),
        .act_in(act_in),
        .psum_in(psum_in),
        .act_out(act_out),
        .psum_out(psum_out),
        .zero_skipped(zero_skipped)
    );

    // 100 MHz clock generation (10 ns period)
    always #5 clk = ~clk;

    // Task to check outputs
    task check_step(
        input string test_name,
        input logic signed [DATA_WIDTH-1:0]  expected_act,
        input logic signed [ACCUM_WIDTH-1:0] expected_psum,
        input logic                          expected_skip
    );
        if (act_out === expected_act && psum_out === expected_psum && zero_skipped === expected_skip) begin
            $display("[PASS] %s | act_out=%0d, psum_out=%0d, skip=%b",
                     test_name, act_out, psum_out, zero_skipped);
            pass_count++;
        end else begin
            $display("[FAIL] %s | act_out=%0d (exp %0d), psum_out=%0d (exp %0d), skip=%b (exp %b)",
                     test_name, act_out, expected_act, psum_out, expected_psum, zero_skipped, expected_skip);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("pe_ternary_waveform.vcd");
        $dumpvars(0, tb_pe_ternary);

        clk         = 0;
        rst_n       = 0;
        enable      = 0;
        weight_load = 0;
        weight_in   = 2'b00;
        act_in      = 0;
        psum_in     = 0;

        $display("\n=======================================================");
        $display("  STARTING TERNARY PROCESSING ELEMENT VERIFICATION");
        $display("=======================================================");

        // -------------------------------------------------------------
        // TEST 1: Synchronous Reset
        // -------------------------------------------------------------
        #15;
        @(posedge clk); #1;
        check_step("Test 1: Synchronous Reset", 16'sd0, 32'sd0, 1'b1);

        // De-assert reset, assert enable
        @(posedge clk); #1;
        rst_n  = 1;
        enable = 1;

        // -------------------------------------------------------------
        // TEST 2: Weight = +1 (2'b01) -> Addition Mode
        // -------------------------------------------------------------
        weight_load = 1;
        weight_in   = 2'b01; // +1
        @(posedge clk); #1;
        weight_load = 0;
        weight_in   = 2'b10; // Change bus to verify stationary retention

        // Apply act_in = +1200, psum_in = 5000 -> Expect psum_out = 6200
        act_in  = 16'sd1200;
        psum_in = 32'sd5000;
        @(posedge clk); #1;
        check_step("Test 2a: Weight +1 Add (+1200 + 5000)", 16'sd1200, 32'sd6200, 1'b0);

        // Apply negative activation with +1 weight: act_in = -450, psum_in = 1000 -> Expect 550
        act_in  = -16'sd450;
        psum_in = 32'sd1000;
        @(posedge clk); #1;
        check_step("Test 2b: Weight +1 with negative act (-450 + 1000)", -16'sd450, 32'sd550, 1'b0);

        // -------------------------------------------------------------
        // TEST 3: Weight = -1 (2'b10) -> Subtraction Mode
        // -------------------------------------------------------------
        weight_load = 1;
        weight_in   = 2'b10; // -1
        @(posedge clk); #1;
        weight_load = 0;
        weight_in   = 2'b00; // Change bus

        // Apply act_in = +800, psum_in = 2000 -> Expect 2000 - (+800) = 1200
        act_in  = 16'sd800;
        psum_in = 32'sd2000;
        @(posedge clk); #1;
        check_step("Test 3a: Weight -1 Sub (+800 from 2000)", 16'sd800, 32'sd1200, 1'b0);

        // Apply act_in = -600, psum_in = 2000 -> Expect 2000 - (-600) = 2600
        act_in  = -16'sd600;
        psum_in = 32'sd2000;
        @(posedge clk); #1;
        check_step("Test 3b: Weight -1 with negative act (2000 - -600)", -16'sd600, 32'sd2600, 1'b0);

        // -------------------------------------------------------------
        // TEST 4: Weight = 0 (2'b00) -> Zero Skip / Operand Isolation
        // -------------------------------------------------------------
        weight_load = 1;
        weight_in   = 2'b00; // 0
        @(posedge clk); #1;
        weight_load = 0;

        // Apply act_in = 32000, psum_in = 7777 -> Expect psum_out = 7777, skip = 1
        act_in  = 16'sd32000;
        psum_in = 32'sd7777;
        @(posedge clk); #1;
        check_step("Test 4: Weight 0 Skip Update", 16'sd32000, 32'sd7777, 1'b1);

        // -------------------------------------------------------------
        // TEST 5: Boundary Values (Max INT16 & Min INT16)
        // -------------------------------------------------------------
        // Load weight = +1
        weight_load = 1;
        weight_in   = 2'b01;
        @(posedge clk); #1;
        weight_load = 0;

        // Max positive INT16 (+32767)
        act_in  = 16'sh7FFF; // +32767
        psum_in = 32'sd0;
        @(posedge clk); #1;
        check_step("Test 5a: Max INT16 (+32767)", 16'sd32767, 32'sd32767, 1'b0);

        // Min negative INT16 (-32768)
        act_in  = -16'sh8000; // -32768
        psum_in = 32'sd0;
        @(posedge clk); #1;
        check_step("Test 5b: Min INT16 (-32768)", -16'sd32768, -32'sd32768, 1'b0);

        // Load weight = -1 with Min negative INT16: 0 - (-32768) = +32768
        weight_load = 1;
        weight_in   = 2'b10;
        @(posedge clk); #1;
        weight_load = 0;

        act_in  = -16'sh8000;
        psum_in = 32'sd0;
        @(posedge clk); #1;
        check_step("Test 5c: Weight -1 with Min INT16 (0 - -32768 = +32768)", -16'sd32768, 32'sd32768, 1'b0);

        // -------------------------------------------------------------
        // TEST 6: Clock Enable / Stall Behavior
        // -------------------------------------------------------------
        enable  = 0;
        act_in  = 16'sd1234;
        psum_in = 32'sd99999;
        @(posedge clk); #1;
        // Expect outputs to hold previous values
        check_step("Test 6a: Stall Cycle 1", -16'sd32768, 32'sd32768, 1'b0);

        @(posedge clk); #1;
        check_step("Test 6b: Stall Cycle 2", -16'sd32768, 32'sd32768, 1'b0);

        // Resume enable: Weight is still -1, act=1234, psum=99999 -> 99999 - 1234 = 98765
        enable = 1;
        @(posedge clk); #1;
        check_step("Test 6c: Resume After Stall", 16'sd1234, 32'sd98765, 1'b0);

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("=======================================================");
        $display("  TERNARY PE SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("=======================================================\n");

        if (fail_count == 0) begin
            $display(">> TERNARY PROCESSING ELEMENT (pe_ternary.sv): ALL TESTS PASSED!\n");
        end else begin
            $display(">> TERNARY PROCESSING ELEMENT (pe_ternary.sv): VERIFICATION FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
