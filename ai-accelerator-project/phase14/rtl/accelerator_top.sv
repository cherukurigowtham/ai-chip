// ==============================================================================
// Module: accelerator_top
// Description: Parameterizable Top-Level AI Accelerator Core for Phase 14
//              Physical Silicon Calibration & Synthesis.
//
// Integrates:
//   - Memory-Mapped Dynamic Configuration Registers (dynamic_config_reg)
//   - Autonomous Dual-Mode Dataflow Controller (dataflow_controller)
//   - 4x4 Adaptive Systolic Array Mesh (systolic_array_adaptive)
//   - Configurable On-Chip SRAM Buffers (BUFFER_VECS, OUT_BUF_DEPTH)
// ==============================================================================

`timescale 1ns / 1ps

module accelerator_top #(
    parameter int DATA_WIDTH    = 16,
    parameter int ACCUM_WIDTH   = 32,
    parameter int ROWS          = 4,
    parameter int COLS          = 4,
    parameter int BUFFER_VECS   = 64,
    parameter int OUT_BUF_DEPTH = 256
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Host Memory-Mapped Register Interface
    input  logic                   reg_wr_en,
    input  logic [7:0]             reg_addr,
    input  logic [31:0]            reg_wdata,
    input  logic                   reg_rd_en,
    output logic [31:0]            reg_rdata,

    // Off-Chip DRAM Read Channel
    output logic                   dram_rd_req,
    output logic [15:0]            dram_rd_addr,
    input  logic                   dram_rd_valid,
    input  logic signed [DATA_WIDTH-1:0] dram_rd_data,

    // Off-Chip DRAM Write Channel
    output logic                   dram_wr_req,
    output logic [15:0]            dram_wr_addr,
    output logic signed [ACCUM_WIDTH-1:0] dram_wr_data,
    input  logic                   dram_wr_ack,

    // Status Signals
    output logic                   busy,
    output logic                   done,
    output logic                   active_dataflow
);

    // Internal Control Signals
    logic        ctrl_start;
    logic [1:0]  ctrl_dataflow_mode;
    logic [15:0] ctrl_cfg_M;
    logic [15:0] ctrl_cfg_K;
    logic [15:0] ctrl_cfg_N;
    logic [15:0] ctrl_tile_M;
    logic [15:0] ctrl_tile_K;
    logic [15:0] ctrl_tile_N;
    logic        ctrl_double_buffering;

    logic [31:0] perf_total_cycles;
    logic [31:0] perf_compute_cycles;
    logic [31:0] perf_active_mac_cycles;
    logic [31:0] perf_stall_cycles;
    logic [31:0] perf_dram_reads;
    logic [31:0] perf_dram_writes;
    logic [15:0] perf_mac_util_permille;

    // Memory-Mapped Configuration Register File
    dynamic_config_reg #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_config_reg (
        .clk(clk),
        .rst_n(rst_n),
        .reg_wr_en(reg_wr_en),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rd_en(reg_rd_en),
        .reg_rdata(reg_rdata),
        .ctrl_start(ctrl_start),
        .ctrl_dataflow_mode(ctrl_dataflow_mode),
        .ctrl_cfg_M(ctrl_cfg_M),
        .ctrl_cfg_K(ctrl_cfg_K),
        .ctrl_cfg_N(ctrl_cfg_N),
        .ctrl_tile_M(ctrl_tile_M),
        .ctrl_tile_K(ctrl_tile_K),
        .ctrl_tile_N(ctrl_tile_N),
        .ctrl_double_buffering(ctrl_double_buffering),
        .core_busy(busy),
        .core_done(done),
        .core_active_dataflow(active_dataflow),
        .core_perf_total_cycles(perf_total_cycles),
        .core_perf_compute_cycles(perf_compute_cycles),
        .core_perf_dram_reads(perf_dram_reads),
        .core_perf_dram_writes(perf_dram_writes),
        .core_perf_mac_util_permille(perf_mac_util_permille)
    );

    // Autonomous Top-Level Controller with Systolic Array
    dataflow_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .BUFFER_VECS(BUFFER_VECS),
        .OUT_BUF_DEPTH(OUT_BUF_DEPTH)
    ) u_controller (
        .clk(clk),
        .rst_n(rst_n),
        .start(ctrl_start),
        .dataflow_mode(ctrl_dataflow_mode),
        .cfg_M(ctrl_cfg_M),
        .cfg_K(ctrl_cfg_K),
        .cfg_N(ctrl_cfg_N),
        .busy(busy),
        .done(done),
        .active_dataflow(active_dataflow),
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
        .perf_mac_util_permille(perf_mac_util_permille)
    );

endmodule
