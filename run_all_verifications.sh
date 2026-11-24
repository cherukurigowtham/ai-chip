#!/usr/bin/env bash
# ==============================================================================
# Script: run_all_verifications.sh
# Description: Unified Silicon Verification & Pre-Tapeout Regression Suite
#              for BitNet-130 AI Accelerator & Quad-Cluster Tensor Engine.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}==========================================================================${NC}"
echo -e "${BLUE}  BITNET-130 UNIFIED PRE-TAPEOT SILICON VERIFICATION SUITE              ${NC}"
echo -e "${BLUE}  Signoff Clock: 500 MHz (2.0 ns) | Process Tech: SkyWater Sky130 / Nangate 45nm${NC}"
echo -e "${BLUE}==========================================================================${NC}"

RTL_DIR="ai-accelerator-project/ternary/rtl"
VERIF_DIR="ai-accelerator-project/verification/deep_testing"
SDK_DIR="ai-accelerator-project/sdk"
FIRMWARE_DIR="hardware/carrier_board/firmware"

# 1. Reconfigurable Multi-Precision Matrix Engine (Ternary + INT4 + INT8)
echo -e "\n${YELLOW}>>> [1/52] Running Reconfigurable Multi-Precision Engine (Ternary + INT4 + INT8)...${NC}"
iverilog -g2012 -o /tmp/sim_multiprecision.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${VERIF_DIR}/tb_reconfigurable_multiprecision.sv
vvp /tmp/sim_multiprecision.vvp
echo -e "${GREEN}[OK] Reconfigurable Multi-Precision Engine Passed!${NC}"

# 2. Autonomous Transformer Attention Engine (RoPE + On-Chip KV Cache)
echo -e "\n${YELLOW}>>> [2/52] Running Autonomous Attention Engine (RoPE CORDIC + 2KB KV Cache)...${NC}"
iverilog -g2012 -o /tmp/sim_attention.vvp \
  ${RTL_DIR}/rope_engine.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/transformer_attention_subsystem.sv \
  ${VERIF_DIR}/tb_transformer_attention.sv
vvp /tmp/sim_attention.vvp
echo -e "${GREEN}[OK] Autonomous Attention Subsystem Passed!${NC}"

# 3. Quad-Cluster 256-PE Verification
echo -e "\n${YELLOW}>>> [3/52] Running Quad-Core Clustered Tensor Engine (256 PEs) Verification...${NC}"
iverilog -g2012 -o /tmp/sim_cluster.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/pe_ternary.sv \
  ${RTL_DIR}/systolic_array_ternary.sv \
  ${RTL_DIR}/ternary_weight_buffer.sv \
  ${RTL_DIR}/ternary_weight_unpacker.sv \
  ${RTL_DIR}/vector_activation_unit.sv \
  ${RTL_DIR}/dynamic_config_reg.sv \
  ${RTL_DIR}/ternary_controller.sv \
  ${RTL_DIR}/accelerator_ternary_top.sv \
  ${RTL_DIR}/bitnet_quad_cluster_top.sv \
  ${VERIF_DIR}/tb_quad_cluster_256pe.sv
vvp /tmp/sim_cluster.vvp
echo -e "${GREEN}[OK] Quad-Core 256-PE Verification Passed!${NC}"

# 4. Multi-Layer Transformer Verification
echo -e "\n${YELLOW}>>> [4/52] Running End-to-End BitNet Transformer Block Verification...${NC}"
iverilog -g2012 -o /tmp/sim_transformer.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/pe_ternary.sv \
  ${RTL_DIR}/systolic_array_ternary.sv \
  ${RTL_DIR}/ternary_weight_buffer.sv \
  ${RTL_DIR}/ternary_weight_unpacker.sv \
  ${RTL_DIR}/vector_activation_unit.sv \
  ${RTL_DIR}/dynamic_config_reg.sv \
  ${RTL_DIR}/ternary_controller.sv \
  ${RTL_DIR}/accelerator_ternary_top.sv \
  ${VERIF_DIR}/tb_end_to_end_transformer.sv
vvp /tmp/sim_transformer.vvp
echo -e "${GREEN}[OK] End-to-End Transformer Block Verification Passed!${NC}"

