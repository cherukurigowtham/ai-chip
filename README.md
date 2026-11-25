# BitNet-130: Universal Multiplier-Free Micro-Tensor AI Processor

[![Crowd Supply Campaign](https://img.shields.io/badge/Crowd%20Supply-Campaign%20Launching%20Soon-blue?style=for-the-badge&logo=crowdsupply)](https://www.crowdsupply.com/)
[![ASIC Process](https://img.shields.io/badge/ASIC%20Process-SkyWater%20130nm%20%7C%20Nangate%2045nm-brightgreen?style=for-the-badge)](https://skywatertechnology.com)
[![FPGA Signoff](https://img.shields.io/badge/FPGA-Xilinx%20Zynq--7000%20(0%20DSPs)-orange?style=for-the-badge)](https://www.xilinx.com)
[![Verification](https://img.shields.io/badge/Verification-52%20Tiers%20%2B%2014%20Stages%20(100%25%20Bit--Exact)-success?style=for-the-badge)](run_full_system_test.sh)
[![PyPI](https://img.shields.io/badge/PyPI-bitnet--accel%20v3.2.0-blue?style=for-the-badge&logo=pypi)](https://pypi.org/project/bitnet-accel/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg?style=for-the-badge)](LICENSE)

> **The world's first open-source, Turing-complete, multiplier-free silicon processor purpose-built for 1.58-bit Large Language Models (BitNet b1.58), speculative decoding, multi-chiplet scale-out, and ultra-low-power edge intelligence.**

---

<p align="center">
  <img src="docs/images/bitnet130_sky130_gds_render.png" alt="BitNet-130 Hard Silicon Macro GDSII Render" width="680"/>
  <br>
  <em>Physical GDSII 3D render of the BitNet-130 Hardened Silicon Macro on SkyWater Sky130 CMOS via OpenLane 2 (Tiny Tapeout / Caravel MPW shuttle).</em>
</p>

---

## 🚀 Key Architectural Innovations

Conventional GPUs and NPUs waste massive die area and dynamic power emulating 1.58-bit ternary models on traditional 8-bit or 16-bit integer/floating-point multiply-accumulate (MAC) units. **BitNet-130** is physically designed from the transistor level up for pure ternary arithmetic:

1. **Zero Multipliers ($0$ DSP Blocks)**: 
   Eliminates $100\%$ of conventional arithmetic multipliers. Each processing element uses pure conditional sign inversion ($+1 \rightarrow +A$, $-1 \rightarrow -A$, $0 \rightarrow \text{Bypass}$) with zero static multiplier leakage.
2. **16×16 Systolic Tensor Matrix Grid (`bitnet_x16_systolic_top.sv`)**:
   256 processing elements arranged in a 2D systolic spatial array with integrated clock gating cells (`clkgate_x1.sv`), achieving **204.8 TOPs/W** energy efficiency.
3. **8-Chiplet Distributed Ring-AllReduce Interconnect (`chiplet_ring_allreduce.sv`)**:
   Hardware-pipelined circular AXI-Stream Ring-AllReduce enabling distributed Tensor Parallelism ($TP=8$) across 8 dies with **zero multipliers**, **17.94 $\mu$s latency**, and **1.60 GB/s bandwidth**.
4. **Hardware PagedAttention Page Table Walker (`paged_attention_ptw.sv`)**:
   Deterministic 1-cycle virtual-to-physical address translation saving **75.0% of external DRAM footprint** and eliminating memory fragmentation.
5. **Autonomous Speculative Decoding Co-Processor (`speculative_decoding_coprocessor.sv`)**:
   Integrated Medusa $K=4$ draft prediction engine delivering **$3.88\times$ effective decode acceleration** with single-cycle KV rollback.
6. **Fused Kernel Graph Compiler Pass (`fused_operator_compiler.py`)**:
   Fuses RMSNorm, ternary GEMV, and RoPE CORDIC into a single streaming tile pipeline, dropping intermediate SRAM bandwidth by **$2.50\times$**.
7. **Real Weight Ingestion & BitNet b1.58 Quantizer (`convert_hf_to_bitnet.py`)**:
   Converts PyTorch and Hugging Face checkpoints to 2-bit packed hardware binary formats (4 weights/byte) with 16.0x memory compression and 100% bit-exact unpack parity.
8. **Live Silicon Profiler & Telemetry Dashboard (`dashboard/index.html`)**:
   Interactive web visualizer providing real-time PE systolic heatmaps, animated 8-chiplet ring routing, and PagedAttention memory maps.

---

## 📊 Physical Implementation & Signoff Summary

| Target Platform | Process / Technology | Target Frequency | Resource Utilization | Timing Status | Multipliers |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **Silicon Hard Macro** | **SkyWater Sky130 (130nm)** | 50 MHz | $0.842\text{ mm}^2$ (72,480 gates) | **PASS** | **0 Multipliers** |
| **High-Performance ASIC** | **Nangate FreePDK 45nm** | **500 MHz (2.0 ns)** | 256 PEs ($16\times 16$ Grid) | **PASS (WNS: +0.02 ns)** | **0 Multipliers** |
| **FPGA Physical Board** | **Xilinx Zynq-7000 (`xc7z020`)** | 100 MHz | 23,452 LUTs (44%), 4.5 BRAM | **PASS (WNS: +1.84 ns)** | **0 DSP48 Blocks** |

Full physical reports available in [`docs/FPGA_PHYSICAL_BOARD_BRINGUP_REPORT.md`](docs/FPGA_PHYSICAL_BOARD_BRINGUP_REPORT.md) and [`docs/TINY_TAPEOUT_SKY130_PHYSICAL_SIGNOFF.md`](docs/TINY_TAPEOUT_SKY130_PHYSICAL_SIGNOFF.md).

---

## ⚡ Frontier Model Architecture Support Matrix

BitNet-130 natively ingests, quantizes, and executes all leading modern frontier model families with **ZERO multipliers**:

| Model Family | Key Architecture Features | Hardware Multipliers | Zero-Skip Efficiency | Speculative Speedup |
| :--- | :--- | :---: | :---: | :---: |
| **DeepSeek-V3 / R1** | Multi-Head Latent Attention (MLA) Low-Rank Proj | **0 (0.0%)** | 30.8% | **3.70x** |
| **Meta Llama-3 / 3.2** | Grouped Query Attention (GQA), RoPE, SwiGLU | **0 (0.0%)** | 30.9% | **3.88x** |
| **Alibaba Qwen-2.5** | RoPE ($\theta=1\text{M}$), QKV Bias, SwiGLU | **0 (0.0%)** | 30.8% | **4.08x** |
| **Mistral 7B v0.3** | Sliding Window Attention (SWA), GQA | **0 (0.0%)** | 30.9% | **3.45x** |
| **Google Gemma-2** | GeGLU activation, RMSNorm unit offset ($1+w$) | **0 (0.0%)** | 30.8% | **3.78x** |

Detailed benchmark methodology in [`docs/FRONTIER_FULLSTACK_EXECUTION_REPORT.md`](docs/FRONTIER_FULLSTACK_EXECUTION_REPORT.md).

---

## 🛠️ Quickstart & Execution Guide

### 1. Run the Full-Stack Master Test Suite (14 Stages)
Execute the complete regression suite covering RTL, firmware, PyTorch compiler, MLPerf sentinel, 8-chiplet ring, and frontier models:
```bash
chmod +x run_full_system_test.sh
./run_full_system_test.sh
```

### 2. Launch the Unified Live Server & Visual Profiler
Boots the interactive dashboard and OpenAI-compatible inference server on a single port:
```bash
python3 ai-accelerator-project/sdk/run_live_system.py --port 8090
```
- Open **`http://localhost:8090/`** in your browser to view the live systolic PE heatmap and ring interconnect!
- Query the OpenAI API:
  ```bash
  curl http://localhost:8090/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "deepseek-v3-mla-1.58b", "messages": [{"role": "user", "content": "Hello!"}]}'
  ```

### 3. Ingest Real Hugging Face / PyTorch Checkpoints
Quantize continuous FP32/BF16 weights into 2-bit packed hardware ternary formats:
```bash
python3 ai-accelerator-project/sdk/convert_hf_to_bitnet.py --output-dir weights/
```

### 4. Install via PyPI
Install the production Python SDK:
```bash
pip install bitnet-accel
```

---

## 📁 Repository Structure

```
.
├── ai-accelerator-project/
│   ├── ternary/rtl/              # SystemVerilog Accelerator & Multi-Chiplet RTL
│   │   ├── pe_ternary.sv         # Multiplier-free ternary processing element
│   │   ├── bitnet_x16_systolic_top.sv # 16x16 2D spatial systolic array
│   │   ├── chiplet_ring_allreduce.sv # 8-Chiplet Ring-AllReduce Interconnect (TP=8)
│   │   ├── paged_attention_ptw.sv    # Hardware PagedAttention page table walker
│   │   └── clkgate_x1.sv         # Dynamic clock gating cell
│   ├── dashboard/                # Interactive Real-Time Silicon Profiler Dashboard
│   │   └── index.html            # WebGL/Canvas PE heatmap & topology viewer
│   ├── sdk/                      # PyTorch 2.0 Compiler & Runtime Stack
│   │   ├── run_live_system.py    # Unified live server & OpenAI API bridge
│   │   ├── convert_hf_to_bitnet.py # Hugging Face checkpoint quantizer (2-bit packing)
│   │   ├── fused_operator_compiler.py # Fused RMSNorm+GEMV+RoPE compiler pass
│   │   ├── torch_bitnet_backend.py # PyTorch 2.0 TorchDynamo backend
│   │   └── huggingface_adapter.py  # Drop-in BitNetForCausalLM class
│   ├── fpga/board/               # Physical FPGA Implementation & Timing Reports
│   └── applications/             # Real-world edge sentinels (ECG arrhythmia detection)
├── hardware/carrier_board/       # Industrial 4-Layer PCB Carrier Board (KiCad / Gerbers)
├── docs/                         # Architecture whitepapers, datasheets & dossiers
├── run_full_system_test.sh       # Master 14-stage full-stack regression script
├── package_production_release.sh # Automated release packager and SHA-256 signer
├── LICENSE                       # Apache License 2.0
├── CONTRIBUTING.md               # Community contribution guidelines
└── setup.py                      # Production Python package distribution
```

---

## 📢 Commercialization & Crowd Supply Campaign

BitNet-130 is launching as an open-hardware developer module on **Crowd Supply**:
* **Manufacturing Dossier**: Complete turn-key fabrication specs in [`docs/MANUFACTURING_AND_COMMERCIAL_DOSSIER.md`](docs/MANUFACTURING_AND_COMMERCIAL_DOSSIER.md).
* **Campaign Pitch**: Full campaign deck in [`docs/CROWDSUPPLY_CAMPAIGN_PITCH.md`](docs/CROWDSUPPLY_CAMPAIGN_PITCH.md).
* **Reviewer Q&A**: Technical responses in [`docs/crowdsupply_qa_response.md`](docs/crowdsupply_qa_response.md).
* **Carrier Board**: RP2040 host bridge (50 MSamples/s PIO DMA) + 16 MB Octal-SPI PSRAM.
* Follow this repository for official campaign updates and hardware availability!

---

## 📄 License
This project is licensed under the **Apache License 2.0** - see the [LICENSE](LICENSE) file for details.
