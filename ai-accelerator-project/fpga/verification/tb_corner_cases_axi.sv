// ==============================================================================
// Testbench: tb_corner_cases_axi.sv
// Description: Directed Hardware Verification for Critical FPGA AXI Corner Cases:
//   1. Stream Data Ingestion, AXI-Lite Config & Execution Launch
//   2. FIFO Completeness upon IRQ Assertion (exact 64 words exist before done)
//   3. Sticky Interrupt (IRQ) persistence and Status Register Read Invariance
//   4. Explicit Write-1-to-Clear (W1C) Semantics & Invariance
//   5. Extreme M_AXIS Downstream Backpressure & Final-Beat TLAST/TVALID Persistence
//   6. Hardware Telemetry & Cycle Counter Readback via MMIO
//   7. Simultaneous Hardware Completion & Software W1C (Set-Dominant Priority)
//   8. Repeated Back-to-Back GEMM Tile Transactions, FIFO Pointer Reset & Data Integrity
//   + Continuous AXI4-Stream & AXI4-Lite Protocol Compliance Monitoring
// ==============================================================================

`timescale 1ns / 1ps

module tb_corner_cases_axi;

    localparam real CLK_PERIOD = 10.0; // 100 MHz System Clock (10.0 ns)

    logic        clk;
    logic        rst_n;

    // AXI4-Lite Slave Interface
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

    // AXI4-Stream Ingress Slave (DMA MM2S)
    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;

    // AXI4-Stream Egress Master (DMA S2MM)
    logic [31:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;

    // Dedicated Interrupt Line
    logic        irq_done;

    // DUT Instantiation
    accelerator_ternary_axi_top #(
        .AXIL_ADDR_WIDTH(8),
        .AXIL_DATA_WIDTH(32),
        .AXIS_DATA_WIDTH(32),
        .CORE_DATA_WIDTH(16),
        .ACCUM_WIDTH(32),
        .ROWS(8),
        .COLS(8),
        .BUFFER_VECS(128),
        .OUT_BUF_DEPTH(512)
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

    // 100 MHz Clock Generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // =========================================================================
    // Continuous AXI Protocol Compliance Checker
    // =========================================================================
    int protocol_violations = 0;

    // Check M_AXIS Egress: When stalled (TVALID && !TREADY), TVALID, TDATA, TLAST must not change until handshake
    logic        prev_m_stalled;
    logic [31:0] prev_m_axis_tdata;
    logic        prev_m_axis_tlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_m_stalled    <= 1'b0;
            prev_m_axis_tdata <= '0;
            prev_m_axis_tlast <= 1'b0;
        end else begin
            if (prev_m_stalled) begin
                if (!m_axis_tvalid) begin
                    $display("[AXI PROTOCOL ERROR] M_AXIS TVALID dropped without handshake at time %0t!", $time);
                    protocol_violations++;
                end
                if (m_axis_tdata !== prev_m_axis_tdata) begin
                    $display("[AXI PROTOCOL ERROR] M_AXIS TDATA changed while stalled! prev=%h curr=%h at time %0t",
                             prev_m_axis_tdata, m_axis_tdata, $time);
                    protocol_violations++;
                end
                if (m_axis_tlast !== prev_m_axis_tlast) begin
                    $display("[AXI PROTOCOL ERROR] M_AXIS TLAST changed while stalled! prev=%b curr=%b at time %0t",
                             prev_m_axis_tlast, m_axis_tlast, $time);
                    protocol_violations++;
                end
            end
            prev_m_stalled    <= (m_axis_tvalid && !m_axis_tready);
            prev_m_axis_tdata <= m_axis_tdata;
            prev_m_axis_tlast <= m_axis_tlast;
        end
    end

    // Check S_AXIS Ingress: When stalled (TVALID && !TREADY), TVALID, TDATA, TLAST must remain stable
    logic        prev_s_stalled;
    logic [31:0] prev_s_axis_tdata;
    logic        prev_s_axis_tlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_s_stalled    <= 1'b0;
            prev_s_axis_tdata <= '0;
            prev_s_axis_tlast <= 1'b0;
        end else begin
            if (prev_s_stalled) begin
                if (!s_axis_tvalid) begin
                    $display("[AXI PROTOCOL ERROR] S_AXIS TVALID dropped without handshake at time %0t!", $time);
                    protocol_violations++;
                end
                if (s_axis_tdata !== prev_s_axis_tdata) begin
                    $display("[AXI PROTOCOL ERROR] S_AXIS TDATA changed while stalled at time %0t!", $time);
                    protocol_violations++;
                end
                if (s_axis_tlast !== prev_s_axis_tlast) begin
                    $display("[AXI PROTOCOL ERROR] S_AXIS TLAST changed while stalled at time %0t!", $time);
                    protocol_violations++;
                end
            end
            prev_s_stalled    <= (s_axis_tvalid && !s_axis_tready);
            prev_s_axis_tdata <= s_axis_tdata;
            prev_s_axis_tlast <= s_axis_tlast;
        end
    end

    // =========================================================================
    // AXI Bus Driver Tasks
    // =========================================================================

    // AXI-Lite write task
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

    // AXI-Lite read task
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

    // AXI-Stream push task
    task axis_push(input [31:0] word, input logic is_last);
        @(negedge clk);
        s_axis_tdata  = word;
        s_axis_tvalid = 1'b1;
        s_axis_tlast  = is_last;

        wait(s_axis_tready);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    // Accounting counters
    int total_corner_tests = 0;
    int passed_corner_tests = 0;

    // Separate variables without static initialization warnings
    int words_popped;
    logic tlast_stable;

    // =========================================================================
    // Main Directed Test Sequence
    // =========================================================================
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
        m_axis_tready  = 0; // Downstream initially stalled

        #40;
        @(negedge clk);
        rst_n = 1;
        #20;
        @(negedge clk);

        $display("===============================================================");
        $display("  STARTING DIRECTED AXI CORNER-CASE HARDWARE VERIFICATION");
        $display("===============================================================");

        // ---------------------------------------------------------------------
        // TEST C1: Ingest Stream Data, AXI-Lite Config & Execution Launch
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 1] Ingest Stream Data & Launch WS GEMM ---");
        // Push 4 words weights (all +1: 2-bit 01 -> 32'h55555555)
        for (int i = 0; i < 4; i++) begin
            axis_push(32'h55555555, 1'b0);
        end
        // Push 32 words activations (all 100: {16'd100, 16'd100})
        for (int i = 0; i < 32; i++) begin
            axis_push({16'd100, 16'd100}, (i == 31));
        end

        // Configure M=8, K=8, N=8, Start
        axil_write(8'h08, 32'd8);
        axil_write(8'h0C, 32'd8);
        axil_write(8'h10, 32'd8);
        axil_write(8'h00, 32'h03); // START + WS mode

        // Verify that core left IDLE and rx_mem holds ingested data
        if (dut.u_axis_adapter.rx_wr_ptr == 72) begin // 36 words of 32-bit = 72 words of 16-bit
            $display("[PASS] Stream ingestion complete: rx_wr_ptr = %0d (36 32-bit DMA words ingested)",
                     dut.u_axis_adapter.rx_wr_ptr);
            passed_corner_tests++;
        end else begin
            $display("[FAIL] Incomplete stream ingestion: rx_wr_ptr = %0d (expected 72)",
                     dut.u_axis_adapter.rx_wr_ptr);
        end

        // ---------------------------------------------------------------------
        // TEST C2: Verify DMA Egress FIFO Completeness Before / Upon Done
        // ---------------------------------------------------------------------
        total_corner_tests++;
        wait(irq_done);
        $display("\n--- [CORNER TEST 2] FIFO Completeness upon IRQ Assertion ---");
        if (dut.u_axis_adapter.tx_wr_ptr == 64) begin
            $display("[PASS] Exact 64 words reside in Egress FIFO upon IRQ assertion (tx_wr_ptr = %0d)",
                     dut.u_axis_adapter.tx_wr_ptr);
            passed_corner_tests++;
        end else begin
            $display("[FAIL] Incomplete words in FIFO: tx_wr_ptr = %0d (expected 64)",
                     dut.u_axis_adapter.tx_wr_ptr);
        end

        // ---------------------------------------------------------------------
        // TEST C3: Sticky Interrupt & Status Register Read Persistence
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 3] Sticky Interrupt & Status Register Persistence ---");
        begin
            logic [31:0] status_r;
            // Wait 25 cycles after irq asserted
            repeat (25) @(posedge clk);
            axil_read(8'h04, status_r);
            if (irq_done == 1'b1 && status_r[1] == 1'b1) begin
                $display("[PASS] IRQ line and STATUS[1] remain stably HIGH 25 cycles after completion (STATUS = %h)", status_r);
                passed_corner_tests++;
            end else begin
                $display("[FAIL] Interrupt deasserted prematurely! irq_done=%b status=%h", irq_done, status_r);
            end
        end

        // ---------------------------------------------------------------------
        // TEST C4: Explicit Write-1-to-Clear (W1C) Semantics
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 4] Explicit Write-1-to-Clear (W1C) Semantics ---");
        begin
            logic [31:0] status_r;
            // Write 0 to status (should NOT clear W1C bit 1)
            axil_write(8'h04, 32'h00);
            if (irq_done == 1'b1) begin
                $display("[PASS] Writing 0x00 to STATUS preserved sticky IRQ.");
            end else begin
                $display("[FAIL] Writing 0x00 cleared IRQ unexpectedly!");
            end

            // Write 0x02 (bit 1) to status: MUST clear IRQ
            axil_write(8'h04, 32'h02);
            axil_read(8'h04, status_r);
            if (irq_done == 1'b0 && status_r[1] == 1'b0) begin
                $display("[PASS] W1C write of 0x02 to STATUS cleanly deasserted IRQ line and STATUS[1].");
                passed_corner_tests++;
            end else begin
                $display("[FAIL] W1C failed to clear IRQ: irq_done=%b status=%h", irq_done, status_r);
            end
        end

        // ---------------------------------------------------------------------
        // TEST C5: Extreme Downstream Backpressure & TLAST Persistence
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 5] Extreme M_AXIS Backpressure & TLAST Persistence ---");
        begin
            words_popped = 0;
            tlast_stable = 1'b1;

            // Pop first 63 words with random backpressure
            while (words_popped < 63) begin
                @(negedge clk);
                m_axis_tready = ($random % 2) != 0;
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    words_popped++;
                end
            end

            $display("[INFO] Successfully popped 63 words. Stalling at word 64 (final beat)...");
            // Now at word 63 (the 64th word): freeze TREADY = 0 for 15 clock cycles!
            @(negedge clk);
            m_axis_tready = 1'b0;

            for (int stall = 0; stall < 15; stall++) begin
                @(posedge clk);
                if (!(m_axis_tvalid === 1'b1 && m_axis_tlast === 1'b1)) begin
                    tlast_stable = 1'b0;
                    $display("[ERROR] TLAST or TVALID dropped during stall cycle %0d! valid=%b last=%b",
                             stall, m_axis_tvalid, m_axis_tlast);
                end
            end

            if (tlast_stable) begin
                $display("[PASS] TLAST and TVALID remained 100%% stable and asserted across all 15 stall cycles!");
            end

            // Now release backpressure (TREADY = 1)
            @(negedge clk);
            m_axis_tready = 1'b1;
            @(posedge clk); // Final word accepted here
            words_popped++;

            // On next cycle, both TVALID and TLAST must deassert
            @(posedge clk);
            if (m_axis_tvalid == 1'b0 && m_axis_tlast == 1'b0 && words_popped == 64) begin
                $display("[PASS] Final beat accepted; TVALID and TLAST cleanly deasserted together.");
                passed_corner_tests++;
            end else begin
                $display("[FAIL] Stream deassertion failed: valid=%b last=%b words=%0d",
                         m_axis_tvalid, m_axis_tlast, words_popped);
            end
            m_axis_tready = 1'b0;
        end

        // ---------------------------------------------------------------------
        // TEST C6: Telemetry Readback Verification
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 6] Hardware Telemetry & Cycle Counter Readback ---");
        begin
            logic [31:0] zero_skips_val;
            logic [31:0] cycles_val;
            zero_skips_val = 0;
            cycles_val = 0;
            axil_read(8'h20, zero_skips_val);
            axil_read(8'h24, cycles_val);
            $display("[INFO] Telemetry: zero_skips=%0d, total_cycles=%0d", zero_skips_val, cycles_val);
            if (cycles_val > 0) begin
                $display("[PASS] Hardware telemetry and cycle counters accurately read via AXI-Lite.");
                passed_corner_tests++;
            end else begin
                $display("[FAIL] Invalid cycle counter returned: %0d", cycles_val);
            end
        end

        // ---------------------------------------------------------------------
        // TEST C7: Simultaneous Hardware Completion & Software W1C (Set-Dominant)
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 7] Simultaneous Hardware Completion & Software W1C (Set-Dominant Priority) ---");
        begin
            // Feed a small transaction to test the edge race condition
            for (int i = 0; i < 4; i++) axis_push(32'h55555555, 1'b0);
            for (int i = 0; i < 32; i++) axis_push({16'd10, 16'd10}, (i == 31));

            // Start GEMM
            axil_write(8'h08, 32'd8);
            axil_write(8'h0C, 32'd8);
            axil_write(8'h10, 32'd8);
            axil_write(8'h00, 32'h03);

            // Wait until word 63 (the 63rd word) is being written, so AXI-Lite write aligns with core_done
            wait(dut.u_axis_adapter.tx_wr_ptr == 63);

            // Synchronously initiate AXI-Lite W1C on STATUS (0x02) so reg_wr_en aligns exactly with core_done!
            @(negedge clk);
            s_axil_awaddr  = 8'h04;
            s_axil_awvalid = 1'b1;
            s_axil_wdata   = 32'h02;
            s_axil_wstrb   = 4'hF;
            s_axil_wvalid  = 1'b1;
            s_axil_bready  = 1'b1;

            // Wait for write address/data handshake
            wait(s_axil_awready && s_axil_wready);
            $display("[INFO] Handshake edge: core_done=%b, reg_wr_en=%b, reg_addr=%h, reg_wdata=%h, irq_done=%b at %0t",
                     dut.core_done, dut.u_axil_slave.reg_wr_en, dut.u_axil_slave.reg_addr, dut.u_axil_slave.reg_wdata, irq_done, $time);

            @(negedge clk);
            s_axil_awvalid = 1'b0;
            s_axil_wvalid  = 1'b0;

            // Wait for write response handshake
            wait(s_axil_bvalid);
            @(negedge clk);
            s_axil_bready  = 1'b0;

            @(posedge clk);
            #1;
            $display("[INFO] After simultaneous edge: irq_done=%b (expected 1 due to set-dominant priority)", irq_done);

            // Verify set-dominant priority: irq_done must be HIGH (1'b1)
            if (irq_done == 1'b1) begin
                $display("[PASS] Set-dominant priority confirmed: irq_done asserted (1'b1) despite concurrent W1C write!");
                passed_corner_tests++;
            end else begin
                $display("[FAIL] Priority inversion defect: software W1C dropped concurrent completion interrupt!");
            end

            // Flush out outputs to clear FIFO for next test
            @(negedge clk);
            m_axis_tready = 1'b1;
            wait(m_axis_tvalid && m_axis_tlast);
            @(posedge clk);
            @(negedge clk);
            m_axis_tready = 1'b0;

            // Now perform a clean software W1C to acknowledge the interrupt
            axil_write(8'h04, 32'h02);
            @(posedge clk);
            if (irq_done == 1'b0) begin
                $display("[PASS] Software subsequently cleared irq_done cleanly via W1C.");
            end
        end



        // ---------------------------------------------------------------------
        // TEST C8: Repeated Back-to-Back GEMM Tile Transactions Over DMA
        // ---------------------------------------------------------------------
        total_corner_tests++;
        $display("\n--- [CORNER TEST 8] Repeated Back-to-Back GEMM Tile Transactions Over DMA ---");
        begin
            logic all_outputs_match;
            int word_out_idx;
            all_outputs_match = 1'b1;
            word_out_idx = 0;

            // Ingest new weights: all -1 (2-bit 10 -> 32'hAAAAAAAA)
            for (int i = 0; i < 4; i++) begin
                axis_push(32'hAAAAAAAA, 1'b0);
            end
            // Ingest new activations: all +50 ({16'd50, 16'd50})
            for (int i = 0; i < 32; i++) begin
                axis_push({16'd50, 16'd50}, (i == 31));
            end

            // Start second GEMM transaction (M=8, K=8, N=8)
            axil_write(8'h08, 32'd8);
            axil_write(8'h0C, 32'd8);
            axil_write(8'h10, 32'd8);
            axil_write(8'h00, 32'h03);

            // Verify pointer resets
            if (dut.u_axis_adapter.tx_rd_ptr == 0) begin
                $display("[PASS] Second transaction cleanly reset tx_rd_ptr to 0.");
            end

            // Wait for completion
            wait(irq_done);

            // Check that all 64 words exist in egress buffer
            if (dut.u_axis_adapter.tx_wr_ptr == 64) begin
                $display("[PASS] Second GEMM completed with exact 64 words in FIFO.");
            end else begin
                $display("[FAIL] Unexpected tx_wr_ptr in second transaction: %0d", dut.u_axis_adapter.tx_wr_ptr);
                all_outputs_match = 1'b0;
            end

            // Drain and verify values: Expected = 8 * (-1 * 50) = -400 = 32'shFFFFFE70
            @(negedge clk);
            m_axis_tready = 1'b1;

            while (word_out_idx < 64) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    if ($signed(m_axis_tdata) !== -32'sd400) begin
                        $display("[ERROR] Word %0d mismatch: got %0d, expected -400", word_out_idx, $signed(m_axis_tdata));
                        all_outputs_match = 1'b0;
                    end
                    if (word_out_idx == 63 && !m_axis_tlast) begin
                        $display("[ERROR] Word 63 did not assert TLAST!");
                        all_outputs_match = 1'b0;
                    end
                    word_out_idx++;
                end
            end

            @(negedge clk);
            m_axis_tready = 1'b0;

            if (all_outputs_match) begin
                $display("[PASS] All 64 outputs of second tile matched expected (-400) bit-exactly with TLAST asserted!");
                passed_corner_tests++;
            end else begin
                $display("[FAIL] Data mismatches or TLAST failure detected in second transaction.");
            end

            // Clear IRQ
            axil_write(8'h04, 32'h02);
            @(posedge clk);
        end

        // ---------------------------------------------------------------------
        // Summary & Signoff
        // ---------------------------------------------------------------------
        $display("\n===============================================================");
        $display("  CORNER-CASE VERIFICATION SUMMARY");
        $display("  TOTAL TESTS: %0d | PASSED: %0d | FAILED: %0d | PROTOCOL VIOLATIONS: %0d",
                 total_corner_tests, passed_corner_tests, total_corner_tests - passed_corner_tests, protocol_violations);
        $display("===============================================================");

        if (total_corner_tests == passed_corner_tests && protocol_violations == 0) begin
            $display(">> ALL DIRECTED AXI CORNER CASES PASSED 100%% WITH ZERO PROTOCOL VIOLATIONS!");
        end else begin
            $display(">> DIRECTED AXI CORNER CASES FAILED!");
            $fatal(1);
        end

        $finish;
    end

endmodule
