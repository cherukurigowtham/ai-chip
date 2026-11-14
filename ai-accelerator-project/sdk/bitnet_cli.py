#!/usr/bin/env python3
"""
==============================================================================
BitNet-130: Unified Developer Command-Line Interface (CLI)
==============================================================================
The definitive command-line utility for interacting with the BitNet-130
multiplier-free edge AI co-processor and lowering frontier LLMs.

Commands:
    bitnet convert    - Turnkey PTQ-Ternary lowering for Llama 3, Qwen 2.5, Mistral, Gemma 2, DeepSeek
    bitnet chat       - Interactive conversational chat with live energy telemetry
    bitnet serve      - Run local OpenAI-compatible REST server (port 8080)
    bitnet benchmark  - Run automated hardware throughput and cross-model benchmarks
    bitnet info       - Display physical silicon signoff specifications and frontier support
==============================================================================
"""

import sys
import os
import time
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from huggingface_adapter import BitNetForCausalLM
from frontier_model_adapter import (
    FrontierModelConverter, FrontierModelForCausalLM, SUPPORTED_ARCHS,
    QUAD_CORE_POWER_MW, CLOCK_FREQ_MHZ
)


def cmd_convert(args):
    print("=" * 76)
    print("   BITNET-130 FRONTIER MODEL INGESTION & PTQ-TERNARY COMPILER")
    print("   Target Silicon: BitNet-130 Quad-Core 256-PE Silicon Macro (500 MHz)")
    print("=" * 76)

    arch = args.model.lower()
    edge_preset = not args.full_scale

    output_path = args.output
    if output_path is None:
        suffix = "edge" if edge_preset else "full"
        output_path = f"{arch}_{suffix}_bitnet130.bitnet"

    res = FrontierModelConverter.convert(
        arch=arch,
        weights_path=args.weights,
        output_path=output_path,
        edge_preset=edge_preset
    )

    fp16_kb = (res["total_weights"] * 2) / 1024.0
    bitnet_kb = res["file_size_kb"]
    ratio = fp16_kb / max(bitnet_kb, 1e-3)

    print("\n" + "-" * 76)
    print("  PHYSICAL SILICON INGESTION AUDIT:")
    print(f"    Target Architecture    : {arch.upper()}")
    print(f"    Quantized Parameters   : {res['total_weights']:,} weights")
    print(f"    Raw FP16 Baseline      : {fp16_kb:,.1f} KB")
    print(f"    BitNet-130 Packed Size : {bitnet_kb:,.1f} KB (.bitnet hardware package)")
    print(f"    Memory Collapse Factor : {ratio:.1f}x reduction")
    print(f"    Hardware Multipliers   : ZERO (100% Add/Sub/Zero-Skip)")
    print(f"    Zero-Skip Sparsity     : {res['zero_skip_pct']:.2f}% clock-gated cycles saved")
    print(f"    Peak Silicon Power     : {QUAD_CORE_POWER_MW} mW @ {CLOCK_FREQ_MHZ:.0f} MHz")
    print(f"    Output Binary Path     : {os.path.abspath(output_path)}")
    print("=" * 76 + "\n")


def cmd_chat(args):
    print("=" * 72)
    print("   BITNET-130 HARDWARE INTERACTIVE CONVERSATIONAL TERMINAL")
    print("   Target: 100% Multiplier-Free Silicon Engine | 500 MHz Signoff")
    print("   Type 'exit' or 'quit' to end session.")
    print("=" * 72)

    model = BitNetForCausalLM.from_pretrained(args.model)
    print(f"\n[READY] Loaded {args.model} (0 Hardware Multipliers). Start chatting:\n")

    while True:
        try:
            user_input = input("\033[1;36mYou >\033[0m ").strip()
            if not user_input:
                continue
            if user_input.lower() in ["exit", "quit"]:
                print("Session terminated.")
                break

            print("\033[1;32mBitNet-130 >\033[0m ", end="", flush=True)

            def print_token(token_text):
                sys.stdout.write(token_text)
                sys.stdout.flush()

            res = model.generate(
                prompt=f"user: {user_input}\nassistant: ",
                max_new_tokens=args.max_tokens,
                temperature=args.temp,
                stream_callback=print_token
            )
            print() # Newline

            # Telemetry footer
            print(f"\033[90m  [{res['tokens_per_sec']:,.0f} tok/s | {res['energy_per_token_uj']:.4f} uJ/tok | "
                  f"Latency: {res['silicon_latency_ms']:.2f} ms | Multipliers: 0]\033[0m\n")

        except KeyboardInterrupt:
            print("\nSession ended.")
            break