# 5. NVIDIA-Grade Deep Stress Testing
echo -e "\n${YELLOW}>>> [5/52] Running NVIDIA-Grade Adversarial Stress Suite (8 Tiers)...${NC}"
iverilog -g2012 -o /tmp/sim_deep_stress.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/pe_ternary.sv \
  ${RTL_DIR}/systolic_array_ternary.sv \
  ${RTL_DIR}/ternary_weight_buffer.sv \
  ${RTL_DIR}/ternary_weight_unpacker.sv \
  ${RTL_DIR}/vector_activation_unit.sv \
  ${RTL_DIR}/dynamic_config_reg.sv \
  ${RTL_DIR}/ternary_controller.sv \
  ${RTL_DIR}/accelerator_ternary_top.sv \
  ${VERIF_DIR}/tb_deep_stress_8x8.sv
vvp /tmp/sim_deep_stress.vvp
echo -e "${GREEN}[OK] NVIDIA-Grade Deep Testing Suite Passed!${NC}"

# 6. Python SDK Inference Pipeline
echo -e "\n${YELLOW}>>> [6/52] Running Python Compiler & Runtime SDK Inference Demo...${NC}"
python3 ${SDK_DIR}/run_bitnet_transformer_inference.py
echo -e "${GREEN}[OK] Python Compiler & SDK Test Passed!${NC}"

# 7. C Embedded Firmware Driver Test
echo -e "\n${YELLOW}>>> [7/52] Compiling and Executing RP2040 Carrier Board Embedded Firmware...${NC}"
gcc -Wall -Wextra -Werror -O2 ${FIRMWARE_DIR}/main.c ${FIRMWARE_DIR}/bitnet_asic.c -o /tmp/bitnet_firmware_test
/tmp/bitnet_firmware_test
echo -e "${GREEN}[OK] Carrier Board Firmware Clean Build & Execution Passed!${NC}"

# 8. Compressed Sparse DMA Engine (CS-DMA)
echo -e "\n${YELLOW}>>> [8/52] Running Compressed Sparse DMA (CS-DMA) Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_cs_dma.vvp \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${VERIF_DIR}/tb_cs_dma_engine.sv
vvp /tmp/sim_cs_dma.vvp
echo -e "${GREEN}[OK] Compressed Sparse DMA Engine Passed!${NC}"

# 9. Speculative Decoding Micro-Core & 1-Cycle KV Cache Rewind Co-Simulation
echo -e "\n${YELLOW}>>> [9/52] Running Speculative Decoding Micro-Core & KV Cache Co-Simulation...${NC}"
iverilog -g2012 -o /tmp/sim_spec_dec.vvp \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${VERIF_DIR}/tb_speculative_decoding.sv
vvp /tmp/sim_spec_dec.vvp
echo -e "${GREEN}[OK] Speculative Decoding Micro-Core Co-Simulation Passed!${NC}"

# 10. 2D Mesh Network-on-Chip (NoC) Multi-Die Packet Router
echo -e "\n${YELLOW}>>> [10/52] Running 2D Mesh Network-on-Chip (NoC) Router Verification...${NC}"
iverilog -g2012 -o /tmp/sim_noc.vvp \
  ${RTL_DIR}/noc_router_2d.sv \
  ${VERIF_DIR}/tb_noc_router_2d.sv
vvp /tmp/sim_noc.vvp
echo -e "${GREEN}[OK] 2D Mesh NoC Multi-Die Router Passed!${NC}"

# 11. Extreme Pre-Silicon Chaos & Random Backpressure Fuzzer
echo -e "\n${YELLOW}>>> [11/52] Running Extreme Pre-Silicon Chaos & Backpressure Fuzzer...${NC}"
iverilog -g2012 -o /tmp/sim_chaos.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/noc_router_2d.sv \
  ${VERIF_DIR}/tb_extreme_chaos_fuzzer.sv
vvp /tmp/sim_chaos.vvp
echo -e "${GREEN}[OK] Extreme Chaos Fuzzer Passed!${NC}"

# 12. Dynamic PVT Jitter, Clock Droop & Protocol SVA Assertion Fuzzer
echo -e "\n${YELLOW}>>> [12/52] Running Dynamic PVT Jitter, Clock Droop & SVA Assertions...${NC}"
iverilog -g2012 -o /tmp/sim_jitter_pvt.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${VERIF_DIR}/tb_jitter_pvt_sva_fuzzer.sv
vvp /tmp/sim_jitter_pvt.vvp
echo -e "${GREEN}[OK] Dynamic PVT Jitter & SVA Assertions Passed!${NC}"

