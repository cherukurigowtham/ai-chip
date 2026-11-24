// ==============================================================================
// Module: riscv_xbitnet_core.sv
// Description: Embedded 32-Bit RISC-V Processor Core with Native Xbitnet Matrix
//              Tensor ISA Extension. Transforms the BitNet accelerator into a
//              Turing-complete Universal Micro-Tensor AI Processor.
//
// Native Xbitnet Custom Instructions (Opcode CUSTOM_0 = 7'b0001011):
// 1. vternary.gemv rd, rs1, rs2 (funct7=7'b0000001, funct3=3'b000):
//    - Triggers hardware 64-PE ternary matrix multiplication.
// 2. vsparse.decomp rd, rs1, rs2 (funct7=7'b0000010, funct3=3'b001):
//    - Reconstructs 2:4 structured sparsity and computes 1-cycle dot product into rd.
// 3. vspec.draft rd, rs1, rs2 (funct7=7'b0000011, funct3=3'b010):
//    - Triggers Medusa K=4 speculative draft token generation engine in 2 cycles.
// 4. vkv.rollback rd, rs1 (funct7=7'b0000100, funct3=3'b011):
//    - Executes 1-cycle instantaneous KV cache rewind to seq_len in rs1.
// 5. vfp8.gemm rd, rs1, rs2 (funct7=7'b0000101, funct3=3'b100):
//    - Executes fused FP8 vector operation for RMSNorm and Softmax scores.
// ==============================================================================

