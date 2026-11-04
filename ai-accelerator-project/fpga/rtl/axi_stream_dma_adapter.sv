// ==============================================================================
// Module: axi_stream_dma_adapter
// Description: Dual-channel AXI4-Stream Adapter with synchronous BRAM queues
//              bridging standard AXI DMA to the 8x8 Ternary Accelerator core.
//
// Channels:
//   - S_AXIS (Ingress): Ingests packed weights & activation vectors from Host DMA
//   - M_AXIS (Egress):  Streams drained accumulator matrix results back to Host DMA
// ==============================================================================

`timescale 1ns / 1ps

module axi_stream_dma_adapter #(
    parameter int AXIS_DATA_WIDTH = 32,
    parameter int CORE_DATA_WIDTH = 16,
    parameter int ACCUM_WIDTH     = 32,
    parameter int FIFO_DEPTH      = 512
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Stream Slave Interface (Host DMA -> Accelerator RX FIFO)
    // -------------------------------------------------------------------------
    input  logic [AXIS_DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic                          s_axis_tlast,

    // -------------------------------------------------------------------------
    // AXI4-Stream Master Interface (Accelerator TX FIFO -> Host DMA)
    // -------------------------------------------------------------------------
    output logic [AXIS_DATA_WIDTH-1:0]    m_axis_tdata,
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic                          m_axis_tlast,

    // -------------------------------------------------------------------------
    // Accelerator Core DRAM Ingress Interface (Read Channel)
    // -------------------------------------------------------------------------
    input  logic                          core_rd_req,
    input  logic [15:0]                   core_rd_addr,
    output logic                          core_rd_valid,
    output logic signed [CORE_DATA_WIDTH-1:0] core_rd_data,

    // -------------------------------------------------------------------------
    // Accelerator Core DRAM Egress Interface (Write Channel)
    // -------------------------------------------------------------------------
    input  logic                          core_wr_req,
    input  logic [15:0]                   core_wr_addr,
    input  logic signed [ACCUM_WIDTH-1:0] core_wr_data,
    output logic                          core_wr_ack,

    // Telemetry & Control
    input  logic                          ctrl_start,
    input  logic                          core_done,
    output logic [31:0]                   telemetry_words_in,
    output logic [31:0]                   telemetry_words_out
);

    // -------------------------------------------------------------------------
    // Ingress (RX) Stream-to-Core Storage (512 x 16-bit)
    // -------------------------------------------------------------------------
    logic [CORE_DATA_WIDTH-1:0] rx_mem [0:FIFO_DEPTH-1];
    logic [15:0] rx_wr_ptr;
    logic [15:0] rx_rd_ptr;

    // -------------------------------------------------------------------------
    // Egress (TX) Core-to-Stream Storage (512 x 32-bit)
    // -------------------------------------------------------------------------
    logic [ACCUM_WIDTH-1:0] tx_mem [0:FIFO_DEPTH-1];
    logic [15:0] tx_wr_ptr;
    logic [15:0] tx_rd_ptr;

    // Stream ready: ready whenever space is available
    assign s_axis_tready = (rx_wr_ptr < (FIFO_DEPTH - 2));

    // Track total words
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            telemetry_words_in  <= '0;
            telemetry_words_out <= '0;
        end else if (ctrl_start) begin
            telemetry_words_in  <= '0;
            telemetry_words_out <= '0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) telemetry_words_in  <= telemetry_words_in + 2;
            if (m_axis_tvalid && m_axis_tready) telemetry_words_out <= telemetry_words_out + 1;
        end
    end

    // -------------------------------------------------------------------------
    // RX Ingress: Ingest 32-bit DMA words into 16-bit core words
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_wr_ptr <= '0;
        end else if (core_done) begin
            rx_wr_ptr <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            rx_mem[rx_wr_ptr]     <= s_axis_tdata[15:0];
            rx_mem[rx_wr_ptr + 1] <= s_axis_tdata[31:16];
            rx_wr_ptr             <= rx_wr_ptr + 2;
        end
    end

    // Core Read Channel: Synchronous 1-Cycle Read Latency (Matching Standard BRAM)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_rd_valid <= 1'b0;
            core_rd_data  <= '0;
            rx_rd_ptr     <= '0;
        end else if (ctrl_start) begin
            rx_rd_ptr     <= '0;
            core_rd_valid <= 1'b0;
        end else if (core_rd_req) begin
            core_rd_valid <= 1'b1;
            core_rd_data  <= rx_mem[rx_rd_ptr];
            rx_rd_ptr     <= rx_rd_ptr + 1;
        end else begin
            core_rd_valid <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // TX Egress: Drain from Core into TX FIFO
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_wr_ptr   <= '0;
            core_wr_ack <= 1'b0;
        end else if (ctrl_start) begin
            tx_wr_ptr   <= '0;
            core_wr_ack <= 1'b0;
        end else begin
            core_wr_ack <= core_wr_req;
            if (core_wr_req && core_wr_ack) begin
                tx_mem[tx_wr_ptr] <= core_wr_data;
                tx_wr_ptr         <= tx_wr_ptr + 1;
            end
        end
    end

    // AXI-Stream Master Egress to DMA S2MM
    assign m_axis_tvalid = (tx_rd_ptr < tx_wr_ptr);
    assign m_axis_tdata  = tx_mem[tx_rd_ptr];
    assign m_axis_tlast  = ((tx_rd_ptr + 1 == tx_wr_ptr) && core_done);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_rd_ptr <= '0;
        end else if (ctrl_start) begin
            tx_rd_ptr <= '0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            tx_rd_ptr <= tx_rd_ptr + 1;
        end
    end

endmodule
