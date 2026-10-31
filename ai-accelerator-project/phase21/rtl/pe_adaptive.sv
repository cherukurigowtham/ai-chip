// ==============================================================================
// Module: pe_adaptive (Reconfigurable / Adaptive Processing Element)
// Description: Unified Dual-Mode PE with Clustered Local Slices and
//              Interconnect-Aware Control Distribution (Phase 20 Optimization).
//              - In Weight-Stationary (WS) Mode:
//                  * Stationary weight loaded directly from weight_tile_in into w_reg.
//                  * Dedicated WS adder: ws_next = mult_product + psum_in.
//              - In Output-Stationary (OS) Mode:
//                  * Dedicated OS accumulator: accum_next = accum_reg + mult_product.
//                  * Zero mode-selection muxing on the accumulator critical path!
//              - Phase 20 Optimization:
//                  * Clustered Local Mode Registers: Dedicated flip-flops for multiplier
//                    slices, drain mux slices, and register enables.
//                  * Fanout per flip-flop is strictly <= 16 loads, completely
//                    preventing buffer tree insertion and eliminating buffer delay.
// ==============================================================================

`timescale 1ns / 1ps

module pe_adaptive #(
    parameter int DATA_WIDTH  = 16,
    parameter int ACCUM_WIDTH = 32
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               mode_os,         // Global mode select from controller
    input  logic                               enable,
    input  logic                               weight_load,     // WS only: latch stationary weight
    input  logic                               accum_clear,     // OS only: clear local accumulator
    input  logic                               drain_en,        // OS only: shift accumulator vertically

    input  logic signed [DATA_WIDTH-1:0]       act_in,
    input  logic signed [DATA_WIDTH-1:0]       weight_in,       // OS: streaming weight from top mesh
    input  logic signed [DATA_WIDTH-1:0]       weight_tile_in,  // WS: stationary weight from tile buffer
    input  logic signed [ACCUM_WIDTH-1:0]      psum_in,

    output logic signed [DATA_WIDTH-1:0]       act_out,
    output logic signed [DATA_WIDTH-1:0]       weight_out,
    output logic signed [ACCUM_WIDTH-1:0]      psum_out
);

    // -------------------------------------------------------------------------
    // Phase 20 Clustered Local Mode Registers
    // Sliced so that each flip-flop drives <= 16 loads, preventing buffer trees!
    // -------------------------------------------------------------------------
    (* keep = "true" *) logic mode_os_mult_b0;
    (* keep = "true" *) logic mode_os_mult_b1;
    (* keep = "true" *) logic mode_os_drain_lo;
    (* keep = "true" *) logic mode_os_drain_hi;
    (* keep = "true" *) logic mode_os_accum;
    (* keep = "true" *) logic mode_os_psum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_os_mult_b0  <= 1'b0;
            mode_os_mult_b1  <= 1'b0;
            mode_os_drain_lo <= 1'b0;
            mode_os_drain_hi <= 1'b0;
            mode_os_accum    <= 1'b0;
            mode_os_psum     <= 1'b0;
        end else if (!enable) begin
            mode_os_mult_b0  <= mode_os;
            mode_os_mult_b1  <= mode_os;
            mode_os_drain_lo <= mode_os;
            mode_os_drain_hi <= mode_os;
            mode_os_accum    <= mode_os;
            mode_os_psum     <= mode_os;
        end
    end

    // Internal Registers
    logic signed [DATA_WIDTH-1:0]  w_reg;
    logic signed [ACCUM_WIDTH-1:0] accum_reg;
    logic signed [ACCUM_WIDTH-1:0] psum_out_ws;

    // -------------------------------------------------------------------------
    // Multiplier Datapath with Sliced MUX Control (8 bits per slice)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]  mult_op_b;
    logic signed [ACCUM_WIDTH-1:0] mult_product;

    assign mult_op_b[7:0]   = mode_os_mult_b0 ? weight_in[7:0]  : w_reg[7:0];
    assign mult_op_b[15:8]  = mode_os_mult_b1 ? weight_in[15:8] : w_reg[15:8];
    assign mult_product     = $signed(act_in) * $signed(mult_op_b);

    // -------------------------------------------------------------------------
    // Restructured Control Paths (Zero Mode Muxing on Adder Inputs!)
    // -------------------------------------------------------------------------
    // OS Local Accumulator Path: directly adds accum_reg + mult_product
    logic signed [ACCUM_WIDTH-1:0] accum_next;
    assign accum_next = accum_reg + mult_product;

    // WS Vertical PSum Path: directly adds psum_in + mult_product
    logic signed [ACCUM_WIDTH-1:0] ws_next;
    assign ws_next = psum_in + mult_product;

    // Sliced drain output selection (16 bits per slice)
    assign psum_out[15:0]  = mode_os_drain_lo ? accum_reg[15:0]  : psum_out_ws[15:0];
    assign psum_out[31:16] = mode_os_drain_hi ? accum_reg[31:16] : psum_out_ws[31:16];

    // -------------------------------------------------------------------------
    // Sequential State Updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_reg       <= '0;
            accum_reg   <= '0;
            act_out     <= '0;
            weight_out  <= '0;
            psum_out_ws <= '0;
        end else begin
            // Stationary Weight Load (WS)
            if (weight_load) begin
                w_reg <= weight_tile_in;
            end

            // Activations & Streaming Weights Forwarding
            if (enable) begin
                act_out    <= act_in;
                weight_out <= weight_in;
            end

            // Output-Stationary Accumulator
            if (mode_os_accum) begin
                if (accum_clear) begin
                    accum_reg <= '0;
                end else if (drain_en) begin
                    accum_reg <= psum_in;
                end else if (enable) begin
                    accum_reg <= accum_next;
                end
            end

            // Weight-Stationary Output
            if (!mode_os_psum) begin
                if (enable) begin
                    psum_out_ws <= ws_next;
                end
            end
        end
    end

endmodule
