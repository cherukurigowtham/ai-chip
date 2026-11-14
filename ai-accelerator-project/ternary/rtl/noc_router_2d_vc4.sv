// ==============================================================================
// Module: noc_router_2d_vc4.sv
// Description: Gen-2 5-Port 2D Mesh NoC Router with 4 Virtual Channels (VCs).
//              Eliminates Head-of-Line (HOL) blocking across multi-die clusters.
//
// Virtual Channel Priority Classes:
//   - VC 0 (2'b00): HIGHEST PRIORITY - Real-Time KV Cache Streaming (Latency-Critical)
//   - VC 1 (2'b01): HIGH PRIORITY    - Speculative Decoding Rollback & Draft Tokens
//   - VC 2 (2'b10): MEDIUM PRIORITY  - Bulk Weight Transfers from Octal-SPI CS-DMA
//   - VC 3 (2'b11): LOW PRIORITY     - Telemetry, Profiling & MMIO Configuration
// ==============================================================================

`timescale 1ns / 1ps

module noc_router_2d_vc4 #(
    parameter int NODE_X      = 0,
    parameter int NODE_Y      = 0,
    parameter int FLIT_WIDTH  = 32,
    parameter int VC_COUNT    = 4,
    parameter int FIFO_DEPTH  = 4
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // 5 Input Ports [4:0] = {WEST, SOUTH, EAST, NORTH, LOCAL}
    input  logic [4:0]             in_flit_valid,
    input  logic [(5*FLIT_WIDTH)-1:0] in_flit_data_packed,
    output logic [4:0]             in_flit_ready,

    // 5 Output Ports
    output logic [4:0]             out_flit_valid,
    output logic [(5*FLIT_WIDTH)-1:0] out_flit_data_packed,
    input  logic [4:0]             out_flit_ready,

    // QoS Telemetry
    output logic [31:0]            telemetry_vc0_flits,
    output logic [31:0]            telemetry_total_flits
);

    localparam int PORT_LOCAL = 0;
    localparam int PORT_NORTH = 1;
    localparam int PORT_EAST  = 2;
    localparam int PORT_SOUTH = 3;
    localparam int PORT_WEST  = 4;

    logic [FLIT_WIDTH-1:0] in_flits [0:4];
    logic [FLIT_WIDTH-1:0] out_flits [0:4];

    genvar p;
    generate
        for (p = 0; p < 5; p++) begin : gen_port_unpack
            assign in_flits[p] = in_flit_data_packed[p*FLIT_WIDTH +: FLIT_WIDTH];
            assign out_flit_data_packed[p*FLIT_WIDTH +: FLIT_WIDTH] = out_flits[p];
        end
    endgenerate

    // 4 Virtual Channel FIFOs per port: [port][vc][depth]
    logic [FLIT_WIDTH-1:0] vc_mem [0:4][0:3][0:FIFO_DEPTH-1];
    logic [2:0]            vc_wr_ptr [0:4][0:3];
    logic [2:0]            vc_rd_ptr [0:4][0:3];
    logic [2:0]            vc_count  [0:4][0:3];

    // Readyness
    logic [1:0] in_vc_target [0:4];
    generate
        for (p = 0; p < 5; p++) begin : gen_ready
            assign in_vc_target[p] = in_flits[p][25:24];
            assign in_flit_ready[p] = (vc_count[p][in_vc_target[p]] < FIFO_DEPTH);
        end
    endgenerate

    // Head flit per port chosen via STRICT PRIORITY (VC0 > VC1 > VC2 > VC3)
    logic [FLIT_WIDTH-1:0] port_head_flit [0:4];
    logic [1:0]            port_head_vc   [0:4];
    logic                  port_has_flit  [0:4];

    always_comb begin
        for (int ip = 0; ip < 5; ip++) begin
            if (vc_count[ip][0] > 0) begin
                port_head_flit[ip] = vc_mem[ip][0][vc_rd_ptr[ip][0]];
                port_head_vc[ip]   = 2'd0;
                port_has_flit[ip]  = 1'b1;
            end else if (vc_count[ip][1] > 0) begin
                port_head_flit[ip] = vc_mem[ip][1][vc_rd_ptr[ip][1]];
                port_head_vc[ip]   = 2'd1;
                port_has_flit[ip]  = 1'b1;
            end else if (vc_count[ip][2] > 0) begin
                port_head_flit[ip] = vc_mem[ip][2][vc_rd_ptr[ip][2]];
                port_head_vc[ip]   = 2'd2;
                port_has_flit[ip]  = 1'b1;
            end else if (vc_count[ip][3] > 0) begin
                port_head_flit[ip] = vc_mem[ip][3][vc_rd_ptr[ip][3]];
                port_head_vc[ip]   = 2'd3;
                port_has_flit[ip]  = 1'b1;
            end else begin
                port_head_flit[ip] = '0;
                port_head_vc[ip]   = 2'd0;
                port_has_flit[ip]  = 1'b0;
            end
        end
    end

    // X-Y Dimension Order Routing
    wire [1:0] dest_x_0 = port_head_flit[0][29:28]; wire [1:0] dest_y_0 = port_head_flit[0][27:26];
    wire [1:0] dest_x_1 = port_head_flit[1][29:28]; wire [1:0] dest_y_1 = port_head_flit[1][27:26];
    wire [1:0] dest_x_2 = port_head_flit[2][29:28]; wire [1:0] dest_y_2 = port_head_flit[2][27:26];
    wire [1:0] dest_x_3 = port_head_flit[3][29:28]; wire [1:0] dest_y_3 = port_head_flit[3][27:26];
    wire [1:0] dest_x_4 = port_head_flit[4][29:28]; wire [1:0] dest_y_4 = port_head_flit[4][27:26];

    wire req_local_0 = port_has_flit[0] && (dest_x_0 == NODE_X[1:0]) && (dest_y_0 == NODE_Y[1:0]);
    wire req_local_1 = port_has_flit[1] && (dest_x_1 == NODE_X[1:0]) && (dest_y_1 == NODE_Y[1:0]);
    wire req_local_2 = port_has_flit[2] && (dest_x_2 == NODE_X[1:0]) && (dest_y_2 == NODE_Y[1:0]);
    wire req_local_3 = port_has_flit[3] && (dest_x_3 == NODE_X[1:0]) && (dest_y_3 == NODE_Y[1:0]);
    wire req_local_4 = port_has_flit[4] && (dest_x_4 == NODE_X[1:0]) && (dest_y_4 == NODE_Y[1:0]);

    wire req_east_0  = port_has_flit[0] && (dest_x_0 > NODE_X[1:0]);
    wire req_east_1  = port_has_flit[1] && (dest_x_1 > NODE_X[1:0]);
    wire req_east_2  = port_has_flit[2] && (dest_x_2 > NODE_X[1:0]);
    wire req_east_3  = port_has_flit[3] && (dest_x_3 > NODE_X[1:0]);
    wire req_east_4  = port_has_flit[4] && (dest_x_4 > NODE_X[1:0]);

    wire req_west_0  = port_has_flit[0] && (dest_x_0 < NODE_X[1:0]);
    wire req_west_1  = port_has_flit[1] && (dest_x_1 < NODE_X[1:0]);
    wire req_west_2  = port_has_flit[2] && (dest_x_2 < NODE_X[1:0]);
    wire req_west_3  = port_has_flit[3] && (dest_x_3 < NODE_X[1:0]);
    wire req_west_4  = port_has_flit[4] && (dest_x_4 < NODE_X[1:0]);

    wire req_south_0 = port_has_flit[0] && (dest_x_0 == NODE_X[1:0]) && (dest_y_0 > NODE_Y[1:0]);
    wire req_south_1 = port_has_flit[1] && (dest_x_1 == NODE_X[1:0]) && (dest_y_1 > NODE_Y[1:0]);
    wire req_south_2 = port_has_flit[2] && (dest_x_2 == NODE_X[1:0]) && (dest_y_2 > NODE_Y[1:0]);
    wire req_south_3 = port_has_flit[3] && (dest_x_3 == NODE_X[1:0]) && (dest_y_3 > NODE_Y[1:0]);
    wire req_south_4 = port_has_flit[4] && (dest_x_4 == NODE_X[1:0]) && (dest_y_4 > NODE_Y[1:0]);

    wire req_north_0 = port_has_flit[0] && (dest_x_0 == NODE_X[1:0]) && (dest_y_0 < NODE_Y[1:0]);
    wire req_north_1 = port_has_flit[1] && (dest_x_1 == NODE_X[1:0]) && (dest_y_1 < NODE_Y[1:0]);
    wire req_north_2 = port_has_flit[2] && (dest_x_2 == NODE_X[1:0]) && (dest_y_2 < NODE_Y[1:0]);
    wire req_north_3 = port_has_flit[3] && (dest_x_3 == NODE_X[1:0]) && (dest_y_3 < NODE_Y[1:0]);
    wire req_north_4 = port_has_flit[4] && (dest_x_4 == NODE_X[1:0]) && (dest_y_4 < NODE_Y[1:0]);

    // Crossbar Arbitration & Pop Request
    logic [4:0] pop_port;
    logic [1:0] pop_vc [0:4];

    wire ready_local = out_flit_ready[0];
    wire ready_north = out_flit_ready[1];
    wire ready_east  = out_flit_ready[2];
    wire ready_south = out_flit_ready[3];
    wire ready_west  = out_flit_ready[4];

    always_comb begin
        pop_port = 5'b00000;
        for (int i = 0; i < 5; i++) pop_vc[i] = port_head_vc[i];

        // --- LOCAL Port (0) ---
        out_flit_valid[0] = 1'b0;
        out_flits[0]      = '0;
        if (ready_local) begin
            if (req_local_0)      begin out_flit_valid[0] = 1'b1; out_flits[0] = port_head_flit[0]; pop_port[0] = 1'b1; end
            else if (req_local_1) begin out_flit_valid[0] = 1'b1; out_flits[0] = port_head_flit[1]; pop_port[1] = 1'b1; end
            else if (req_local_2) begin out_flit_valid[0] = 1'b1; out_flits[0] = port_head_flit[2]; pop_port[2] = 1'b1; end
            else if (req_local_3) begin out_flit_valid[0] = 1'b1; out_flits[0] = port_head_flit[3]; pop_port[3] = 1'b1; end
            else if (req_local_4) begin out_flit_valid[0] = 1'b1; out_flits[0] = port_head_flit[4]; pop_port[4] = 1'b1; end
        end

        // --- NORTH Port (1) ---
        out_flit_valid[1] = 1'b0;
        out_flits[1]      = '0;
        if (ready_north) begin
            if (req_north_0)      begin out_flit_valid[1] = 1'b1; out_flits[1] = port_head_flit[0]; pop_port[0] = 1'b1; end
            else if (req_north_1) begin out_flit_valid[1] = 1'b1; out_flits[1] = port_head_flit[1]; pop_port[1] = 1'b1; end
            else if (req_north_2) begin out_flit_valid[1] = 1'b1; out_flits[1] = port_head_flit[2]; pop_port[2] = 1'b1; end
            else if (req_north_3) begin out_flit_valid[1] = 1'b1; out_flits[1] = port_head_flit[3]; pop_port[3] = 1'b1; end
            else if (req_north_4) begin out_flit_valid[1] = 1'b1; out_flits[1] = port_head_flit[4]; pop_port[4] = 1'b1; end
        end

        // --- EAST Port (2) ---
        out_flit_valid[2] = 1'b0;
        out_flits[2]      = '0;
        if (ready_east) begin
            if (req_east_0)      begin out_flit_valid[2] = 1'b1; out_flits[2] = port_head_flit[0]; pop_port[0] = 1'b1; end
            else if (req_east_1) begin out_flit_valid[2] = 1'b1; out_flits[2] = port_head_flit[1]; pop_port[1] = 1'b1; end
            else if (req_east_2) begin out_flit_valid[2] = 1'b1; out_flits[2] = port_head_flit[2]; pop_port[2] = 1'b1; end
            else if (req_east_3) begin out_flit_valid[2] = 1'b1; out_flits[2] = port_head_flit[3]; pop_port[3] = 1'b1; end
            else if (req_east_4) begin out_flit_valid[2] = 1'b1; out_flits[2] = port_head_flit[4]; pop_port[4] = 1'b1; end
        end

        // --- SOUTH Port (3) ---
        out_flit_valid[3] = 1'b0;
        out_flits[3]      = '0;
        if (ready_south) begin
            if (req_south_0)      begin out_flit_valid[3] = 1'b1; out_flits[3] = port_head_flit[0]; pop_port[0] = 1'b1; end
            else if (req_south_1) begin out_flit_valid[3] = 1'b1; out_flits[3] = port_head_flit[1]; pop_port[1] = 1'b1; end
            else if (req_south_2) begin out_flit_valid[3] = 1'b1; out_flits[3] = port_head_flit[2]; pop_port[2] = 1'b1; end
            else if (req_south_3) begin out_flit_valid[3] = 1'b1; out_flits[3] = port_head_flit[3]; pop_port[3] = 1'b1; end
            else if (req_south_4) begin out_flit_valid[3] = 1'b1; out_flits[3] = port_head_flit[4]; pop_port[4] = 1'b1; end
        end

        // --- WEST Port (4) ---
        out_flit_valid[4] = 1'b0;
        out_flits[4]      = '0;
        if (ready_west) begin
            if (req_west_0)      begin out_flit_valid[4] = 1'b1; out_flits[4] = port_head_flit[0]; pop_port[0] = 1'b1; end
            else if (req_west_1) begin out_flit_valid[4] = 1'b1; out_flits[4] = port_head_flit[1]; pop_port[1] = 1'b1; end
            else if (req_west_2) begin out_flit_valid[4] = 1'b1; out_flits[4] = port_head_flit[2]; pop_port[2] = 1'b1; end
            else if (req_west_3) begin out_flit_valid[4] = 1'b1; out_flits[4] = port_head_flit[3]; pop_port[3] = 1'b1; end
            else if (req_west_4) begin out_flit_valid[4] = 1'b1; out_flits[4] = port_head_flit[4]; pop_port[4] = 1'b1; end
        end
    end

    // Sequential Queue State Management
    logic [31:0] cnt_vc0, cnt_tot;
    assign telemetry_vc0_flits   = cnt_vc0;
    assign telemetry_total_flits = cnt_tot;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_vc0 <= '0;
            cnt_tot <= '0;
            for (int ip = 0; ip < 5; ip++) begin
                for (int vc = 0; vc < 4; vc++) begin
                    vc_wr_ptr[ip][vc] <= '0;
                    vc_rd_ptr[ip][vc] <= '0;
                    vc_count[ip][vc]  <= '0;
                    for (int d = 0; d < FIFO_DEPTH; d++) begin
                        vc_mem[ip][vc][d] <= '0;
                    end
                end
            end
        end else begin
            for (int ip = 0; ip < 5; ip++) begin
                // Ingress Push
                if (in_flit_valid[ip] && (vc_count[ip][in_vc_target[ip]] < FIFO_DEPTH)) begin
                    vc_mem[ip][in_vc_target[ip]][vc_wr_ptr[ip][in_vc_target[ip]]] <= in_flits[ip];
                    vc_wr_ptr[ip][in_vc_target[ip]] <= (vc_wr_ptr[ip][in_vc_target[ip]] + 1'b1) % FIFO_DEPTH;
                end

                // Egress Pop
                if (pop_port[ip]) begin
                    vc_rd_ptr[ip][pop_vc[ip]] <= (vc_rd_ptr[ip][pop_vc[ip]] + 1'b1) % FIFO_DEPTH;
                    cnt_tot <= cnt_tot + 1'b1;
                    if (pop_vc[ip] == 2'd0) cnt_vc0 <= cnt_vc0 + 1'b1;
                end

                // Count update
                for (int vc = 0; vc < 4; vc++) begin
                    logic is_push;
                    logic is_pop;
                    is_push = in_flit_valid[ip] && (in_vc_target[ip] == vc[1:0]) && (vc_count[ip][vc] < FIFO_DEPTH);
                    is_pop  = pop_port[ip] && (pop_vc[ip] == vc[1:0]);

                    if (is_push && !is_pop) begin
                        vc_count[ip][vc] <= vc_count[ip][vc] + 1'b1;
                    end else if (!is_push && is_pop) begin
                        vc_count[ip][vc] <= vc_count[ip][vc] - 1'b1;
                    end
                end
            end
        end
    end

endmodule
