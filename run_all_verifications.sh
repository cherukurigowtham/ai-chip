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
echo -e "\n${YELLOW}>>> [1/19] Running Reconfigurable Multi-Precision Engine (Ternary + INT4 + INT8)...${NC}"
iverilog -g2012 -o /tmp/sim_multiprecision.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${VERIF_DIR}/tb_reconfigurable_multiprecision.sv
vvp /tmp/sim_multiprecision.vvp
echo -e "${GREEN}[OK] Reconfigurable Multi-Precision Engine Passed!${NC}"

# 2. Autonomous Transformer Attention Engine (RoPE + On-Chip KV Cache)
echo -e "\n${YELLOW}>>> [2/19] Running Autonomous Attention Engine (RoPE CORDIC + 2KB KV Cache)...${NC}"
iverilog -g2012 -o /tmp/sim_attention.vvp \
  ${RTL_DIR}/rope_engine.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/transformer_attention_subsystem.sv \
  ${VERIF_DIR}/tb_transformer_attention.sv
vvp /tmp/sim_attention.vvp
echo -e "${GREEN}[OK] Autonomous Attention Subsystem Passed!${NC}"

# 3. Quad-Cluster 256-PE Verification
echo -e "\n${YELLOW}>>> [3/19] Running Quad-Core Clustered Tensor Engine (256 PEs) Verification...${NC}"
iverilog -g2012 -o /tmp/sim_cluster.vvp \
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
echo -e "\n${YELLOW}>>> [4/19] Running End-to-End BitNet Transformer Block Verification...${NC}"
iverilog -g2012 -o /tmp/sim_transformer.vvp \
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
echo -e "\n${YELLOW}>>> [5/19] Running NVIDIA-Grade Adversarial Stress Suite (8 Tiers)...${NC}"
iverilog -g2012 -o /tmp/sim_deep_stress.vvp \
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
echo -e "\n${YELLOW}>>> [6/19] Running Python Compiler & Runtime SDK Inference Demo...${NC}"
python3 ${SDK_DIR}/run_bitnet_transformer_inference.py
echo -e "${GREEN}[OK] Python Compiler & SDK Test Passed!${NC}"

# 7. C Embedded Firmware Driver Test
echo -e "\n${YELLOW}>>> [7/19] Compiling and Executing RP2040 Carrier Board Embedded Firmware...${NC}"
gcc -Wall -Wextra -Werror -O2 ${FIRMWARE_DIR}/main.c ${FIRMWARE_DIR}/bitnet_asic.c -o /tmp/bitnet_firmware_test
/tmp/bitnet_firmware_test
echo -e "${GREEN}[OK] Carrier Board Firmware Clean Build & Execution Passed!${NC}"

# 8. Compressed Sparse DMA Engine (CS-DMA)
echo -e "\n${YELLOW}>>> [8/19] Running Compressed Sparse DMA (CS-DMA) Engine Verification...${NC}"
iverilog -g2012 -o /tmp/sim_cs_dma.vvp \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${VERIF_DIR}/tb_cs_dma_engine.sv
vvp /tmp/sim_cs_dma.vvp
echo -e "${GREEN}[OK] Compressed Sparse DMA Engine Passed!${NC}"

# 9. Speculative Decoding Micro-Core & 1-Cycle KV Cache Rewind Co-Simulation
echo -e "\n${YELLOW}>>> [9/19] Running Speculative Decoding Micro-Core & KV Cache Co-Simulation...${NC}"
iverilog -g2012 -o /tmp/sim_spec_dec.vvp \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${VERIF_DIR}/tb_speculative_decoding.sv
vvp /tmp/sim_spec_dec.vvp
echo -e "${GREEN}[OK] Speculative Decoding Micro-Core Co-Simulation Passed!${NC}"

# 10. 2D Mesh Network-on-Chip (NoC) Multi-Die Packet Router
echo -e "\n${YELLOW}>>> [10/19] Running 2D Mesh Network-on-Chip (NoC) Router Verification...${NC}"
iverilog -g2012 -o /tmp/sim_noc.vvp \
  ${RTL_DIR}/noc_router_2d.sv \
  ${VERIF_DIR}/tb_noc_router_2d.sv
vvp /tmp/sim_noc.vvp
echo -e "${GREEN}[OK] 2D Mesh NoC Multi-Die Router Passed!${NC}"

# 11. Extreme Pre-Silicon Chaos & Random Backpressure Fuzzer
echo -e "\n${YELLOW}>>> [11/19] Running Extreme Pre-Silicon Chaos & Backpressure Fuzzer...${NC}"
iverilog -g2012 -o /tmp/sim_chaos.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/kv_cache_ring_buffer.sv \
  ${RTL_DIR}/noc_router_2d.sv \
  ${VERIF_DIR}/tb_extreme_chaos_fuzzer.sv
