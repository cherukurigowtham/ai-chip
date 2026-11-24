// ==============================================================================
// Module: bitnet_chiplet_dual_die_top.sv
// Description: Multi-Die Dual-Chiplet Assembly with D2D UCIe 1.0/2.0 PHY & Link Layer.
//              Clusters two 64-PE dies (Die 0 @ X=0, Y=0 and Die 1 @ X=1, Y=0) across
//              an advanced high-density silicon interposer / organic substrate.
//
// Microarchitecture:
// 1. Die 0 (Primary Compute Die - Node (0,0)):
//    - 2D Mesh NoC Router with 4 Virtual Channels.
//    - UCIe East Port D2D Link Layer + PHY Transceiver.
// 2. Die 1 (Secondary Compute Die - Node (1,0)):
//    - 2D Mesh NoC Router with 4 Virtual Channels.
//    - UCIe West Port D2D Link Layer + PHY Transceiver.
// 3. Physical Beachfront Channel:
//    - 16 Mainband Data Lanes + 1 Spare Repair Lane + Forwarded Clock + Sideband.
//    - Runtime Microbump Defect Injection and Dynamic Spare Lane Bypass.
// ==============================================================================

`timescale 1ns / 1ps

module bitnet_chiplet_dual_die_top #(
    parameter int FLIT_WIDTH    = 32,
    parameter int PHY_LANES     = 16,
    parameter int REPAIR_LANES  = 1,
    parameter int VC_COUNT      = 4
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // -------------------------------------------------------------------------
    // Die 0 Local Core Interface (Node 0,0)
    // -------------------------------------------------------------------------
    input  logic                   d0_core_tx_valid,
    input  logic [FLIT_WIDTH-1:0]  d0_core_tx_flit,
    output logic                   d0_core_tx_ready,

    output logic                   d0_core_rx_valid,
    output logic [FLIT_WIDTH-1:0]  d0_core_rx_flit,
    input  logic                   d0_core_rx_ready,

    // -------------------------------------------------------------------------
    // Die 1 Local Core Interface (Node 1,0)
    // -------------------------------------------------------------------------
    input  logic                   d1_core_tx_valid,
    input  logic [FLIT_WIDTH-1:0]  d1_core_tx_flit,
    output logic                   d1_core_tx_ready,

    output logic                   d1_core_rx_valid,
    output logic [FLIT_WIDTH-1:0]  d1_core_rx_flit,
    input  logic                   d1_core_rx_ready,

    // -------------------------------------------------------------------------
    // Defect Injection & Microbump Spare Repair Control
    // -------------------------------------------------------------------------
    input  logic [3:0]             cfg_d0_bad_lane_idx,
    input  logic                   cfg_d0_lane_repair_en,
    input  logic [3:0]             cfg_d1_bad_lane_idx,
    input  logic                   cfg_d1_lane_repair_en,

    // Physical Interposer Defect Mask (Simulates physical broken/shorted microbump)
    input  logic [PHY_LANES+REPAIR_LANES-1:0] interposer_defect_mask_d0_to_d1,
    input  logic [PHY_LANES+REPAIR_LANES-1:0] interposer_defect_mask_d1_to_d0,

    // -------------------------------------------------------------------------
    // Telemetry & Status
    // -------------------------------------------------------------------------
    output logic                   d0_phy_link_up,
    output logic                   d1_phy_link_up,
    output logic [31:0]            d0_telemetry_tx_flits,
    output logic [31:0]            d1_telemetry_rx_flits,
    output logic [31:0]            d1_telemetry_tx_flits,
    output logic [31:0]            d0_telemetry_rx_flits
);

    localparam int PORT_LOCAL = 0;
    localparam int PORT_NORTH = 1;
    localparam int PORT_EAST  = 2;
    localparam int PORT_SOUTH = 3;
    localparam int PORT_WEST  = 4;

    // =========================================================================
    // DIE 0: Node (0,0) Router & UCIe Stack
    // =========================================================================
    logic [4:0]                 d0_in_valid, d0_in_ready;
    logic [(5*FLIT_WIDTH)-1:0]  d0_in_packed;
    logic [4:0]                 d0_out_valid, d0_out_ready;
    logic [(5*FLIT_WIDTH)-1:0]  d0_out_packed;

    // DIE 0 Local Port (PORT_LOCAL = 0)
    assign d0_in_valid[PORT_LOCAL]                                   = d0_core_tx_valid;
    assign d0_in_packed[PORT_LOCAL*FLIT_WIDTH +: FLIT_WIDTH]         = d0_core_tx_flit;
    assign d0_core_tx_ready                                          = d0_in_ready[PORT_LOCAL];

    assign d0_core_rx_valid                                          = d0_out_valid[PORT_LOCAL];
    assign d0_core_rx_flit                                           = d0_out_packed[PORT_LOCAL*FLIT_WIDTH +: FLIT_WIDTH];
    assign d0_out_ready[PORT_LOCAL]                                  = d0_core_rx_ready;

    // Tie off unused Die 0 ports (NORTH, SOUTH, WEST)
    assign d0_in_valid[PORT_NORTH]                                   = 1'b0;
    assign d0_in_packed[PORT_NORTH*FLIT_WIDTH +: FLIT_WIDTH]         = '0;
    assign d0_out_ready[PORT_NORTH]                                  = 1'b1;

    assign d0_in_valid[PORT_SOUTH]                                   = 1'b0;
    assign d0_in_packed[PORT_SOUTH*FLIT_WIDTH +: FLIT_WIDTH]         = '0;
    assign d0_out_ready[PORT_SOUTH]                                  = 1'b1;

    assign d0_in_valid[PORT_WEST]                                    = 1'b0;
    assign d0_in_packed[PORT_WEST*FLIT_WIDTH +: FLIT_WIDTH]          = '0;
    assign d0_out_ready[PORT_WEST]                                   = 1'b1;

    // Die 0 East Port (PORT_EAST = 2) connected to D2D Link Layer
    logic                  d0_east_tx_valid, d0_east_tx_ready;
    logic [FLIT_WIDTH-1:0] d0_east_tx_flit;
    logic                  d0_east_rx_valid, d0_east_rx_ready;
    logic [FLIT_WIDTH-1:0] d0_east_rx_flit;

    assign d0_east_tx_valid                                          = d0_out_valid[PORT_EAST];
    assign d0_east_tx_flit                                           = d0_out_packed[PORT_EAST*FLIT_WIDTH +: FLIT_WIDTH];
    assign d0_out_ready[PORT_EAST]                                   = d0_east_tx_ready;

    assign d0_in_valid[PORT_EAST]                                    = d0_east_rx_valid;
    assign d0_in_packed[PORT_EAST*FLIT_WIDTH +: FLIT_WIDTH]          = d0_east_rx_flit;
    assign d0_east_rx_ready                                          = d0_in_ready[PORT_EAST];

    noc_router_2d_vc4 #(
        .NODE_X(0),
        .NODE_Y(0),
        .FLIT_WIDTH(FLIT_WIDTH),
        .VC_COUNT(VC_COUNT),
        .FIFO_DEPTH(4)
    ) u_noc_router_die0 (
        .clk(clk),
        .rst_n(rst_n),
        .in_flit_valid(d0_in_valid),
        .in_flit_data_packed(d0_in_packed),
        .in_flit_ready(d0_in_ready),
        .out_flit_valid(d0_out_valid),
        .out_flit_data_packed(d0_out_packed),
        .out_flit_ready(d0_out_ready),
        .telemetry_vc0_flits(),
        .telemetry_total_flits()
    );

    // Die 0 Link Layer
    logic [PHY_LANES-1:0] d0_phy_tx_data, d0_phy_rx_data;
    logic                 d0_phy_tx_valid, d0_phy_tx_ready, d0_phy_rx_valid;
    logic [VC_COUNT-1:0]  d0_link_tx_crd, d0_link_rx_crd;

    d2d_link_layer #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .PHY_WIDTH(PHY_LANES),
        .VC_COUNT(VC_COUNT),
        .MAX_CREDITS(4)
    ) u_d2d_link_die0 (
        .clk(clk),
        .rst_n(rst_n),
        .noc_tx_valid(d0_east_tx_valid),
        .noc_tx_flit(d0_east_tx_flit),
        .noc_tx_ready(d0_east_tx_ready),
        .noc_rx_valid(d0_east_rx_valid),
        .noc_rx_flit(d0_east_rx_flit),
        .noc_rx_ready(d0_east_rx_ready),
        .phy_tx_data(d0_phy_tx_data),
        .phy_tx_valid(d0_phy_tx_valid),
        .phy_tx_ready(d0_phy_tx_ready),
        .phy_rx_data(d0_phy_rx_data),
        .phy_rx_valid(d0_phy_rx_valid),
        .link_tx_credit_ret(d0_link_tx_crd),
        .link_rx_credit_ret(d0_link_rx_crd),
        .telemetry_d2d_tx_flits(d0_telemetry_tx_flits),
        .telemetry_d2d_rx_flits(d0_telemetry_rx_flits),
        .telemetry_crc_errors()
    );

    // Die 0 Physical Layer (UCIe PHY)
    logic [PHY_LANES+REPAIR_LANES-1:0] d0_beachfront_tx_lanes;
    logic                              d0_beachfront_tx_valid;
    logic                              d0_beachfront_tx_clk;
    logic                              d0_beachfront_tx_sb;
    logic [VC_COUNT-1:0]               d0_beachfront_tx_crd;

    logic [PHY_LANES+REPAIR_LANES-1:0] d0_beachfront_rx_lanes;
    logic                              d0_beachfront_rx_valid;
    logic                              d0_beachfront_rx_clk;
    logic                              d0_beachfront_rx_sb;
    logic [VC_COUNT-1:0]               d0_beachfront_rx_crd;

    d2d_ucie_phy #(
        .LANES(PHY_LANES),
        .REPAIR_LANES(REPAIR_LANES),
        .VC_COUNT(VC_COUNT)
    ) u_d2d_phy_die0 (
        .clk(clk),
        .rst_n(rst_n),
        .link_tx_data(d0_phy_tx_data),
        .link_tx_valid(d0_phy_tx_valid),
        .link_tx_ready(d0_phy_tx_ready),
        .link_rx_data(d0_phy_rx_data),
        .link_rx_valid(d0_phy_rx_valid),
        .link_tx_credit_ret(d0_link_tx_crd),
        .link_rx_credit_ret(d0_link_rx_crd),
        .phy_tx_lanes(d0_beachfront_tx_lanes),
        .phy_tx_valid_lane(d0_beachfront_tx_valid),
        .phy_tx_fwd_clk(d0_beachfront_tx_clk),
        .phy_tx_sideband(d0_beachfront_tx_sb),
        .phy_tx_credits(d0_beachfront_tx_crd),
        .phy_rx_lanes(d0_beachfront_rx_lanes),
        .phy_rx_valid_lane(d0_beachfront_rx_valid),
        .phy_rx_fwd_clk(d0_beachfront_rx_clk),
        .phy_rx_sideband(d0_beachfront_rx_sb),
        .phy_rx_credits(d0_beachfront_rx_crd),
        .cfg_bad_lane_idx(cfg_d0_bad_lane_idx),
        .cfg_lane_repair_en(cfg_d0_lane_repair_en),
        .phy_link_up(d0_phy_link_up),
        .telemetry_phy_tx_words(),
        .telemetry_phy_rx_words()
    );

    // =========================================================================
    // DIE 1: Node (1,0) Router & UCIe Stack
    // =========================================================================
    logic [4:0]                 d1_in_valid, d1_in_ready;
    logic [(5*FLIT_WIDTH)-1:0]  d1_in_packed;
    logic [4:0]                 d1_out_valid, d1_out_ready;
    logic [(5*FLIT_WIDTH)-1:0]  d1_out_packed;

    // DIE 1 Local Port (PORT_LOCAL = 0)
    assign d1_in_valid[PORT_LOCAL]                                   = d1_core_tx_valid;
    assign d1_in_packed[PORT_LOCAL*FLIT_WIDTH +: FLIT_WIDTH]         = d1_core_tx_flit;
    assign d1_core_tx_ready                                          = d1_in_ready[PORT_LOCAL];

    assign d1_core_rx_valid                                          = d1_out_valid[PORT_LOCAL];
    assign d1_core_rx_flit                                           = d1_out_packed[PORT_LOCAL*FLIT_WIDTH +: FLIT_WIDTH];
    assign d1_out_ready[PORT_LOCAL]                                  = d1_core_rx_ready;

    // Tie off unused Die 1 ports (NORTH, SOUTH, EAST)
    assign d1_in_valid[PORT_NORTH]                                   = 1'b0;
    assign d1_in_packed[PORT_NORTH*FLIT_WIDTH +: FLIT_WIDTH]         = '0;
    assign d1_out_ready[PORT_NORTH]                                  = 1'b1;

    assign d1_in_valid[PORT_SOUTH]                                   = 1'b0;
    assign d1_in_packed[PORT_SOUTH*FLIT_WIDTH +: FLIT_WIDTH]         = '0;
    assign d1_out_ready[PORT_SOUTH]                                  = 1'b1;

    assign d1_in_valid[PORT_EAST]                                    = 1'b0;
    assign d1_in_packed[PORT_EAST*FLIT_WIDTH +: FLIT_WIDTH]          = '0;
    assign d1_out_ready[PORT_EAST]                                   = 1'b1;

    // Die 1 West Port (PORT_WEST = 4) connected to D2D Link Layer
    logic                  d1_west_tx_valid, d1_west_tx_ready;
    logic [FLIT_WIDTH-1:0] d1_west_tx_flit;
    logic                  d1_west_rx_valid, d1_west_rx_ready;
    logic [FLIT_WIDTH-1:0] d1_west_rx_flit;

    assign d1_west_tx_valid                                          = d1_out_valid[PORT_WEST];
    assign d1_west_tx_flit                                           = d1_out_packed[PORT_WEST*FLIT_WIDTH +: FLIT_WIDTH];
    assign d1_out_ready[PORT_WEST]                                   = d1_west_tx_ready;

    assign d1_in_valid[PORT_WEST]                                    = d1_west_rx_valid;
    assign d1_in_packed[PORT_WEST*FLIT_WIDTH +: FLIT_WIDTH]          = d1_west_rx_flit;
    assign d1_west_rx_ready                                          = d1_in_ready[PORT_WEST];

    noc_router_2d_vc4 #(
        .NODE_X(1),
        .NODE_Y(0),
        .FLIT_WIDTH(FLIT_WIDTH),
        .VC_COUNT(VC_COUNT),
        .FIFO_DEPTH(4)
    ) u_noc_router_die1 (
        .clk(clk),
        .rst_n(rst_n),
        .in_flit_valid(d1_in_valid),
        .in_flit_data_packed(d1_in_packed),
        .in_flit_ready(d1_in_ready),
        .out_flit_valid(d1_out_valid),
        .out_flit_data_packed(d1_out_packed),
        .out_flit_ready(d1_out_ready),
        .telemetry_vc0_flits(),
        .telemetry_total_flits()
    );

    // Die 1 Link Layer
    logic [PHY_LANES-1:0] d1_phy_tx_data, d1_phy_rx_data;
    logic                 d1_phy_tx_valid, d1_phy_tx_ready, d1_phy_rx_valid;
    logic [VC_COUNT-1:0]  d1_link_tx_crd, d1_link_rx_crd;

    d2d_link_layer #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .PHY_WIDTH(PHY_LANES),
        .VC_COUNT(VC_COUNT),
        .MAX_CREDITS(4)
    ) u_d2d_link_die1 (
        .clk(clk),
        .rst_n(rst_n),
        .noc_tx_valid(d1_west_tx_valid),
        .noc_tx_flit(d1_west_tx_flit),
        .noc_tx_ready(d1_west_tx_ready),
        .noc_rx_valid(d1_west_rx_valid),
        .noc_rx_flit(d1_west_rx_flit),
        .noc_rx_ready(d1_west_rx_ready),
        .phy_tx_data(d1_phy_tx_data),
        .phy_tx_valid(d1_phy_tx_valid),
        .phy_tx_ready(d1_phy_tx_ready),
        .phy_rx_data(d1_phy_rx_data),
        .phy_rx_valid(d1_phy_rx_valid),
        .link_tx_credit_ret(d1_link_tx_crd),
        .link_rx_credit_ret(d1_link_rx_crd),
        .telemetry_d2d_tx_flits(d1_telemetry_tx_flits),
        .telemetry_d2d_rx_flits(d1_telemetry_rx_flits),
        .telemetry_crc_errors()
    );

    // Die 1 Physical Layer (UCIe PHY)
    logic [PHY_LANES+REPAIR_LANES-1:0] d1_beachfront_tx_lanes;
    logic                              d1_beachfront_tx_valid;
    logic                              d1_beachfront_tx_clk;
    logic                              d1_beachfront_tx_sb;
    logic [VC_COUNT-1:0]               d1_beachfront_tx_crd;

    logic [PHY_LANES+REPAIR_LANES-1:0] d1_beachfront_rx_lanes;
    logic                              d1_beachfront_rx_valid;
    logic                              d1_beachfront_rx_clk;
    logic                              d1_beachfront_rx_sb;
    logic [VC_COUNT-1:0]               d1_beachfront_rx_crd;

    d2d_ucie_phy #(
        .LANES(PHY_LANES),
        .REPAIR_LANES(REPAIR_LANES),
        .VC_COUNT(VC_COUNT)
    ) u_d2d_phy_die1 (
        .clk(clk),
        .rst_n(rst_n),
        .link_tx_data(d1_phy_tx_data),
        .link_tx_valid(d1_phy_tx_valid),
        .link_tx_ready(d1_phy_tx_ready),
        .link_rx_data(d1_phy_rx_data),
        .link_rx_valid(d1_phy_rx_valid),
        .link_tx_credit_ret(d1_link_tx_crd),
        .link_rx_credit_ret(d1_link_rx_crd),
        .phy_tx_lanes(d1_beachfront_tx_lanes),
        .phy_tx_valid_lane(d1_beachfront_tx_valid),
        .phy_tx_fwd_clk(d1_beachfront_tx_clk),
        .phy_tx_sideband(d1_beachfront_tx_sb),
        .phy_tx_credits(d1_beachfront_tx_crd),
        .phy_rx_lanes(d1_beachfront_rx_lanes),
        .phy_rx_valid_lane(d1_beachfront_rx_valid),
        .phy_rx_fwd_clk(d1_beachfront_rx_clk),
        .phy_rx_sideband(d1_beachfront_rx_sb),
        .phy_rx_credits(d1_beachfront_rx_crd),
        .cfg_bad_lane_idx(cfg_d1_bad_lane_idx),
        .cfg_lane_repair_en(cfg_d1_lane_repair_en),
        .phy_link_up(d1_phy_link_up),
        .telemetry_phy_tx_words(),
        .telemetry_phy_rx_words()
    );

    // =========================================================================
    // PHYSICAL INTERPOSER / SUBSTRATE CHANNEL MODEL
    // =========================================================================
    // Connects beachfront microbumps of Die 0 to Die 1 with optional defect injection
    // Defect mask: bit=1 means open/broken microbump (drives 0 to receiver)
    assign d1_beachfront_rx_lanes = d0_beachfront_tx_lanes & ~interposer_defect_mask_d0_to_d1;
    assign d1_beachfront_rx_valid = d0_beachfront_tx_valid;
    assign d1_beachfront_rx_clk   = d0_beachfront_tx_clk;
    assign d1_beachfront_rx_sb    = d0_beachfront_tx_sb;
    assign d1_beachfront_rx_crd   = d0_beachfront_tx_crd;

    assign d0_beachfront_rx_lanes = d1_beachfront_tx_lanes & ~interposer_defect_mask_d1_to_d0;
    assign d0_beachfront_rx_valid = d1_beachfront_tx_valid;
    assign d0_beachfront_rx_clk   = d1_beachfront_tx_clk;
    assign d0_beachfront_rx_sb    = d1_beachfront_tx_sb;
    assign d0_beachfront_rx_crd   = d1_beachfront_tx_crd;

endmodule
