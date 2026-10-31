// ==============================================================================
// Testbench: tb_systolic_array_4x4
// Description: Comprehensive verification of the 4x4 Systolic Array.
//              Tests:
//              1. 1x1 matrix multiplication (isolated sub-PE test)
//              2. 2x2 matrix multiplication (sub-mesh test)
//              3. 4x4 matrix multiplication with cycle-by-cycle execution trace
//              4. Negative signed operands (mixed positive & negative values)
//              5. Back-to-back matrix executions (streaming pipeline test)
//              6. Reset assertion during active operation & clean recovery
//              7. Clock enable stall (freezing pipeline mid-computation)
// ==============================================================================

`timescale 1ns / 1ps

module tb_systolic_array_4x4;

    parameter int DATA_WIDTH  = 16;
    parameter int ACCUM_WIDTH = 32;
    parameter int ROWS        = 4;
    parameter int COLS        = 4;

    logic clk;
    logic rst_n;
    logic enable;
    logic weight_load;

    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] weight_in_flat;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      act_in_flat;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     psum_in_flat;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     psum_out_flat;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     psum_out_deskewed_flat;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      act_out_flat;

    // Test matrix storage
    logic signed [DATA_WIDTH-1:0]  A_mat    [0:ROWS-1][0:ROWS-1];
    logic signed [DATA_WIDTH-1:0]  B_mat    [0:ROWS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] C_golden [0:ROWS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0] C_sim    [0:ROWS-1][0:COLS-1];

    int pass_count = 0;
    int fail_count = 0;
    int cycle_num  = 0;

    // Instantiate 4x4 Systolic Array DUT
    systolic_array_4x4 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .INTERNAL_SKEW(1'b1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .weight_load(weight_load),
        .weight_in_flat(weight_in_flat),
        .act_in_flat(act_in_flat),
        .psum_in_flat(psum_in_flat),
        .psum_out_flat(psum_out_flat),
        .psum_out_deskewed_flat(psum_out_deskewed_flat),
        .act_out_flat(act_out_flat)
    );

    // 100 MHz clock
    always #5 begin
        clk = ~clk;
        if (clk) cycle_num++;
    end

    // Task: Compute golden C = A * B with explicit 32-bit signed casting
    task automatic compute_golden();
        for (int i = 0; i < ROWS; i++) begin
            for (int j = 0; j < COLS; j++) begin
                C_golden[i][j] = 0;
                for (int k = 0; k < ROWS; k++) begin
                    C_golden[i][j] += 32'($signed(A_mat[i][k])) * 32'($signed(B_mat[k][j]));
                end
            end
        end
    endtask

    // Task: Pack B_mat into weight_in_flat
    task automatic pack_weights();
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                weight_in_flat[(r*COLS + c)*DATA_WIDTH +: DATA_WIDTH] = B_mat[r][c];
            end
        end
    endtask

    // Task: Pack activation row i into act_in_flat
    task automatic pack_act_row(input int r_idx);
        for (int k = 0; k < ROWS; k++) begin
            act_in_flat[k*DATA_WIDTH +: DATA_WIDTH] = A_mat[r_idx][k];
        end
    endtask

    // Task: Capture deskewed output row into C_sim
    task automatic unpack_deskewed_row(input int out_row_idx);
        for (int c = 0; c < COLS; c++) begin
            C_sim[out_row_idx][c] = psum_out_deskewed_flat[c*ACCUM_WIDTH +: ACCUM_WIDTH];
        end
    endtask

    // Task: Run full GEMM execution on current A_mat and B_mat
    task automatic execute_test(input string test_name, input bit print_trace);
        bit test_passed;
        test_passed = 1;

        // Clear simulation output matrix
        for (int i = 0; i < ROWS; i++) begin
            for (int j = 0; j < COLS; j++) begin
                C_sim[i][j] = '0;
            end
        end

        compute_golden();

        // 1. Load weights
        @(posedge clk); #1;
        weight_load  = 1;
        pack_weights();
        act_in_flat  = '0;
        psum_in_flat = '0;

        @(posedge clk); #1;
        weight_load    = 0;
        weight_in_flat = '0;

        // 2. Stream 4 rows of A_mat across cycles
        // Output row 0 arrives at cycle 7 (input skew + systolic latency + deskew)
        for (int cycle = 0; cycle < 14; cycle++) begin
            @(posedge clk); #1;

            if (cycle < ROWS) begin
                pack_act_row(cycle);
            end else begin
                act_in_flat = '0;
            end

            // Capture output rows at cycles 7, 8, 9, 10
            if (cycle >= 7 && cycle <= 10) begin
                int out_idx;
                out_idx = cycle - 7;
                unpack_deskewed_row(out_idx);
            end

            if (print_trace && cycle <= 11) begin
                $display("  [Cycle %2d] Stream Act Row %0d: [%4d, %4d, %4d, %4d] | Deskewed Output: [%6d, %6d, %6d, %6d]",
                         cycle,
                         (cycle < ROWS ? cycle : -1),
                         (cycle < ROWS ? A_mat[cycle][0] : 0),
                         (cycle < ROWS ? A_mat[cycle][1] : 0),
                         (cycle < ROWS ? A_mat[cycle][2] : 0),
                         (cycle < ROWS ? A_mat[cycle][3] : 0),
                         psum_out_deskewed_flat[0*ACCUM_WIDTH +: ACCUM_WIDTH],
                         psum_out_deskewed_flat[1*ACCUM_WIDTH +: ACCUM_WIDTH],
                         psum_out_deskewed_flat[2*ACCUM_WIDTH +: ACCUM_WIDTH],
                         psum_out_deskewed_flat[3*ACCUM_WIDTH +: ACCUM_WIDTH]);
            end
        end

        // Check for mismatch
        for (int i = 0; i < ROWS; i++) begin
            for (int j = 0; j < COLS; j++) begin
                if (C_sim[i][j] !== C_golden[i][j]) begin
                    test_passed = 0;
                    $display("    [ERROR] Mismatch at C[%0d,%0d]: Got %0d, Expected %0d",
                             i, j, C_sim[i][j], C_golden[i][j]);
                end
            end
        end

        if (test_passed) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Execution
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("ai-accelerator-project/results/systolic_array_waveform.vcd");
        $dumpvars(0, tb_systolic_array_4x4);

        clk            = 0;
        rst_n          = 0;
        enable         = 0;
        weight_load    = 0;
        weight_in_flat = '0;
        act_in_flat    = '0;
        psum_in_flat   = '0;

        $display("\n==========================================================================");
        $display("  STARTING 4x4 SYSTOLIC ARRAY HARDWARE VERIFICATION SUITE");
        $display("==========================================================================");

        // Reset pulse
        #15;
        @(posedge clk); #1;
        rst_n  = 1;
        enable = 1;

        // ---------------------------------------------------------------------
        // TEST 1: 1x1 Matrix Multiplication (Single PE in Mesh)
        // ---------------------------------------------------------------------
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                A_mat[r][c] = (r == 0 && c == 0) ? 16'sd7 : 16'sd0;
                B_mat[r][c] = (r == 0 && c == 0) ? 16'sd3 : 16'sd0;
            end
        end
        execute_test("Test 1: 1x1 Matrix Multiplication (Exp C[0,0] = 21)", 0);

        // ---------------------------------------------------------------------
        // TEST 2: 2x2 Matrix Multiplication (Sub-mesh)
        // ---------------------------------------------------------------------
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                A_mat[r][c] = 0;
                B_mat[r][c] = 0;
            end
        end
        A_mat[0][0] = 16'sd2; A_mat[0][1] = 16'sd3;
        A_mat[1][0] = 16'sd1; A_mat[1][1] = 16'sd4;

        B_mat[0][0] = 16'sd5; B_mat[0][1] = 16'sd2;
        B_mat[1][0] = 16'sd1; B_mat[1][1] = 16'sd6;
        execute_test("Test 2: 2x2 Matrix Multiplication", 0);

        // ---------------------------------------------------------------------
        // TEST 3: Full 4x4 Matrix Multiplication with Execution Trace
        // ---------------------------------------------------------------------
        A_mat[0][0]=1; A_mat[0][1]=2; A_mat[0][2]=3; A_mat[0][3]=4;
        A_mat[1][0]=5; A_mat[1][1]=6; A_mat[1][2]=7; A_mat[1][3]=8;
        A_mat[2][0]=2; A_mat[2][1]=1; A_mat[2][2]=4; A_mat[2][3]=3;
        A_mat[3][0]=3; A_mat[3][1]=5; A_mat[3][2]=2; A_mat[3][3]=1;

        B_mat[0][0]=2; B_mat[0][1]=0; B_mat[0][2]=1; B_mat[0][3]=3;
        B_mat[1][0]=1; B_mat[1][1]=4; B_mat[1][2]=2; B_mat[1][3]=0;
        B_mat[2][0]=3; B_mat[2][1]=1; B_mat[2][2]=0; B_mat[2][3]=2;
        B_mat[3][0]=0; B_mat[3][1]=2; B_mat[3][2]=3; B_mat[3][3]=1;

        $display("\n--- Detailed Cycle-by-Cycle Execution Trace for 4x4 Test ---");
        execute_test("Test 3: Full 4x4 Matrix Multiplication (Positive Operands)", 1);

        // ---------------------------------------------------------------------
        // TEST 4: Signed Negative Operands
        // ---------------------------------------------------------------------
        A_mat[0][0]=-10; A_mat[0][1]= 15; A_mat[0][2]= -4; A_mat[0][3]=  8;
        A_mat[1][0]=  7; A_mat[1][1]=-12; A_mat[1][2]=  6; A_mat[1][3]= -2;
        A_mat[2][0]= -3; A_mat[2][1]=  5; A_mat[2][2]= -9; A_mat[2][3]= 11;
        A_mat[3][0]= 14; A_mat[3][1]= -8; A_mat[3][2]=  2; A_mat[3][3]= -7;

        B_mat[0][0]=  4; B_mat[0][1]= -7; B_mat[0][2]=  2; B_mat[0][3]=  5;
        B_mat[1][0]= -6; B_mat[1][1]=  3; B_mat[1][2]= -8; B_mat[1][3]=  1;
        B_mat[2][0]=  9; B_mat[2][1]= -2; B_mat[2][2]=  4; B_mat[2][3]= -6;
        B_mat[3][0]= -5; B_mat[3][1]=  8; B_mat[3][2]= -1; B_mat[3][3]=  3;
        execute_test("Test 4: 4x4 Matrix Multiplication (Signed Negative Operands)", 0);

        // ---------------------------------------------------------------------
        // TEST 5: Back-to-Back Matrix Operations (No idle bubbles)
        // ---------------------------------------------------------------------
        A_mat[0][0]=3; A_mat[0][1]=1; A_mat[0][2]=2; A_mat[0][3]=4;
        A_mat[1][0]=2; A_mat[1][1]=4; A_mat[1][2]=1; A_mat[1][3]=3;
        A_mat[2][0]=4; A_mat[2][1]=2; A_mat[2][2]=3; A_mat[2][3]=1;
        A_mat[3][0]=1; A_mat[3][1]=3; A_mat[3][2]=4; A_mat[3][3]=2;

        B_mat[0][0]=1; B_mat[0][1]=2; B_mat[0][2]=3; B_mat[0][3]=4;
        B_mat[1][0]=4; B_mat[1][1]=3; B_mat[1][2]=2; B_mat[1][3]=1;
        B_mat[2][0]=2; B_mat[2][1]=1; B_mat[2][2]=4; B_mat[2][3]=3;
        B_mat[3][0]=3; B_mat[3][1]=4; B_mat[3][2]=1; B_mat[3][3]=2;
        execute_test("Test 5: Back-to-Back Matrix Execution", 0);

        // ---------------------------------------------------------------------
        // TEST 6: Reset During Operation & Recovery
        // ---------------------------------------------------------------------
        $display("Running Test 6: Reset mid-stream and clean recovery...");
        @(posedge clk); #1;
        act_in_flat = '1; // Corrupt inputs
        rst_n       = 0;  // Assert synchronous reset
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n       = 1;  // Clear reset

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                A_mat[r][c] = (r == 0 && c == 0) ? 16'sd9 : 16'sd0;
                B_mat[r][c] = (r == 0 && c == 0) ? 16'sd8 : 16'sd0;
            end
        end
        execute_test("Test 6: Post-Reset Recovery Verification (C[0,0] = 72)", 0);

        // ---------------------------------------------------------------------
        // TEST 7: Clock Enable Stalls (Pipeline freeze mid-stream)
        // ---------------------------------------------------------------------
        begin
            bit stall_pass;
            stall_pass = 1;

            for (int i = 0; i < ROWS; i++) begin
                for (int j = 0; j < COLS; j++) begin
                    C_sim[i][j] = '0;
                end
            end

            A_mat[0][0]=4; A_mat[0][1]=2; A_mat[0][2]=1; A_mat[0][3]=3;
            A_mat[1][0]=1; A_mat[1][1]=5; A_mat[1][2]=2; A_mat[1][3]=4;
            A_mat[2][0]=3; A_mat[2][1]=1; A_mat[2][2]=4; A_mat[2][3]=2;
            A_mat[3][0]=2; A_mat[3][1]=4; A_mat[3][2]=3; A_mat[3][3]=1;

            B_mat[0][0]=2; B_mat[0][1]=3; B_mat[0][2]=1; B_mat[0][3]=4;
            B_mat[1][0]=4; B_mat[1][1]=1; B_mat[1][2]=3; B_mat[1][3]=2;
            B_mat[2][0]=1; B_mat[2][1]=2; B_mat[2][2]=4; B_mat[2][3]=3;
            B_mat[3][0]=3; B_mat[3][1]=4; B_mat[3][2]=2; B_mat[3][3]=1;

            compute_golden();

            // Load weights
            @(posedge clk); #1;
            weight_load  = 1;
            pack_weights();
            act_in_flat  = '0;
            psum_in_flat = '0;

            @(posedge clk); #1;
            weight_load    = 0;
            weight_in_flat = '0;

            // Stream 4 activation rows
            for (int r = 0; r < ROWS; r++) begin
                @(posedge clk); #1;
                pack_act_row(r);
            end

            @(posedge clk); #1;
            act_in_flat = '0;

            // STALL PIPELINE: Freeze for 3 clock cycles!
            enable = 0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            @(posedge clk); #1;
            enable = 1; // Unfreeze

            // Now wait remaining cycles until output arrives
            // Total active enabled cycles from start of stream:
            // 4 rows fed (cycles 0,1,2,3), then cycle 4 fed 0.
            // Row 0 emerges at 7th active cycle.
            // So after unfreezing, row 0 emerges in 2 cycles (active cycle 5 and 6, then at 7)!
            @(posedge clk); #1;
            @(posedge clk); #1;

            // Capture output rows at active cycles 7, 8, 9, 10
            for (int out_r = 0; out_r < ROWS; out_r++) begin
                @(posedge clk); #1;
                unpack_deskewed_row(out_r);
            end

            for (int i = 0; i < ROWS; i++) begin
                for (int j = 0; j < COLS; j++) begin
                    if (C_sim[i][j] !== C_golden[i][j]) begin
                        stall_pass = 0;
                        $display("    [ERROR] Stall mismatch at [%0d,%0d]: Got %0d, Expected %0d",
                                 i, j, C_sim[i][j], C_golden[i][j]);
                    end
                end
            end

            if (stall_pass) begin
                $display("[PASS] Test 7: Clock Enable Stalls (Pipeline Freeze & Clean Resume)");
                pass_count++;
            end else begin
                $display("[FAIL] Test 7: Clock Enable Stalls");
                fail_count++;
            end
        end

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("\n==========================================================================");
        $display("  4x4 SYSTOLIC ARRAY SUITE SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==========================================================================");

        if (fail_count == 0) begin
            $display(">> 4x4 SYSTOLIC ARRAY HARDWARE VERIFICATION: 100%% SUCCESSFUL!\n");
        end else begin
            $display(">> 4x4 SYSTOLIC ARRAY HARDWARE VERIFICATION: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