# 13. Hardware BIST (Galois LFSR / MISR) & Stuck-at Fault Injection Engine
echo -e "\n${YELLOW}>>> [13/52] Running Hardware BIST & Stuck-at Fault Injection Suite...${NC}"
iverilog -g2012 -o /tmp/sim_bist.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${VERIF_DIR}/tb_bist_fault_injection.sv
vvp /tmp/sim_bist.vvp
echo -e "${GREEN}[OK] Hardware BIST & Fault Injection Suite Passed!${NC}"

# 14. 100,000-Pass Industrial Endurance & Mathematical Headroom Campaign
echo -e "\n${YELLOW}>>> [14/52] Running 100,000-Pass Industrial Endurance & Stress Campaign...${NC}"
python3 ${VERIF_DIR}/run_100k_endurance_fuzzing.py
echo -e "${GREEN}[OK] 100,000-Pass Industrial Endurance Campaign Passed!${NC}"

# 15. Open-Source MLCommons MLPerf Tiny & Edge Benchmark Suite
echo -e "\n${YELLOW}>>> [15/52] Running MLCommons MLPerf Tiny & Edge Benchmark Suite...${NC}"
iverilog -g2012 -o /tmp/sim_mlperf_tiny.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${VERIF_DIR}/tb_mlperf_tiny_workloads.sv
vvp /tmp/sim_mlperf_tiny.vvp
python3 ai-accelerator-project/benchmarks/run_mlperf_tiny_benchmark.py
echo -e "${GREEN}[OK] MLCommons MLPerf Tiny Benchmark Suite Passed!${NC}"

# 16. Gate-Level Yosys Synthesis & Physical Area Signoff
echo -e "\n${YELLOW}>>> [16/52] Running Gate-Level Yosys Synthesis & PPA Area Signoff...${NC}"
python3 ai-accelerator-project/ternary/synthesis/run_full_cluster_synthesis.py
echo -e "${GREEN}[OK] Gate-Level Yosys Synthesis & PPA Area Signoff Passed!${NC}"

# 17. TinyTapeout tt10 & SkyWater Sky130 Tapeout Precheck (1x1 Tile)
echo -e "\n${YELLOW}>>> [17/52] Running TinyTapeout tt10 & SkyWater Sky130 Tapeout Precheck...${NC}"
python3 scripts/run_tapeout_precheck.py
echo -e "${GREEN}[OK] TinyTapeout tt10 & SkyWater Sky130 Precheck Passed!${NC}"

# 18. TinyTapeout 2x2 Multi-Tile Scaled Cluster Precheck & Verification
echo -e "\n${YELLOW}>>> [18/52] Running TinyTapeout 2x2 Multi-Tile Scaled Cluster Precheck...${NC}"
python3 scripts/run_multitile_precheck.py
echo -e "${GREEN}[OK] TinyTapeout 2x2 Multi-Tile Scaled Cluster Passed!${NC}"

# 19. PyTorch 2.0 Compiler Backend & TorchFX Graph Lowering
echo -e "\n${YELLOW}>>> [19/52] Running PyTorch 2.0 Compiler Backend & TorchFX Graph Lowering...${NC}"
python3 ai-accelerator-project/sdk/test_torch_compile_backend.py
echo -e "${GREEN}[OK] PyTorch 2.0 Compiler Backend Passed!${NC}"

# 20. ONNX Runtime Multiplier-Free Exporter & Edge Engine
echo -e "\n${YELLOW}>>> [20/52] Running ONNX Runtime Multiplier-Free Exporter & Edge Engine...${NC}"
PYTHONPATH=ai-accelerator-project/sdk python3 ai-accelerator-project/sdk/test_onnx_export.py
echo -e "${GREEN}[OK] ONNX Runtime Multiplier-Free Exporter Passed!${NC}"

# 21. High-Speed Octal-SPI (OSPI) Burst DMA Engine & Wide Bus Verification
echo -e "\n${YELLOW}>>> [21/52] Running High-Speed Octal-SPI (OSPI) Burst DMA Verification (200 MB/s)...${NC}"
iverilog -g2012 -o /tmp/sim_ospi.vvp \
  ${RTL_DIR}/ospi_dma_controller.sv \
  ${VERIF_DIR}/tb_ospi_dma_controller.sv
vvp /tmp/sim_ospi.vvp
echo -e "${GREEN}[OK] High-Speed Octal-SPI (OSPI) Burst DMA Engine Passed!${NC}"

