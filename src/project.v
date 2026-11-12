`default_nettype none

// ==============================================================================
// Module: tt_um_cherukurigowtham_ternary_mac
// Description: Multiplier-Free Dual-Mode (WS/OS) Ternary Processing Element
//              for Tiny Tapeout (SkyWater Sky130 / OpenLane).
//
// Key Features:
// 1. Dual-Mode Operation:
//    - Weight-Stationary (WS, mode_os = 0):
//        Stationary 2-bit weight latched on weight_load.
//        Accumulates: accum <= accum + (act_in * w_reg).
//    - Output-Stationary (OS, mode_os = 1):
//        Streaming 2-bit weight from uio_in[1:0].
//        Accumulates: accum <= accum + (act_in * weight_in).
// 2. Multiplier-Free Ternary Arithmetic (2-bit encoding):
//    - 2'b00 : Zero (Skip update / operand isolate)
//    - 2'b01 : Positive (+1, Add activation)
//    - 2'b10 : Negative (-1, Subtract activation)
//    - 2'b11 : Reserved / NOP (Skip update)
// 3. Dynamic Zero-Skip Telemetry:
//    - Real-time flag and 8-bit counter tracking energy-saving zero skips.
// 4. 24-bit Signed Accumulator:
//    - Byte-multiplexed readout via uo_out using byte_select[1:0].
// ==============================================================================

module tt_um_cherukurigowtham_ternary_mac (
    input  wire [7:0] ui_in,    // Dedicated inputs: act_in[7:0] (signed 8-bit)
    output wire [7:0] uo_out,   // Dedicated outputs: multiplexed accumulator / telemetry
    input  wire [7:0] uio_in,   // IOs: Input path (Control and Weight)
    output wire [7:0] uio_out,  // IOs: Output path (Telemetry)
    output wire [7:0] uio_oe,   // IOs: Enable path (0 = all input)
    input  wire       ena,      // always 1 when design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - active low
);

    // -------------------------------------------------------------------------
    // Control Signal Decoding from uio_in
    // -------------------------------------------------------------------------
    wire [1:0] weight_in   = uio_in[1:0]; // 2-bit ternary weight
    wire       weight_load = uio_in[2];   // WS: latch weight into stationary register
    wire       mode_os     = uio_in[3];   // 0: Weight Stationary, 1: Output Stationary
    wire       accum_clear = uio_in[4];   // Sync clear accumulator
    wire       enable      = uio_in[5];   // Compute enable
    wire [1:0] byte_select = uio_in[7:6]; // Output byte select

    // Dedicate bidirectional pins as inputs (oe = 0)
    assign uio_oe = 8'b0000_0000;

    // -------------------------------------------------------------------------
    // Activation Input (Signed 8-bit)
    // -------------------------------------------------------------------------
    wire signed [7:0] act_in = ui_in[7:0];

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    reg [1:0]                w_reg;
    reg signed [23:0]        accum_reg;
    reg                      zero_skipped_reg;
    reg [7:0]                zero_skips_count;
    reg                      mode_os_reg;
    reg                      overflow_reg;

    // -------------------------------------------------------------------------
    // Ternary Weight Selection & Decoding
    // -------------------------------------------------------------------------
    wire [1:0] curr_weight = (mode_os) ? weight_in : w_reg;

    wire is_zero = (curr_weight == 2'b00) || (curr_weight == 2'b11);
    wire is_add  = (curr_weight == 2'b01);
    wire is_sub  = (curr_weight == 2'b10);

    // -------------------------------------------------------------------------
    // Multiplier-Free Arithmetic with Operand Isolation
    // -------------------------------------------------------------------------
    // Clamping operand to 0 on zero weight prevents adder dynamic power dissipation
    wire signed [23:0] act_extended = {{16{act_in[7]}}, act_in};
    wire signed [23:0] operand      = (is_zero) ? 24'sd0 : act_extended;

    wire signed [23:0] raw_sum  = accum_reg + operand;
    wire signed [23:0] raw_diff = accum_reg - operand;

    // Overflow detection (signed 24-bit)
    wire add_overflow = is_add && (!accum_reg[23] && !operand[23] && raw_sum[23]);
    wire sub_overflow = is_sub && (accum_reg[23] && !operand[23] && !raw_diff[23]);

    // Saturating arithmetic clamping (prevents catastrophic sign inversion rollover)
    wire signed [23:0] accum_next =
        (is_add) ? (add_overflow ? 24'sh7F_FFFF : raw_sum) :
        (is_sub) ? (sub_overflow ? -24'sh80_0000 : raw_diff) :
                   accum_reg;

    // -------------------------------------------------------------------------
    // Sequential State Update
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_reg            <= 2'b00;
            accum_reg        <= 24'sd0;
            zero_skipped_reg <= 1'b0;
            zero_skips_count <= 8'd0;
            mode_os_reg      <= 1'b0;
            overflow_reg     <= 1'b0;
        end else if (ena) begin
            mode_os_reg <= mode_os;

            // WS Mode: latch stationary weight
            if (!mode_os && weight_load) begin
                w_reg <= weight_in;
            end

            // Accumulator update
            if (accum_clear) begin
                accum_reg        <= 24'sd0;
                overflow_reg     <= 1'b0;
                zero_skipped_reg <= 1'b0;
            end else if (enable) begin
                accum_reg        <= accum_next;
                zero_skipped_reg <= is_zero;

                if (is_zero) begin
                    zero_skips_count <= zero_skips_count + 8'd1;
                end

                if (add_overflow || sub_overflow) begin
                    overflow_reg <= 1'b1;
                end
            end else begin
                zero_skipped_reg <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Multiplexed Output Bus (uo_out[7:0])
    // -------------------------------------------------------------------------
    reg [7:0] out_mux;
    always @(*) begin
        case (byte_select)
            2'b00:   out_mux = accum_reg[7:0];   // Byte 0 (LSB)
            2'b01:   out_mux = accum_reg[15:8];  // Byte 1 (Mid)
            2'b10:   out_mux = accum_reg[23:16]; // Byte 2 (MSB)
            2'b11:   out_mux = {zero_skips_count[3:0], overflow_reg, mode_os_reg, zero_skipped_reg, is_zero}; // Status telemetry
            default: out_mux = 8'h00;
        endcase
    end

    assign uo_out = out_mux;

    // -------------------------------------------------------------------------
    // Telemetry Output Path (uio_out[7:0])
    // -------------------------------------------------------------------------
    assign uio_out = {zero_skips_count[3:0], overflow_reg, is_sub, is_add, zero_skipped_reg};

endmodule
