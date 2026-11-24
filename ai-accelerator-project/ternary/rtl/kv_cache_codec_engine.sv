// ==============================================================================
// Module: kv_cache_codec_engine.sv
// Description: Multiplier-Free 1-Cycle Hardware 4-Bit Packed KV-Cache Compression
//              and Decompression Engine for 4x On-Chip Context Expansion.
//
// Modes:
// 1. Pack Mode (mode_unpack == 0):
//    - Ingests four 8-bit activations: {x3[7:0], x2[7:0], x1[7:0], x0[7:0]} in rs1.
//    - Quantizes each element into signed 4-bit nibbles: q_i = clamp(x_i >>> shift, -8, 7).
//    - Emits packed 16-bit word in rd[15:0]: {q3[3:0], q2[3:0], q1[3:0], q0[3:0]}.
// 2. Unpack Mode (mode_unpack == 1):
//    - Ingests packed 16-bit word {q3, q2, q1, q0} in rs1[15:0].
//    - Dequantizes each nibble back to signed 8-bit: x_i = sign_extend(q_i) <<< shift.
//    - Emits four unpacked 8-bit activations {x3, x2, x1, x0} in rd[31:0].
//
// Key Specifications:
// - 1-Cycle Combinational Latency (500 MHz signoff).
// - Zero Hardware Multipliers: Evaluated purely via barrel shifters and clamp multiplexers.
// ==============================================================================

`timescale 1ns / 1ps

module kv_cache_codec_engine (
    // rs1: Input Data (Pack: 4x 8-bit activations; Unpack: packed 16-bit nibbles)
    input  logic signed [31:0] data_in,

    // rs2: Control & Shift Configuration: {shift_amount[3:0], reserved, mode_unpack}
    input  logic        [31:0] config_in,

    // rd: Codec Output
    output logic signed [31:0] data_out
);

    wire        mode_unpack = config_in[0];
    wire [2:0]  shift_amt   = config_in[4:2]; // Shift amount in 0..7

    // -------------------------------------------------------------------------
    // Pack Path: Four 8-bit activations -> Four 4-bit signed nibbles
    // -------------------------------------------------------------------------
    wire signed [7:0] x0 = data_in[7:0];
    wire signed [7:0] x1 = data_in[15:8];
    wire signed [7:0] x2 = data_in[23:16];
    wire signed [7:0] x3 = data_in[31:24];

    function automatic logic signed [3:0] quantize_clamp(input logic signed [7:0] val, input logic [2:0] sh);
        logic signed [7:0] scaled;
        begin
            scaled = val >>> sh;
            if (scaled > 8'sd7) begin
                quantize_clamp = 4'sd7;
            end else if (scaled < -8'sd8) begin
                quantize_clamp = -4'sd8;
            end else begin
                quantize_clamp = scaled[3:0];
            end
        end
    endfunction

    wire signed [3:0] q0 = quantize_clamp(x0, shift_amt);
    wire signed [3:0] q1 = quantize_clamp(x1, shift_amt);
    wire signed [3:0] q2 = quantize_clamp(x2, shift_amt);
    wire signed [3:0] q3 = quantize_clamp(x3, shift_amt);

    wire [31:0] pack_result = {16'h0000, q3, q2, q1, q0};

    // -------------------------------------------------------------------------
    // Unpack Path: Four 4-bit nibbles -> Four 8-bit activations
    // -------------------------------------------------------------------------
    wire signed [3:0] uq0 = data_in[3:0];
    wire signed [3:0] uq1 = data_in[7:4];
    wire signed [3:0] uq2 = data_in[11:8];
    wire signed [3:0] uq3 = data_in[15:12];

    wire signed [7:0] ux0 = 8'(signed'({{4{uq0[3]}}, uq0}) <<< shift_amt);
    wire signed [7:0] ux1 = 8'(signed'({{4{uq1[3]}}, uq1}) <<< shift_amt);
    wire signed [7:0] ux2 = 8'(signed'({{4{uq2[3]}}, uq2}) <<< shift_amt);
    wire signed [7:0] ux3 = 8'(signed'({{4{uq3[3]}}, uq3}) <<< shift_amt);

    wire [31:0] unpack_result = {ux3, ux2, ux1, ux0};

    // Output Multiplexer
    assign data_out = mode_unpack ? unpack_result : pack_result;

endmodule
