// ==============================================================================
// Module: clkgate_x1.sv
// Description: Standard Integrated Clock Gating (ICG) Cell.
//              Glitch-free, hazard-free clock gating element for high-frequency ASICs.
//
// Microarchitecture:
//   - Level-sensitive latch transparent when clk_in is LOW.
//   - When clk_in transitions HIGH, the latch captures enable and holds it static.
//   - The AND gate is driven by clk_in and the static en_latch, guaranteeing
//     ZERO clock glitches, runt pulses, or timing hazard transitions.
//   - test_mode: Forces clock gate open during ATPG manufacturing scan testing.
// ==============================================================================

`timescale 1ns / 1ps

module clkgate_x1 (
    input  logic clk_in,
    input  logic enable,
    input  logic test_mode,
    output logic clk_out
);

`ifdef SKY130_PHYSICAL
    // SkyWater 130nm High-Density Standard Cell Primitive
    sky130_fd_sc_hd__dlclkp_1 u_sky130_icg (
        .CLK(clk_in),
        .GATE(enable | test_mode),
        .GCLK(clk_out)
    );
`else
    // Silicon-accurate latch-based behavioral model
    logic en_latch;

    always_latch begin
        if (!clk_in) begin
            en_latch <= enable | test_mode;
        end
    end

    assign clk_out = clk_in && en_latch;
`endif

endmodule