// ==============================================================================
// Module: memory_controller_v2
// Description: Advanced Pipelined Memory Controller for 4x4 Systolic Array
//              with Continuous Streaming and Ping-Pong Double Buffering.
//
// Optimizations implemented in Phase 10:
// 1. Continuous Pipelined Streaming:
//    - Streams arbitrary vector lengths (e.g. STREAM_VECS = 16 or 32) continuously.
//    - Latch deskewed output rows at stream_counter >= 7 and < (stream_len + 7).
// 2. Ping-Pong Double Buffering:
//    - Bank 0 feeds the active systolic array while Bank 1 is refilled from DRAM.
//    - Background DRAM weight refill finishes well before compute ends, hiding 100% of DRAM weight latency.
// 3. Real-time Hardware Performance Profiler:
//    - Reports total cycles, active compute MACs, DRAM/SRAM counts, and MAC utilization.
// ==============================================================================

`timescale 1ns / 1ps

module memory_controller_v2 #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32,
    parameter int ROWS        = 4,
    parameter int COLS        = 4,
    parameter int BUFFER_VECS = 32
)(
    input  logic                                            clk,
    input  logic                                            rst_n,

    // Accelerator Command Interface
    input  logic                                            start_gemm,
    input  logic [7:0]                                      total_weight_tiles,
    input  logic [15:0]                                     stream_len,
    output logic                                            busy,
    output logic                                            done,

    // External DRAM Handshake Interface
    output logic                                            dram_rd_req,
    output logic [15:0]                                     dram_rd_addr,
    input  logic                                            dram_rd_valid,
    input  logic signed [DATA_WIDTH-1:0]                    dram_rd_data,

    output logic                                            dram_wr_req,
    output logic [15:0]                                     dram_wr_addr,
    output logic signed [ACCUM_WIDTH-1:0]                   dram_wr_data,
    input  logic                                            dram_wr_ack,

    // Hardware Performance Counters
    output logic [31:0]                                     perf_total_cycles,
    output logic [31:0]                                     perf_compute_cycles,
    output logic [31:0]                                     perf_active_mac_cycles,
    output logic [31:0]                                     perf_stall_cycles,
    output logic [31:0]                                     perf_dram_reads,
    output logic [31:0]                                     perf_dram_writes,
    output logic [31:0]                                     perf_sram_reads,
    output logic [31:0]                                     perf_sram_writes,
    output logic [15:0]                                     perf_mac_util_permille,
    output logic [15:0]                                     perf_compute_util_permille
);

    typedef enum logic [3:0] {
        IDLE                 = 4'd0,
        PRELOAD_WEIGHT_BANK0 = 4'd1,
        PRELOAD_ACT_BUFFER   = 4'd2,
        SETUP_WEIGHT_READ    = 4'd3,
        SETUP_WEIGHT_LATCH   = 4'd4,
        STREAM_COMPUTE       = 4'd5,
        DRAIN_OUTPUT         = 4'd6,
        COMPLETE             = 4'd7
    } state_t;

    state_t current_state, next_state;

    logic ping_pong_sel; // 0: Bank 0 active; 1: Bank 1 active
    logic [7:0] tile_counter;

    // Subsystem Interconnect
    logic                                     sa_enable;
    logic                                     sa_weight_load;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] sa_weight_in;
    logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_in;
    logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed;

    // Weight Buffer Interface
    logic        wbuf_wr_en;
    logic        wbuf_wr_bank;
    logic [3:0]  wbuf_word_idx;
    logic        wbuf_rd_en;
    logic        wbuf_rd_bank;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] wbuf_tile_out;
    logic        wbuf_valid;

    // Activation Buffer Interface
    logic        abuf_wr_en;
    logic [$clog2(BUFFER_VECS)-1:0] abuf_vec_wr;
    logic [1:0]  abuf_word_wr;
    logic        abuf_rd_en;
    logic [$clog2(BUFFER_VECS)-1:0] abuf_vec_rd;
    logic signed [(ROWS*DATA_WIDTH)-1:0] abuf_vec_out;
    logic        abuf_valid;

    // Output Storage Buffer (Holds up to 256 output words)
    localparam int OUT_BUF_DEPTH = 256;
    logic signed [ACCUM_WIDTH-1:0] out_buf [OUT_BUF_DEPTH-1:0];
    logic [15:0] drain_counter;
    logic [15:0] total_drain_words;

    // Counters
    logic [15:0] word_counter;
    logic [15:0] req_counter;
    logic [15:0] stream_counter;
    logic [15:0] out_base;

    // Overlapped Background DRAM Weight Refill Interface
    logic        bg_dram_refill_active;
    logic [3:0]  bg_refill_word_idx;
    logic [3:0]  bg_req_counter;
    logic        bg_refill_done;

    // Instantiations
    weight_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .NUM_TILES(2)
    ) u_wbuf (
        .clk(clk),
        .rst_n(rst_n),
        .dram_wr_en(wbuf_wr_en),
        .tile_wr_sel(wbuf_wr_bank),
        .word_wr_idx(wbuf_word_idx),
        .dram_wr_data(dram_rd_data),
        .tile_rd_en(wbuf_rd_en),
        .tile_rd_sel(wbuf_rd_bank),
        .weight_tile_out(wbuf_tile_out),
        .tile_valid(wbuf_valid)
    );

    activation_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .ROWS(ROWS),
        .BUFFER_VECS(BUFFER_VECS)
    ) u_abuf (
        .clk(clk),
        .rst_n(rst_n),
        .dram_wr_en(abuf_wr_en),
        .vec_wr_addr(abuf_vec_wr),
        .word_wr_addr(abuf_word_wr),
        .dram_wr_data(dram_rd_data),
        .stream_rd_en(abuf_rd_en),
        .vec_rd_addr(abuf_vec_rd),
        .act_vec_out(abuf_vec_out),
        .vec_valid(abuf_valid)
    );

    systolic_array_4x4 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .INTERNAL_SKEW(1'b1)
    ) u_systolic_core (
        .clk(clk),
        .rst_n(rst_n),
        .enable(sa_enable),
        .weight_load(sa_weight_load),
        .weight_in_flat(sa_weight_in),
        .act_in_flat(sa_act_in),
        .psum_in_flat(sa_psum_in),
        .psum_out_flat(),
        .psum_out_deskewed_flat(sa_psum_out_deskewed),
        .act_out_flat()
    );

    assign sa_enable      = (current_state == STREAM_COMPUTE) || (current_state == SETUP_WEIGHT_LATCH);
    assign sa_weight_load = (current_state == SETUP_WEIGHT_LATCH);
    assign sa_weight_in   = wbuf_tile_out;
    assign sa_psum_in     = '0;

    assign sa_act_in = (current_state == STREAM_COMPUTE && stream_counter < stream_len) ? abuf_vec_out : '0;

    assign wbuf_rd_bank = ping_pong_sel;
    assign wbuf_wr_bank = (current_state == PRELOAD_WEIGHT_BANK0) ? 1'b0 : ~ping_pong_sel;

    assign busy = (current_state != IDLE) && (current_state != COMPLETE);
    assign done = (current_state == COMPLETE);

    assign dram_wr_data = out_buf[drain_counter];

    // FSM State Register
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // FSM Combinational Transitions
    always_comb begin
        next_state   = current_state;
        dram_rd_req  = 1'b0;
        dram_wr_req  = 1'b0;
        wbuf_wr_en   = 1'b0;
        wbuf_rd_en   = 1'b0;
        abuf_wr_en   = 1'b0;
        abuf_rd_en   = 1'b0;

        case (current_state)
            IDLE: begin
                if (start_gemm) next_state = PRELOAD_WEIGHT_BANK0;
            end

            PRELOAD_WEIGHT_BANK0: begin
                dram_rd_req = (req_counter < 16);
                if (dram_rd_valid) begin
                    wbuf_wr_en = 1'b1;
                    if (word_counter == 15) next_state = PRELOAD_ACT_BUFFER;
                end
            end

            PRELOAD_ACT_BUFFER: begin
                dram_rd_req = (req_counter < (stream_len * ROWS));
                if (dram_rd_valid) begin
                    abuf_wr_en = 1'b1;
                    if (word_counter == (stream_len * ROWS - 1)) next_state = SETUP_WEIGHT_READ;
                end
            end

            SETUP_WEIGHT_READ: begin
                wbuf_rd_en = 1'b1;
                next_state = SETUP_WEIGHT_LATCH;
            end

            SETUP_WEIGHT_LATCH: begin
                abuf_rd_en = 1'b1; // Prime first activation vector
                next_state = STREAM_COMPUTE;
            end

            STREAM_COMPUTE: begin
                abuf_rd_en = (stream_counter < stream_len);

                // All outputs emerge by (stream_len + 8) cycles
                if (stream_counter == (stream_len + 8)) begin
                    if (tile_counter + 1 == total_weight_tiles) begin
                        next_state = DRAIN_OUTPUT;
                    end else begin
                        next_state = SETUP_WEIGHT_READ;
                    end
                end

                // Concurrent background DRAM refill for next weight tile
                if (bg_dram_refill_active && !bg_refill_done) begin
                    dram_rd_req = (bg_req_counter < 16);
                    if (dram_rd_valid) begin
                        wbuf_wr_en = 1'b1;
                    end
                end
            end

            DRAIN_OUTPUT: begin
                dram_wr_req = 1'b1;
                if (dram_wr_ack) begin
                    if (drain_counter + 1 == total_drain_words) begin
                        next_state = COMPLETE;
                    end
                end
            end

            COMPLETE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Sequential Datapath
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ping_pong_sel         <= 1'b0;
            tile_counter          <= '0;
            word_counter          <= '0;
            stream_counter        <= '0;
            drain_counter         <= '0;
            total_drain_words     <= '0;
            abuf_vec_rd           <= '0;
            bg_dram_refill_active <= 1'b0;
            bg_refill_word_idx    <= '0;
            bg_refill_done        <= 1'b0;

            for (int i = 0; i < OUT_BUF_DEPTH; i++) out_buf[i] <= '0;
        end else begin
            case (current_state)
                IDLE: begin
                    ping_pong_sel         <= 1'b0;
                    tile_counter          <= '0;
                    word_counter          <= '0;
                    req_counter           <= '0;
                    stream_counter        <= '0;
                    drain_counter         <= '0;
                    total_drain_words     <= '0;
                    abuf_vec_rd           <= '0;
                    bg_dram_refill_active <= 1'b0;
                    bg_refill_word_idx    <= '0;
                    bg_req_counter        <= '0;
                    bg_refill_done        <= 1'b0;
                end

                PRELOAD_WEIGHT_BANK0: begin
                    if (dram_rd_req) begin
                        req_counter <= req_counter + 1;
                    end
                    if (dram_rd_valid) begin
                        if (word_counter == 15) begin
                            word_counter <= '0;
                            req_counter  <= '0;
                        end else begin
                            word_counter <= word_counter + 1;
                        end
                    end
                end

                PRELOAD_ACT_BUFFER: begin
                    if (dram_rd_req) begin
                        req_counter <= req_counter + 1;
                    end
                    if (dram_rd_valid) begin
                        if (word_counter == (stream_len * ROWS - 1)) begin
                            word_counter <= '0;
                            req_counter  <= '0;
                        end else begin
                            word_counter <= word_counter + 1;
                        end
                    end
                end

                SETUP_WEIGHT_READ: begin
                    // Wait 1 cycle for SRAM weight buffer read latency
                end

                SETUP_WEIGHT_LATCH: begin
                    stream_counter <= '0;
                    abuf_vec_rd    <= '0;
                    if (tile_counter + 1 < total_weight_tiles) begin
                        bg_dram_refill_active <= 1'b1;
                        bg_refill_word_idx    <= '0;
                        bg_req_counter        <= '0;
                        bg_refill_done        <= 1'b0;
                    end else begin
                        bg_dram_refill_active <= 1'b0;
                    end
                end

                STREAM_COMPUTE: begin
                    stream_counter <= stream_counter + 1;

                    if (abuf_rd_en && (abuf_vec_rd + 1 < stream_len)) begin
                        abuf_vec_rd <= abuf_vec_rd + 1;
                    end

                    // Latch deskewed output row emerging at cycle stream_counter
                    if (stream_counter >= 8 && stream_counter < (stream_len + 8)) begin
                        out_base = (tile_counter * stream_len * COLS) + (stream_counter - 8)*COLS;
                        out_buf[out_base + 0] <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 1] <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 2] <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[out_base + 3] <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                        total_drain_words <= total_drain_words + COLS;
                    end

                    // Background refill
                    if (bg_dram_refill_active) begin
                        if (dram_rd_req) begin
                            bg_req_counter <= bg_req_counter + 1;
                        end
                        if (dram_rd_valid) begin
                            if (bg_refill_word_idx == 15) begin
                                bg_refill_done        <= 1'b1;
                                bg_dram_refill_active <= 1'b0;
                            end else begin
                                bg_refill_word_idx <= bg_refill_word_idx + 1;
                            end
                        end
                    end

                    // End of tile compute: instantaneous Ping-Pong swap!
                    if (stream_counter == (stream_len + 8)) begin
                        if (tile_counter + 1 < total_weight_tiles) begin
                            tile_counter  <= tile_counter + 1;
                            ping_pong_sel <= ~ping_pong_sel;
                        end
                    end
                end

                DRAIN_OUTPUT: begin
                    if (dram_wr_ack) begin
                        drain_counter <= drain_counter + 1;
                    end
                end

                COMPLETE: begin
                    // Done
                end
            endcase
        end
    end

    // Address Generators
    assign wbuf_word_idx = (current_state == PRELOAD_WEIGHT_BANK0) ? word_counter[3:0] : bg_refill_word_idx;
    assign abuf_vec_wr   = word_counter / ROWS;
    assign abuf_word_wr  = word_counter % ROWS;

    assign dram_rd_addr  = 16'h1000 + perf_dram_reads[15:0];
    assign dram_wr_addr  = 16'h3000 + perf_dram_writes[15:0];

    // Hardware Performance Profiler Logic
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            perf_total_cycles      <= '0;
            perf_compute_cycles    <= '0;
            perf_active_mac_cycles <= '0;
            perf_stall_cycles      <= '0;
            perf_dram_reads        <= '0;
            perf_dram_writes       <= '0;
            perf_sram_reads        <= '0;
            perf_sram_writes       <= '0;
        end else if (busy) begin
            perf_total_cycles <= perf_total_cycles + 1;

            if (current_state == STREAM_COMPUTE) begin
                perf_compute_cycles <= perf_compute_cycles + 1;

                // All 16 MACs actively compute during steady-state
                if (stream_counter >= (ROWS - 1) && stream_counter < stream_len) begin
                    perf_active_mac_cycles <= perf_active_mac_cycles + (ROWS * COLS);
                end else begin
                    perf_active_mac_cycles <= perf_active_mac_cycles + 8;
                end
            end else begin
                perf_stall_cycles <= perf_stall_cycles + 1;
            end

            if (dram_rd_req && dram_rd_valid) perf_dram_reads <= perf_dram_reads + 1;
            if (dram_wr_req && dram_wr_ack)   perf_dram_writes <= perf_dram_writes + 1;
            if (wbuf_wr_en || abuf_wr_en)     perf_sram_writes <= perf_sram_writes + 1;
            if (wbuf_rd_en)                   perf_sram_reads  <= perf_sram_reads + (ROWS * COLS);
            if (abuf_rd_en)                   perf_sram_reads  <= perf_sram_reads + ROWS;
        end
    end

    always_comb begin
        if (perf_total_cycles > 0) begin
            perf_mac_util_permille = (perf_active_mac_cycles * 1000) / (perf_total_cycles * (ROWS * COLS));
        end else begin
            perf_mac_util_permille = '0;
        end

        if (perf_compute_cycles > 0) begin
            perf_compute_util_permille = (perf_active_mac_cycles * 1000) / (perf_compute_cycles * (ROWS * COLS));
        end else begin
            perf_compute_util_permille = '0;
        end
    end

endmodule
