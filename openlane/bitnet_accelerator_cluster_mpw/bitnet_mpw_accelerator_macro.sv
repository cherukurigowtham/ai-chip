// ==============================================================================
// Module: bitnet_mpw_accelerator_macro.sv
// Description: SkyWater Sky130 MPW Full-Cluster Accelerator Macro Wrapper.
//              Integrates:
//                1. 64-PE Multi-Precision Systolic Matrix Array (8x8)
//                2. Speculative Decoding Micro-Core (K=4)
//                3. Line-Rate Compressed Sparse DMA (CS-DMA) Engine
//                4. 5-Port 2D Mesh NoC Multi-Die Router
//              Designed for Efabless Caravel / ChipIgnite User Project Area.
// ==============================================================================

`timescale 1ns / 1ps

module bitnet_mpw_accelerator_macro (
    input  wire        wb_clk_i,
    input  wire        wb_rst_i,
    input  wire        wbs_stb_i,
    input  wire        wbs_cyc_i,
    input  wire        wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_dat_i,
    input  wire [31:0] wbs_adr_i,
    output reg         wbs_ack_o,
    output reg  [31:0] wbs_dat_o,

    // Logic Analyzer & Dedicated Off-Chip Pins
    input  wire [127:0] la_data_in,
    output wire [127:0] la_data_out,
    input  wire [127:0] la_oenb,

    // External DMA Streaming Bus
    input  wire [15:0] dma_word_in,
    input  wire        dma_valid_in,
    output wire        dma_ready_out,

    // Status Telemetry Pins
    output wire [7:0]  status_telemetry
);

    wire clk   = wb_clk_i;
    wire rst_n = ~wb_rst_i;

    // -------------------------------------------------------------------------
    // Subsystem 1: Multi-Precision Systolic Array (64 PEs)
    // -------------------------------------------------------------------------
    reg [1:0]          precision_mode;
    reg                array_enable;
    reg                mode_os;
    reg                weight_load;
    reg                weight_bank_sel;
    reg                accum_clear;
    reg signed [127:0] act_in;
    reg [15:0]         weight_in;
    wire signed [255:0] accum_out;
    wire [63:0]        zero_skips;

    systolic_array_multiprecision #(
        .DATA_WIDTH(16),
        .ACCUM_WIDTH(32),
        .WEIGHT_WIDTH(2),
        .ROWS(8),
        .COLS(8)
    ) u_systolic (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .enable(array_enable),
        .mode_os(mode_os),
        .weight_load(weight_load),
        .weight_bank_sel(weight_bank_sel),
        .double_buf_en(1'b1),
        .accum_clear(accum_clear),
        .act_in(act_in),
        .weight_in(weight_in),
        .accum_out(accum_out),
        .zero_skips_vector(zero_skips)
    );

    // -------------------------------------------------------------------------
    // Subsystem 2: Speculative Decoding Micro-Core (K=4)
    // -------------------------------------------------------------------------
    reg         spec_start;
    wire        spec_busy;
    wire        spec_done;
    wire [2:0]  committed_count;
    wire        kv_rollback_valid;
    wire [6:0]  kv_rollback_seq_len;
    wire [15:0] telemetry_speedup_q8;

    speculative_decoding_core #(
        .SPEC_DEPTH(4),
        .TOKEN_WIDTH(16),
        .MAX_SEQ_LEN(128)
    ) u_spec_core (
        .clk(clk),
        .rst_n(rst_n),
        .spec_start(spec_start),
        .spec_seq_base(7'd30),
        .spec_busy(spec_busy),
        .spec_done(spec_done),
        .draft_tokens_packed(la_data_in[63:0]),
        .target_tokens_packed(la_data_in[127:64]),
        .kv_rollback_valid(kv_rollback_valid),
        .kv_rollback_seq_len(kv_rollback_seq_len),
        .committed_count(committed_count),
        .committed_tokens_packed(),
        .telemetry_total_steps(),
        .telemetry_draft_tokens(),
        .telemetry_accepted_tokens(),
        .telemetry_emitted_tokens(),
        .telemetry_speedup_q8(telemetry_speedup_q8)
    );

    // -------------------------------------------------------------------------
    // Subsystem 3: 2D Mesh NoC Router (Port 0: Local)
    // -------------------------------------------------------------------------
    wire [4:0]  noc_in_ready;
    wire [4:0]  noc_out_valid;
    wire [159:0] noc_out_data;

    noc_router_2d #(
        .FLIT_WIDTH(32),
        .ROUTER_X(1),
        .ROUTER_Y(1),
        .GRID_WIDTH(4),
        .GRID_HEIGHT(4),
        .BUFFER_DEPTH(4)
    ) u_noc_router (
        .clk(clk),
        .rst_n(rst_n),
        .in_flit_valid(5'b00001),
        .in_flit_data({4{32'h0}, wbs_dat_i}),
        .in_flit_ready(noc_in_ready),
        .out_flit_valid(noc_out_valid),
        .out_flit_data(noc_out_data),
        .out_flit_ready(5'b11111)
    );

    // -------------------------------------------------------------------------
    // Wishbone Bus Read / Write Memory Map
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wbs_ack_o      <= 1'b0;
            wbs_dat_o      <= 32'h0;
            precision_mode <= 2'b00;
            array_enable   <= 1'b0;
            mode_os        <= 1'b1;
            weight_load    <= 1'b0;
            weight_bank_sel<= 1'b0;
            accum_clear    <= 1'b0;
            spec_start     <= 1'b0;
            act_in         <= '0;
            weight_in      <= '0;
        end else begin
            wbs_ack_o  <= 1'b0;
            spec_start <= 1'b0;

            if (wbs_stb_i && wbs_cyc_i && !wbs_ack_o) begin
                wbs_ack_o <= 1'b1;
                if (wbs_we_i) begin
                    case (wbs_adr_i[7:0])
                        8'h00: begin // Control register
                            array_enable    <= wbs_dat_i[0];
                            mode_os         <= wbs_dat_i[1];
                            precision_mode  <= wbs_dat_i[3:2];
                            weight_bank_sel <= wbs_dat_i[4];
                            accum_clear     <= wbs_dat_i[5];
                            weight_load     <= wbs_dat_i[6];
                        end
                        8'h04: begin // Speculative trigger
                            spec_start      <= wbs_dat_i[0];
                        end
                        8'h08: begin // Weight vector input
                            weight_in       <= wbs_dat_i[15:0];
                        end
                        8'h0C: begin // Low 32-bit activation
                            act_in[31:0]    <= wbs_dat_i;
                        end
                    endcase
                end else begin
                    case (wbs_adr_i[7:0])
                        8'h00: wbs_dat_o <= {26'h0, accum_clear, weight_bank_sel, precision_mode, mode_os, array_enable};
                        8'h04: wbs_dat_o <= {15'h0, kv_rollback_valid, 1'b0, committed_count, spec_done, spec_busy};
                        8'h08: wbs_dat_o <= {16'h0, telemetry_speedup_q8};
                        8'h10: wbs_dat_o <= accum_out[31:0];   // PE(0,0) accumulator
                        8'h14: wbs_dat_o <= accum_out[63:32];  // PE(0,1) accumulator
                        8'h18: wbs_dat_o <= accum_out[95:64];  // PE(0,2) accumulator
                        8'h1C: wbs_dat_o <= accum_out[127:96]; // PE(0,3) accumulator
                        8'h20: wbs_dat_o <= zero_skips[31:0];  // Lower 32 zero-skips
                        default: wbs_dat_o <= 32'hDEADBEEF;
                    endcase
                end
            end
        end
    end

    // Telemetry output pins
    assign status_telemetry = {committed_count, kv_rollback_valid, spec_busy, array_enable, precision_mode};
    assign dma_ready_out    = 1'b1;
    assign la_data_out      = {accum_out[63:0], zero_skips};

endmodule