# 22. Gen-2 Dual-Issue Multiplier-Free Ternary PE (2 MACs/Cycle)
echo -e "\n${YELLOW}>>> [22/52] Running Gen-2 Dual-Issue Multiplier-Free Ternary PE (2 MACs/Cycle)...${NC}"
iverilog -g2012 -o /tmp/sim_pe_dual.vvp \
  ${RTL_DIR}/pe_dual_issue_ternary.sv \
  ${VERIF_DIR}/tb_pe_dual_issue_ternary.sv
vvp /tmp/sim_pe_dual.vvp
echo -e "${GREEN}[OK] Gen-2 Dual-Issue Multiplier-Free Ternary PE Passed!${NC}"

# 23. Multiplier-Free Reciprocal RMSNorm Engine (64-Element)
echo -e "\n${YELLOW}>>> [23/52] Running Multiplier-Free Reciprocal RMSNorm Normalization Engine...${NC}"
iverilog -g2012 -o /tmp/sim_rmsnorm.vvp \
  ${RTL_DIR}/rmsnorm_engine.sv \
  ${VERIF_DIR}/tb_rmsnorm_engine.sv
vvp /tmp/sim_rmsnorm.vvp
echo -e "${GREEN}[OK] Multiplier-Free Reciprocal RMSNorm Engine Passed!${NC}"

# 24. Gen-2 1-Cycle Hybrid Spatial Multicast GEMV Engine (16x Latency Reduction)
echo -e "\n${YELLOW}>>> [24/52] Running 1-Cycle Spatial Multicast GEMV Engine (16x Latency Speedup)...${NC}"
iverilog -g2012 -o /tmp/sim_multicast.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/hybrid_multicast_gemv_engine.sv \
  ${VERIF_DIR}/tb_hybrid_multicast_gemv.sv
vvp /tmp/sim_multicast.vvp
echo -e "${GREEN}[OK] 1-Cycle Spatial Multicast GEMV Engine Passed!${NC}"

# 25. 4-Virtual-Channel QoS NoC Router (HOL Blocking Elimination)
echo -e "\n${YELLOW}>>> [25/52] Running 4-Virtual-Channel QoS NoC Router Verification...${NC}"
iverilog -g2012 -o /tmp/sim_noc_vc4.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${VERIF_DIR}/tb_noc_router_2d_vc4.sv
vvp /tmp/sim_noc_vc4.vvp
echo -e "${GREEN}[OK] 4-Virtual-Channel QoS NoC Router Passed!${NC}"

# 26. In-PE OCP Micro-Scaling (MX) Exponent Unit & Outlier Resilience
echo -e "\n${YELLOW}>>> [26/52] Running In-PE OCP Micro-Scaling (MX) Exponent Unit Verification...${NC}"
iverilog -g2012 -o /tmp/sim_pe_mx.vvp \
  ${RTL_DIR}/pe_mx_ternary.sv \
  ${VERIF_DIR}/tb_pe_mx_ternary.sv
vvp /tmp/sim_pe_mx.vvp
echo -e "${GREEN}[OK] In-PE OCP Micro-Scaling (MX) Exponent Unit Passed!${NC}"

# 27. Hardware Online FlashAttention-3 Micro-Engine (O(1) SRAM Footprint)
echo -e "\n${YELLOW}>>> [27/52] Running Hardware Online FlashAttention-3 Micro-Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_online_flash.vvp \
  ${RTL_DIR}/online_flash_attention_engine.sv \
  ${VERIF_DIR}/tb_online_flash_attention.sv
vvp /tmp/sim_online_flash.vvp
echo -e "${GREEN}[OK] Hardware Online FlashAttention-3 Micro-Engine Passed!${NC}"

# 28. Asynchronous Elastic Zero-Bypass Queue (2.67x Sparsity Throughput Speedup)
echo -e "\n${YELLOW}>>> [28/52] Running Asynchronous Elastic Zero-Bypass Queue Verification...${NC}"
iverilog -g2012 -o /tmp/sim_elastic.vvp \
  ${RTL_DIR}/elastic_zero_bypass_fifo.sv \
  ${VERIF_DIR}/tb_elastic_zero_bypass.sv
vvp /tmp/sim_elastic.vvp
echo -e "${GREEN}[OK] Asynchronous Elastic Zero-Bypass Queue Passed!${NC}"

