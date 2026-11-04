// ==============================================================================
// Module: accelerator_ternary_axi_top
// Description: Complete FPGA SoC Top-Level for the 8x8 Ternary AI Accelerator.
//
// Interfaces:
//   - AXI4-Lite Slave (Control / Status / Telemetry Registers)
//   - AXI4-Stream Slave (DMA Ingress: Packed Weights & Input Activations)
//   - AXI4-Stream Master (DMA Egress: Output Accumulation Results)
//   - Dedicated Level-Sensitive Interrupt (irq_done)
// ==============================================================================

`timescale 1ns / 1ps

module accelerator_ternary_axi_top #(
    parameter int AXIL_ADDR_WIDTH = 8,
    parameter int AXIL_DATA_WIDTH = 32,
    parameter int AXIS_DATA_WIDTH = 32,
    parameter int CORE_DATA_WIDTH = 16,
    parameter int ACCUM_WIDTH     = 32,
    parameter int ROWS            = 8,
    parameter int COLS            = 8,
    parameter int BUFFER_VECS     = 16,
    parameter int OUT_BUF_DEPTH   = 64
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Interface (Host CPU MMIO)
    // -------------------------------------------------------------------------
    input  logic [AXIL_ADDR_WIDTH-1:0]    s_axil_awaddr,
    input  logic [2:0]                    s_axil_awprot,
    input  logic                          s_axil_awvalid,
    output logic                          s_axil_awready,

    input  logic [AXIL_DATA_WIDTH-1:0]    s_axil_wdata,
    input  logic [(AXIL_DATA_WIDTH/8)-1:0] s_axil_wstrb,
    input  logic                          s_axil_wvalid,
    output logic                          s_axil_wready,

    output logic [1:0]                    s_axil_bresp,
    output logic                          s_axil_bvalid,
    input  logic                          s_axil_bready,

    input  logic [AXIL_ADDR_WIDTH-1:0]    s_axil_araddr,
    input  logic [2:0]                    s_axil_arprot,
    input  logic                          s_axil_arvalid,
    output logic                          s_axil_arready,

    output logic [AXIL_DATA_WIDTH-1:0]    s_axil_rdata,
    output logic [1:0]                    s_axil_rresp,
    output logic                          s_axil_rvalid,
    input  logic                          s_axil_rready,

    // -------------------------------------------------------------------------
    // AXI4-Stream Slave Interface (DMA -> Accelerator Ingress)
    // -------------------------------------------------------------------------
    input  logic [AXIS_DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic                          s_axis_tlast,

    // -------------------------------------------------------------------------
    // AXI4-Stream Master Interface (Accelerator Egress -> DMA)
    // -------------------------------------------------------------------------
    output logic [AXIS_DATA_WIDTH-1:0]    m_axis_tdata,
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic                          m_axis_tlast,

    // Interrupt Line to Host Interrupt Controller
    output logic                          irq_done
);

    // Internal interconnect nets
    logic        reg_wr_en;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_rd_en;
    logic [31:0] reg_rdata;

    logic        core_dram_rd_req;
    logic [15:0] core_dram_rd_addr;
    logic        core_dram_rd_valid;
    logic signed [CORE_DATA_WIDTH-1:0] core_dram_rd_data;

    logic        core_dram_wr_req;
    logic [15:0] core_dram_wr_addr;
    logic signed [ACCUM_WIDTH-1:0] core_dram_wr_data;
    logic        core_dram_wr_ack;

    logic        core_busy;
    logic        core_done;
    logic        core_active_dataflow;
    logic [31:0] core_zero_skips;
    logic [31:0] words_in_count;
    logic [31:0] words_out_count;

    // Detect START command from AXI-Lite write to 0x00
    logic ctrl_start;
    assign ctrl_start = (reg_wr_en && reg_addr == 8'h00 && reg_wdata[0]);

    // -------------------------------------------------------------------------
    // 1. AXI4-Lite Slave Adapter
    // -------------------------------------------------------------------------
    axi_lite_slave #(
        .ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .DATA_WIDTH(AXIL_DATA_WIDTH)
    ) u_axil_slave (
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
        .reg_wr_en     (reg_wr_en),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_rd_en     (reg_rd_en),
        .reg_rdata     (reg_rdata),
        .core_done     (core_done),
        .irq_done      (irq_done)
    );

    // -------------------------------------------------------------------------
    // 2. AXI4-Stream DMA Ingress/Egress Adapter
    // -------------------------------------------------------------------------
    axi_stream_dma_adapter #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .CORE_DATA_WIDTH(CORE_DATA_WIDTH),
        .ACCUM_WIDTH    (ACCUM_WIDTH),
        .FIFO_DEPTH     (256)
    ) u_axis_adapter (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_axis_tdata      (s_axis_tdata),
        .s_axis_tvalid     (s_axis_tvalid),
        .s_axis_tready     (s_axis_tready),
        .s_axis_tlast      (s_axis_tlast),
        .m_axis_tdata      (m_axis_tdata),
        .m_axis_tvalid     (m_axis_tvalid),
        .m_axis_tready     (m_axis_tready),
        .m_axis_tlast      (m_axis_tlast),
        .core_rd_req       (core_dram_rd_req),
        .core_rd_addr      (core_dram_rd_addr),
        .core_rd_valid     (core_dram_rd_valid),
        .core_rd_data      (core_dram_rd_data),
        .core_wr_req       (core_dram_wr_req),
        .core_wr_addr      (core_dram_wr_addr),
        .core_wr_data      (core_dram_wr_data),
        .core_wr_ack       (core_dram_wr_ack),
        .ctrl_start        (ctrl_start),
        .core_done         (core_done),
        .telemetry_words_in(words_in_count),
        .telemetry_words_out(words_out_count)
    );

    // -------------------------------------------------------------------------
    // 3. 8x8 Ternary Accelerator Core
    // -------------------------------------------------------------------------
    accelerator_ternary_top #(
        .DATA_WIDTH   (CORE_DATA_WIDTH),
        .ACCUM_WIDTH  (ACCUM_WIDTH),
        .ROWS         (ROWS),
        .COLS         (COLS),
        .BUFFER_VECS  (BUFFER_VECS),
        .OUT_BUF_DEPTH(OUT_BUF_DEPTH)
    ) u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .reg_wr_en       (reg_wr_en),
        .reg_addr        (reg_addr),
        .reg_wdata       (reg_wdata),
        .reg_rd_en       (reg_rd_en),
        .reg_rdata       (reg_rdata),
        .dram_rd_req     (core_dram_rd_req),
        .dram_rd_addr    (core_dram_rd_addr),
        .dram_rd_valid   (core_dram_rd_valid),
        .dram_rd_data    (core_dram_rd_data),
        .dram_wr_req     (core_dram_wr_req),
        .dram_wr_addr    (core_dram_wr_addr),
        .dram_wr_data    (core_dram_wr_data),
        .dram_wr_ack     (core_dram_wr_ack),
        .busy            (core_busy),
        .done            (core_done),
        .active_dataflow (core_active_dataflow),
        .zero_skips_count(core_zero_skips)
    );

endmodule
