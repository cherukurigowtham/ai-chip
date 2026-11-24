// ==============================================================================
// Module: chiplet_ring_allreduce.sv
// Description: Multi-Chiplet Hardware Ring-AllReduce Engine for Distributed
//              Ternary AI Accelerators (Tensor Parallelism TP=8 / TP=16).
//
// Features:
// - Pipelined Reduce-Scatter followed by All-Gather over AXI-Stream Ring.
// - Zero Multipliers: Pure signed fixed-point accumulation with saturation.
// - Integrated Dual-Port Vector Scratchpad Memory (1024 elements).
// - Host Read/Write interface for pre-loading partial sums & inspecting results.
// - Fully autonomous FSM triggered by single CSR start pulse.
// ==============================================================================

`timescale 1ns / 1ps

module chiplet_ring_allreduce #(
    parameter int NODE_ID       = 0,
    parameter int NUM_NODES     = 8,
    parameter int DATA_WIDTH    = 16,
    parameter int CHUNK_LEN     = 128,   // Elements per chunk
    parameter int TOTAL_LEN     = NUM_NODES * CHUNK_LEN, // 1024 elements
    parameter int ADDR_WIDTH    = 11
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // CSR Control & Status Interface
    input  logic                   start,
    output logic                   busy,
    output logic                   done,
    output logic [31:0]            cycle_count,
    output logic [31:0]            packets_sent,
    output logic [31:0]            packets_recv,

    // Host Memory Access Port (Active when !busy)
    input  logic                   host_we,
    input  logic [ADDR_WIDTH-1:0]  host_addr,
    input  logic [DATA_WIDTH-1:0]  host_wdata,
    output logic [DATA_WIDTH-1:0]  host_rdata,

    // AXI-Stream Inbound (From predecessor node: (NODE_ID - 1 + NUM_NODES) % NUM_NODES)
    input  logic [DATA_WIDTH-1:0]  s_axis_tdata,
    input  logic                   s_axis_tvalid,
    output logic                   s_axis_tready,
    input  logic                   s_axis_tlast,

    // AXI-Stream Outbound (To successor node: (NODE_ID + 1) % NUM_NODES)
    output logic [DATA_WIDTH-1:0]  m_axis_tdata,
    output logic                   m_axis_tvalid,
    input  logic                   m_axis_tready,
    output logic                   m_axis_tlast
);

    // -------------------------------------------------------------------------
    // Dual-Port Scratchpad Memory (SRAM)
    // Port A: Read port (TX streaming & Host read)
    // Port B: Write port (RX accumulation/write & Host write)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] sram [0:TOTAL_LEN-1];

    // -------------------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE           = 3'b000,
        REDUCE_SCATTER = 3'b001,
        RS_STEP_DONE   = 3'b010,
        ALL_GATHER     = 3'b011,
        AG_STEP_DONE   = 3'b100,
        FINISHED       = 3'b101
    } state_t;

    state_t state;

    logic [3:0]   step_idx;        // 0 to NUM_NODES - 2
    logic [15:0]  elem_tx_idx;     // 0 to CHUNK_LEN - 1
    logic [15:0]  elem_rx_idx;     // 0 to CHUNK_LEN - 1

    logic [31:0]  cycles;
    logic [31:0]  tx_count;
    logic [31:0]  rx_count;

    // Helper functions for ring chunk calculation
    function automatic int calc_rs_send(input int node, input int step, input int total);
        int v;
        v = (node - step) % total;
        if (v < 0) v = v + total;
        return v;
    endfunction

    function automatic int calc_rs_recv(input int node, input int step, input int total);
        int v;
        v = (node - step - 1) % total;
        if (v < 0) v = v + total;
        return v;
    endfunction

    function automatic int calc_ag_send(input int node, input int step, input int total);
        int v;
        v = (node + 1 - step) % total;
        if (v < 0) v = v + total;
        return v;
    endfunction

    function automatic int calc_ag_recv(input int node, input int step, input int total);
        int v;
        v = (node - step) % total;
        if (v < 0) v = v + total;
        return v;
    endfunction

    // Current chunk indices
    int cur_send_chunk;
    int cur_recv_chunk;

    always_comb begin
        if (state == REDUCE_SCATTER) begin
            cur_send_chunk = calc_rs_send(NODE_ID, step_idx, NUM_NODES);
            cur_recv_chunk = calc_rs_recv(NODE_ID, step_idx, NUM_NODES);
        end else begin
            cur_send_chunk = calc_ag_send(NODE_ID, step_idx, NUM_NODES);
            cur_recv_chunk = calc_ag_recv(NODE_ID, step_idx, NUM_NODES);
        end
    end

    // TX Addressing
    logic [ADDR_WIDTH-1:0] tx_addr;
    assign tx_addr = (cur_send_chunk * CHUNK_LEN) + elem_tx_idx[ADDR_WIDTH-1:0];

    // RX Addressing
    logic [ADDR_WIDTH-1:0] rx_addr;
    assign rx_addr = (cur_recv_chunk * CHUNK_LEN) + elem_rx_idx[ADDR_WIDTH-1:0];

    // AXI-Stream Control
    logic tx_fire;
    logic rx_fire;
    assign tx_fire = m_axis_tvalid && m_axis_tready;
    assign rx_fire = s_axis_tvalid && s_axis_tready;

    // TX Flow
    assign m_axis_tvalid = (state == REDUCE_SCATTER || state == ALL_GATHER) && (elem_tx_idx < CHUNK_LEN);
    assign m_axis_tdata  = sram[tx_addr];
    assign m_axis_tlast  = (elem_tx_idx == CHUNK_LEN - 1);

    // RX Flow
    assign s_axis_tready = (state == REDUCE_SCATTER || state == ALL_GATHER) && (elem_rx_idx < CHUNK_LEN);

    // Multiplier-Free Saturated Addition
    logic signed [DATA_WIDTH:0]   add_temp;
    logic signed [DATA_WIDTH-1:0] sat_result;

    always_comb begin
        add_temp = sram[rx_addr] + $signed(s_axis_tdata);
        if (add_temp > 17'sd32767)
            sat_result = 16'sd32767;
        else if (add_temp < -17'sd32768)
            sat_result = -16'sd32768;
        else
            sat_result = 16'(add_temp);
    end

    // Synchronous Memory Write & Update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            step_idx    <= '0;
            elem_tx_idx <= '0;
            elem_rx_idx <= '0;
            cycles      <= '0;
            tx_count    <= '0;
            rx_count    <= '0;
        end else begin
            // Host Write (when idle)
            if (state == IDLE && host_we) begin
                sram[host_addr] <= host_wdata;
            end

            case (state)
                IDLE: begin
                    step_idx    <= '0;
                    elem_tx_idx <= '0;
                    elem_rx_idx <= '0;
                    if (start) begin
                        state  <= REDUCE_SCATTER;
                        cycles <= '0;
                    end
                end

                REDUCE_SCATTER: begin
                    cycles <= cycles + 1;

                    // Outbound stream advance
                    if (tx_fire) begin
                        tx_count    <= tx_count + 1;
                        elem_tx_idx <= elem_tx_idx + 1;
                    end

                    // Inbound stream advance and accumulation
                    if (rx_fire) begin
                        rx_count        <= rx_count + 1;
                        sram[rx_addr]   <= sat_result;
                        elem_rx_idx     <= elem_rx_idx + 1;
                    end

                    // Step transition
                    if ((elem_tx_idx >= CHUNK_LEN || (elem_tx_idx == CHUNK_LEN-1 && tx_fire)) &&
                        (elem_rx_idx >= CHUNK_LEN || (elem_rx_idx == CHUNK_LEN-1 && rx_fire))) begin
                        elem_tx_idx <= '0;
                        elem_rx_idx <= '0;
                        if (step_idx == NUM_NODES - 2) begin
                            state    <= RS_STEP_DONE;
                            step_idx <= '0;
                        end else begin
                            step_idx <= step_idx + 1;
                        end
                    end
                end

                RS_STEP_DONE: begin
                    cycles   <= cycles + 1;
                    state    <= ALL_GATHER;
                    step_idx <= '0;
                end

                ALL_GATHER: begin
                    cycles <= cycles + 1;

                    if (tx_fire) begin
                        tx_count    <= tx_count + 1;
                        elem_tx_idx <= elem_tx_idx + 1;
                    end

                    if (rx_fire) begin
                        rx_count      <= rx_count + 1;
                        sram[rx_addr] <= $signed(s_axis_tdata); // Overwrite chunk with fully reduced value
                        elem_rx_idx   <= elem_rx_idx + 1;
                    end

                    if ((elem_tx_idx >= CHUNK_LEN || (elem_tx_idx == CHUNK_LEN-1 && tx_fire)) &&
                        (elem_rx_idx >= CHUNK_LEN || (elem_rx_idx == CHUNK_LEN-1 && rx_fire))) begin
                        elem_tx_idx <= '0;
                        elem_rx_idx <= '0;
                        if (step_idx == NUM_NODES - 2) begin
                            state <= AG_STEP_DONE;
                        end else begin
                            step_idx <= step_idx + 1;
                        end
                    end
                end

                AG_STEP_DONE: begin
                    cycles <= cycles + 1;
                    state  <= FINISHED;
                end

                FINISHED: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // Host Read
    assign host_rdata = sram[host_addr];

    // Status Signals
    assign busy         = (state != IDLE && state != FINISHED);
    assign done         = (state == FINISHED);
    assign cycle_count  = cycles;
    assign packets_sent = tx_count;
    assign packets_recv = rx_count;

endmodule
