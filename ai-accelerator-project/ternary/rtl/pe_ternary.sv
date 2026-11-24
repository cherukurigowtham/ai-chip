// ==============================================================================
// Module: pe_ternary (Unified Dual-Mode WS/OS Ternary Processing Element)
// Description: Multiplier-free, Dual-Mode (Weight-Stationary / Output-Stationary)
//              Processing Element for Hybrid Binary-Ternary AI Accelerators.
//
// Features:
// 1. Dual-Mode Operation:
//    - Weight-Stationary (WS, mode_os = 0):
//        * Stationary 2-bit weight latched in w_reg from weight_tile_in.
//        * Multiplier-free accumulation: ws_next = psum_in + (act_in * w_reg).
//    - Output-Stationary (OS, mode_os = 1):
//        * Weights stream vertically (weight_in -> weight_out, 2-bit).
//        * Local 32-bit accumulator: accum_next = accum_reg + (act_in * weight_in).
//        * Vertical drain on drain_en (accum_reg <= psum_in).
// 2. Multiplier-Free Ternary Arithmetic (2-bit encoding):
//    - 2'b00 : Zero (Skip update / operand isolate)
//    - 2'b01 : Positive (+1, Add activation)
//    - 2'b10 : Negative (-1, Subtract activation)
//    - 2'b11 : Reserved / NOP (Bypass accumulator)
// 3. Operand Isolation:
//    - Clamps internal adder operand to 0 when weight is 0, eliminating carry chain
//      dynamic switching power.
// 4. Clustered Mode Registers:
//    - Sliced control flip-flops driving <= 16 loads for 500 MHz timing closure.
// ==============================================================================