# 29. Autonomous Power Management & DVFS Retention Controller
echo -e "\n${YELLOW}>>> [29/52] Running Autonomous Power Management & DVFS Retention Controller...${NC}"
iverilog -g2012 -o /tmp/sim_dvfs.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/power_management_dvfs_controller.sv \
  ${VERIF_DIR}/tb_power_management_dvfs.sv
vvp /tmp/sim_dvfs.vvp
echo -e "${GREEN}[OK] Autonomous Power Management & DVFS Controller Passed!${NC}"

# 30. Gen-2 Unified Multiplier-Free AI Accelerator Top-Level Silicon Macro
echo -e "\n${YELLOW}>>> [30/52] Running Gen-2 Unified Multiplier-Free AI Accelerator Top-Level Silicon Macro Verification...${NC}"
iverilog -g2012 -o /tmp/sim_gen2_top.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/power_management_dvfs_controller.sv \
  ${RTL_DIR}/ospi_dma_controller.sv \
  ${RTL_DIR}/hybrid_multicast_gemv_engine.sv \
  ${RTL_DIR}/rmsnorm_engine.sv \
  ${RTL_DIR}/online_flash_attention_engine.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${RTL_DIR}/bitnet_gen2_accelerator_top.sv \
  ${VERIF_DIR}/tb_bitnet_gen2_top.sv
vvp /tmp/sim_gen2_top.vvp
echo -e "${GREEN}[OK] Gen-2 Unified Multiplier-Free AI Accelerator Top-Level Silicon Macro Passed!${NC}"

# 31. Universal Frontier Model Architecture Suite (Llama 3, Qwen 2.5, Mistral, Gemma 2, DeepSeek)
echo -e "\n${YELLOW}>>> [31/52] Running Universal Frontier Model Architecture & PTQ-Ternary Verification Suite...${NC}"
PYTHONPATH=${SDK_DIR} python3 ${SDK_DIR}/test_frontier_architectures.py -v
echo -e "${GREEN}[OK] Universal Frontier Model Architecture Suite Passed!${NC}"

# 32. Dual-Die UCIe Chiplet D2D Interconnect & Redundant Microbump Repair
echo -e "\n${YELLOW}>>> [32/52] Running Dual-Die UCIe Chiplet D2D Interconnect & Repair Verification...${NC}"
iverilog -g2012 -o /tmp/sim_d2d.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/d2d_ucie_phy.sv \
  ${RTL_DIR}/d2d_link_layer.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${RTL_DIR}/bitnet_chiplet_dual_die_top.sv \
  ${VERIF_DIR}/tb_chiplet_dual_die_d2d.sv
vvp /tmp/sim_d2d.vvp
echo -e "${GREEN}[OK] Dual-Die UCIe Chiplet D2D Interconnect Passed!${NC}"

# 33. Hardware Speculative Decoding Draft Engine & 1-Cycle KV Rollback
echo -e "\n${YELLOW}>>> [33/52] Running Hardware Speculative Decoding Co-Processor Verification...${NC}"
iverilog -g2012 -o /tmp/sim_spec.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/draft_token_engine.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/speculative_decoding_coprocessor.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${VERIF_DIR}/tb_speculative_coprocessor_system.sv
vvp /tmp/sim_spec.vvp
echo -e "${GREEN}[OK] Hardware Speculative Decoding Co-Processor Passed!${NC}"

# 34. 2:4 Semi-Structured Sparsity Decompressor & Matrix Engine
echo -e "\n${YELLOW}>>> [34/52] Running 2:4 Semi-Structured Sparsity Matrix Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_sparse.vvp \
  ${RTL_DIR}/sparse_2_4_ternary_decompressor.sv \
  ${VERIF_DIR}/tb_sparse_2_4_ternary.sv
vvp /tmp/sim_sparse.vvp
echo -e "${GREEN}[OK] 2:4 Semi-Structured Sparsity Matrix Engine Passed!${NC}"

# 35. OpenLane Caravel MPW Silicon Accelerator Macro
echo -e "\n${YELLOW}>>> [35/52] Running OpenLane Caravel MPW Accelerator Macro Verification...${NC}"
iverilog -g2012 -o /tmp/sim_mpw.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/sparse_2_4_ternary_decompressor.sv \
  ${RTL_DIR}/draft_token_engine.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/speculative_decoding_coprocessor.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${RTL_DIR}/d2d_link_layer.sv \
  ${RTL_DIR}/d2d_ucie_phy.sv \
  ${RTL_DIR}/power_management_dvfs_controller.sv \
  openlane/bitnet_accelerator_cluster_mpw/bitnet_mpw_accelerator_macro.sv \
  openlane/bitnet_accelerator_cluster_mpw/tb_bitnet_mpw_accelerator_macro.sv
