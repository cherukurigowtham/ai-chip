// ==============================================================================
// Module: bitnet_x16_systolic_top.sv
// Description: BitNet-X16: 16-Core (4x4) 2D Spatial Systolic Tensor Engine.
//              - Multiplier-free ternary computing: W in {-1, 0, +1}
//              - 16 Processing Elements arranged in a 4x4 2D spatial mesh
//              - Dual-Mode execution:
//                  * Weight-Stationary (WS, mode_os = 0) with 0..3 cycle row skew
//                    and 3..0 cycle column deskewing.
//                  * Output-Stationary (OS, mode_os = 1) with stationary PEs
//                    and vertical partial-sum draining.
//              - Distributed Ping-Pong Shadow Weight Buffers in every PE
//                (zero-stall weight preloading while computing).
//              - Dynamic Operand Isolation & Dual-Sided Zero-Skipping (W=0 or A=0).
//              - Integrated 16-Core Real-Time Energy Telemetry Counter.
//              - Performance: 16 MACs/cycle = 1.60 GOPS @ 50 MHz (sub-30 mW).
// ==============================================================================

`timescale 1ns / 1ps

module bitnet_x16_systolic_top #(
    parameter int DATA_WIDTH   = 16, // Activation width (16-bit signed)
    parameter int ACCUM_WIDTH  = 32, // Accumulator width (32-bit signed)
    parameter int WEIGHT_WIDTH = 2,  // Ternary weight width (2-bit encoded)
    parameter int ROWS         = 4,  // 4 Rows
    parameter int COLS         = 4   // 4 Columns
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               enable,

    // Execution Mode Controls
    input  logic                               mode_os,         // 0: WS, 1: OS
    input  logic                               weight_load,     // WS: Latch stationary weights into shadow/active bank
    input  logic                               weight_bank_sel, // Ping-Pong select: 0 = Bank A, 1 = Bank B
    input  logic                               double_buf_en,   // 0: Direct single buffer, 1: Double-buffering enabled
    input  logic                               accum_clear,     // OS: Synchronous clear of internal accumulators
    input  logic                               drain_en,        // OS: Vertically drain accumulators through mesh

    // Streaming Handshakes
    input  logic                               in_valid,        // High when activation inputs are valid
    output logic                               out_valid,       // High when deskewed outputs are valid

    // 4-Row Activation Stream Inputs (4 x 16-bit = 64 bits)
    input  logic signed [(ROWS*DATA_WIDTH)-1:0]       act_in_flat,

    // 4-Column Streaming Weights (OS Mode: 4 x 2-bit = 8 bits)
    input  logic        [(COLS*WEIGHT_WIDTH)-1:0]     weight_in_col_flat,

    // 16-Core Stationary Weight Matrix (WS Mode: 16 x 2-bit = 32 bits)
    input  logic        [(ROWS*COLS*WEIGHT_WIDTH)-1:0]weight_in_tile_flat,

    // 4-Column Deskewed Partial-Sum Outputs (WS Mode: 4 x 32-bit = 128 bits)
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      psum_out_deskewed_flat,

    // 4-Column Drain Outputs (OS Mode: 4 x 32-bit = 128 bits)
    output logic signed [(COLS*ACCUM_WIDTH)-1:0]      drain_out_flat,

    // Telemetry & Diagnostic Interface
    output logic [(ROWS*COLS)-1:0]                    zero_skip_mask,      // Active-high per-PE zero skip flag
    output logic [31:0]                               total_zero_skips     // Real-time cumulative zero-skip counter
);

    // -------------------------------------------------------------------------
    // Unpack Flat Inputs into Structured Arrays
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]   act_raw [0:ROWS-1];
    logic        [WEIGHT_WIDTH-1:0] weight_col_raw [0:COLS-1];
    logic        [WEIGHT_WIDTH-1:0] weight_tile_matrix [0:ROWS-1][0:COLS-1];

    always_comb begin
        for (int r_i = 0; r_i < ROWS; r_i++) begin
            act_raw[r_i] = act_in_flat[r_i*DATA_WIDTH +: DATA_WIDTH];
        end
        for (int c_i = 0; c_i < COLS; c_i++) begin
            weight_col_raw[c_i] = weight_in_col_flat[c_i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
        end
        for (int r_i = 0; r_i < ROWS; r_i++) begin
            for (int c_i = 0; c_i < COLS; c_i++) begin
                weight_tile_matrix[r_i][c_i] =
                    weight_in_tile_flat[(r_i*COLS + c_i)*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Row Skewing Network (Row r is delayed by r cycles)
    // Row 0: 0 cycles delay
    // Row 1: 1 cycle delay
    // Row 2: 2 cycles delay
    // Row 3: 3 cycles delay
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] act_skewed [0:ROWS-1];
    genvar r_skew;
    generate
        for (r_skew = 0; r_skew < ROWS; r_skew++) begin : gen_act_skew
            if (r_skew == 0) begin : gen_row0
                assign act_skewed[0] = act_raw[0];
            end else begin : gen_row_pipe
                logic signed [DATA_WIDTH-1:0] pipe [0:r_skew-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < r_skew; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= act_raw[r_skew];
                        for (int k = 1; k < r_skew; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign act_skewed[r_skew] = pipe[r_skew-1];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Column Skewing Network for OS Streaming Weights (Col c delayed by c cycles)
    // Col 0: 0 cycles delay
    // Col 1: 1 cycle delay
    // Col 2: 2 cycles delay
    // Col 3: 3 cycles delay
    // -------------------------------------------------------------------------
    logic [WEIGHT_WIDTH-1:0] weight_skewed [0:COLS-1];
    genvar c_skew;
    generate
        for (c_skew = 0; c_skew < COLS; c_skew++) begin : gen_w_skew
            if (c_skew == 0) begin : gen_col0
                assign weight_skewed[0] = weight_col_raw[0];
            end else begin : gen_col_pipe
                logic [WEIGHT_WIDTH-1:0] pipe [0:c_skew-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < c_skew; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= weight_col_raw[c_skew];
                        for (int k = 1; k < c_skew; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign weight_skewed[c_skew] = pipe[c_skew-1];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4x4 2D Spatial Mesh Interconnect
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]   act_mesh [0:ROWS-1][0:COLS];
    logic        [WEIGHT_WIDTH-1:0] weight_mesh [0:ROWS][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0]  psum_mesh [0:ROWS][0:COLS-1];
    logic                           skip_matrix [0:ROWS-1][0:COLS-1];

    genvar r_idx, c_idx;
    generate
        for (r_idx = 0; r_idx < ROWS; r_idx++) begin : gen_left_boundary
            assign act_mesh[r_idx][0] = act_skewed[r_idx];
        end
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_top_boundary
            assign weight_mesh[0][c_idx] = weight_skewed[c_idx];
            assign psum_mesh[0][c_idx]   = '0;
        end
    endgenerate

    // Instantiate 16 Processing Elements (4x4 Array)
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_pe_row
            for (c = 0; c < COLS; c++) begin : gen_pe_col
                pe_ternary #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH),
                    .WEIGHT_WIDTH(WEIGHT_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .mode_os(mode_os),
                    .enable(enable),
                    .weight_load(weight_load),
                    .weight_bank_sel(weight_bank_sel),
                    .double_buf_en(double_buf_en),
                    .accum_clear(accum_clear),
                    .drain_en(drain_en),
                    .act_in(act_mesh[r][c]),
                    .weight_in(weight_mesh[r][c]),
                    .weight_tile_in(weight_tile_matrix[r][c]),
                    .psum_in(psum_mesh[r][c]),
                    .act_out(act_mesh[r][c+1]),
                    .weight_out(weight_mesh[r+1][c]),
                    .psum_out(psum_mesh[r+1][c]),
                    .zero_skipped(skip_matrix[r][c])
                );
                assign zero_skip_mask[r*COLS + c] = skip_matrix[r][c];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // WS Output Deskewing Network (Aligns all 4 columns to emerge on same cycle)
    // Delay = (COLS - 1 - c)
    // Col 0: 3 cycles delay
    // Col 1: 2 cycles delay
    // Col 2: 1 cycle delay
    // Col 3: 0 cycles delay
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH-1:0] ws_deskewed [0:COLS-1];
    genvar c_deskew;
    generate
        for (c_deskew = 0; c_deskew < COLS; c_deskew++) begin : gen_col_deskew
            localparam int DELAY = COLS - 1 - c_deskew;
            if (DELAY == 0) begin : gen_deskew_zero
                assign ws_deskewed[c_deskew] = psum_mesh[ROWS][c_deskew];
            end else begin : gen_deskew_pipe
                logic signed [ACCUM_WIDTH-1:0] pipe [0:DELAY-1];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int k = 0; k < DELAY; k++) pipe[k] <= '0;
                    end else if (enable) begin
                        pipe[0] <= psum_mesh[ROWS][c_deskew];
                        for (int k = 1; k < DELAY; k++) begin
                            pipe[k] <= pipe[k-1];
                        end
                    end
                end
                assign ws_deskewed[c_deskew] = pipe[DELAY-1];
            end
        end
    endgenerate

    // Flatten Deskewed and Drain Outputs
    generate
        for (c_idx = 0; c_idx < COLS; c_idx++) begin : gen_flatten_outputs
            assign psum_out_deskewed_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = ws_deskewed[c_idx];
            assign drain_out_flat[c_idx*ACCUM_WIDTH +: ACCUM_WIDTH]         = psum_mesh[ROWS][c_idx];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Valid Propagation Pipeline (Latency = ROWS + COLS = 8 cycles in WS mode)
    // -------------------------------------------------------------------------
    localparam int TOTAL_LATENCY = (ROWS + COLS); // 4 + 4 = 8 cycles
    logic [TOTAL_LATENCY-1:0] valid_pipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
        end else if (enable) begin
            valid_pipe <= {valid_pipe[TOTAL_LATENCY-2:0], in_valid};
        end
    end
    assign out_valid = valid_pipe[TOTAL_LATENCY-1];

    // -------------------------------------------------------------------------
    // Real-Time Cumulative Zero-Skip Energy Telemetry Profiler
    // -------------------------------------------------------------------------
    // Adder tree counting active zero-skips across all 16 PEs in current cycle
    logic [4:0] current_cycle_zero_skips; // Max 16
    always_comb begin
        current_cycle_zero_skips = 5'd0;
        for (int i = 0; i < ROWS*COLS; i++) begin
            if (zero_skip_mask[i]) begin
                current_cycle_zero_skips = current_cycle_zero_skips + 5'd1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_zero_skips <= 32'd0;
        end else if (enable && in_valid) begin
            total_zero_skips <= total_zero_skips + {27'd0, current_cycle_zero_skips};
        end
    end

endmodule
