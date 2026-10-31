// ==============================================================================
// Module: scratchpad
// Description: Synchronous Dual-Port Static RAM (SRAM) block.
//              - Port A: Write/Refill port from memory controller / DRAM interface.
//              - Port B: Read port streaming operands to Systolic Array.
//              - Parameterizable DATA_WIDTH and ADDR_WIDTH.
// ==============================================================================

`timescale 1ns / 1ps

module scratchpad #(
    parameter int DATA_WIDTH = 16,
    parameter int ADDR_WIDTH = 8,
    parameter int DEPTH      = (1 << ADDR_WIDTH)
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Port A: Write / Refill Interface
    input  logic                  we_a,
    input  logic [ADDR_WIDTH-1:0] addr_a,
    input  logic [DATA_WIDTH-1:0] din_a,

    // Port B: Read Interface
    input  logic                  re_b,
    input  logic [ADDR_WIDTH-1:0] addr_b,
    output logic [DATA_WIDTH-1:0] dout_b
);

    // Memory array
    logic [DATA_WIDTH-1:0] mem [DEPTH-1:0];

    // Port A synchronous write
    always_ff @(posedge clk) begin
        if (we_a) begin
            mem[addr_a] <= din_a;
        end
    end

    // Port B synchronous read
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dout_b <= '0;
        end else if (re_b) begin
            dout_b <= mem[addr_b];
        end
    end

endmodule