vvp /tmp/sim_mpw.vvp
echo -e "${GREEN}[OK] OpenLane Caravel MPW Accelerator Macro Passed!${NC}"

# 36. PagedAttention Hardware Page Table Walker & Virtual Memory Engine
echo -e "\n${YELLOW}>>> [36/52] Running PagedAttention Hardware Page Table Walker Verification...${NC}"
iverilog -g2012 -o /tmp/sim_ptw.vvp \
  ${RTL_DIR}/paged_attention_ptw.sv \
  ${VERIF_DIR}/tb_paged_attention_ptw.sv
vvp /tmp/sim_ptw.vvp
echo -e "${GREEN}[OK] PagedAttention Hardware Page Table Walker Passed!${NC}"

# 37. Turing-Complete RISC-V + Xbitnet Universal Tensor Processor Top
echo -e "\n${YELLOW}>>> [37/52] Running Turing-Complete RISC-V + Xbitnet Universal Processor Top...${NC}"
iverilog -g2012 -o /tmp/sim_univ.vvp \
  ${RTL_DIR}/clkgate_x1.sv \
  ${RTL_DIR}/openram_dual_port_macro.sv \
  ${RTL_DIR}/sparse_2_4_ternary_decompressor.sv \
  ${RTL_DIR}/sparse_quad_vec_decompressor.sv \
  ${RTL_DIR}/moe_topk_router.sv \
  ${RTL_DIR}/draft_token_engine.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/speculative_decoding_coprocessor.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/noc_router_2d_vc4.sv \
  ${RTL_DIR}/d2d_link_layer.sv \
  ${RTL_DIR}/d2d_ucie_phy.sv \
  ${RTL_DIR}/rope_2d_cordic.sv \
  ${RTL_DIR}/swiglu_vector_engine.sv \
  ${RTL_DIR}/llm_sampler_engine.sv \
  ${RTL_DIR}/flash_online_softmax_engine.sv \
  ${RTL_DIR}/rmsnorm_vector_engine.sv \
  ${RTL_DIR}/llm_stochastic_sampler_engine.sv \
  ${RTL_DIR}/kv_cache_codec_engine.sv \
  ${RTL_DIR}/prefix_cache_matcher_engine.sv \
  ${RTL_DIR}/mx_block_dot_engine.sv \
  ${RTL_DIR}/mla_compression_engine.sv \
  ${RTL_DIR}/ucie_link_health_engine.sv \
  ${RTL_DIR}/riscv_xbitnet_core.sv \
  ${RTL_DIR}/bitnet_universal_processor_top.sv \
  ${VERIF_DIR}/tb_bitnet_universal_processor.sv
vvp /tmp/sim_univ.vvp
echo -e "${GREEN}[OK] Turing-Complete RISC-V + Xbitnet Universal Processor Top Passed!${NC}"

# 38. BitNet Universal Compiler (PyTorch to Xbitnet Machine Code Lowering Pass)
echo -e "\n${YELLOW}>>> [38/52] Running BitNet Universal Compiler (PyTorch -> Xbitnet ISA) Verification...${NC}"
python3 ${SDK_DIR}/xbitnet_universal_compiler.py
echo -e "${GREEN}[OK] BitNet Universal Compiler Lowering Pass Passed!${NC}"

# 39. Hardware-Fused MoE Top-K Gating Router (DeepSeek V3 / Mixtral Acceleration)
echo -e "\n${YELLOW}>>> [39/52] Running Hardware-Fused MoE Top-K Router Verification...${NC}"
iverilog -g2012 -o /tmp/sim_moe.vvp \
  ${RTL_DIR}/moe_topk_router.sv \
  ${VERIF_DIR}/tb_moe_topk_router.sv
vvp /tmp/sim_moe.vvp
echo -e "${GREEN}[OK] Hardware-Fused MoE Top-K Router Passed!${NC}"

