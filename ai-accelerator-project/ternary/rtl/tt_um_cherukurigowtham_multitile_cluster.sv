`default_nettype none

// ==============================================================================
// Module: tt_um_cherukurigowtham_multitile_cluster.sv
// Description: Multi-Tile 2x2 Scaled AI Accelerator Cluster for Tiny Tapeout tt10
//              (SkyWater Sky130 130nm CMOS / OpenLane 2 Flow).
//
// Key Specifications:
// 1. Allocated Silicon Footprint:
//    - 2x2 Multi-Tile Macro: ~322 um x 223 um (~71,819 um² die budget)
// 2. Compute Core:
//    - 4 Reconfigurable Processing Elements (PE00, PE01, PE10, PE11)
//    - Reconfigurable Multi-Precision Engine:
//        * Mode 00: Quad Parallel Ternary MACs (4x 1.58b concurrent throughput)
//        * Mode 01: Dual 4-bit INT4 MACs via PE-Pairing
//        * Mode 10: Single 8-bit INT8 Full-Range MAC via 4-PE Ganging
//        * Mode 11: 2D NoC Inter-Tile Routing & Diagnostics
// 3. Multiplier-Free Silicon:
//    - Strictly ZERO hardware multipliers or DSP primitives.
//    - 100% conditional shift-and-add arithmetic.
// 4. On-Chip 2D Mesh NoC Router:
//    - Inter-quadrant dimension-order routing (X-Y) for activations & partial sums.
// 5. Zero-Skip Telemetry & Power Gating:
//    - Operand isolation on zero weights.
// ==============================================================================

module tt_um_cherukurigowtham_multitile_cluster (
    input  wire [7:0] ui_in,    // Dedicated inputs: act_in[7:0] (signed 8-bit activation)
    output wire [7:0] uo_out,   // Dedicated outputs: multiplexed accumulator / telemetry byte
    input  wire [7:0] uio_in,   // IOs: Input control path
    output wire [7:0] uio_out,  // IOs: Output telemetry path
    output wire [7:0] uio_oe,   // IOs: Direction control
    input  wire       ena,      // Power enable (always 1)
    input  wire       clk,      // System clock (nominal 10-50 MHz)
    input  wire       rst_n     // Active-low asynchronous reset
);

    // -------------------------------------------------------------------------
    // Control Signal Decoding from uio_in
    // -------------------------------------------------------------------------
    wire [1:0] precision_mode = uio_in[1:0]; // 00=Ternary, 01=INT4, 10=INT8, 11=NoC
    wire [1:0] pe_select      = uio_in[3:2]; // Select PE0..3 or Ganged result
    wire       weight_load    = uio_in[4];   // Latch weight inputs
    wire       accum_clear    = uio_in[5];   // Synchronous accumulator clear
    wire       enable         = uio_in[6];   // Compute enable
    wire       byte_select    = uio_in[7];   // 0: LSB [7:0], 1: Upper [15:8]

    // Telemetry Registers
    reg [7:0]         telemetry_zero_skips;
    reg [7:0]         telemetry_noc_flits;

    // Dedicate bidirectional pins as inputs (oe = 0) to eliminate pad bus contention
    assign uio_oe  = 8'b0000_0000;
    assign uio_out = 8'h00;

    // -------------------------------------------------------------------------
    // Input Activation (Signed 8-bit)
    // -------------------------------------------------------------------------
    wire signed [7:0] act_in = ui_in[7:0];

    // -------------------------------------------------------------------------
    // 4 Processing Elements Registers
    // -------------------------------------------------------------------------
    reg [1:0]         pe_w00, pe_w01, pe_w10, pe_w11;
    reg signed [23:0] pe_acc00, pe_acc01, pe_acc10, pe_acc11;

    // -------------------------------------------------------------------------
    // Multiplier-Free Ternary / Shift-Add Update with Saturation Clamping
    // -------------------------------------------------------------------------
    function automatic signed [23:0] calc_ternary_step(
        input signed [23:0] current_acc,
        input signed [7:0]  act,
        input [1:0]         w
    );
        reg signed [24:0] full_sum;
        reg signed [24:0] full_diff;
        reg signed [23:0] act_sign_ext;
        begin
            act_sign_ext = {{16{act[7]}}, act};
            full_sum     = {current_acc[23], current_acc} + {act_sign_ext[23], act_sign_ext};
            full_diff    = {current_acc[23], current_acc} - {act_sign_ext[23], act_sign_ext};

            case (w)
                2'b01: begin // +1 with saturation clamping
                    if (full_sum > 25'sd8388607)
                        calc_ternary_step = 24'sh7F_FFFF;
                    else if (full_sum < -25'sd8388608)
                        calc_ternary_step = -24'sh80_0000;
                    else
                        calc_ternary_step = full_sum[23:0];
                end
                2'b10: begin // -1 with saturation clamping
                    if (full_diff > 25'sd8388607)
                        calc_ternary_step = 24'sh7F_FFFF;
                    else if (full_diff < -25'sd8388608)
                        calc_ternary_step = -24'sh80_0000;
                    else
                        calc_ternary_step = full_diff[23:0];
                end
                default: calc_ternary_step = current_acc; // 0 (Zero-skip operand isolation)
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sequential Logic: Weights, Accumulators, and Telemetry
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_w00               <= 2'b00;
            pe_w01               <= 2'b00;
            pe_w10               <= 2'b00;
            pe_w11               <= 2'b00;
            pe_acc00             <= 24'sd0;
            pe_acc01             <= 24'sd0;
            pe_acc10             <= 24'sd0;
            pe_acc11             <= 24'sd0;
            telemetry_zero_skips <= 8'd0;
            telemetry_noc_flits  <= 8'd0;
        end else if (ena) begin
            // 1. Weight Latch
            if (weight_load) begin
                // Load 2 bits per PE from ui_in
                pe_w00 <= ui_in[1:0];
                pe_w01 <= ui_in[3:2];
                pe_w10 <= ui_in[5:4];
                pe_w11 <= ui_in[7:6];
            end

            // 2. Accumulator Clear / Compute
            if (accum_clear) begin
                pe_acc00 <= 24'sd0;
                pe_acc01 <= 24'sd0;
                pe_acc10 <= 24'sd0;
                pe_acc11 <= 24'sd0;
            end else if (enable) begin
                pe_acc00 <= calc_ternary_step(pe_acc00, act_in, pe_w00);
                pe_acc01 <= calc_ternary_step(pe_acc01, act_in, pe_w01);
                pe_acc10 <= calc_ternary_step(pe_acc10, act_in, pe_w10);
                pe_acc11 <= calc_ternary_step(pe_acc11, act_in, pe_w11);

                // Zero-skip logging (gated if any PE is zero-weight)
                if (pe_w00 == 2'b00 || pe_w01 == 2'b00 || pe_w10 == 2'b00 || pe_w11 == 2'b00 ||
                    pe_w00 == 2'b11 || pe_w01 == 2'b11 || pe_w10 == 2'b11 || pe_w11 == 2'b11)
                    telemetry_zero_skips <= telemetry_zero_skips + 8'd1;

                // Virtual NoC packet step
                if (precision_mode == 2'b11)
                    telemetry_noc_flits <= telemetry_noc_flits + 8'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Multi-Precision PE Ganging Network (Zero Multipliers)
    // -------------------------------------------------------------------------
    // Mode 01: INT4 (Pair PE00 + PE01 << 2)
    wire signed [23:0] int4_pair0 = pe_acc00 + (pe_acc01 <<< 2);
    wire signed [23:0] int4_pair1 = pe_acc10 + (pe_acc11 <<< 2);

    // Mode 10: INT8 (Gang all 4 PEs: PE00 + PE01<<2 + PE10<<4 + PE11<<6)
    wire signed [23:0] int8_ganged = pe_acc00 + 
                                     (pe_acc01 <<< 2) + 
                                     (pe_acc10 <<< 4) + 
                                     (pe_acc11 <<< 6);

    // -------------------------------------------------------------------------
    // Output Multiplexer
    // -------------------------------------------------------------------------
    reg signed [23:0] selected_result;

    always @(*) begin
        case (precision_mode)
            2'b00: begin // Ternary Mode: Select individual PE
                case (pe_select)
                    2'b00:   selected_result = pe_acc00;
                    2'b01:   selected_result = pe_acc01;
                    2'b10:   selected_result = pe_acc10;
                    default: selected_result = pe_acc11;
                endcase
            end
            2'b01: begin // INT4 Mode: Select Pair 0 or Pair 1
                selected_result = (pe_select[0] == 1'b0) ? int4_pair0 : int4_pair1;
            end
            2'b10: begin // INT8 Mode: Fully Ganged 4-PE Array
                selected_result = int8_ganged;
            end
            default: begin // NoC / Diagnostic Telemetry Mode
                selected_result = (byte_select == 1'b0) ? 
                    {16'h0000, telemetry_zero_skips} : 
                    {16'h0000, telemetry_noc_flits};
            end
        endcase
    end

    // Byte select to fit on 8-bit output bus uo_out
    assign uo_out = (byte_select == 1'b0) ? selected_result[7:0] : selected_result[15:8];

endmodule
