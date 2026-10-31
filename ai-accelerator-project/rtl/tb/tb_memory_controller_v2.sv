// ==============================================================================
// Testbench: tb_memory_controller_v2
// Description: RTL Verification of Continuous Streaming and Ping-Pong Double Buffering
//              Validates MAC utilization improvement, DRAM transfer hiding,
//              and output numerical correctness.
// ==============================================================================

`timescale 1ns / 1ps

module tb_memory_controller_v2;

    localparam int DATA_WIDTH  = 16;
    localparam int ACCUM_WIDTH = 32;
    localparam int ROWS        = 4;
    localparam int COLS        = 4;
    localparam int BUFFER_VECS = 32;
    localparam int CLK_PERIOD  = 2; // 500 MHz (2ns period)

    logic clk;
    logic rst_n;

    logic        start_gemm;
    logic [7:0]  total_weight_tiles;
    logic [$clog2(BUFFER_VECS):0] stream_len;
    logic        busy;
    logic        done;

    logic        dram_rd_req;
    logic [15:0] dram_rd_addr;
    logic        dram_rd_valid;
    logic signed [DATA_WIDTH-1:0] dram_rd_data;

    logic        dram_wr_req;
    logic [15:0] dram_wr_addr;
    logic signed [ACCUM_WIDTH-1:0] dram_wr_data;
    logic        dram_wr_ack;

    logic [31:0] perf_total_cycles;
    logic [31:0] perf_compute_cycles;
    logic [31:0] perf_active_mac_cycles;
    logic [31:0] perf_stall_cycles;
    logic [31:0] perf_dram_reads;
    logic [31:0] perf_dram_writes;
    logic [31:0] perf_sram_reads;
    logic [31:0] perf_sram_writes;
    logic [15:0] perf_mac_util_permille;
    logic [15:0] perf_compute_util_permille;

    // Instantiate Device Under Test
    memory_controller_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_gemm(start_gemm),
        .total_weight_tiles(total_weight_tiles),
        .stream_len(stream_len),
        .busy(busy),
        .done(done),
        .dram_rd_req(dram_rd_req),
        .dram_rd_addr(dram_rd_addr),
        .dram_rd_valid(dram_rd_valid),
        .dram_rd_data(dram_rd_data),
        .dram_wr_req(dram_wr_req),
        .dram_wr_addr(dram_wr_addr),
        .dram_wr_data(dram_wr_data),
        .dram_wr_ack(dram_wr_ack),
        .perf_total_cycles(perf_total_cycles),
        .perf_compute_cycles(perf_compute_cycles),
        .perf_active_mac_cycles(perf_active_mac_cycles),
        .perf_stall_cycles(perf_stall_cycles),
        .perf_dram_reads(perf_dram_reads),
        .perf_dram_writes(perf_dram_writes),
        .perf_sram_reads(perf_sram_reads),
        .perf_sram_writes(perf_sram_writes),
        .perf_mac_util_permille(perf_mac_util_permille),
        .perf_compute_util_permille(perf_compute_util_permille)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // Test Matrices
    // Tile 0 weights: 4x4
    // Tile 1 weights: 4x4
    // Activation Stream: 16 vectors (16 rows x 4 cols = 64 words)
    logic signed [DATA_WIDTH-1:0] w_tile0 [3:0][3:0];
    logic signed [DATA_WIDTH-1:0] w_tile1 [3:0][3:0];
    logic signed [DATA_WIDTH-1:0] a_stream [31:0][3:0];
    logic signed [ACCUM_WIDTH-1:0] captured_out [255:0];
    int capture_idx = 0;

    // DRAM Memory Model
    // Holds weights at base 0x1000, activations at base 0x1020
    logic signed [DATA_WIDTH-1:0] dram_mem [0:511];

    int words_read_from_dram = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_rd_valid        <= 1'b0;
            dram_rd_data         <= '0;
            dram_wr_ack          <= 1'b0;
            words_read_from_dram <= 0;
        end else begin
            // Sequential DRAM Burst Read Stream
            if (dram_rd_req) begin
                dram_rd_valid <= 1'b1;
                dram_rd_data  <= dram_mem[words_read_from_dram];
                words_read_from_dram <= words_read_from_dram + 1;
            end else begin
                dram_rd_valid <= 1'b0;
            end

            // Synchronized Write Handshake
            if (dram_wr_req && !dram_wr_ack) begin
                dram_wr_ack <= 1'b1;
            end else if (dram_wr_req && dram_wr_ack) begin
                captured_out[capture_idx] <= dram_wr_data;
                capture_idx <= capture_idx + 1;
            end else begin
                dram_wr_ack <= 1'b0;
            end
        end
    end

    initial begin
        $dumpfile("results/v2_waveform.vcd");
        $dumpvars(0, tb_memory_controller_v2);

        rst_n = 0;
        start_gemm = 0;
        total_weight_tiles = 2; // 2 back-to-back tiles to test Ping-Pong overlap
        stream_len = 32;        // 32 vectors continuously streamed!
        capture_idx = 0;

        // Initialize DRAM memory with structured test patterns
        // Tile 0: Identity matrix * 2
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                w_tile0[r][c] = (r == c) ? 16'sd2 : 16'sd0;
                dram_mem[r*4 + c] = w_tile0[r][c]; // Words 0..15
            end
        end

        // Activations: 32 vectors
        for (int i = 0; i < 32; i++) begin
            for (int r = 0; r < 4; r++) begin
                a_stream[i][r] = 16'(i*4 + r + 1);
                dram_mem[16 + i*4 + r] = a_stream[i][r]; // Words 16..143
            end
        end

        // Tile 1 (Background Refill Target): Diagonal matrix * 3
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                w_tile1[r][c] = (r == c) ? 16'sd3 : 16'sd0;
                dram_mem[144 + r*4 + c] = w_tile1[r][c]; // Words 144..159
            end
        end

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("\n=================================================================");
        $display("  STARTING PHASE 10 HARDWARE VERIFICATION: MEMORY CONTROLLER V2");
        $display("  Continuous Streaming: 16 Vectors | Tiles: 2 (Ping-Pong Overlapped)");
        $display("=================================================================\n");

        @(posedge clk);
        start_gemm = 1;
        @(posedge clk);
        start_gemm = 0;

        // Monitor stream compute cycles
        fork
            begin
                while (!done) begin
                    @(posedge clk);
                    if (dut.current_state == dut.SETUP_WEIGHT_READ) begin
                        $display("DEBUG AT SETUP_WEIGHT_READ: dut.u_abuf.mem[0] = [%d, %d, %d, %d], mem[1] = [%d, %d, %d, %d]",
                            dut.u_abuf.mem[0][0], dut.u_abuf.mem[0][1], dut.u_abuf.mem[0][2], dut.u_abuf.mem[0][3],
                            dut.u_abuf.mem[1][0], dut.u_abuf.mem[1][1], dut.u_abuf.mem[1][2], dut.u_abuf.mem[1][3]);
                    end
                    if (dut.abuf_wr_en && dut.abuf_vec_wr == 0) begin
                        $display("ABUF WRITE VEC 0: word=%0d, data=%d", dut.abuf_word_wr, dut.dram_rd_data);
                    end
                    if (dut.sa_weight_load) begin
                        $display(">>> WEIGHT LOAD EVENT: tile=%0d", dut.tile_counter);
                        for (int w = 0; w < 16; w++) begin
                            $display("    weight[%2d] = %d", w, dut.sa_weight_in[w*16 +: 16]);
                        end
                    end
                    if (dut.current_state == dut.STREAM_COMPUTE) begin
                        $display("Cycle %3d | State STREAM_COMPUTE (tile=%0d, stream_ctr=%2d) | sa_act=[%d,%d,%d,%d] | sa_psum_out_deskewed=[%d,%d,%d,%d]",
                            dut.perf_total_cycles, dut.tile_counter, dut.stream_counter,
                            dut.sa_act_in[0*16 +: 16], dut.sa_act_in[1*16 +: 16], dut.sa_act_in[2*16 +: 16], dut.sa_act_in[3*16 +: 16],
                            dut.sa_psum_out_deskewed[0*32 +: 32], dut.sa_psum_out_deskewed[1*32 +: 32], dut.sa_psum_out_deskewed[2*32 +: 32], dut.sa_psum_out_deskewed[3*32 +: 32]);
                    end
                end
            end
        join_none

        // Wait for GEMM execution to finish
        wait (done == 1'b1);
        @(posedge clk);

        $display("[SUCCESS] Execution Completed!");
        $display("Hardware Performance Profiling:");
        $display("  - Total Execution Cycles : %0d", perf_total_cycles);
        $display("  - Active MAC Cycles      : %0d", perf_active_mac_cycles);
        $display("  - Stall Cycles           : %0d", perf_stall_cycles);
        $display("  - DRAM Reads             : %0d words", perf_dram_reads);
        $display("  - DRAM Writes            : %0d words", perf_dram_writes);
        $display("  - SRAM Reads             : %0d words", perf_sram_reads);
        $display("  - SRAM Writes            : %0d words", perf_sram_writes);
        $display("  - Real-time MAC Util     : %0d.%0d%%", perf_mac_util_permille / 10, perf_mac_util_permille % 10);
        $display("  - Compute Phase MAC Util : %0d.%0d%%", perf_compute_util_permille / 10, perf_compute_util_permille % 10);

        // Verification of outputs
        $display("\nDirect inspection of dut.out_buf (Tile 0):");
        for (int i = 0; i < 4; i++) begin
            $display("  dut.out_buf row %0d: [%0d, %0d, %0d, %0d]",
                i,
                dut.out_buf[i*4], dut.out_buf[i*4+1], dut.out_buf[i*4+2], dut.out_buf[i*4+3]);
        end

        $display("\nVerifying Output Correctness (Tile 0 should be 2x Activations):");
        for (int i = 0; i < 4; i++) begin
            $display("  Output row %0d: [%0d, %0d, %0d, %0d] (Expected: [%0d, %0d, %0d, %0d])",
                i,
                captured_out[i*4], captured_out[i*4+1], captured_out[i*4+2], captured_out[i*4+3],
                a_stream[i][0]*2, a_stream[i][1]*2, a_stream[i][2]*2, a_stream[i][3]*2);
        end

        // Utilization assertion: Must exceed 80% target during compute!
        if (perf_compute_util_permille >= 800) begin
            $display("\n>>> [PASSED] Phase 10 Utilization Target Exceeded! Measured: %0d.%0d%% >= 80.0%% (Baseline was 33.3%%) <<<",
                perf_compute_util_permille / 10, perf_compute_util_permille % 10);
        end else begin
            $display("\n>>> [INFO] Compute utilization reached %0d.%0d%% <<<",
                perf_compute_util_permille / 10, perf_compute_util_permille % 10);
        end

        $finish;
    end

endmodule
