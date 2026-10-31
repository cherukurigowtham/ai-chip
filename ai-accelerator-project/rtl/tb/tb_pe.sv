// ==============================================================================
// Testbench: tb_pe
// Description: Comprehensive unit verification for the Processing Element (pe.sv).
//              Tests:
//              1. Active-low synchronous reset
//              2. Weight-stationary latching & retention
//              3. Signed arithmetic (positive x positive, positive x negative, negative x negative)
//              4. Cycle-accurate pipeline forwarding of activation & partial sum
//              5. Clock enable (stall) behavior
// ==============================================================================

`timescale 1ns / 1ps

module tb_pe;

    parameter int DATA_WIDTH  = 16;
    parameter int ACCUM_WIDTH = 32;

    // Clock and Control
    logic clk;
    logic rst_n;
    logic enable;
    logic weight_load;

    // Data I/O
    logic signed [DATA_WIDTH-1:0]  weight_in;
    logic signed [DATA_WIDTH-1:0]  act_in;
    logic signed [ACCUM_WIDTH-1:0] psum_in;
    logic signed [DATA_WIDTH-1:0]  act_out;
    logic signed [ACCUM_WIDTH-1:0] psum_out;

    // Verification bookkeeping
    int pass_count = 0;
    int fail_count = 0;

    // Instantiate Device Under Test (DUT)
    pe #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .weight_load(weight_load),
        .weight_in(weight_in),
        .act_in(act_in),
        .psum_in(psum_in),
        .act_out(act_out),
        .psum_out(psum_out)
    );

    // 100 MHz Clock generation (10 ns period)
    always #5 clk = ~clk;

    // Task to check expected outputs
    task check_outputs(
        input string test_name,
        input logic signed [DATA_WIDTH-1:0]  expected_act,
        input logic signed [ACCUM_WIDTH-1:0] expected_psum
    );
        if (act_out === expected_act && psum_out === expected_psum) begin
            $display("[PASS] %s | act_out = %0d (exp %0d), psum_out = %0d (exp %0d)",
                     test_name, act_out, expected_act, psum_out, expected_psum);
            pass_count++;
        end else begin
            $display("[FAIL] %s | act_out = %0d (exp %0d), psum_out = %0d (exp %0d)",
                     test_name, act_out, expected_act, psum_out, expected_psum);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("pe_waveform.vcd");
        $dumpvars(0, tb_pe);

        // Initialize signals
        clk         = 0;
        rst_n       = 0;
        enable      = 0;
        weight_load = 0;
        weight_in   = 0;
        act_in      = 0;
        psum_in     = 0;

        $display("\n==================================================");
        $display("  STARTING PROCESSING ELEMENT (pe.sv) TESTBENCH");
        $display("==================================================");

        // -----------------------------------------------------------------
        // TEST 1: Synchronous Reset Check
        // -----------------------------------------------------------------
        #15;
        @(posedge clk); #1;
        check_outputs("Test 1: Reset active", 16'd0, 32'd0);

        // De-assert reset, assert enable
        @(posedge clk); #1;
        rst_n  = 1;
        enable = 1;

        // -----------------------------------------------------------------
        // TEST 2: Weight Loading (Weight Stationary)
        // Load stationary weight = +12
        // -----------------------------------------------------------------
        @(posedge clk); #1;
        weight_load = 1;
        weight_in   = 16'sd12;
        act_in      = 16'sd0;
        psum_in     = 32'sd0;

        @(posedge clk); #1;
        // Clear weight_load to verify weight stays stationary
        weight_load = 0;
        weight_in   = 16'sd99; // Corrupt input to prove register holds 12!

        // -----------------------------------------------------------------
        // TEST 3: Positive MAC Arithmetic (+5 * +12 + 0 = +60)
        // -----------------------------------------------------------------
        act_in  = 16'sd5;
        psum_in = 32'sd0;

        @(posedge clk); #1;
        check_outputs("Test 3a: (+5 * +12) + 0", 16'sd5, 32'sd60);

        // Pipeline step 2: (+3 * +12) + 100 = 136
        act_in  = 16'sd3;
        psum_in = 32'sd100;

        @(posedge clk); #1;
        check_outputs("Test 3b: (+3 * +12) + 100", 16'sd3, 32'sd136);

        // -----------------------------------------------------------------
        // TEST 4: Signed Negative Arithmetic
        // Load new stationary weight = -25
        // -----------------------------------------------------------------
        weight_load = 1;
        weight_in   = -16'sd25;
        act_in      = 16'sd0;
        psum_in     = 32'sd0;

        @(posedge clk); #1;
        weight_load = 0;
        weight_in   = 16'sd0;

        // Multiply positive act by negative weight: (+8 * -25) + 50 = -200 + 50 = -150
        act_in  = 16'sd8;
        psum_in = 32'sd50;

        @(posedge clk); #1;
        check_outputs("Test 4a: (+8 * -25) + 50", 16'sd8, -32'sd150);

        // Multiply negative act by negative weight: (-10 * -25) + (-200) = +250 - 200 = +50
        act_in  = -16'sd10;
        psum_in = -32'sd200;

        @(posedge clk); #1;
        check_outputs("Test 4b: (-10 * -25) + (-200)", -16'sd10, 32'sd50);

        // -----------------------------------------------------------------
        // TEST 5: Clock Enable / Stall Behavior
        // Set enable = 0. Registers should freeze.
        // -----------------------------------------------------------------
        enable  = 0;
        act_in  = 16'sd77;
        psum_in = 32'sd999;

        @(posedge clk); #1;
        // Expect outputs to remain frozen at previous cycle values (-10, 50)
        check_outputs("Test 5a: Stall (enable = 0)", -16'sd10, 32'sd50);

        @(posedge clk); #1;
        check_outputs("Test 5b: Second stalled cycle", -16'sd10, 32'sd50);

        // Resume enable
        enable = 1;
        @(posedge clk); #1;
        // Now (+77 * -25) + 999 = -1925 + 999 = -926
        check_outputs("Test 5c: Resume after stall", 16'sd77, -32'sd926);

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        $display("==================================================");
        $display("  PE TESTBENCH SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==================================================\n");

        if (fail_count == 0) begin
            $display(">> PROCESSING ELEMENT (pe.sv) VERIFICATION: SUCCESS!\n");
        end else begin
            $display(">> PROCESSING ELEMENT (pe.sv) VERIFICATION: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
