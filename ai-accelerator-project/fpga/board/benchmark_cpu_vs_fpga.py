#!/usr/bin/env python3
"""
==============================================================================
Benchmark: benchmark_cpu_vs_fpga.py
Description: Physical Board Comparison Harness for PYNQ-Z2 / ZedBoard.
             Compares ARM Cortex-A9 Host CPU baseline against the 8x8 Ternary
             Accelerator FPGA Overlay across latency, throughput, and energy.
==============================================================================
"""

import time
import os
import sys
from typing import Tuple
import numpy as np

# Add driver directory
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../driver")))
from ternary_inference_engine import BitNetQuantizer
from ternary_pynq_overlay import TernaryPYNQOverlay

def run_cpu_baseline(activations: np.ndarray, weights_ternary: np.ndarray, iterations: int = 50) -> Tuple[float, np.ndarray]:
    """Measures Host CPU execution time (ARM Cortex-A9 on Zynq-7000)."""
    # Warmup
    _ = np.matmul(activations.astype(np.int32), weights_ternary.astype(np.int32))

    t_start = time.perf_counter()
    for _ in range(iterations):
        c_cpu = np.matmul(activations.astype(np.int32), weights_ternary.astype(np.int32))
    t_end = time.perf_counter()

    avg_latency_ms = ((t_end - t_start) / iterations) * 1000.0
    return avg_latency_ms, c_cpu

def run_fpga_benchmark(overlay: TernaryPYNQOverlay,
                       activations: np.ndarray,
                       packed_weights: np.ndarray,
                       M: int, K: int, N: int,
                       iterations: int = 50) -> Tuple[float, np.ndarray]:
    """Measures physical FPGA Accelerator execution time over physical AXI DMA."""
    # Warmup
    _ = overlay.run_tile_dma(activations[:8, :8], packed_weights[:8, 0])

    t_start = time.perf_counter()
    for _ in range(iterations):
        # Tiled execution over physical DMA
        c_fpga = np.zeros((M, N), dtype=np.int32)
        for ti in range(0, M, 8):
            for tj in range(0, N, 8):
                accum_tile = np.zeros((8, 8), dtype=np.int32)
                for tk in range(0, K, 8):
                    act_tile = activations[ti:ti+8, tk:tk+8]
                    w_chunk = packed_weights[tk:tk+8, tj//8]
                    accum_tile += overlay.run_tile_dma(act_tile, w_chunk)
                c_fpga[ti:ti+8, tj:tj+8] = accum_tile
    t_end = time.perf_counter()

    avg_latency_ms = ((t_end - t_start) / iterations) * 1000.0
    return avg_latency_ms, c_fpga

def main():
    print("===============================================================")
    print("  PHYSICAL BOARD COMPARISON: ARM CORTEX-A9 CPU vs FPGA TERNARY")
    print("  Target Platform: PYNQ-Z2 (Zynq-7000 xc7z020) @ 100 MHz")
    print("===============================================================")

    M, K, N = 32, 128, 128
    total_macs = M * K * N
    total_ops  = total_macs * 2

    # Generate synthetic BitNet workload
    np.random.seed(123)
    activations = np.random.randint(-500, 500, size=(M, K), dtype=np.int16)
    weights_fp32 = np.random.randn(K, N).astype(np.float32)
    weights_ternary, _ = BitNetQuantizer.quantize(weights_fp32)
    packed_weights = BitNetQuantizer.pack_2bit(weights_ternary)

    print(f"Workload Shape: [{M} x {K}] @ [{K} x {N}] ({total_macs:,} MACs)")

    # 1. Run CPU Baseline
    print("\n--- Running ARM Cortex-A9 Host CPU Baseline ---")
    cpu_latency_ms, c_cpu = run_cpu_baseline(activations, weights_ternary, iterations=50)
    cpu_gops = (total_ops / (cpu_latency_ms * 1e-3)) / 1e9
    print(f"  CPU Latency:    {cpu_latency_ms:.3f} ms")
    print(f"  CPU Throughput: {cpu_gops:.3f} GOPS")

    # 2. Run FPGA Overlay
    print("\n--- Running 8x8 Ternary Accelerator FPGA Overlay ---")
    overlay = TernaryPYNQOverlay("ternary_pynq_soc.bit")
    fpga_latency_ms, c_fpga = run_fpga_benchmark(overlay, activations, packed_weights, M, K, N, iterations=50)
    fpga_gops = (total_ops / (fpga_latency_ms * 1e-3)) / 1e9
    speedup = cpu_latency_ms / max(1e-6, fpga_latency_ms)

    print(f"  FPGA Latency:    {fpga_latency_ms:.3f} ms")
    print(f"  FPGA Throughput: {fpga_gops:.3f} GOPS")
    print(f"  Hardware Speedup: {speedup:.2f}x over Host CPU")

    # Verification
    match = np.array_equal(c_cpu, c_fpga)
    max_err = np.max(np.abs(c_cpu - c_fpga))
    print(f"\nVerification: {'PASS (Bit-Exact Match)' if match else 'FAIL'} (Max Error: {max_err})")

    # 3. Electrical Power & Energy Estimation
    # On PYNQ-Z2: Dual-core Cortex-A9 active power is typically ~1.8 W - 2.5 W
    # PL Fabric VCCINT active power for this 8x8 ternary design is ~0.15 W - 0.25 W
    print("\n--- Board-Level Electrical Power & Energy Metrics ---")
    print("  [Note: Replace default power values below with live multimeter/PMBus readings]")
    p_cpu_w = 2.10   # Typical ARM Cortex-A9 active power
    p_fpga_w = 0.22  # Typical PL VCCINT active power (25k LUTs @ 100 MHz)

    energy_cpu_uj = cpu_latency_ms * p_cpu_w
    energy_fpga_uj = fpga_latency_ms * p_fpga_w
    energy_efficiency_gain = energy_cpu_uj / max(1e-6, energy_fpga_uj)

    print(f"  Host CPU Estimated Energy per Inference:  {energy_cpu_uj:.2f} uJ")
    print(f"  FPGA PL Estimated Energy per Inference:   {energy_fpga_uj:.2f} uJ")
    print(f"  Estimated Energy Efficiency Gain:         {energy_efficiency_gain:.2f}x")
    print("===============================================================")

if __name__ == "__main__":
    main()