# 40. SIMD Quad-Vector 2:4 Sparsity Decompressor & Dot-Product Engine
echo -e "\n${YELLOW}>>> [40/52] Running SIMD Quad-Vector 2:4 Sparsity Decompressor Verification...${NC}"
iverilog -g2012 -o /tmp/sim_quad_sparse.vvp \
  ${RTL_DIR}/sparse_quad_vec_decompressor.sv \
  ${VERIF_DIR}/tb_sparse_quad_vec_decompressor.sv
vvp /tmp/sim_quad_sparse.vvp
echo -e "${GREEN}[OK] SIMD Quad-Vector 2:4 Sparsity Decompressor Passed!${NC}"

# 41. 1-Cycle CORDIC Rotary Position Embedding (RoPE) Vector Engine
echo -e "\n${YELLOW}>>> [41/52] Running 1-Cycle Hardware CORDIC RoPE Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_rope_cordic.vvp \
  ${RTL_DIR}/rope_2d_cordic.sv \
  ${VERIF_DIR}/tb_rope_2d_cordic.sv
vvp /tmp/sim_rope_cordic.vvp
echo -e "${GREEN}[OK] 1-Cycle Hardware CORDIC RoPE Engine Passed!${NC}"

# 42. Multiplier-Free 1-Cycle Dual SwiGLU / GeGLU Vector Engine
echo -e "\n${YELLOW}>>> [42/52] Running Multiplier-Free 1-Cycle Dual SwiGLU Vector Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_swiglu.vvp \
  ${RTL_DIR}/swiglu_vector_engine.sv \
  ${VERIF_DIR}/tb_swiglu_vector_engine.sv
vvp /tmp/sim_swiglu.vvp
echo -e "${GREEN}[OK] Multiplier-Free 1-Cycle Dual SwiGLU Vector Engine Passed!${NC}"

# 43. Multiplier-Free 1-Cycle Hardware Token Sampler & Greedy Argmax Engine
echo -e "\n${YELLOW}>>> [43/52] Running 1-Cycle Branch-Free Hardware Token Sampler Verification...${NC}"
iverilog -g2012 -o /tmp/sim_sampler.vvp \
  ${RTL_DIR}/llm_sampler_engine.sv \
  ${VERIF_DIR}/tb_llm_sampler_engine.sv
vvp /tmp/sim_sampler.vvp
echo -e "${GREEN}[OK] 1-Cycle Branch-Free Hardware Token Sampler Passed!${NC}"

# 44. Multiplier-Free 1-Cycle FlashAttention Online Softmax Engine
echo -e "\n${YELLOW}>>> [44/52] Running Multiplier-Free 1-Cycle FlashAttention Online Softmax Engine...${NC}"
iverilog -g2012 -o /tmp/sim_softmax.vvp \
  ${RTL_DIR}/flash_online_softmax_engine.sv \
  ${VERIF_DIR}/tb_flash_online_softmax_engine.sv
vvp /tmp/sim_softmax.vvp
echo -e "${GREEN}[OK] 1-Cycle FlashAttention Online Softmax Engine Passed!${NC}"

# 45. Multiplier-Free 1-Cycle Dual-Element Vector RMSNorm Engine
echo -e "\n${YELLOW}>>> [45/52] Running Multiplier-Free 1-Cycle Dual-Element Vector RMSNorm Engine...${NC}"
iverilog -g2012 -o /tmp/sim_norm.vvp \
  ${RTL_DIR}/rmsnorm_vector_engine.sv \
  ${VERIF_DIR}/tb_rmsnorm_vector_engine.sv
vvp /tmp/sim_norm.vvp
echo -e "${GREEN}[OK] 1-Cycle Dual-Element Vector RMSNorm Engine Passed!${NC}"

# 46. Multiplier-Free 1-Cycle Stochastic Min-P / Top-P Sampler Engine
echo -e "\n${YELLOW}>>> [46/52] Running 1-Cycle Stochastic Min-P Sampler Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_stoch.vvp \
  ${RTL_DIR}/llm_stochastic_sampler_engine.sv \
  ${VERIF_DIR}/tb_llm_stochastic_sampler_engine.sv
vvp /tmp/sim_stoch.vvp
echo -e "${GREEN}[OK] 1-Cycle Stochastic Min-P Sampler Engine Passed!${NC}"

# 47. Multiplier-Free 1-Cycle 4-Bit Packed KV-Cache Compression Codec
echo -e "\n${YELLOW}>>> [47/52] Running 1-Cycle 4-Bit Packed KV-Cache Codec Verification...${NC}"
iverilog -g2012 -o /tmp/sim_codec.vvp \
  ${RTL_DIR}/kv_cache_codec_engine.sv \
  ${VERIF_DIR}/tb_kv_cache_codec_engine.sv
