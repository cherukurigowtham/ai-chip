#!/usr/bin/env python3
"""
Unit tests for the BitNet-130 First-Principles Silicon Performance & Roofline Profiler.
"""

import unittest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bitnet_performance_profiler import (
    BitNetPerformanceProfiler, PLATFORMS, WORKLOADS, HardwareConfig, ModelWorkload
)


class TestBitNetPerformanceProfiler(unittest.TestCase):

    def test_01_platforms_and_workloads_registered(self):
        """Verify standard silicon platforms and model workloads are loaded."""
        self.assertIn("bitnet-quad", PLATFORMS)
        self.assertIn("bitnet-x16", PLATFORMS)
        self.assertIn("llama-3.2-1b", WORKLOADS)
        self.assertIn("bitnet-edge-70m", WORKLOADS)

    def test_02_roofline_operational_intensity_surge(self):
        """Verify ternary representation achieves 8x operational intensity over FP16."""
        quad = PLATFORMS["bitnet-quad"]
        llama = WORKLOADS["llama-3.2-1b"]

        res_ternary = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=1, use_cs_dma=False
        )
        # Intensity I = 2 * N / (0.25 * N) ~ 8.0 Ops/Byte
        self.assertGreaterEqual(res_ternary["operational_intensity_ops_per_byte"], 7.0)

    def test_03_cs_dma_sparsity_acceleration(self):
        """Verify CS-DMA zero-skipping reduces transferred bytes and increases throughput."""
        quad = PLATFORMS["bitnet-quad"]
        llama = WORKLOADS["llama-3.2-1b"]

        res_dense = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=1, use_cs_dma=False, use_speculative=False
        )
        res_sparse = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=1, use_cs_dma=True, use_speculative=False
        )

        self.assertLess(res_sparse["transferred_mb"], res_dense["transferred_mb"])
        self.assertGreater(res_sparse["throughput_tokens_per_sec"], res_dense["throughput_tokens_per_sec"])

    def test_04_speculative_decoding_speedup(self):
        """Verify speculative decoding micro-core accelerates token generation."""
        quad = PLATFORMS["bitnet-quad"]
        llama = WORKLOADS["llama-3.2-1b"]

        res_normal = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=1, use_speculative=False
        )
        res_spec = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=1, use_speculative=True, speculative_speedup=3.90
        )

        speedup = res_spec["throughput_tokens_per_sec"] / res_normal["throughput_tokens_per_sec"]
        self.assertAlmostEqual(speedup, 3.90, delta=0.05)

    def test_05_prefill_compute_saturation(self):
        """Verify prompt prefill (M=512) achieves 100% compute saturation."""
        quad = PLATFORMS["bitnet-quad"]
        llama = WORKLOADS["llama-3.2-1b"]

        res_prefill = BitNetPerformanceProfiler.compute_roofline(
            quad, llama, batch_size=1, prompt_len=512
        )
        self.assertEqual(res_prefill["regime"], "COMPUTE-BOUND (Silicon Limited)")
        self.assertEqual(res_prefill["saturation_pct"], 100.0)

    def test_06_reports_generation(self):
        """Verify formatting of comparative Roofline and Waterfall reports."""
        roofline_rep = BitNetPerformanceProfiler.generate_roofline_summary("llama-3.2-1b")
        waterfall_rep = BitNetPerformanceProfiler.generate_speedup_breakdown("llama-3.2-1b")

        self.assertIn("ROOFLINE ANALYSIS", roofline_rep)
        self.assertIn("BitNet-X16", roofline_rep)
        self.assertIn("WATERFALL", waterfall_rep)
        self.assertIn("NET SILICON ACCELERATION", waterfall_rep)


if __name__ == "__main__":
    unittest.main()
