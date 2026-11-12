`timescale 1ns / 1ps
`default_nettype none

// ==============================================================================
// Testbench: tb_macro_deep_stress.v
// Target: tt_um_cherukurigowtham_ternary_mac (Tiny Tapeout Silicon Macro)
// Description: NVIDIA-Grade Exhaustive Pre-Silicon Stress & Corner Testbench
// ==============================================================================

module tb_macro_deep_stress;

    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    // Instantiate DUT
    tt_um_cherukurigowtham_ternary_mac dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    // Clock: 50 MHz (20 ns)
    always #10 clk = ~clk;

    // Helper task to build uio_in
    function [7:0] build_uio;
        input [1:0] weight;
        input       weight_load;
        input       mode_os;
        input       accum_clear;
        input       enable;
        input [1:0] byte_sel;
        begin
            build_uio = {byte_sel, enable, accum_clear, mode_os, weight_load, weight};
        end
    endfunction

    // Helper task to read 24-bit accumulator via byte multiplexing
    task read_accum_24;
        output signed [23:0] accum_val;
        reg [7:0] b0, b1, b2;
        begin
            uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b00);
            @(posedge clk); #1;
            b0 = uo_out;

            uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b01);
            @(posedge clk); #1;
            b1 = uo_out;

            uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b10);
            @(posedge clk); #1;
            b2 = uo_out;

            accum_val = {b2, b1, b0};
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;
    integer i, w_idx;
    reg signed [23:0] readback_val;
    reg signed [23:0] gold_accum;
    reg signed [7:0]  test_act;

    initial begin
        clk = 0;
        rst_n = 0;
        ena = 1;
        ui_in = 0;
        uio_in = 0;

        #100;
        @(posedge clk); #1;
        rst_n = 1;
        #40;

        $display("==========================================================================");
        $display("  NVIDIA-GRADE PRE-SILICON DEEP STRESS TEST: TINY TAPEOUT MACRO");
        $display("  Target: tt_um_cherukurigowtham_ternary_mac (Sky130 50 MHz Silicon Tile)");
        $display("==========================================================================");

        // TEST 1: Exhaustive WS Mode - All 256 Signed Inputs with +1 Weight
        $display("\n>>> [MACRO TIER 1] Exhaustive Input Space Sweep (256 Activations @ W = +1)");
        // Latch weight +1 (2'b01)
        uio_in = build_uio(2'b01, 1'b1, 1'b0, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        gold_accum = 0;
        for (i = -128; i <= 127; i = i + 1) begin
            test_act = i[7:0];
            ui_in = test_act;
            uio_in = build_uio(2'b01, 1'b0, 1'b0, 1'b0, 1'b1, 2'b00);
            gold_accum = gold_accum + test_act;
            @(posedge clk); #1;
        end
        // Disable compute
        uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        read_accum_24(readback_val);
        if (readback_val === gold_accum) begin
            $display("[PASS] Exhaustive +1 Sweep: HW Accum = %0d == Gold Accum = %0d", readback_val, gold_accum);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Exhaustive +1 Sweep: HW Accum = %0d != Gold Accum = %0d", readback_val, gold_accum);
            fail_count = fail_count + 1;
        end

        // TEST 2: Synchronous Clear Verification
        $display("\n>>> [MACRO TIER 2] Synchronous Accumulator Clear");
        uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b1, 1'b0, 2'b00); // accum_clear = 1
        @(posedge clk); #1;
        uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        read_accum_24(readback_val);
        if (readback_val === 24'sd0) begin
            $display("[PASS] Accumulator Synchronous Clear verified (Accum = 0).");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Accumulator Clear failed! Got %0d", readback_val);
            fail_count = fail_count + 1;
        end

        // TEST 3: Exhaustive WS Mode - All 256 Signed Inputs with -1 Weight
        $display("\n>>> [MACRO TIER 3] Exhaustive Input Space Sweep (256 Activations @ W = -1)");
        // Latch weight -1 (2'b10)
        uio_in = build_uio(2'b10, 1'b1, 1'b0, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        gold_accum = 0;
        for (i = -128; i <= 127; i = i + 1) begin
            test_act = i[7:0];
            ui_in = test_act;
            uio_in = build_uio(2'b10, 1'b0, 1'b0, 1'b0, 1'b1, 2'b00);
            gold_accum = gold_accum - test_act;
            @(posedge clk); #1;
        end
        uio_in = build_uio(2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        read_accum_24(readback_val);
        if (readback_val === gold_accum) begin
            $display("[PASS] Exhaustive -1 Sweep: HW Accum = %0d == Gold Accum = %0d", readback_val, gold_accum);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Exhaustive -1 Sweep: HW Accum = %0d != Gold Accum = %0d", readback_val, gold_accum);
            fail_count = fail_count + 1;
        end

        // TEST 4: Output-Stationary Streaming Deep Reduction (K=500 Cycles)
        $display("\n>>> [MACRO TIER 4] Output-Stationary Streaming Deep Reduction (K=500 Cycles)");
        // Clear accum first
        uio_in = build_uio(2'b00, 1'b0, 1'b1, 1'b1, 1'b0, 2'b00);
        @(posedge clk); #1;

        gold_accum = 0;
        for (i = 0; i < 500; i = i + 1) begin
            reg [1:0] cur_w;
            test_act = ((i * 37) % 255) - 128;
            cur_w = (i % 3 == 0) ? 2'b01 : ((i % 3 == 1) ? 2'b10 : 2'b00);
            ui_in = test_act;
            uio_in = build_uio(cur_w, 1'b0, 1'b1, 1'b0, 1'b1, 2'b00); // mode_os = 1, enable = 1
            if (cur_w == 2'b01) gold_accum = gold_accum + test_act;
            else if (cur_w == 2'b10) gold_accum = gold_accum - test_act;
            @(posedge clk); #1;
        end
        uio_in = build_uio(2'b00, 1'b0, 1'b1, 1'b0, 1'b0, 2'b00);
        @(posedge clk); #1;

        read_accum_24(readback_val);
        if (readback_val === gold_accum) begin
            $display("[PASS] OS Deep Reduction (500 cycles): HW = %0d == Gold = %0d", readback_val, gold_accum);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] OS Deep Reduction mismatch: HW = %0d != Gold = %0d", readback_val, gold_accum);
            fail_count = fail_count + 1;
        end

        // TEST 5: Zero-Skip Telemetry Output Check
        $display("\n>>> [MACRO TIER 5] Zero-Skip Telemetry Pin Audit");
        // Clear accumulator and reset
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // Feed 10 zero weights with enable=1
        for (i = 0; i < 10; i = i + 1) begin
            ui_in = 8'd42;
            uio_in = build_uio(2'b00, 1'b0, 1'b1, 1'b0, 1'b1, 2'b00); // weight=0, mode_os=1, enable=1
            @(posedge clk); #1;
        end
        // Disable compute
        uio_in = build_uio(2'b00, 1'b0, 1'b1, 1'b0, 1'b0, 2'b11); // byte_sel = 3
        @(posedge clk); #1;

        // Check byte 3 readout for counter: bits [7:4] are zero_skips_count[3:0]
        if (uo_out[7:4] == 4'd10) begin
            $display("[PASS] Zero-skip telemetry counter accurately logged %0d skips (nibble=%0d).", 10, uo_out[7:4]);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Telemetry counter expected 10, got %0d (uo_out=0x%02h)", uo_out[7:4], uo_out);
            fail_count = fail_count + 1;
        end

        $display("==========================================================================");
        $display("  TINY TAPEOUT MACRO VERIFICATION SUMMARY");
        $display("  Total Tests: %0d | Passed: %0d | Failed: %0d", pass_count + fail_count, pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> SILICON MACRO VERIFICATION: 100%% PASS <<\n");
        end else begin
            $display(">> SILICON MACRO VERIFICATION: FAILED <<\n");
        end

        $finish;
    end

endmodule
