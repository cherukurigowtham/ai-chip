// ==============================================================================
// Module: dynamic_config_reg
// Description: Memory-Mapped Configuration & Control Register File for
//              Phase 13 AI Accelerator Architecture Optimizer.
//
// Allows host CPU or software runtime to dynamically configure:
//   - Dataflow mode: Forced WS (01), Forced OS (10), Auto-Heuristic (00)
//   - Workload dimensions: M, K, N
//   - Tiling parameters: T_M, T_K, T_N
//   - Buffering mode: Single vs Double Buffering
// Reads back execution telemetry & status (cycles, MAC utilization, active mode).
// ==============================================================================

`timescale 1ns / 1ps

module dynamic_config_reg #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Register Bus Interface (Host / Firmware Slave)
    input  logic                   reg_wr_en,
    input  logic [ADDR_WIDTH-1:0]  reg_addr,
    input  logic [DATA_WIDTH-1:0]  reg_wdata,
    input  logic                   reg_rd_en,
    output logic [DATA_WIDTH-1:0]  reg_rdata,

    // Hardware Configuration Outputs to Accelerator Core
    output logic                   ctrl_start,
    output logic [1:0]             ctrl_dataflow_mode, // 01: WS, 10: OS
    output logic [15:0]            ctrl_cfg_M,
    output logic [15:0]            ctrl_cfg_K,
    output logic [15:0]            ctrl_cfg_N,
    output logic [15:0]            ctrl_tile_M,
    output logic [15:0]            ctrl_tile_K,
    output logic [15:0]            ctrl_tile_N,
    output logic                   ctrl_double_buffering,

    // Telemetry & Status Inputs from Accelerator Core
    input  logic                   core_busy,
    input  logic                   core_done,
    input  logic                   core_active_dataflow,
    input  logic [31:0]            core_perf_zero_skips,
    input  logic [31:0]            core_perf_total_cycles,
    input  logic [31:0]            core_perf_compute_cycles,
    input  logic [31:0]            core_perf_dram_reads,
    input  logic [31:0]            core_perf_dram_writes,
    input  logic [15:0]            core_perf_mac_util_permille
);

    // Register Address Map
    localparam [ADDR_WIDTH-1:0] ADDR_CONTROL         = 8'h00; // [0]: start (pulse), [2:1]: mode, [3]: db_en
    localparam [ADDR_WIDTH-1:0] ADDR_STATUS          = 8'h04; // [0]: busy, [1]: done, [2]: active_mode
    localparam [ADDR_WIDTH-1:0] ADDR_CFG_M           = 8'h08; // [15:0]: M
    localparam [ADDR_WIDTH-1:0] ADDR_CFG_K           = 8'h0C; // [15:0]: K
    localparam [ADDR_WIDTH-1:0] ADDR_CFG_N           = 8'h10; // [15:0]: N
    localparam [ADDR_WIDTH-1:0] ADDR_TILE_M          = 8'h14; // [15:0]: T_M
    localparam [ADDR_WIDTH-1:0] ADDR_TILE_K          = 8'h18; // [15:0]: T_K
    localparam [ADDR_WIDTH-1:0] ADDR_TILE_N          = 8'h1C; // [15:0]: T_N
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_ZERO_SKIPS = 8'h20; // Zero-skips count
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_CYCLES     = 8'h24; // Total cycles
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_COMPUTE    = 8'h28; // Compute cycles
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_DRAM_RD    = 8'h2C; // DRAM reads
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_DRAM_WR    = 8'h30; // DRAM writes
    localparam [ADDR_WIDTH-1:0] ADDR_PERF_UTIL       = 8'h34; // Utilization permille

    // Internal Registers
    logic [1:0]  reg_mode;
    logic        reg_double_buffering;
    logic [15:0] reg_m;
    logic [15:0] reg_k;
    logic [15:0] reg_n;
    logic [15:0] reg_tm;
    logic [15:0] reg_tk;
    logic [15:0] reg_tn;
    logic        reg_start_pulse;
    logic        reg_sticky_done;

    assign ctrl_start            = reg_start_pulse;
    assign ctrl_dataflow_mode    = reg_mode;
    assign ctrl_double_buffering = reg_double_buffering;
    assign ctrl_cfg_M            = reg_m;
    assign ctrl_cfg_K            = reg_k;
    assign ctrl_cfg_N            = reg_n;
    assign ctrl_tile_M           = reg_tm;
    assign ctrl_tile_K           = reg_tk;
    assign ctrl_tile_N           = reg_tn;

    // Register Write Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_mode             <= 2'b00; // Auto
            reg_double_buffering <= 1'b1;  // Double buffering default
            reg_m                <= 16'd4;
            reg_k                <= 16'd4;
            reg_n                <= 16'd4;
            reg_tm               <= 16'd4;
            reg_tk               <= 16'd4;
            reg_tn               <= 16'd4;
            reg_start_pulse      <= 1'b0;
            reg_sticky_done      <= 1'b0;
        end else begin
            // Clear single-cycle start strobe
            reg_start_pulse <= 1'b0;

            if (core_done) begin
                reg_sticky_done <= 1'b1;
            end

            if (reg_wr_en) begin
                case (reg_addr)
                    ADDR_CONTROL: begin
                        reg_start_pulse      <= reg_wdata[0];
                        reg_mode             <= reg_wdata[2:1];
                        reg_double_buffering <= reg_wdata[3];
                        if (reg_wdata[0]) reg_sticky_done <= 1'b0; // Auto-clear on start
                    end
                    ADDR_STATUS: begin
                        if (reg_wdata[1]) reg_sticky_done <= 1'b0; // Explicit Write-1-to-Clear (W1C)
                    end
                    ADDR_CFG_M:  reg_m  <= reg_wdata[15:0];
                    ADDR_CFG_K:  reg_k  <= reg_wdata[15:0];
                    ADDR_CFG_N:  reg_n  <= reg_wdata[15:0];
                    ADDR_TILE_M: reg_tm <= reg_wdata[15:0];
                    ADDR_TILE_K: reg_tk <= reg_wdata[15:0];
                    ADDR_TILE_N: reg_tn <= reg_wdata[15:0];
                    default: ;
                endcase
            end
        end
    end

    // Register Read Logic
    always_comb begin
        reg_rdata = 32'd0;
        if (reg_rd_en) begin
            case (reg_addr)
                ADDR_CONTROL:      reg_rdata = {28'd0, reg_double_buffering, reg_mode, 1'b0};
                ADDR_STATUS:       reg_rdata = {29'd0, core_active_dataflow, (core_done || reg_sticky_done), core_busy};
                ADDR_CFG_M:        reg_rdata = {16'd0, reg_m};
                ADDR_CFG_K:        reg_rdata = {16'd0, reg_k};
                ADDR_CFG_N:        reg_rdata = {16'd0, reg_n};
                ADDR_TILE_M:       reg_rdata = {16'd0, reg_tm};
                ADDR_TILE_K:       reg_rdata = {16'd0, reg_tk};
                ADDR_TILE_N:          reg_rdata = {16'd0, reg_tn};
                ADDR_PERF_ZERO_SKIPS: reg_rdata = core_perf_zero_skips;
                ADDR_PERF_CYCLES:     reg_rdata = core_perf_total_cycles;
                ADDR_PERF_COMPUTE:    reg_rdata = core_perf_compute_cycles;
                ADDR_PERF_DRAM_RD:    reg_rdata = core_perf_dram_reads;
                ADDR_PERF_DRAM_WR:    reg_rdata = core_perf_dram_writes;
                ADDR_PERF_UTIL:       reg_rdata = {16'd0, core_perf_mac_util_permille};
                default:           reg_rdata = 32'hDEADBEEF;
            endcase
        end
    end

endmodule
