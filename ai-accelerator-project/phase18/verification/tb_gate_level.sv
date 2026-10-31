// ==============================================================================
// Testbench: phase14/rtl/tb_accelerator_top.sv
// Description: Verification testbench for accelerator_top module.
//              Tests memory-mapped bus programming, WS & OS execution,
//              and 100% bit-exact matrix multiplication.
// ==============================================================================

`timescale 1ns / 1ps

module tb_accelerator_top;

    localparam int DATA_WIDTH    = 16;
    localparam int ACCUM_WIDTH   = 32;
    localparam int ROWS          = 4;
    localparam int COLS          = 4;
    localparam int BUFFER_VECS   = 16;
    localparam int OUT_BUF_DEPTH = 64;
    localparam int CLK_PERIOD    = 2; // 500 MHz

    logic clk;
    logic rst_n;

    logic        reg_wr_en;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_rd_en;
    logic [31:0] reg_rdata;

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

    // Instantiate Top Module
    accelerator_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .reg_wr_en(reg_wr_en),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rd_en(reg_rd_en),
        .reg_rdata(reg_rdata),
        .dram_rd_req(dram_rd_req),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .busy(busy),
        .done(done),
        .active_dataflow(active_dataflow)
    );

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Test Memory
    logic signed [DATA_WIDTH-1:0]  dram_mem [0:4095];
    logic signed [DATA_WIDTH-1:0]  gold_A [15:0][3:0];
    logic signed [DATA_WIDTH-1:0]  gold_W [15:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] gold_C [15:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_C [255:0];

    int words_read_count = 0;
    int words_written_count = 0;
    int passed_tests = 0;

    // DRAM Emulator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_rd_valid       <= 1'b0;
            dram_rd_data        <= '0;
            dram_wr_ack         <= 1'b0;
            words_read_count    <= 0;
            words_written_count <= 0;
        end else begin
            if (dram_rd_req) begin
                dram_rd_valid    <= 1'b1;
                dram_rd_data     <= dram_mem[words_read_count];
                words_read_count <= words_read_count + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

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

    task automatic run_test(
        input string name,
        input [1:0]  mode,
        input int    m_val,
        input int    k_val,
        input int    n_val
    );
        int r, c, k_idx;
        int errs;
        errs = 0;
        words_read_count = 0;
        words_written_count = 0;

        $display("\n=======================================================");
        $display("RUNNING: %s | Mode=%s | M=%0d, K=%0d, N=%0d",
                 name, (mode == 2'b01) ? "WS" : "OS", m_val, k_val, n_val);
        $display("=======================================================");

        if (mode == 2'b01) begin
            // WS
            for (r = 0; r < 4; r++) begin
                for (c = 0; c < 4; c++) begin
                    gold_W[r][c] = (r + 1) * (c + 2);
                    dram_mem[r*4 + c] = gold_W[r][c];
                end
            end
            for (r = 0; r < m_val; r++) begin
                for (c = 0; c < 4; c++) begin
                    gold_A[r][c] = (r + 1) + c;
                    dram_mem[16 + r*4 + c] = gold_A[r][c];
                end
            end
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
                    dram_mem[k_idx*4 + r] = gold_A[k_idx][r];
                end
            end
            for (k_idx = 0; k_idx < k_val; k_idx++) begin
                for (c = 0; c < 4; c++) begin
                    gold_W[k_idx][c] = (k_idx % 4) + c + 1;
                    dram_mem[k_val*4 + k_idx*4 + c] = gold_W[k_idx][c];
                end
            end
            for (r = 0; r < 4; r++) begin
                for (c = 0; c < 4; c++) begin
                    gold_C[r][c] = 0;
                    for (k_idx = 0; k_idx < k_val; k_idx++) begin
                        gold_C[r][c] = gold_C[r][c] + (gold_A[k_idx][r] * gold_W[k_idx][c]);
                    end
                end
            end
        end

        // Program Registers
        write_reg(8'h08, m_val);
        write_reg(8'h0C, k_val);
        write_reg(8'h10, n_val);
        write_reg(8'h00, {28'd0, 1'b1, mode, 1'b1}); // Start pulse

        @(posedge clk);
        while (!done) @(posedge clk);

        // Verify outputs
        if (mode == 2'b01) begin
            for (r = 0; r < m_val; r++) begin
                for (c = 0; c < 4; c++) begin
                    int idx = r * 4 + c;
                    if (captured_C[idx] !== gold_C[r][c]) begin
                        $display("ERROR [WS]: C[%0d][%0d] Expected: %0d, Got: %0d", r, c, gold_C[r][c], captured_C[idx]);
                        errs++;
                    end
                end
            end
        end else begin
            for (r = 0; r < 4; r++) begin
                for (c = 0; c < 4; c++) begin
                    int idx = r * 4 + c;
                    if (captured_C[idx] !== gold_C[r][c]) begin
                        $display("ERROR [OS]: C[%0d][%0d] Expected: %0d, Got: %0d", r, c, gold_C[r][c], captured_C[idx]);
                        errs++;
                    end
                end
            end
        end

        if (errs == 0) begin
            $display(">>> TEST PASSED: 100%% BIT-EXACT MATCH!");
            passed_tests++;
        end else begin
            $fatal(1, "Verification failed!");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        reg_wr_en = 1'b0;
        reg_rd_en = 1'b0;
        reg_addr = '0;
        reg_wdata = '0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        run_test("Test 1: Calibrated WS Execution", 2'b01, 8, 4, 4);
        run_test("Test 2: Calibrated OS Execution", 2'b10, 4, 16, 4);
        run_test("Test 3: Small Edge Matrix (M=4, K=8, N=4)", 2'b10, 4, 8, 4);

        $display("\n=======================================================");
        $display("  ALL %0d TESTS PASSED ON ACCELERATOR_TOP CORE!", passed_tests);
        $display("=======================================================\n");

        $finish;
    end

endmodule