`timescale 1ns / 1ps

module pe_ternary #(
    parameter int DATA_WIDTH   = 16, // Activation width (16-bit signed)
    parameter int ACCUM_WIDTH  = 32, // Accumulator width (32-bit signed)
    parameter int WEIGHT_WIDTH = 2   // Ternary weight width (2-bit encoded)
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               mode_os,        // 0: WS, 1: OS
    input  logic                               enable,
    input  logic                               weight_load,    // WS only: latch stationary weight
    input  logic                               weight_bank_sel,// WS double-buffering: 0=Bank A, 1=Bank B
    input  logic                               double_buf_en,  // 0: single buffer, 1: shadow preload
    input  logic                               accum_clear,    // OS only: clear local accumulator
    input  logic                               drain_en,       // OS only: shift accumulator vertically

    input  logic signed [DATA_WIDTH-1:0]       act_in,         // Activation from left
    input  logic        [WEIGHT_WIDTH-1:0]     weight_in,      // OS: streaming weight from top
    input  logic        [WEIGHT_WIDTH-1:0]     weight_tile_in, // WS: stationary weight from tile buffer
    input  logic signed [ACCUM_WIDTH-1:0]      psum_in,        // Partial sum from top

    output logic signed [DATA_WIDTH-1:0]       act_out,        // Forwarded activation to right
    output logic        [WEIGHT_WIDTH-1:0]     weight_out,     // Forwarded streaming weight to bottom
    output logic signed [ACCUM_WIDTH-1:0]      psum_out,       // Partial sum or drained result to bottom
    output logic                               zero_skipped    // Registered telemetry flag
);

    // -------------------------------------------------------------------------
    // Clustered Local Mode Registers (Fanout <= 16 loads per flip-flop)
    // -------------------------------------------------------------------------
    (* keep = "true" *) logic mode_os_reg_w;
    (* keep = "true" *) logic mode_os_reg_drain_lo;
    (* keep = "true" *) logic mode_os_reg_drain_hi;
    (* keep = "true" *) logic mode_os_reg_accum;
    (* keep = "true" *) logic mode_os_reg_psum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_os_reg_w        <= 1'b0;
            mode_os_reg_drain_lo <= 1'b0;
            mode_os_reg_drain_hi <= 1'b0;
            mode_os_reg_accum    <= 1'b0;
            mode_os_reg_psum     <= 1'b0;
        end else if (!enable) begin
            mode_os_reg_w        <= mode_os;
            mode_os_reg_drain_lo <= mode_os;
            mode_os_reg_drain_hi <= mode_os;
            mode_os_reg_accum    <= mode_os;
            mode_os_reg_psum     <= mode_os;
        end
    end

    // Internal Registers
    logic [WEIGHT_WIDTH-1:0]       w_reg_bank [0:1]; // Shadow Ping-Pong banks
    logic signed [ACCUM_WIDTH-1:0] accum_reg;
    logic signed [ACCUM_WIDTH-1:0] psum_out_ws;

    // -------------------------------------------------------------------------
    // Ternary Weight Selection & Decoding
    // -------------------------------------------------------------------------
    logic [WEIGHT_WIDTH-1:0] curr_weight;
    assign curr_weight = mode_os_reg_w ? weight_in : w_reg_bank[weight_bank_sel];

    logic is_zero;
    logic is_add;
    logic is_sub;

    // Dual-Sided Zero Skipping (Weight == 0 OR Activation == 0)
    assign is_zero = (curr_weight == 2'b00) || (curr_weight == 2'b11) || (act_in == '0);
    assign is_add  = (curr_weight == 2'b01);
    assign is_sub  = (curr_weight == 2'b10);

    // -------------------------------------------------------------------------
    // Operand Isolation & Conditional Arithmetic (Zero Multiplier!)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]  act_isolated;
    logic signed [ACCUM_WIDTH-1:0] ext_act;

    // Isolate activation operand to prevent carry chain switching when weight is zero
    assign act_isolated = is_zero ? '0 : act_in;
    assign ext_act      = {{ (ACCUM_WIDTH - DATA_WIDTH){act_isolated[DATA_WIDTH-1]} }, act_isolated};

    // Single-stage unified adder-subtractor (eliminates 2-level carry chain):
    // In subtraction: accum_reg - ext_act = accum_reg + (~ext_act) + 1
    logic signed [ACCUM_WIDTH-1:0] adder_op_b;
    logic                          adder_cin;

    assign adder_op_b = is_sub ? ~ext_act : ext_act;
    assign adder_cin  = is_sub;

    // Dedicated Paths (Zero Mode Muxing on Adder Inputs)
    logic signed [ACCUM_WIDTH-1:0] accum_next;
    logic signed [ACCUM_WIDTH-1:0] ws_next;

    assign accum_next = is_zero ? accum_reg : (accum_reg + adder_op_b + ACCUM_WIDTH'(adder_cin));
    assign ws_next    = is_zero ? psum_in   : (psum_in + adder_op_b + ACCUM_WIDTH'(adder_cin));

    // Sliced drain output selection (16 bits per slice)
    assign psum_out[15:0]  = mode_os_reg_drain_lo ? accum_reg[15:0]  : psum_out_ws[15:0];
    assign psum_out[31:16] = mode_os_reg_drain_hi ? accum_reg[31:16] : psum_out_ws[31:16];

    // -------------------------------------------------------------------------
    // Fine-Grained Integrated Clock Gating (ICG) for Accumulator
    // Clamps clock to the 32-bit local accumulator when zero-skipping in OS mode
    // -------------------------------------------------------------------------
    wire accum_clk_en = accum_clear || drain_en || (enable && !is_zero);
    wire accum_gclk;

    clkgate_x1 u_icg_accum (
        .clk_in   (clk),
        .enable   (accum_clk_en),
        .test_mode(1'b0),
        .clk_out  (accum_gclk)
    );

    // -------------------------------------------------------------------------
    // Sequential Pipeline Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge accum_gclk or negedge rst_n) begin
        if (!rst_n) begin
            accum_reg <= '0;
        end else if (mode_os_reg_accum) begin
            if (accum_clear) begin
                accum_reg <= '0;
            end else if (drain_en) begin
                accum_reg <= psum_in;
            end else if (enable) begin
                accum_reg <= accum_next;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_reg_bank[0] <= 2'b00;
            w_reg_bank[1] <= 2'b00;
            act_out       <= '0;
            weight_out    <= 2'b00;
            psum_out_ws   <= '0;
            zero_skipped  <= 1'b1;
        end else begin
            // Stationary Weight Load (WS) with Shadow Double-Buffering
            if (weight_load) begin
                if (double_buf_en) begin
                    w_reg_bank[~weight_bank_sel] <= weight_tile_in;
                end else begin
                    w_reg_bank[weight_bank_sel]  <= weight_tile_in;
                end
            end

            // Forward Activations and Streaming Weights
            if (enable) begin
                act_out      <= act_in;
                weight_out   <= weight_in;
                zero_skipped <= is_zero;
            end

            // Weight-Stationary Output
            if (!mode_os_reg_psum) begin
                if (enable) begin
                    psum_out_ws <= ws_next;
                end
            end
        end
    end

endmodule
