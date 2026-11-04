// ==============================================================================
// Testbench: tb_accelerator_ternary_fpga_axi
// Description: System-level FPGA verification testbench for accelerator_ternary_axi_top
//              emulating an AXI4-Lite Host CPU and AXI4-Stream DMA controller.
// ==============================================================================

`timescale 1ns / 1ps

module tb_accelerator_ternary_fpga_axi;

    localparam real CLK_PERIOD = 10.0; // 100 MHz FPGA System Clock (10.0 ns)
    localparam int  DATA_WIDTH = 16;
    localparam int  ACCUM_WIDTH = 32;

    logic clk;
    logic rst_n;

    // AXI4-Lite Interface
    logic [7:0]  s_axil_awaddr;
    logic [2:0]  s_axil_awprot;
    logic        s_axil_awvalid;
    logic        s_axil_awready;

    logic [31:0] s_axil_wdata;
    logic [3:0]  s_axil_wstrb;
    logic        s_axil_wvalid;
    logic        s_axil_wready;

    logic [1:0]  s_axil_bresp;
    logic        s_axil_bvalid;
    logic        s_axil_bready;

    logic [7:0]  s_axil_araddr;
    logic [2:0]  s_axil_arprot;
    logic        s_axil_arvalid;
    logic        s_axil_arready;

    logic [31:0] s_axil_rdata;
    logic [1:0]  s_axil_rresp;
    logic        s_axil_rvalid;
    logic        s_axil_rready;

    // AXI4-Stream Ingress (DMA MM2S -> Accelerator)
    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;

    // AXI4-Stream Egress (Accelerator -> DMA S2MM)
    logic [31:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;

    // Interrupt
    logic        irq_done;

    // Instantiate Top-Level FPGA SoC Core
    accelerator_ternary_axi_top #(
        .AXIL_ADDR_WIDTH(8),
        .AXIL_DATA_WIDTH(32),
        .AXIS_DATA_WIDTH(32),
        .CORE_DATA_WIDTH(16),
        .ACCUM_WIDTH    (32),
        .ROWS           (8),
        .COLS           (8),
        .BUFFER_VECS    (16),
        .OUT_BUF_DEPTH  (64)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axil_awaddr (s_axil_awaddr),
        .s_axil_awprot (s_axil_awprot),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata  (s_axil_wdata),
        .s_axil_wstrb  (s_axil_wstrb),
        .s_axil_wvalid (s_axil_wvalid),
        .s_axil_wready (s_axil_wready),
        .s_axil_bresp  (s_axil_bresp),
        .s_axil_bvalid (s_axil_bvalid),
        .s_axil_bready (s_axil_bready),
        .s_axil_araddr (s_axil_araddr),
        .s_axil_arprot (s_axil_arprot),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata  (s_axil_rdata),
        .s_axil_rresp  (s_axil_rresp),
        .s_axil_rvalid (s_axil_rvalid),
        .s_axil_rready (s_axil_rready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .irq_done      (irq_done)
    );

    // 100 MHz Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // BFM Tasks: AXI4-Lite
    // -------------------------------------------------------------------------
    task axil_write(input [7:0] addr, input [31:0] data);
        @(negedge clk);
        s_axil_awaddr  = addr;
        s_axil_awvalid = 1'b1;
        s_axil_wdata   = data;
        s_axil_wstrb   = 4'hF;
        s_axil_wvalid  = 1'b1;
        s_axil_bready  = 1'b1;

        wait(s_axil_awready && s_axil_wready);
        @(negedge clk);
        s_axil_awvalid = 1'b0;
        s_axil_wvalid  = 1'b0;

        wait(s_axil_bvalid);
        @(negedge clk);
        s_axil_bready  = 1'b0;
    endtask

    task axil_read(input [7:0] addr, output [31:0] data);
        @(negedge clk);
        s_axil_araddr  = addr;
        s_axil_arvalid = 1'b1;
        s_axil_rready  = 1'b1;

        wait(s_axil_arready);
        @(negedge clk);
        s_axil_arvalid = 1'b0;

        wait(s_axil_rvalid);
        data = s_axil_rdata;
        @(negedge clk);
        s_axil_rready  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // BFM Tasks: AXI4-Stream
    // -------------------------------------------------------------------------
    task axis_push_word(input [31:0] word, input logic is_last);
        @(negedge clk);
        s_axis_tdata  = word;
        s_axis_tvalid = 1'b1;
        s_axis_tlast  = is_last;

        wait(s_axis_tready);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    // Bookkeeping
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;

    int signed act_mat [0:15][0:7];
    int signed w_mat   [0:15][0:7];
    int signed c_gold  [0:15][0:7];
    int signed c_recv  [0:63];

    initial begin
        rst_n          = 0;
        s_axil_awaddr  = 0;
        s_axil_awprot  = 0;
        s_axil_awvalid = 0;
        s_axil_wdata   = 0;
        s_axil_wstrb   = 0;
        s_axil_wvalid  = 0;
        s_axil_bready  = 0;
        s_axil_araddr  = 0;
        s_axil_arprot  = 0;
        s_axil_arvalid = 0;
        s_axil_rready  = 0;

        s_axis_tdata   = 0;
        s_axis_tvalid  = 0;
        s_axis_tlast   = 0;
        m_axis_tready  = 1; // DMA ready to receive

        #50;
        @(negedge clk);
        rst_n = 1;
        #20;
        @(negedge clk);

        $display("\n===============================================================");
        $display("  STARTING FPGA SYSTEM AXI-LITE & AXI-STREAM VERIFICATION");
        $display("  Target Clock: 100 MHz | Mesh: 8x8 | Protocol: AXI4-Lite & AXI4-Stream");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // TEST 1: MMIO Register Read/Write via AXI4-Lite
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 1] AXI4-Lite Configuration Register Read/Write ---");
        total_tests++;
        begin
            logic [31:0] rdata;
            axil_write(8'h08, 32'd8);  // CFG_M = 8
            axil_write(8'h0C, 32'd8);  // CFG_K = 8
            axil_write(8'h10, 32'd8);  // CFG_N = 8

            axil_read(8'h08, rdata);
            if (rdata == 32'd8) begin
                $display("[PASS] AXI-Lite MMIO Write/Read verified: CFG_M = %0d", rdata);
                passed_tests++;
            end else begin
                $display("[FAIL] AXI-Lite MMIO Write/Read failed: expected 8, got %0d", rdata);
                failed_tests++;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 2: Weight-Stationary 8x8 GEMM via AXI4-Stream DMA
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 2] 8x8 WS GEMM via AXI4-Stream DMA Ingestion/Egress ---");
        // Generate weights (8 words = 64 weights)
        // Group into 32-bit DMA words (2x 16-bit packed weights per 32-bit word)
        begin
            logic [15:0] w_words [0:7];
            w_words[0] = 16'h2449;
            w_words[1] = 16'h4992;
            w_words[2] = 16'h1248;
            w_words[3] = 16'h9224;
            w_words[4] = 16'h5555;
            w_words[5] = 16'haaaa;
            w_words[6] = 16'h0000;
            w_words[7] = 16'h6996;

            for (int r = 0; r < 8; r++) begin
                for (int c = 0; c < 8; c++) begin
                    logic [1:0] code;
                    code = w_words[r][c*2 +: 2];
                    if (code == 2'b01)      w_mat[r][c] = 1;
                    else if (code == 2'b10) w_mat[r][c] = -1;
                    else                    w_mat[r][c] = 0;
                end
            end

            // Stream 4x 32-bit DMA words of weights to S_AXIS
            for (int w = 0; w < 4; w++) begin
                axis_push_word({w_words[w*2 + 1], w_words[w*2]}, 1'b0);
            end

            // Generate 64 activations (32x 32-bit DMA words)
            for (int m = 0; m < 8; m++) begin
                for (int k = 0; k < 8; k++) begin
                    int signed val;
                    val = ((m + 1) * 80) - (k * 120);
                    act_mat[m][k] = val;
                end
            end

            for (int m = 0; m < 8; m++) begin
                for (int n = 0; n < 8; n++) begin
                    c_gold[m][n] = 0;
                    for (int k = 0; k < 8; k++) begin
                        c_gold[m][n] = c_gold[m][n] + act_mat[m][k] * w_mat[k][n];
                    end
                end
            end

            // Stream 32x 32-bit DMA activation words
            for (int m = 0; m < 8; m++) begin
                for (int k = 0; k < 8; k += 2) begin
                    logic is_last;
                    logic [15:0] val0;
                    logic [15:0] val1;
                    is_last = (m == 7 && k == 6);
                    val0 = act_mat[m][k][15:0];
                    val1 = act_mat[m][k+1][15:0];
                    axis_push_word({val1, val0}, is_last);
                end
            end

            $display("[FPGA-TB] Streamed all weights and activations via S_AXIS DMA.");

            // Launch GEMM via AXI-Lite
            axil_write(8'h08, 32'd8);
            axil_write(8'h0C, 32'd8);
            axil_write(8'h10, 32'd8);
            axil_write(8'h00, 32'h03); // Force WS, Start

            // Collect 64 output words from M_AXIS DMA master
            for (int i = 0; i < 64; i++) begin
                wait(m_axis_tvalid);
                @(negedge clk);
                c_recv[i] = m_axis_tdata;
                @(posedge clk);
            end

            // Verify bit-exact results
            total_tests++;
            begin
                int mismatches;
                mismatches = 0;
                for (int m = 0; m < 8; m++) begin
                    for (int n = 0; n < 8; n++) begin
                        int actual;
                        actual = c_recv[m*8 + n];
                        if (actual !== c_gold[m][n]) begin
                            $display("[ERROR] FPGA AXI-Stream Mismatch at [%0d][%0d]: expected %0d, got %0d",
                                     m, n, c_gold[m][n], actual);
                            mismatches++;
                        end
                    end
                end

                if (mismatches == 0) begin
                    $display("[PASS] FPGA AXI-Stream DMA WS GEMM: 100%% BIT-EXACT MATCH across all 64 outputs!");
                    passed_tests++;
                end else begin
                    $display("[FAIL] FPGA AXI-Stream DMA WS GEMM: %0d mismatches detected!", mismatches);
                    failed_tests++;
                end
            end

            // Wait for irq_done
            total_tests++;
            wait(irq_done);
            if (irq_done == 1'b1) begin
                $display("[PASS] Hardware Interrupt IRQ_DONE successfully asserted to Host CPU.");
                passed_tests++;
            end else begin
                $display("[FAIL] IRQ_DONE not asserted.");
                failed_tests++;
            end

            // Read Telemetry via AXI4-Lite
            total_tests++;
            begin
                logic [31:0] skips_val;
                axil_read(8'h20, skips_val);
                $display("[INFO] AXI-Lite Telemetry: Total Zero-Skips tracked = %0d", skips_val);
                if (skips_val > 0) begin
                    $display("[PASS] Telemetry successfully read over AXI4-Lite bus.");
                    passed_tests++;
                end else begin
                    $display("[FAIL] Telemetry returned 0 skips.");
                    failed_tests++;
                end
            end
        end

        // ---------------------------------------------------------------------
        // TEST 3: Back-to-Back OS GEMM (Deep Reduction K=16 > M=8) via AXI-Stream
        // ---------------------------------------------------------------------
        $display("\n--- [TEST 3] Back-to-Back OS GEMM via AXI4-Stream DMA (Deep Reduction K=16) ---");
        begin
            logic [15:0] w_words [0:15];
            for (int k = 0; k < 16; k++) begin
                for (int r = 0; r < 8; r++) begin
                    act_mat[k][r] = ((k + 1) * 40) - (r * 25);
                end
                w_words[k] = 16'h5a5a ^ (k << 8) ^ k;
                for (int c = 0; c < 8; c++) begin
                    logic [1:0] code;
                    code = w_words[k][c*2 +: 2];
                    if (code == 2'b01)      w_mat[k][c] = 1;
                    else if (code == 2'b10) w_mat[k][c] = -1;
                    else                    w_mat[k][c] = 0;
                end
            end

            for (int r = 0; r < 8; r++) begin
                for (int c = 0; c < 8; c++) begin
                    c_gold[r][c] = 0;
                    for (int k = 0; k < 16; k++) begin
                        c_gold[r][c] = c_gold[r][c] + act_mat[k][r] * w_mat[k][c];
                    end
                end
            end

            // In OS mode, stream 128 activation words (64 32-bit DMA words) then 16 weight words (8 32-bit DMA words)
            for (int k = 0; k < 16; k++) begin
                for (int r = 0; r < 8; r += 2) begin
                    axis_push_word({act_mat[k][r+1][15:0], act_mat[k][r][15:0]}, 1'b0);
                end
            end

            for (int k = 0; k < 16; k += 2) begin
                logic is_last;
                is_last = (k == 14);
                axis_push_word({w_words[k+1], w_words[k]}, is_last);
            end

            // Launch OS GEMM via AXI-Lite
            axil_write(8'h08, 32'd8);   // M = 8
            axil_write(8'h0C, 32'd16);  // K = 16
            axil_write(8'h10, 32'd8);   // N = 8
            axil_write(8'h00, 32'h01);  // Auto Mode

            // Check dynamic mode selection via AXI-Lite
            total_tests++;
            begin
                logic [31:0] status_val;
                #40;
                axil_read(8'h04, status_val);
                if (status_val[2] == 1'b1) begin
                    $display("[PASS] AXI-Lite Status Register confirms Autonomous OS Mode selected for K=16 > M=8!");
                    passed_tests++;
                end else begin
                    $display("[FAIL] Autonomous OS Mode not selected: status = %0h", status_val);
                    failed_tests++;
                end
            end

            // Collect 64 output words from M_AXIS DMA master
            for (int i = 0; i < 64; i++) begin
                wait(m_axis_tvalid);
                @(negedge clk);
                c_recv[i] = m_axis_tdata;
                @(posedge clk);
            end

            // Verify bit-exact OS results
            total_tests++;
            begin
                int mismatches;
                mismatches = 0;
                for (int r = 0; r < 8; r++) begin
                    for (int c = 0; c < 8; c++) begin
                        int actual;
                        actual = c_recv[r*8 + c];
                        if (actual !== c_gold[r][c]) begin
                            $display("[ERROR] FPGA AXI-Stream OS Mismatch at [%0d][%0d]: expected %0d, got %0d",
                                     r, c, c_gold[r][c], actual);
                            mismatches++;
                        end
                    end
                end

                if (mismatches == 0) begin
                    $display("[PASS] FPGA AXI-Stream DMA OS Deep-Reduction: 100%% BIT-EXACT MATCH across all 64 outputs!");
                    passed_tests++;
                end else begin
                    $display("[FAIL] FPGA AXI-Stream DMA OS Deep-Reduction: %0d mismatches detected!", mismatches);
                    failed_tests++;
                end
            end
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("  FPGA SYSTEM AXI-LITE & AXI-STREAM VERIFICATION SUMMARY");
        $display("  TOTAL TESTS: %0d | PASSED: %0d | FAILED: %0d", total_tests, passed_tests, failed_tests);
        $display("===============================================================\n");

        if (failed_tests == 0) begin
            $display(">> FULL FPGA AXI SYSTEM INTEGRATION: SUCCESS!\n");
        end else begin
            $display(">> FULL FPGA AXI SYSTEM INTEGRATION: FAILED!\n");
            $fatal(1);
        end

        $finish;
    end

endmodule
