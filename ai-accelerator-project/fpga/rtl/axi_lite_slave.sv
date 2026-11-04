// ==============================================================================
// Module: axi_lite_slave
// Description: Standard AXI4-Lite Slave Interface for MMIO control, configuration,
//              and status/telemetry readout of the 8x8 Ternary AI Accelerator.
// ==============================================================================

`timescale 1ns / 1ps

module axi_lite_slave #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Interface
    // -------------------------------------------------------------------------
    // Write Address Channel
    input  logic [ADDR_WIDTH-1:0]  s_axil_awaddr,
    input  logic [2:0]             s_axil_awprot,
    input  logic                   s_axil_awvalid,
    output logic                   s_axil_awready,

    // Write Data Channel
    input  logic [DATA_WIDTH-1:0]  s_axil_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] s_axil_wstrb,
    input  logic                   s_axil_wvalid,
    output logic                   s_axil_wready,

    // Write Response Channel
    output logic [1:0]             s_axil_bresp,
    output logic                   s_axil_bvalid,
    input  logic                   s_axil_bready,

    // Read Address Channel
    input  logic [ADDR_WIDTH-1:0]  s_axil_araddr,
    input  logic [2:0]             s_axil_arprot,
    input  logic                   s_axil_arvalid,
    output logic                   s_axil_arready,

    // Read Data Channel
    output logic [DATA_WIDTH-1:0]  s_axil_rdata,
    output logic [1:0]             s_axil_rresp,
    output logic                   s_axil_rvalid,
    input  logic                   s_axil_rready,

    // -------------------------------------------------------------------------
    // Accelerator Core Register Interface
    // -------------------------------------------------------------------------
    output logic                   reg_wr_en,
    output logic [7:0]             reg_addr,
    output logic [31:0]            reg_wdata,
    output logic                   reg_rd_en,
    input  logic [31:0]            reg_rdata,

    // Dedicated interrupt / done pulse to Host CPU (GIC / AXI Interrupt)
    input  logic                   core_done,
    output logic                   irq_done
);

    // Internal AXI4-Lite handshake states
    logic aw_en;
    logic [ADDR_WIDTH-1:0] axi_awaddr;
    logic [ADDR_WIDTH-1:0] axi_araddr;

    // Sticky level interrupt for Zynq GIC (cleared on start or status acknowledgement)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_done <= 1'b0;
        end else begin
            if (core_done) begin
                irq_done <= 1'b1;
            end else if (reg_wr_en && (reg_addr == 8'h00 || reg_addr == 8'h04)) begin
                irq_done <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Write Address & Write Data Channel Handshake
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00; // OKAY
            aw_en          <= 1'b1;
            axi_awaddr     <= '0;
            reg_wr_en      <= 1'b0;
            reg_addr       <= '0;
            reg_wdata      <= '0;
        end else begin
            // Address Write Ready
            if (~s_axil_awready && s_axil_awvalid && s_axil_wvalid && aw_en) begin
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                aw_en          <= 1'b0;
                axi_awaddr     <= s_axil_awaddr;

                // Drive core register write
                reg_wr_en      <= 1'b1;
                reg_addr       <= s_axil_awaddr[7:0];
                reg_wdata      <= s_axil_wdata;
            end else begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                reg_wr_en      <= 1'b0;
            end

            // Write Response Channel
            if (s_axil_awready && s_axil_wready && ~s_axil_bvalid) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00; // OKAY
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
                aw_en         <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read Address & Read Data Channel Handshake
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= '0;
            reg_rd_en      <= 1'b0;
            axi_araddr     <= '0;
        end else begin
            // Address Read Ready
            if (~s_axil_arready && s_axil_arvalid) begin
                s_axil_arready <= 1'b1;
                axi_araddr     <= s_axil_araddr;
                reg_addr       <= s_axil_araddr[7:0];
                reg_rd_en      <= 1'b1;
            end else begin
                s_axil_arready <= 1'b0;
                reg_rd_en      <= 1'b0;
            end

            // Read Data Valid & Latch
            if (s_axil_arready && ~s_axil_rvalid) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00; // OKAY
                s_axil_rdata  <= reg_rdata;
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

endmodule
