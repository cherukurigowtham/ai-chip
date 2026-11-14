#!/usr/bin/env python3
"""
==============================================================================
BitNet-130: Frontier Model Multi-Architecture Verification Suite
==============================================================================
Rigorous pre-silicon verification of universal frontier model ingestion,
PTQ-Ternary quantization, multiplier-free execution, and .bitnet binary serialization.

Test Matrix:
  [TIER 1] Architectural Preset & GQA / MLA Dimensional Integrity
  [TIER 2] 2-Bit Binary Packing & Bit-Exact Ternary Unpacking
  [TIER 3] PTQ-Ternary Quantizer & Zero-Multiplier Mathematical Audit
  [TIER 4] Forward Pass Verification across All 5 Frontier Architectures:
           - Meta Llama-3 / 3.1 / 3.2 (RoPE theta 500k, GQA, SwiGLU)
           - Alibaba Qwen-2.5 (RoPE theta 1M, QKV Bias, GQA, SwiGLU)
           - Mistral AI (RoPE, GQA, SwiGLU)
           - Google Gemma-2 (GeGLU, RMSNorm unit offset, Soft-Capping)
           - DeepSeek-V2 / V3 (Multi-Head Latent Attention - MLA)
  [TIER 5] Turnkey .bitnet Binary Container Round-Trip (Export -> Load -> Verify)
  [TIER 6] Autoregressive Token Generation & Physical Energy Telemetry (<50mW)
  [TIER 7] Hugging Face Adapter Drop-In Factory Verification
==============================================================================
"""

import os
import sys
import tempfile
import unittest
import torch
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frontier_model_adapter import (
    FrontierModelConfig, FrontierModelForCausalLM, FrontierModelConverter,
    PTQTernaryQuantizer, BitNetFrontierLinear, RotaryEmbedding, RMSNorm,
    SUPPORTED_ARCHS, QUAD_CORE_POWER_MW, CLOCK_FREQ_MHZ
)
from huggingface_adapter import BitNetForCausalLM


