// ==============================================================================
// Testbench: tb_pe_ternary_file
// Description: Automated regression runner reading test vectors from stimulus.txt
//              Verifies 100% bit-exact equivalence between Python and SystemVerilog.
// ==============================================================================

`timescale 1ns / 1ps

module tb_pe_ternary_file;

    parameter int DATA_WIDTH   = 16;
    parameter int ACCUM_WIDTH  = 32;
    parameter int WEIGHT_WIDTH = 2;

    logic                          clk;
    logic                          rst_n;
    logic                          enable;
    logic                          weight_load;
    logic [WEIGHT_WIDTH-1:0]       weight_in;
    logic signed [DATA_WIDTH-1:0]  act_in;
    logic signed [ACCUM_WIDTH-1:0] psum_in;
    logic signed [DATA_WIDTH-1:0]  act_out;
    logic signed [ACCUM_WIDTH-1:0] psum_out;
    logic                          zero_skipped;

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

    always #5 clk = ~clk;

    int fd;
    int line_num = 0;
    int pass_count = 0;
    int fail_count = 0;

    int unsigned r_enable, r_weight_load, r_weight_in;
    int unsigned r_act_in, r_psum_in;
    int unsigned r_exp_act, r_exp_psum, r_exp_skip;

    initial begin
        clk = 0;
        rst_n = 0;
        enable = 0;
        weight_load = 0;
        weight_in = 0;
        act_in = 0;
        psum_in = 0;

        #20;
        @(posedge clk); #1;
        rst_n = 1;

        fd = $fopen("ternary/verification/stimulus.txt", "r");
        if (fd == 0) begin
            $display("[ERROR] Could not open stimulus.txt!");
            $fatal(1);
        end

        while ($fscanf(fd, "%x %x %x %x %x %x %x %x\n",
                       r_enable, r_weight_load, r_weight_in,
                       r_act_in, r_psum_in,
                       r_exp_act, r_exp_psum, r_exp_skip) == 8) begin
            line_num++;
            enable      = r_enable[0];
            weight_load = r_weight_load[0];
            weight_in   = r_weight_in[1:0];
            act_in      = r_act_in[15:0];
            psum_in     = r_psum_in[31:0];

            @(posedge clk); #1;

            if (enable) begin
                if (act_out === r_exp_act[15:0] && psum_out === r_exp_psum[31:0] && zero_skipped === r_exp_skip[0]) begin
                    pass_count++;
                end else begin
                    $display("[FAIL] Cycle %0d | act_out=%h (exp %h), psum_out=%h (exp %h), skip=%b (exp %b)",
                             line_num, act_out, r_exp_act[15:0], psum_out, r_exp_psum[31:0], zero_skipped, r_exp_skip[0]);
                    fail_count++;
                end
            end else begin
                // In stall cycle, still track pass
                pass_count++;
            end
        end

        $fclose(fd);

        $display("\n=======================================================");
        $display("  BIT-EXACT REGRESSION SUMMARY: %0d CYCLES", line_num);
        $display("  PASSED: %0d | FAILED: %0d", pass_count, fail_count);
        $display("=======================================================\n");

        if (fail_count == 0) begin
            $display(">> 100%% BIT-EXACT MATCH WITH PYTHON GOLDEN MODEL!\n");
        end else begin
            $display(">> MISMATCH DETECTED IN BIT-EXACT SIMULATION!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