`timescale 1ns / 1ps

module riscv_xbitnet_core #(
    parameter int PC_RESET = 32'h0000_0000
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Instruction Memory Interface
    output logic [31:0]            imem_addr,
    input  logic [31:0]            imem_rdata,

    // Data Memory / SRAM Interface
    output logic                   dmem_en,
    output logic                   dmem_we,
    output logic [31:0]            dmem_addr,
    output logic [31:0]            dmem_wdata,
    input  logic [31:0]            dmem_rdata,

    // Dedicated Hardware Xbitnet Coprocessor Interface
    // 1. 2:4 Structured Sparsity Unit
    output logic [1:0]             xbit_sparse_w0,
    output logic [1:0]             xbit_sparse_w1,
    output logic [2:0]             xbit_sparse_pattern,
    output logic [31:0]            xbit_sparse_act_in,
    input  logic signed [31:0]     xbit_sparse_dot_out,

    // 2. Speculative Decoding Co-Processor
    output logic                   xbit_spec_start,
    output logic [31:0]            xbit_spec_hidden_state,
    input  logic                   xbit_spec_done,
    input  logic [2:0]             xbit_spec_committed_count,

    // 3. KV Cache Rollback Engine
    output logic                   xbit_kv_rollback_valid,
    output logic [7:0]             xbit_kv_rollback_seq_len,

    // 4. 64-PE Systolic Array Control
    output logic                   xbit_array_enable,
    output logic                   xbit_mode_os,
    output logic [1:0]             xbit_precision_mode,

    // 5. 1-Cycle Hardware CORDIC RoPE Engine
    output logic [15:0]            xbit_rope_pos,
    output logic signed [15:0]     xbit_rope_x_in,
    output logic signed [15:0]     xbit_rope_y_in,
    input  logic signed [15:0]     xbit_rope_x_out,
    input  logic signed [15:0]     xbit_rope_y_out,

    // 6. Hardware-Fused MoE Top-K Router
    output logic [1:0]             xbit_moe_topk_mode,
    output logic                   xbit_moe_wr_en,
    output logic [1:0]             xbit_moe_wr_idx,
    output logic [31:0]            xbit_moe_wr_data,
    input  logic [31:0]            xbit_moe_packed_result,

    // 7. SIMD Quad-Vector 2:4 Sparsity Engine (16 elements, 8 active ops)
    output logic [27:0]            xbit_sparse_quad_weights,
    output logic [31:0]            xbit_sparse_quad_act,
    input  logic signed [31:0]     xbit_sparse_quad_dot_out,

    // 8. 1-Cycle Dual-Element SwiGLU / GeGLU Vector Engine
    output logic signed [31:0]     xbit_swiglu_gate_in,
    output logic signed [31:0]     xbit_swiglu_up_in,
    input  logic signed [31:0]     xbit_swiglu_pair_out,

    // 9. 1-Cycle Hardware Token Sampler & Greedy Argmax Engine
    output logic signed [31:0]     xbit_sampler_cand_in,
    output logic signed [31:0]     xbit_sampler_best_in,
    input  logic signed [31:0]     xbit_sampler_winner_out,

    // 10. 1-Cycle Hardware FlashAttention Online Softmax Engine
    output logic signed [31:0]     xbit_vattn_state_in,
    output logic signed [31:0]     xbit_vattn_score_in,
    input  logic signed [31:0]     xbit_vattn_state_out,

    // 11. 1-Cycle Dual-Element Vector RMSNorm Engine
    output logic signed [31:0]     xbit_rmsnorm_act_in,
    output logic signed [31:0]     xbit_rmsnorm_scale_in,
    input  logic signed [31:0]     xbit_rmsnorm_norm_out,

    // 12. 1-Cycle Hardware Stochastic Top-P / Min-P Sampler Engine
    output logic signed [31:0]     xbit_stoch_cand_in,
    output logic signed [31:0]     xbit_stoch_best_in,
    output logic        [31:0]     xbit_stoch_config_in,
    input  logic signed [31:0]     xbit_stoch_winner_out,

    // 13. 1-Cycle 4-Bit Packed KV-Cache Compression Codec
    output logic signed [31:0]     xbit_kv_codec_data_in,
    output logic        [31:0]     xbit_kv_codec_config_in,
    input  logic signed [31:0]     xbit_kv_codec_data_out,

    // 14. 1-Cycle Hardware Prefix Cache Hash & Radix Matcher Engine
    output logic [31:0]            xbit_prefix_tok_in,
    output logic [31:0]            xbit_prefix_cfg_in,
    input  logic [31:0]            xbit_prefix_result_out,

    // 15. 1-Cycle Multiplier-Free Microscaling (MX) Dot Product Engine
    output logic signed [31:0]     xbit_mx_act_in,
    output logic        [31:0]     xbit_mx_cfg_in,
    input  logic signed [31:0]     xbit_mx_result_out,

    // 16. 1-Cycle Multi-Head Latent Attention (MLA) Low-Rank Compression Engine
    output logic signed [31:0]     xbit_mla_act_in,
    output logic        [31:0]     xbit_mla_cfg_in,
    input  logic signed [31:0]     xbit_mla_packed_out,

    // 17. 1-Cycle Hardware CRC & Link Parity Health Engine for UCIe
    output logic [31:0]            xbit_link_flit_in,
    output logic [31:0]            xbit_link_cfg_in,
    input  logic [31:0]            xbit_link_status_out,

    // Status & Telemetry
    output logic [31:0]            telemetry_retired_instr,
    output logic [31:0]            telemetry_cycle_count
);

    localparam logic [6:0] OPCODE_CUSTOM_0 = 7'b0001011; // Standard RISC-V Custom Extension Opcode
    localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011; // ADDI, SLTI, etc.
    localparam logic [6:0] OPCODE_OP       = 7'b0110011; // ADD, SUB, etc.
    localparam logic [6:0] OPCODE_LOAD     = 7'b0000011; // LW
    localparam logic [6:0] OPCODE_STORE    = 7'b0100011; // SW
    localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011; // BEQ, BNE
    localparam logic [6:0] OPCODE_JAL      = 7'b1101111; // JAL

    // -------------------------------------------------------------------------
    // 1. 32-Entry General Purpose Register File (x0..x31)
    // -------------------------------------------------------------------------
    logic [31:0] regfile [0:31];
    logic [4:0]  rs1_idx, rs2_idx, rd_idx;
    logic [31:0] rs1_data, rs2_data;

    assign rs1_data = (rs1_idx == 5'd0) ? 32'h0 : regfile[rs1_idx];
    assign rs2_data = (rs2_idx == 5'd0) ? 32'h0 : regfile[rs2_idx];

    // -------------------------------------------------------------------------
    // 2. Fetch & Program Counter FSM
    // -------------------------------------------------------------------------
    logic [31:0] pc_reg;
    assign imem_addr = pc_reg;

    // Instruction Decode Fields
    wire [6:0]  opcode = imem_rdata[6:0];
    wire [2:0]  funct3 = imem_rdata[14:12];
    wire [6:0]  funct7 = imem_rdata[31:25];
    assign rd_idx      = imem_rdata[11:7];
    assign rs1_idx     = imem_rdata[19:15];
    assign rs2_idx     = imem_rdata[24:20];

    // Immediates
    wire [31:0] imm_i = {{20{imem_rdata[31]}}, imem_rdata[31:20]};
    wire [31:0] imm_s = {{20{imem_rdata[31]}}, imem_rdata[31:25], imem_rdata[11:7]};
    wire [31:0] imm_b = {{19{imem_rdata[31]}}, imem_rdata[31], imem_rdata[7], imem_rdata[30:25], imem_rdata[11:8], 1'b0};
    wire [31:0] imm_j = {{12{imem_rdata[31]}}, imem_rdata[19:12], imem_rdata[20], imem_rdata[30:21], 1'b0};

    // Combinational Memory Bus
    assign dmem_en    = (opcode == OPCODE_LOAD) || (opcode == OPCODE_STORE);
    assign dmem_we    = (opcode == OPCODE_STORE);
    assign dmem_addr  = (opcode == OPCODE_LOAD) ? (rs1_data + imm_i) : (rs1_data + imm_s);
    assign dmem_wdata = rs2_data;

    // Combinational 2:4 Sparsity Accelerator Dispatch
    assign xbit_sparse_act_in  = rs1_data;
    assign xbit_sparse_w0      = rs2_data[1:0];
    assign xbit_sparse_w1      = rs2_data[3:2];
    assign xbit_sparse_pattern = rs2_data[6:4];

    // Combinational 1-Cycle CORDIC RoPE Dispatch
    assign xbit_rope_pos   = rs1_data[15:0];
    assign xbit_rope_x_in  = rs2_data[15:0];
    assign xbit_rope_y_in  = rs2_data[31:16];

    // Combinational MoE Router Dispatch
    logic [1:0] moe_mode_reg;
    assign xbit_moe_topk_mode = ((opcode == OPCODE_CUSTOM_0) && (funct7 == 7'b0000110) && (funct3 != 3'b110)) ? rs1_data[1:0] : moe_mode_reg;
    assign xbit_moe_wr_idx    = rs1_data[1:0];
    assign xbit_moe_wr_data   = rs2_data;
    assign xbit_moe_wr_en     = (opcode == OPCODE_CUSTOM_0) && (funct7 == 7'b0000110) && (funct3 == 3'b110);

    // Combinational SIMD Quad-Vector Sparsity Dispatch
    assign xbit_sparse_quad_weights = rs2_data[27:0];
    assign xbit_sparse_quad_act     = rs1_data;

    // Combinational SwiGLU Vector Dispatch
    assign xbit_swiglu_gate_in = rs1_data;
    assign xbit_swiglu_up_in   = rs2_data;

    // Combinational Sampler Dispatch
    assign xbit_sampler_cand_in = rs1_data;
    assign xbit_sampler_best_in = rs2_data;

    // Combinational FlashAttention Online Softmax Dispatch
    assign xbit_vattn_state_in = rs1_data;
    assign xbit_vattn_score_in = rs2_data;

    // Combinational Vector RMSNorm Dispatch
    assign xbit_rmsnorm_act_in   = rs1_data;
    assign xbit_rmsnorm_scale_in = rs2_data;

    // Combinational Stochastic Sampler Dispatch
    assign xbit_stoch_cand_in   = rs1_data;
    assign xbit_stoch_best_in   = rs2_data;
    assign xbit_stoch_config_in = imm_i;

    // Combinational 4-Bit KV-Cache Codec Dispatch
    assign xbit_kv_codec_data_in   = rs1_data;
    assign xbit_kv_codec_config_in = rs2_data;

    // Combinational Prefix Cache Matcher Dispatch
    assign xbit_prefix_tok_in = rs1_data;
    assign xbit_prefix_cfg_in = rs2_data;

    // Combinational Microscaling (MX) Dot Engine Dispatch
    assign xbit_mx_act_in = rs1_data;
    assign xbit_mx_cfg_in = rs2_data;

    // Combinational Multi-Head Latent Attention (MLA) Dispatch
    assign xbit_mla_act_in = rs1_data;
    assign xbit_mla_cfg_in = rs2_data;

    // Combinational UCIe Link Health Dispatch
    assign xbit_link_flit_in = rs1_data;
    assign xbit_link_cfg_in  = rs2_data;

    // Performance telemetry counters
    logic [31:0] cnt_instr, cnt_cycles;
    assign telemetry_retired_instr = cnt_instr;
    assign telemetry_cycle_count   = cnt_cycles;

    // -------------------------------------------------------------------------
    // 3. Execution & Custom Xbitnet Coprocessor Dispatch (Single-Cycle Datapath)
    // -------------------------------------------------------------------------
    logic        stall_for_spec;
    logic [4:0]  latched_spec_rd;
    logic        rf_we_comb;
    logic [4:0]  rf_waddr_comb;
    logic [31:0] rf_wdata_comb;
    logic [31:0] next_pc_comb;
    logic        instr_retire_comb;

    always_comb begin
        rf_we_comb        = 1'b0;
        rf_waddr_comb     = rd_idx;
        rf_wdata_comb     = '0;
        next_pc_comb      = pc_reg + 4;
        instr_retire_comb = 1'b1;

        if (stall_for_spec) begin
            if (xbit_spec_done) begin
                rf_we_comb        = 1'b1;
                rf_waddr_comb     = latched_spec_rd;
                rf_wdata_comb     = {29'h0, xbit_spec_committed_count};
                next_pc_comb      = pc_reg + 4;
                instr_retire_comb = 1'b1;
            end else begin
                rf_we_comb        = 1'b0;
                rf_waddr_comb     = '0;
                rf_wdata_comb     = '0;
                next_pc_comb      = pc_reg;
                instr_retire_comb = 1'b0;
            end
        end else begin
            case (opcode)
                // Standard RISC-V Load Word (LW)
                OPCODE_LOAD: begin
                    rf_we_comb    = 1'b1;
                    rf_wdata_comb = dmem_rdata;
                end

                // Standard RISC-V ADDI
                OPCODE_OP_IMM: begin
                    if (funct3 == 3'b000) begin
                        rf_we_comb    = 1'b1;
                        rf_wdata_comb = rs1_data + imm_i;
                    end
                end

                // Standard RISC-V ADD / SUB
                OPCODE_OP: begin
                    rf_we_comb    = 1'b1;
                    rf_wdata_comb = (funct7 == 7'b0100000) ? (rs1_data - rs2_data) : (rs1_data + rs2_data);
                end

                // Standard RISC-V SW (Store Word)
                OPCODE_STORE: begin
                    rf_we_comb = 1'b0;
                end

                // Standard RISC-V Branch BEQ / BNE
                OPCODE_BRANCH: begin
                    rf_we_comb = 1'b0;
                    if (funct3 == 3'b000 && (rs1_data == rs2_data))      next_pc_comb = pc_reg + imm_b;
                    else if (funct3 == 3'b001 && (rs1_data != rs2_data)) next_pc_comb = pc_reg + imm_b;
                end

                // Standard RISC-V Jump And Link (JAL)
                OPCODE_JAL: begin
                    rf_we_comb    = (rd_idx != 5'd0);
                    rf_wdata_comb = pc_reg + 4;
                    next_pc_comb  = pc_reg + imm_j;
                end

                // -------------------------------------------------------------
                // CUSTOM_0: Native Xbitnet Matrix-Tensor Coprocessor Extension
                // -------------------------------------------------------------
                OPCODE_CUSTOM_0: begin
                    case (funct7)
                        // 1. vternary.gemv rd, rs1, rs2: Trigger array execution
                        7'b0000001: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = 32'h0000_0001; // Success acknowledge
                        end

                        // 2. vsparse.decomp rd, rs1, rs2: 1-Cycle 2:4 Sparsity Dot Product
                        7'b0000010: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_sparse_dot_out;
                        end

                        // 3. vspec.draft rd, rs1, rs2: Trigger Medusa K=4 Speculation Engine
                        7'b0000011: begin
                            rf_we_comb        = 1'b0;
                            next_pc_comb      = pc_reg; // Pause PC until coprocessor completes
                            instr_retire_comb = 1'b0;
                        end

                        // 4. vkv.rollback rd, rs1: 1-Cycle Instantaneous KV Cache Rollback
                        7'b0000100: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = {24'h0, rs1_data[7:0]};
                        end

                        // 5. vrope.rot rd, rs1, rs2: 1-Cycle CORDIC Rotary Position Embedding
                        7'b0000101: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = {xbit_rope_y_out, xbit_rope_x_out};
                        end

                        // 6. vmoe.topk / vmoe.wrlogit: Hardware MoE Top-K Router
                        7'b0000110: begin
                            if (funct3 == 3'b110) begin
                                rf_we_comb = 1'b0;
                            end else begin
                                rf_we_comb    = 1'b1;
                                rf_wdata_comb = xbit_moe_packed_result;
                            end
                        end

                        // 7. vsparse.vec4 rd, rs1, rs2: 1-Cycle SIMD Quad-Vector 2:4 Sparsity Dot Product
                        7'b0000111: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_sparse_quad_dot_out;
                        end

                        // 8. vswiglu.vec2 rd, rs1, rs2: 1-Cycle Multiplier-Free Dual SwiGLU
                        7'b0001000: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_swiglu_pair_out;
                        end

                        // 9. vsampler.argmax rd, rs1, rs2: 1-Cycle Branch-Free Argmax Sampler
                        7'b0001001: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_sampler_winner_out;
                        end

                        // 10. vattn.online rd, rs1, rs2: 1-Cycle FlashAttention Online Softmax State Update
                        7'b0001010: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_vattn_state_out;
                        end

                        // 11. vrmsnorm.vec2 rd, rs1, rs2: 1-Cycle Dual-Element Vector RMSNorm Normalization
                        7'b0001011: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_rmsnorm_norm_out;
                        end

                        // 12. vsampler.sample rd, rs1, rs2: 1-Cycle Stochastic Min-P / Top-P Sampler
                        7'b0001100: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_stoch_winner_out;
                        end

                        // 13. vkv.codec rd, rs1, rs2: 1-Cycle 4-Bit Packed KV-Cache Codec
                        7'b0001101: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_kv_codec_data_out;
                        end

                        // 14. vprefix.match rd, rs1, rs2: 1-Cycle Prefix Cache Hash & Radix Matcher
                        7'b0001110: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_prefix_result_out;
                        end

                        // 15. vmx.dot4 rd, rs1, rs2: 1-Cycle Microscaling (MX) Dot Product Engine
                        7'b0001111: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_mx_result_out;
                        end

                        // 16. vmla.compress rd, rs1, rs2: 1-Cycle Multi-Head Latent Attention (MLA)
                        7'b0010000: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_mla_packed_out;
                        end

                        // 17. vlink.crc rd, rs1, rs2: 1-Cycle Hardware CRC & UCIe Link Health
                        7'b0010001: begin
                            rf_we_comb    = 1'b1;
                            rf_wdata_comb = xbit_link_status_out;
                        end

                        default: begin
                            rf_we_comb = 1'b0;
                        end
                    endcase
                end

                default: begin
                    rf_we_comb = 1'b0;
                end
            endcase
        end
    end

    // Sequential State Update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_reg                   <= PC_RESET;
            xbit_spec_start          <= 1'b0;
            xbit_spec_hidden_state   <= '0;
            xbit_kv_rollback_valid   <= 1'b0;
            xbit_kv_rollback_seq_len <= '0;
            xbit_array_enable        <= 1'b0;
            xbit_mode_os             <= 1'b1;
            xbit_precision_mode      <= 2'b00;
            stall_for_spec           <= 1'b0;
            latched_spec_rd          <= '0;
            moe_mode_reg             <= 2'b00;
            cnt_instr                <= '0;
            cnt_cycles               <= '0;
            for (int r = 0; r < 32; r++) begin
                regfile[r] <= 32'h0;
            end
        end else begin
            cnt_cycles             <= cnt_cycles + 1'b1;
            xbit_spec_start        <= 1'b0;
            xbit_kv_rollback_valid <= 1'b0;
            xbit_array_enable      <= 1'b0;

            if (instr_retire_comb) begin
                cnt_instr <= cnt_instr + 1'b1;
            end

            pc_reg <= next_pc_comb;

            if (rf_we_comb && (rf_waddr_comb != 5'd0)) begin
                regfile[rf_waddr_comb] <= rf_wdata_comb;
            end

            if (stall_for_spec) begin
                if (xbit_spec_done) begin
                    stall_for_spec <= 1'b0;
                end
            end else if (opcode == OPCODE_CUSTOM_0) begin
                case (funct7)
                    7'b0000001: begin
                        xbit_array_enable   <= 1'b1;
                        xbit_precision_mode <= rs2_data[1:0];
                        xbit_mode_os        <= rs2_data[2];
                    end
                    7'b0000011: begin
                        xbit_spec_start        <= 1'b1;
                        xbit_spec_hidden_state <= rs1_data;
                        stall_for_spec         <= 1'b1;
                        latched_spec_rd        <= rd_idx;
                    end
                    7'b0000100: begin
                        xbit_kv_rollback_valid   <= 1'b1;
                        xbit_kv_rollback_seq_len <= rs1_data[7:0];
                    end
                    7'b0000110: begin
                        if (funct3 != 3'b110) begin
                            moe_mode_reg <= rs1_data[1:0];
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