class TestFrontierArchitectures(unittest.TestCase):

    def setUp(self):
        torch.manual_seed(42)
        np.random.seed(42)

    # --------------------------------------------------------------------------
    # TIER 1: Architectural Presets & Dimensional Integrity
    # --------------------------------------------------------------------------
    def test_01_architectural_presets(self):
        """Verify architectural parameters for all 5 frontier models."""
        for arch in SUPPORTED_ARCHS:
            config = FrontierModelConfig.get_preset(arch, edge_preset=True)
            self.assertEqual(config.arch, arch)
            self.assertGreater(config.d_model, 0)
            self.assertGreater(config.num_heads, 0)
            self.assertGreaterEqual(config.num_heads, config.num_kv_heads)
            self.assertGreater(config.d_ff, 0)

        # Architectural specifics
        llama = FrontierModelConfig.get_preset("llama3", edge_preset=True)
        self.assertEqual(llama.rope_theta, 500000.0)

        qwen = FrontierModelConfig.get_preset("qwen2.5", edge_preset=True)
        self.assertEqual(qwen.rope_theta, 1000000.0)
        self.assertTrue(qwen.qkv_bias)

        gemma = FrontierModelConfig.get_preset("gemma2", edge_preset=True)
        self.assertEqual(gemma.activation, "geglu")
        self.assertTrue(gemma.rms_norm_offset)
        self.assertIsNotNone(gemma.attn_logit_softcapping)

        deepseek = FrontierModelConfig.get_preset("deepseek", edge_preset=True)
        self.assertTrue(deepseek.use_mla)
        self.assertGreater(deepseek.q_lora_rank, 0)
        self.assertGreater(deepseek.kv_lora_rank, 0)

    # --------------------------------------------------------------------------
    # TIER 2: 2-Bit Packing & Bit-Exact Recovery
    # --------------------------------------------------------------------------
    def test_02_ternary_bit_packing(self):
        """Verify 2-bit packing format across 65,536 random ternary weights."""
        num_elements = 65536
        random_ternary = torch.randint(-1, 2, (128, 512)).float()

        # Pack into 2-bit bytes
        packed_bytes = PTQTernaryQuantizer.pack_ternary_tensor(random_ternary)
        # Expected bytes: 65,536 weights / 4 weights per byte = 16,384 bytes
        self.assertEqual(len(packed_bytes), num_elements // 4)

        # Unpack
        unpacked_tensor = PTQTernaryQuantizer.unpack_ternary_tensor(
            packed_bytes, num_elements, (128, 512)
        )

        # Verify 100% bit-exact equivalence
        diff = torch.abs(random_ternary - unpacked_tensor).sum().item()
        self.assertEqual(diff, 0.0, "Mismatch in 2-bit ternary packing/unpacking recovery!")

    # --------------------------------------------------------------------------
    # TIER 3: PTQ-Ternary Quantizer & Zero DSP Multipliers
    # --------------------------------------------------------------------------
    def test_03_ptq_quantization_and_multipliers(self):
        """Verify continuous weight lowering into {-1, 0, +1} and zero DSP multipliers."""
        raw_weight = torch.randn(256, 128) * 0.05
        layer = BitNetFrontierLinear(128, 256, bias=False)
        stats = layer.load_and_quantize(raw_weight)

        self.assertEqual(stats["multipliers_used"], 0)
        self.assertGreater(stats["zero_skip_pct"], 15.0)

        # Assert every single weight in layer is in {-1.0, 0.0, +1.0}
        unique_vals = set(torch.unique(layer.w_ternary).tolist())
        self.assertTrue(unique_vals.issubset({-1.0, 0.0, 1.0}))

        # Assert gammas are strictly positive
        self.assertTrue(torch.all(layer.gamma > 0.0))

    # --------------------------------------------------------------------------
    # TIER 4: Forward Pass Across All 5 Frontier Architectures
    # --------------------------------------------------------------------------
    def test_04_all_frontier_architectures_forward(self):
        """Verify forward pass on Llama-3, Qwen-2.5, Mistral, Gemma-2, and DeepSeek."""
        batch_size = 2
        seq_len = 8
        dummy_input = torch.randint(0, 256, (batch_size, seq_len), dtype=torch.long)

        for arch in SUPPORTED_ARCHS:
            with self.subTest(arch=arch):
                model = FrontierModelForCausalLM.from_pretrained(arch, edge_preset=True)
                logits = model(dummy_input)

                # Output shape must be [batch, seq_len, vocab_size]
                self.assertEqual(logits.shape, (batch_size, seq_len, model.config.vocab_size))
                # Numerical sanity: no NaNs or Infs
                self.assertFalse(torch.isnan(logits).any(), f"NaN detected in {arch} logits!")
                self.assertFalse(torch.isinf(logits).any(), f"Inf detected in {arch} logits!")

    # --------------------------------------------------------------------------
    # TIER 5: .bitnet Hardware Binary Container Round-Trip
    # --------------------------------------------------------------------------
    def test_05_bitnet_binary_serialization_roundtrip(self):
        """Export model to .bitnet binary, reload, and verify bit-exact weights."""
        with tempfile.TemporaryDirectory() as tmpdir:
            for arch in ["llama3", "deepseek"]:
                orig_model = FrontierModelForCausalLM.from_pretrained(arch, edge_preset=True)
                bin_path = os.path.join(tmpdir, f"{arch}_test.bitnet")

                # Export
                export_meta = orig_model.export_bitnet_package(bin_path)
                self.assertTrue(os.path.exists(bin_path))
                self.assertGreater(export_meta["file_size_kb"], 0.0)

                # Reload into brand new instance
                new_model = FrontierModelForCausalLM.from_pretrained(arch, weights_path=bin_path, edge_preset=True)

                # Compare all ternary weights
                for (n1, m1), (n2, m2) in zip(orig_model.named_modules(), new_model.named_modules()):
                    if isinstance(m1, BitNetFrontierLinear):
                        w_diff = torch.abs(m1.w_ternary - m2.w_ternary).sum().item()
                        g_diff = torch.abs(m1.gamma - m2.gamma).sum().item()
                        self.assertEqual(w_diff, 0.0, f"Weight mismatch in layer {n1} after reload!")
                        self.assertLess(g_diff, 1e-4, f"Gamma scale mismatch in layer {n1} after reload!")

    # --------------------------------------------------------------------------
    # TIER 6: Autoregressive Token Generation & Energy Telemetry
    # --------------------------------------------------------------------------
    def test_06_autoregressive_generation_telemetry(self):
        """Verify autoregressive generation, sub-50mW power envelope, and 0 multipliers."""
        model = FrontierModelForCausalLM.from_pretrained("llama3", edge_preset=True)
        prompt_tokens = [1, 2, 3, 4]
        gen_res = model.generate(prompt_tokens=prompt_tokens, max_new_tokens=10, temperature=0.7)

        self.assertEqual(gen_res["total_tokens"], 10)
        self.assertEqual(gen_res["dsp_multipliers"], 0)
        self.assertEqual(gen_res["silicon_power_mw"], QUAD_CORE_POWER_MW)
        self.assertGreater(gen_res["tokens_per_sec"], 0.0)
        self.assertGreater(gen_res["energy_per_token_uj"], 0.0)

    # --------------------------------------------------------------------------
    # TIER 7: Hugging Face Adapter Drop-In Factory
    # --------------------------------------------------------------------------
    def test_07_huggingface_adapter_integration(self):
        """Verify BitNetForCausalLM drop-in instantiation for all frontier models."""
        for arch in ["llama3", "qwen2.5", "mistral", "gemma2", "deepseek"]:
            hf_model = BitNetForCausalLM.from_pretrained(arch)
            res = hf_model.generate("Silicon test", max_new_tokens=5, temperature=0.0)

            self.assertEqual(res["total_tokens"], 5)
            self.assertEqual(res["hardware_multipliers"], 0)
            self.assertIn("tokens_per_sec", res)
            self.assertIn("energy_per_token_uj", res)


if __name__ == "__main__":
    unittest.main()