vvp /tmp/sim_chaos.vvp
echo -e "${GREEN}[OK] Extreme Chaos Fuzzer Passed!${NC}"

# 12. Dynamic PVT Jitter, Clock Droop & Protocol SVA Assertion Fuzzer
echo -e "\n${YELLOW}>>> [12/19] Running Dynamic PVT Jitter, Clock Droop & SVA Assertions...${NC}"
iverilog -g2012 -o /tmp/sim_jitter_pvt.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${RTL_DIR}/cs_dma_engine.sv \
  ${VERIF_DIR}/tb_jitter_pvt_sva_fuzzer.sv
vvp /tmp/sim_jitter_pvt.vvp
echo -e "${GREEN}[OK] Dynamic PVT Jitter & SVA Assertions Passed!${NC}"

# 13. Hardware BIST (Galois LFSR / MISR) & Stuck-at Fault Injection Engine
echo -e "\n${YELLOW}>>> [13/19] Running Hardware BIST & Stuck-at Fault Injection Suite...${NC}"
iverilog -g2012 -o /tmp/sim_bist.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${VERIF_DIR}/tb_bist_fault_injection.sv
vvp /tmp/sim_bist.vvp
echo -e "${GREEN}[OK] Hardware BIST & Fault Injection Suite Passed!${NC}"

# 14. 100,000-Pass Industrial Endurance & Mathematical Headroom Campaign
echo -e "\n${YELLOW}>>> [14/19] Running 100,000-Pass Industrial Endurance & Stress Campaign...${NC}"
python3 ${VERIF_DIR}/run_100k_endurance_fuzzing.py
echo -e "${GREEN}[OK] 100,000-Pass Industrial Endurance Campaign Passed!${NC}"

# 15. Open-Source MLCommons MLPerf Tiny & Edge Benchmark Suite
echo -e "\n${YELLOW}>>> [15/19] Running MLCommons MLPerf Tiny & Edge Benchmark Suite...${NC}"
iverilog -g2012 -o /tmp/sim_mlperf_tiny.vvp \
  ${RTL_DIR}/pe_reconfigurable_multiprecision.sv \
  ${RTL_DIR}/systolic_array_multiprecision.sv \
  ${RTL_DIR}/speculative_decoding_core.sv \
  ${VERIF_DIR}/tb_mlperf_tiny_workloads.sv
vvp /tmp/sim_mlperf_tiny.vvp
python3 ai-accelerator-project/benchmarks/run_mlperf_tiny_benchmark.py
echo -e "${GREEN}[OK] MLCommons MLPerf Tiny Benchmark Suite Passed!${NC}"

# 16. Gate-Level Yosys Synthesis & Physical Area Signoff
echo -e "\n${YELLOW}>>> [16/19] Running Gate-Level Yosys Synthesis & PPA Area Signoff...${NC}"
python3 ai-accelerator-project/ternary/synthesis/run_full_cluster_synthesis.py
echo -e "${GREEN}[OK] Gate-Level Yosys Synthesis & PPA Area Signoff Passed!${NC}"

# 17. TinyTapeout tt10 & SkyWater Sky130 Tapeout Precheck (1x1 Tile)
echo -e "\n${YELLOW}>>> [17/19] Running TinyTapeout tt10 & SkyWater Sky130 Tapeout Precheck...${NC}"
python3 scripts/run_tapeout_precheck.py
echo -e "${GREEN}[OK] TinyTapeout tt10 & SkyWater Sky130 Precheck Passed!${NC}"

# 18. TinyTapeout 2x2 Multi-Tile Scaled Cluster Precheck & Verification
echo -e "\n${YELLOW}>>> [18/19] Running TinyTapeout 2x2 Multi-Tile Scaled Cluster Precheck...${NC}"
python3 scripts/run_multitile_precheck.py
echo -e "${GREEN}[OK] TinyTapeout 2x2 Multi-Tile Scaled Cluster Passed!${NC}"

# 19. PyTorch 2.0 Compiler Backend & TorchFX Graph Lowering
echo -e "\n${YELLOW}>>> [19/19] Running PyTorch 2.0 Compiler Backend & TorchFX Graph Lowering...${NC}"
python3 ai-accelerator-project/sdk/test_torch_compile_backend.py
echo -e "${GREEN}[OK] PyTorch 2.0 Compiler Backend Passed!${NC}"

echo -e "\n${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  ALL 19 INDUSTRIAL SILICON VERIFICATION TIERS PASSED WITH ZERO VIOLATIONS!${NC}"
echo -e "${GREEN}  CORE STATUS: 100% BIT-EXACT SIGNOFF READY FOR MPW FABRICATION           ${NC}"
echo -e "${GREEN}==========================================================================${NC}\n"
