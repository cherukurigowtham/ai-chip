#!/usr/bin/env python3
"""
==============================================================================
Benchmark: run_quantized_mlp.py
Description: End-to-End Real Quantized MLP / Linear Layer Workload Benchmark
             on the 8x8 Ternary AI Accelerator FPGA Prototype.
             Executes multi-layer BitNet b1.58 inference across 8x8 tiles,
             verifying 100% bit-exact correctness against pure software reference,
             measuring zero-skipping telemetry, latency, and throughput.
==============================================================================
"""

import sys
import os
import time
import numpy as np

# Add driver directory to sys.path
driver_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../driver"))
if driver_path not in sys.path:
    sys.path.append(driver_path)

from ternary_inference_engine import BitNetQuantizer, TernaryAcceleratorEngine

def test_single_layer(engine: TernaryAcceleratorEngine,
                      batch_size: int,
                      in_features: int,
                      out_features: int,
                      layer_name: str) -> dict:
    print(f"\n---------------------------------------------------------------")
    print(f"  Running Layer: {layer_name} [Batch={batch_size}, In={in_features}, Out={out_features}]")
    print(f"---------------------------------------------------------------")

    # 1. Generate activations (16-bit signed integer range)
    np.random.seed(42 + in_features)
    activations = np.random.randint(-500, 500, size=(batch_size, in_features), dtype=np.int16)

    # 2. Generate FP32 weights and quantize via BitNet b1.58
    weights_fp32 = np.random.randn(in_features, out_features).astype(np.float32)
    weights_ternary, scale = BitNetQuantizer.quantize(weights_fp32)

    num_zeros = np.sum(weights_ternary == 0)
    num_pos = np.sum(weights_ternary == 1)
    num_neg = np.sum(weights_ternary == -1)
    total_weights = weights_ternary.size
    print(f"  [Weights] Total: {total_weights} | Zeros: {num_zeros} ({num_zeros/total_weights*100:.1f}%) | "
          f"+1: {num_pos} ({num_pos/total_weights*100:.1f}%) | -1: {num_neg} ({num_neg/total_weights*100:.1f}%)")

    # 3. Pack weights into 2-bit format (16-bit words)
    packed_weights = BitNetQuantizer.pack_2bit(weights_ternary)
    compression_ratio = (total_weights * 16) / (packed_weights.size * 16)
    print(f"  [Memory] Compressed to {packed_weights.nbytes} bytes ({compression_ratio:.1f}x compression)")

    # 4. Golden Software Reference: Integer Matrix Multiply
    t0_ref = time.perf_counter()
    golden_output = np.matmul(activations.astype(np.int32), weights_ternary.astype(np.int32))
    t1_ref = time.perf_counter()

    # 5. Hardware Accelerator Tiled Execution
    engine.reset_telemetry()
    t0_accel = time.perf_counter()
    hw_output = engine.tiled_gemm(activations, packed_weights, batch_size, in_features, out_features)
    t1_accel = time.perf_counter()

    # 6. Verify Bit-Exact Match
    match = np.array_equal(golden_output, hw_output)
    max_diff = np.max(np.abs(golden_output - hw_output))
    telemetry = engine.get_telemetry()

    if match:
        print(f"  [VERIFICATION] PASSED: 100% BIT-EXACT MATCH across all {golden_output.size} outputs! (Max diff: {max_diff})")
    else:
        print(f"  [VERIFICATION] FAILED: Output mismatch detected! (Max diff: {max_diff})")
        sys.exit(1)

    print(f"  [Telemetry] Total MAC Ops: {telemetry['total_mac_ops']:,}")
    print(f"  [Telemetry] Zero-Skips:    {telemetry['total_zero_skips']:,} ({telemetry['zero_skip_sparsity_percent']}% sparsity savings)")
    print(f"  [Telemetry] Compute Clock Cycles: {telemetry['total_compute_cycles']:,}")
    print(f"  [Telemetry] FPGA Throughput (at 100 MHz): {telemetry['throughput_gops_at_100mhz']} GOPS")

    return {
        "layer": layer_name,
        "batch": batch_size,
        "in": in_features,
        "out": out_features,
        "mac_ops": telemetry["total_mac_ops"],
        "zero_skips": telemetry["total_zero_skips"],
        "sparsity_percent": telemetry["zero_skip_sparsity_percent"],
        "cycles": telemetry["total_compute_cycles"],
        "throughput_gops": telemetry["throughput_gops_at_100mhz"],
        "verified": match
    }

def main():
    print("===============================================================")
    print("  PHASE 10: QUANTIZED NEURAL NETWORK INFERENCE BENCHMARK")
    print("  Architecture: 8x8 Ternary Systolic Array SoC")
    print("  Quantization: BitNet b1.58 {-1, 0, +1} with 2-bit packing")
    print("  Target Clock: 100 MHz (FPGA) / 500 MHz (ASIC signoff)")
    print("===============================================================")

    engine = TernaryAcceleratorEngine(array_rows=8, array_cols=8)

    # Multi-layer network architecture (MLP / Transformer FFN projection block)
    layers = [
        (32, 128, 128, "Layer 1: FFN Projection (128 -> 128)"),
        (32, 128, 64,  "Layer 2: Bottleneck Down-Projection (128 -> 64)"),
        (32, 64,  128, "Layer 3: Hidden Up-Projection (64 -> 128)"),
        (16, 256, 128, "Layer 4: Wide Linear Layer (256 -> 128)")
    ]

    results = []
    for batch, in_f, out_f, name in layers:
        res = test_single_layer(engine, batch, in_f, out_f, name)
        results.append(res)

    print("\n===============================================================")
    print("  BENCHMARK SUMMARY ACROSS ALL LAYERS")
    print("===============================================================")
    print(f"{'Layer Name':<42} | {'MAC Ops':<10} | {'Zero-Skips':<10} | {'Sparsity':<9} | {'Cycles':<8} | {'Status'}")
    print("-" * 96)
    total_ops = 0
    total_skips = 0
    total_cyc = 0
    for r in results:
        status_str = "PASS (Bit-Exact)" if r["verified"] else "FAIL"
        print(f"{r['layer']:<42} | {r['mac_ops']:<10,d} | {r['zero_skips']:<10,d} | {r['sparsity_percent']:>7.1f}% | {r['cycles']:<8,d} | {status_str}")
        total_ops += r["mac_ops"]
        total_skips += r["zero_skips"]
        total_cyc += r["cycles"]

    overall_sparsity = (total_skips / total_ops) * 100.0
    overall_throughput_100mhz = (total_ops * 2 / total_cyc) * 0.1
    overall_throughput_500mhz = overall_throughput_100mhz * 5.0

    print("-" * 96)
    print(f"{'TOTAL / OVERALL':<42} | {total_ops:<10,d} | {total_skips:<10,d} | {overall_sparsity:>7.1f}% | {total_cyc:<8,d} | ALL PASSED")
    print(f"\n  Peak Throughput at 100 MHz (FPGA): {overall_throughput_100mhz:.2f} GOPS")
    print(f"  Peak Throughput at 500 MHz (ASIC): {overall_throughput_500mhz:.2f} GOPS")
    print(f"  Average Zero-Skip Energy Savings:  {overall_sparsity:.1f}%")
    print("===============================================================")

if __name__ == "__main__":
    main()