def cmd_serve(args):
    from bitnet_server import run_server
    run_server(host=args.host, port=args.port, model_name=args.model)


def cmd_benchmark(args):
    print("=" * 76)
    print("   BITNET-130 SILICON PEAK PERFORMANCE & ENERGY BENCHMARK")
    print("   Operating Frequency: 500 MHz (2.0 ns clock period)")
    print("=" * 76)

    targets = SUPPORTED_ARCHS if args.model.lower() == "all" else [args.model]

    test_prompts = [
        "What is the future of edge computing?",
        "Autonomous medical sensor telemetry analysis.",
        "Deep space radiation-hardened satellite inference.",
        "Zero-multiplier ternary neural network mathematics."
    ]

    for target in targets:
        print(f"\n>>> Evaluating Architecture Target: [{target.upper()}] (0 Multipliers)...")
        model = BitNetForCausalLM.from_pretrained(target)

        total_tokens = 0
        total_energy = 0.0
        total_time_ms = 0.0

        for i, p in enumerate(test_prompts):
            res = model.generate(prompt=p, max_new_tokens=25, temperature=0.7)
            total_tokens += res["total_tokens"]
            total_energy += res["energy_total_uj"]
            total_time_ms += res["silicon_latency_ms"]

            print(f"  [WORKLOAD {i+1}] '{p[:32]}...'")
            print(f"    * Generated : {res['total_tokens']} tokens")
            print(f"    * Latency   : {res['silicon_latency_ms']:.2f} ms ({res['tokens_per_sec']:,.0f} tok/s)")
            print(f"    * Energy    : {res['energy_total_uj']:.4f} uJ ({res['energy_per_token_uj']:.4f} uJ/token)")

        avg_throughput = total_tokens / max(1e-6, (total_time_ms * 1e-3))
        avg_energy = total_energy / max(1, total_tokens)
        print("-" * 76)
        print(f"  TARGET [{target.upper()}] SUMMARY:")
        print(f"    Average Throughput   : {avg_throughput:,.0f} tok/s")
        print(f"    Average Energy/Token : {avg_energy:.4f} uJ/token")
        print(f"    Active Compute Power : {QUAD_CORE_POWER_MW:.2f} mW (vs 700 W GPU -> 14,200x efficiency)")
        print(f"    Hardware Multipliers : ZERO (100% Add/Sub/Shift Silicon)")

    print("=" * 76 + "\n")


