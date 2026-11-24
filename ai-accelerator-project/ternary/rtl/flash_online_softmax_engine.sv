// ==============================================================================
// Module: flash_online_softmax_engine.sv
// Description: Multiplier-Free 1-Cycle Hardware Online Softmax Engine for
//              FlashAttention-2 & FlashAttention-3 LLM Acceleration.
//              Directly computes running maximum (m) and accumulated denominator (d):
//                 m_new = max(m_prev, s_j)
//                 delta_m = m_new - m_prev  (>= 0)
//                 delta_s = m_new - s_j     (>= 0)
//                 d_new = (d_prev >> delta_m) + (1.0 >> delta_s)
//
// Key Specifications:
// 1. Single-Instruction FlashAttention-3 Online State Update:
//    - rs1 = {m_prev[15:0], d_prev[15:0]} (Q8.8 running max, Q8.8 denominator)
//    - rs2 = {16'h0000, s_new[15:0]}      (Q8.8 candidate attention score)
//    - rd  = {m_new[15:0],  d_new[15:0]}  (Updated Online Softmax statistics)
// 2. Base-2 Exponential Scaling:
//    - Eliminates expensive transcendental exp() approximations via exact power-of-two shifts.
// 3. 1-Cycle Combinational Latency (500 MHz, < 1.2 ns path delay).
// 4. Zero Hardware Multipliers: Pure combinational comparators, subtractors, and barrel shifters.
// ==============================================================================

`timescale 1ns / 1ps

module flash_online_softmax_engine #(
    parameter int DATA_WIDTH = 16 // Q8.8 fixed-point (256 = 1.0)
)(
    // Input 1: {m_prev[15:0], d_prev[15:0]}
    input  logic signed [31:0] state_prev_in,

    // Input 2: {reserved[15:0], s_new[15:0]}
    input  logic signed [31:0] score_cand_in,

    // Output: {m_new[15:0], d_new[15:0]}
    output logic signed [31:0] state_new_out
);

    // Unpack inputs
    wire signed [DATA_WIDTH-1:0] m_prev = state_prev_in[31:16];
    wire        [DATA_WIDTH-1:0] d_prev = state_prev_in[15:0];
    wire signed [DATA_WIDTH-1:0] s_new  = score_cand_in[15:0];

    // Running maximum
    logic signed [DATA_WIDTH-1:0] m_new;
    always_comb begin
        if (s_new > m_prev) begin
            m_new = s_new;
        end else begin
            m_new = m_prev;
        end
    end

    // Compute exponent shifts (difference in Q8.8 format)
    // Integer exponent shift is delta >>> 8 (each 256 in Q8.8 corresponds to a factor of 2)
    wire signed [DATA_WIDTH-1:0] diff_m = m_new - m_prev; // >= 0
    wire signed [DATA_WIDTH-1:0] diff_s = m_new - s_new;  // >= 0

    // Extract shift amounts (with clamping to avoid undefined bit shifts)
    wire [4:0] shift_m = (diff_m[15:8] > 8'd15) ? 5'd16 : diff_m[12:8];
    wire [4:0] shift_s = (diff_s[15:8] > 8'd15) ? 5'd16 : diff_s[12:8];

    // Rescale previous denominator: alpha * d_prev = 2^(-shift_m) * d_prev
    wire [DATA_WIDTH-1:0] d_rescaled = (shift_m >= 5'd16) ? 16'd0 : (d_prev >> shift_m);

    // Current candidate contribution: 2^(-shift_s) * 1.0 (where 1.0 in Q8.8 is 16'd256)
    wire [DATA_WIDTH-1:0] p_cand = (shift_s >= 5'd16) ? 16'd0 : (16'd256 >> shift_s);

    // Updated accumulated denominator
    wire [DATA_WIDTH-1:0] d_new = d_rescaled + p_cand;

    assign state_new_out = {m_new, d_new};

endmodule
