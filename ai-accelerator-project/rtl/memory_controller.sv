// ==============================================================================
// Module: memory_controller
// Description: AI Accelerator Memory Hierarchy Controller & Performance Monitor.
//              - Manages external DRAM burst transfers into on-chip SRAM buffers.
//              - Handles synchronous 1-cycle read latency for Weight & Activation SRAM.
//              - Orchestrates Weight-Stationary loading, activation streaming, and output drain.
//              - Integrates hardware performance counters to directly measure:
//                * DRAM Reads & Writes
//                * SRAM Buffer Accesses
//                * Active Compute Cycles & Total Execution Time
// ==============================================================================

`timescale 1ns / 1ps

module memory_controller #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32,
    parameter int ROWS        = 4,
    parameter int COLS        = 4
)(
    input  logic         clk,
    input  logic         rst_n,

    // Command Interface
    input  logic         start_gemm,
    input  logic [15:0]  tile_k_count,
    input  logic [15:0]  tile_m_count,
    output logic         done,
    output logic         busy,

    // DRAM Memory Bus Interface (Word-granular handshake)
    output logic         dram_rd_req,
    input  logic         dram_rd_valid,
    input  logic signed [DATA_WIDTH-1:0] dram_rd_data,

    output logic         dram_wr_req,
    output logic signed [ACCUM_WIDTH-1:0] dram_wr_data,
    input  logic         dram_wr_ack,

    // Interface to Systolic Array Core
    output logic         sa_enable,
    output logic         sa_weight_load,
    output logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] sa_weight_in,
    output logic signed [(ROWS*DATA_WIDTH)-1:0]      sa_act_in,
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_in,
    input  logic signed [(COLS*ACCUM_WIDTH)-1:0]     sa_psum_out_deskewed,

    // Hardware Performance Counters (Visible to Host/Software)
    output logic [31:0]  perf_dram_reads,
    output logic [31:0]  perf_dram_writes,
    output logic [31:0]  perf_sram_reads,
    output logic [31:0]  perf_sram_writes,
    output logic [31:0]  perf_active_cycles,
    output logic [31:0]  perf_total_cycles
);

    // Controller FSM States
    typedef enum logic [2:0] {
        IDLE                 = 3'b000,
        LOAD_WEIGHT_SRAM     = 3'b001,
        LOAD_ACT_SRAM        = 3'b010,
        SETUP_SYSTOLIC_READ  = 3'b011,
        SETUP_SYSTOLIC_LATCH = 3'b100,
        STREAM_COMPUTE       = 3'b101,
        DRAIN_OUTPUT         = 3'b110,
        COMPLETE             = 3'b111
    } state_t;

    state_t current_state, next_state;

    // Sequence Counters
    logic [4:0] word_counter;
    logic [4:0] stream_counter;
    logic [4:0] drain_counter;
    logic       running;

    // Submodules: Weight Buffer & Activation Buffer
    logic        wbuf_wr_en;
    logic [3:0]  wbuf_word_idx;
    logic        wbuf_rd_en;
    logic        wbuf_valid;
    logic signed [(ROWS*COLS*DATA_WIDTH)-1:0] wbuf_tile_out;

    logic        abuf_wr_en;
    logic [3:0]  abuf_vec_wr;
    logic [1:0]  abuf_word_wr;
    logic        abuf_rd_en;
    logic [3:0]  abuf_vec_rd;
    logic signed [(ROWS*DATA_WIDTH)-1:0] abuf_vec_out;
    logic        abuf_valid;

    // Output Staging Buffer (16 words = 4 rows x 4 cols)
    logic signed [ACCUM_WIDTH-1:0] out_buf [15:0];

    // Combinational DRAM write data bus
    assign dram_wr_data = out_buf[drain_counter[3:0]];

    // Combinational write address decoding from word_counter (zero latency skew)
    assign wbuf_word_idx = word_counter[3:0];
    assign abuf_vec_wr   = word_counter[3:2];
    assign abuf_word_wr  = word_counter[1:0];

    weight_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .NUM_TILES(2)
    ) u_wbuf (
        .clk(clk),
        .rst_n(rst_n),
        .dram_wr_en(wbuf_wr_en),
        .tile_wr_sel(1'b0),
        .word_wr_idx(wbuf_word_idx),
        .dram_wr_data(dram_rd_data),
        .tile_rd_en(wbuf_rd_en),
        .tile_rd_sel(1'b0),
        .weight_tile_out(wbuf_tile_out),
        .tile_valid(wbuf_valid)
    );

    activation_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .ROWS(ROWS),
        .BUFFER_VECS(16)
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

    assign busy = (current_state != IDLE) && (current_state != COMPLETE);
    assign done = (current_state == COMPLETE);

    // Assign Systolic Array Interface
    assign sa_enable      = (current_state == STREAM_COMPUTE) || (current_state == SETUP_SYSTOLIC_LATCH);
    assign sa_weight_load = (current_state == SETUP_SYSTOLIC_LATCH);
    assign sa_weight_in   = wbuf_tile_out;
    assign sa_act_in      = (current_state == STREAM_COMPUTE && stream_counter < ROWS) ? abuf_vec_out : '0;
    assign sa_psum_in     = '0;

    // FSM State Register
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // FSM Next-State Logic
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
                if (start_gemm) next_state = LOAD_WEIGHT_SRAM;
            end

            LOAD_WEIGHT_SRAM: begin
                dram_rd_req = 1'b1;
                if (dram_rd_valid) begin
                    wbuf_wr_en = 1'b1;
                    if (word_counter == 15) next_state = LOAD_ACT_SRAM;
                end
            end

            LOAD_ACT_SRAM: begin
                dram_rd_req = 1'b1;
                if (dram_rd_valid) begin
                    abuf_wr_en = 1'b1;
                    if (word_counter == 15) next_state = SETUP_SYSTOLIC_READ;
                end
            end

            // Cycle 1 of Setup: Read SRAM weight buffer
            SETUP_SYSTOLIC_READ: begin
                wbuf_rd_en = 1'b1;
                next_state = SETUP_SYSTOLIC_LATCH;
            end

            // Cycle 2 of Setup: Weights valid on wbuf_tile_out; Latch into PEs and prime activation read
            SETUP_SYSTOLIC_LATCH: begin
                abuf_rd_en = 1'b1; // Read vector 0
                next_state = STREAM_COMPUTE;
            end

            STREAM_COMPUTE: begin
                abuf_rd_en = (stream_counter >= 0 && stream_counter < 3);
                if (stream_counter == 11) next_state = DRAIN_OUTPUT;
            end

            DRAIN_OUTPUT: begin
                dram_wr_req = 1'b1;
                if (dram_wr_ack) begin
                    if (drain_counter == 15) next_state = COMPLETE;
                end
            end

            COMPLETE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Counter updates & output latching
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            word_counter   <= '0;
            stream_counter <= '0;
            drain_counter  <= '0;
            abuf_vec_rd    <= '0;
            for (int i = 0; i < 16; i++) begin
                out_buf[i] <= '0;
            end
        end else begin
            case (current_state)
                IDLE: begin
                    word_counter   <= '0;
                    stream_counter <= '0;
                    drain_counter  <= '0;
                    abuf_vec_rd    <= '0;
                end

                LOAD_WEIGHT_SRAM: begin
                    if (dram_rd_valid) begin
                        if (word_counter == 15) begin
                            word_counter <= '0;
                        end else begin
                            word_counter <= word_counter + 1;
                        end
                    end
                end

                LOAD_ACT_SRAM: begin
                    if (dram_rd_valid) begin
                        if (word_counter == 15) begin
                            word_counter <= '0;
                        end else begin
                            word_counter <= word_counter + 1;
                        end
                    end
                end

                SETUP_SYSTOLIC_READ: begin
                    abuf_vec_rd <= '0;
                end

                SETUP_SYSTOLIC_LATCH: begin
                    abuf_vec_rd <= abuf_vec_rd + 1;
                end

                STREAM_COMPUTE: begin
                    stream_counter <= stream_counter + 1;
                    if (stream_counter >= 0 && stream_counter < 3) begin
                        abuf_vec_rd <= abuf_vec_rd + 1;
                    end

                    // Latch deskewed output rows at cycles 7, 8, 9, 10
                    if (stream_counter == 7) begin
                        out_buf[0]  <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[1]  <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[2]  <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[3]  <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                    end else if (stream_counter == 8) begin
                        out_buf[4]  <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[5]  <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[6]  <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[7]  <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                    end else if (stream_counter == 9) begin
                        out_buf[8]  <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[9]  <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[10] <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[11] <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                    end else if (stream_counter == 10) begin
                        out_buf[12] <= sa_psum_out_deskewed[0*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[13] <= sa_psum_out_deskewed[1*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[14] <= sa_psum_out_deskewed[2*ACCUM_WIDTH +: ACCUM_WIDTH];
                        out_buf[15] <= sa_psum_out_deskewed[3*ACCUM_WIDTH +: ACCUM_WIDTH];
                    end
                end

                DRAIN_OUTPUT: begin
                    if (dram_wr_ack) begin
                        drain_counter <= drain_counter + 1;
                    end
                end

                COMPLETE: begin
                    stream_counter <= '0;
                    drain_counter  <= '0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Hardware Performance Counters Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            perf_dram_reads    <= '0;
            perf_dram_writes   <= '0;
            perf_sram_reads    <= '0;
            perf_sram_writes   <= '0;
            perf_active_cycles <= '0;
            perf_total_cycles  <= '0;
            running            <= 1'b0;
        end else begin
            if (start_gemm) begin
                running <= 1'b1;
            end else if (current_state == COMPLETE) begin
                running <= 1'b0;
            end

            if (running) begin
                perf_total_cycles <= perf_total_cycles + 1;

                // DRAM accesses
                if (dram_rd_req && dram_rd_valid) perf_dram_reads <= perf_dram_reads + 1;
                if (dram_wr_req && dram_wr_ack)   perf_dram_writes <= perf_dram_writes + 1;

                // SRAM accesses
                if (wbuf_wr_en || abuf_wr_en)     perf_sram_writes <= perf_sram_writes + 1;
                if (wbuf_rd_en || abuf_rd_en)     perf_sram_reads  <= perf_sram_reads + 1;

                // Active compute cycles
                if (current_state == STREAM_COMPUTE) perf_active_cycles <= perf_active_cycles + 1;
            end
        end
    end

endmodule