def cmd_info(args):
    print("=" * 76)
    print("   BITNET-130 HARDWARE ARCHITECTURE & SILICON SPECIFICATION")
    print("=" * 76)
    print("  Silicon Macro       : bitnet_gen2_accelerator_top.sv")
    print("  Physical Nodes      : SkyWater Sky130 (130nm) | Nangate Open Cell 45nm")
    print("  Signoff Frequencies : 50 MHz (SkyWater 130) | 500 MHz (Nangate 45)")
    print("  Processing Elements : 256 PEs (Quad-Core Clustered Tensor Engine)")
    print("  Arithmetic Pipeline : Multiplier-Free Conditional Sign Inversion {-1, 0, +1}")
    print("  Hardware Multipliers: ZERO (0 DSP48 / 0 Hard Multipliers)")
    print("  Power Rails         :")
    print("    * Active Burst    : 49.2 mW @ 500 MHz (2.0 ns)")
    print("    * Active Eco      : 12.3 mW @ 125 MHz (OSPI DMA streaming)")
    print("    * Deep Retention  : 14.8 uW @ 0 MHz (SRAM KV cache preserved)")
    print("  Memory Subsystem    : Octal-SPI 200 MB/s Burst DMA Engine")
    print("  On-Chip Attention   : Hardware-Fused Online FlashAttention-3 (O(1) SRAM)")
    print("  On-Chip Normalizer  : Multiplier-Free Reciprocal RMSNorm Engine")
    print("  Interconnect        : 4-Virtual-Channel QoS 2D Mesh NoC Router")
    print("  Host Bridge Board   : USB-C Carrier Board (Raspberry Pi RP2040 Dual ARM M0+)")
    print("  Firmware Microcode  : bitnet_stream.pio (50 MSamples/sec Line-Rate DMA)")
    print("  Compiler Framework  : PyTorch 2.0 TorchDynamo / TorchFX ('bitnet130')")
    print("----------------------------------------------------------------------------")
    print("  FRONTIER MODEL ARCHITECTURAL SUPPORT MATRIX:")
    print("    1. Llama 3 / 3.1 / 3.2  : RoPE (theta 500k), GQA, SwiGLU MLP")
    print("    2. Qwen 2 / 2.5         : RoPE (theta 1M), GQA, QKV Bias, SwiGLU")
    print("    3. Mistral / Mixtral    : RoPE, GQA, Sliding Window Attention, SwiGLU")
    print("    4. Gemma 2              : GeGLU, RMSNorm unit offset, Logit Soft-Capping")
    print("    5. DeepSeek V2 / V3     : Multi-Head Latent Attention (MLA) Low-Rank Proj")
    print("=" * 76 + "\n")


def main():
    parser = argparse.ArgumentParser(
        prog="bitnet",
        description="BitNet-130 AI Co-Processor Command Line Interface"
    )
    subparsers = parser.add_subparsers(dest="command", help="Available subcommands")

    # convert
    p_conv = subparsers.add_parser("convert", help="Convert & quantize frontier model to .bitnet silicon package")
    p_conv.add_argument("--model", type=str, required=True, choices=SUPPORTED_ARCHS, help="Frontier architecture")
    p_conv.add_argument("--weights", type=str, default=None, help="Path to PyTorch checkpoint / state dict")
    p_conv.add_argument("--output", type=str, default=None, help="Output .bitnet binary file path")
    p_conv.add_argument("--full-scale", action="store_true", help="Compile production full-scale configuration")

    # chat
    p_chat = subparsers.add_parser("chat", help="Start interactive conversational chat session")
    p_chat.add_argument("--model", type=str, default="bitnet-130m", help="Model variant or frontier architecture")
    p_chat.add_argument("--temp", type=float, default=0.7, help="Sampling temperature")
    p_chat.add_argument("--max-tokens", type=int, default=30, help="Max tokens per turn")

    # serve
    p_serve = subparsers.add_parser("serve", help="Launch local OpenAI-compatible REST API server")
    p_serve.add_argument("--host", type=str, default="0.0.0.0", help="Host address")
    p_serve.add_argument("--port", type=int, default=8080, help="Port to listen on")
    p_serve.add_argument("--model", type=str, default="bitnet-130m", help="Model variant or frontier architecture")

    # benchmark
    p_bench = subparsers.add_parser("benchmark", help="Run silicon throughput and energy benchmarks")
    p_bench.add_argument("--model", type=str, default="all", help="Model variant, frontier architecture, or 'all'")

    # info
    subparsers.add_parser("info", help="Display physical silicon specifications and PPA")

    args = parser.parse_args()

    if args.command == "convert":
        cmd_convert(args)
    elif args.command == "chat":
        cmd_chat(args)
    elif args.command == "serve":
        cmd_serve(args)
    elif args.command == "benchmark":
        cmd_benchmark(args)
    elif args.command == "info":
        cmd_info(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