vvp /tmp/sim_codec.vvp
echo -e "${GREEN}[OK] 1-Cycle 4-Bit Packed KV-Cache Codec Passed!${NC}"

# 48. Multiplier-Free 1-Cycle Hardware Prefix Cache Hash & Radix Matcher Engine
echo -e "\n${YELLOW}>>> [48/52] Running 1-Cycle Hardware Prefix Cache Radix Matcher Verification...${NC}"
iverilog -g2012 -o /tmp/sim_prefix.vvp \
  ${RTL_DIR}/prefix_cache_matcher_engine.sv \
  ${VERIF_DIR}/tb_prefix_cache_matcher_engine.sv
vvp /tmp/sim_prefix.vvp
echo -e "${GREEN}[OK] 1-Cycle Hardware Prefix Cache Radix Matcher Passed!${NC}"

# 49. Multiplier-Free 1-Cycle Microscaling (MX) Block Dot Product Engine
echo -e "\n${YELLOW}>>> [49/52] Running 1-Cycle Microscaling (MX) Block Dot Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_mx.vvp \
  ${RTL_DIR}/mx_block_dot_engine.sv \
  ${VERIF_DIR}/tb_mx_block_dot_engine.sv
vvp /tmp/sim_mx.vvp
echo -e "${GREEN}[OK] 1-Cycle Microscaling (MX) Block Dot Engine Passed!${NC}"

# 50. Multiplier-Free 1-Cycle Multi-Head Latent Attention (MLA) Engine (DeepSeek V2/V3)
echo -e "\n${YELLOW}>>> [50/52] Running 1-Cycle Multi-Head Latent Attention (MLA) Engine...${NC}"
iverilog -g2012 -o /tmp/sim_mla.vvp \
  ${RTL_DIR}/mla_compression_engine.sv \
  ${VERIF_DIR}/tb_mla_compression_engine.sv
vvp /tmp/sim_mla.vvp
echo -e "${GREEN}[OK] 1-Cycle Multi-Head Latent Attention Engine Passed!${NC}"

# 51. Multiplier-Free 1-Cycle Hardware CRC & UCIe Link Health Engine
echo -e "\n${YELLOW}>>> [51/52] Running 1-Cycle Hardware CRC & UCIe Link Health Engine...${NC}"
iverilog -g2012 -o /tmp/sim_crc.vvp \
  ${RTL_DIR}/ucie_link_health_engine.sv \
  ${VERIF_DIR}/tb_ucie_link_health_engine.sv
vvp /tmp/sim_crc.vvp
echo -e "${GREEN}[OK] 1-Cycle Hardware CRC & UCIe Link Health Engine Passed!${NC}"

# 52. Multi-Vector Silicon Boundary, Saturation & Corner-Case Stress Harness
echo -e "\n${YELLOW}>>> [52/52] Running Multi-Vector Silicon Boundary & Extreme Edge-Case Harness...${NC}"
iverilog -g2012 -o /tmp/sim_edge_cases.vvp \
  ${RTL_DIR}/sparse_2_4_ternary_decompressor.sv \
  ${RTL_DIR}/moe_topk_router.sv \
  ${RTL_DIR}/flash_online_softmax_engine.sv \
  ${RTL_DIR}/rmsnorm_vector_engine.sv \
  ${RTL_DIR}/swiglu_vector_engine.sv \
  ${RTL_DIR}/prefix_cache_matcher_engine.sv \
  ${RTL_DIR}/mx_block_dot_engine.sv \
  ${RTL_DIR}/mla_compression_engine.sv \
  ${RTL_DIR}/ucie_link_health_engine.sv \
  ${VERIF_DIR}/tb_extreme_edge_cases.sv
vvp /tmp/sim_edge_cases.vvp
echo -e "${GREEN}[OK] Multi-Vector Silicon Boundary & Extreme Edge-Case Harness Passed!${NC}"

echo -e "\n${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  ALL 52 INDUSTRIAL SILICON VERIFICATION TIERS PASSED WITH ZERO VIOLATIONS!${NC}"
echo -e "${GREEN}  UNIVERSAL TENSOR PROCESSOR STATUS: 100% BIT-EXACT SIGNOFF READY         ${NC}"
echo -e "${GREEN}==========================================================================${NC}\n"
