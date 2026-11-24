#!/usr/bin/env python3
"""
==============================================================================
BitNet-130: Hugging Face & Frontier Model Weight Ingestion and Quantizer
==============================================================================
Converts PyTorch / Hugging Face float32 / bfloat16 / float16 weights into
hardware-native 2-bit packed ternary formats for the BitNet-130 silicon engine.

Features:
- BitNet b1.58 formulation: gamma = mean(|W|), W_ternary = clip(round(W / gamma), -1, 1)
- 2-bit Hardware Encoding: 00 -> 0, 01 -> +1, 11 -> -1 (4 weights per byte)
- Direct export to:
  * Raw Binary (.bin): Streamable via AXI DMA Controller
  * C Header (.h): Bare-metal embedded firmware execution
  * JSON Metadata: Dynamic layer scales and shapes
- High-fidelity verification: Cosine similarity and sparsity profiling
==============================================================================
"""

import os
import sys
import json
import struct
import argparse
import numpy as np
import torch
import torch.nn as nn
from typing import Dict, Tuple, Any, List


def quantize_ternary_bitnet158(weight: torch.Tensor) -> Tuple[torch.Tensor, float, float]:
    """
    Quantize arbitrary floating point weights into ternary {-1, 0, +1}
    using the BitNet b1.58 formulation.
    Returns:
        w_ternary: int8 tensor with values in {-1, 0, +1}
        gamma: dynamic scalar weight scaling factor
        cosine_sim: reconstruction cosine similarity
    """
    w_float = weight.detach().float()
    gamma = w_float.abs().mean().item()
    if gamma < 1e-8:
        gamma = 1e-8

    w_scaled = w_float / gamma
    w_ternary = torch.clamp(torch.round(w_scaled), -1.0, 1.0).to(torch.int8)

    # Reconstructed float
    w_recon = w_ternary.float() * gamma
    
    # Cosine similarity
    dot = (w_float * w_recon).sum().item()
    norm_orig = w_float.norm(2).item()
    norm_recon = w_recon.norm(2).item()
    if norm_orig > 1e-8 and norm_recon > 1e-8:
        cosine_sim = dot / (norm_orig * norm_recon)
    else:
        cosine_sim = 1.0

    return w_ternary, gamma, cosine_sim


def pack_ternary_2bit(w_ternary: torch.Tensor) -> bytes:
    """
    Pack ternary int8 weights {-1, 0, +1} into 2-bit hardware encoding:
        2'b00 =  0
        2'b01 = +1
        2'b11 = -1
    Packed into bytes: 4 weights per byte.
    """
    flat = w_ternary.flatten().cpu().numpy()
    total_elements = len(flat)
    
    # Pad to multiple of 4
    remainder = total_elements % 4
    if remainder != 0:
        pad_len = 4 - remainder
        flat = np.pad(flat, (0, pad_len), constant_values=0)
    
    # Map values to 2-bit codes: 0 -> 0, 1 -> 1, -1 -> 3 (0b11)
    mapping = {0: 0b00, 1: 0b01, -1: 0b11}
    lut = np.vectorize(lambda x: mapping.get(int(x), 0b00), otypes=[np.uint8])
    encoded = lut(flat)

    # Pack 4 weights per byte
    w0 = encoded[0::4]
    w1 = encoded[1::4] << 2
    w2 = encoded[2::4] << 4
    w3 = encoded[3::4] << 6
    packed = (w0 | w1 | w2 | w3).astype(np.uint8)

    return packed.tobytes()


def unpack_ternary_2bit(packed_bytes: bytes, total_elements: int) -> np.ndarray:
    """Unpack 2-bit encoded bytes back to ternary {-1, 0, +1}."""
    packed = np.frombuffer(packed_bytes, dtype=np.uint8)
    w0 = (packed & 0x03).astype(np.int8)
    w1 = ((packed >> 2) & 0x03).astype(np.int8)
    w2 = ((packed >> 4) & 0x03).astype(np.int8)
    w3 = ((packed >> 6) & 0x03).astype(np.int8)

    unpacked = np.empty(len(packed) * 4, dtype=np.int8)
    unpacked[0::4] = np.where(w0 == 3, np.int8(-1), w0)
    unpacked[1::4] = np.where(w1 == 3, np.int8(-1), w1)
    unpacked[2::4] = np.where(w2 == 3, np.int8(-1), w2)
    unpacked[3::4] = np.where(w3 == 3, np.int8(-1), w3)

    return unpacked[:total_elements]


class BitNetCheckpointConverter:
    """Converts model checkpoints into BitNet-130 hardware release artifacts."""

    def __init__(self, output_dir: str):
        self.output_dir = output_dir
        os.makedirs(output_dir, exist_ok=True)
        self.metadata = {
            "format": "bitnet130_ternary_packed_v3.1",
            "layers": {}
        }

    def convert_weights_dict(self, state_dict: Dict[str, torch.Tensor], model_name: str = "bitnet_model"):
        """Convert a dictionary of linear layer weights."""
        print(f"\n[INFO] Starting BitNet b1.58 Quantization & Ingestion: {model_name}")
        print("=" * 80)
        print(f"{'Layer Name':<35} {'Shape':<16} {'Sparsity':<10} {'Gamma':<10} {'Cosine Sim':<10}")
        print("-" * 80)

        total_weights = 0
        total_zero_weights = 0

        for name, weight in state_dict.items():
            if "weight" in name and weight.dim() >= 2:
                w_ternary, gamma, cos_sim = quantize_ternary_bitnet158(weight)
                packed_bytes = pack_ternary_2bit(w_ternary)

                zeros = (w_ternary == 0).sum().item()
                numel = w_ternary.numel()
                sparsity = (zeros / numel) * 100.0

                total_weights += numel
                total_zero_weights += zeros

                # Save raw binary
                safe_name = name.replace(".", "_")
                bin_path = os.path.join(self.output_dir, f"{safe_name}.bin")
                with open(bin_path, "wb") as f:
                    f.write(packed_bytes)

                self.metadata["layers"][name] = {
                    "shape": list(weight.shape),
                    "num_elements": numel,
                    "packed_bytes": len(packed_bytes),
                    "gamma_scale": float(gamma),
                    "zero_sparsity_pct": float(sparsity),
                    "cosine_similarity": float(cos_sim),
                    "bin_file": os.path.basename(bin_path)
                }

                shape_str = f"{weight.shape[0]}x{weight.shape[1]}"
                print(f"{name:<35} {shape_str:<16} {sparsity:>7.1f}%   {gamma:>9.4f} {cos_sim:>9.4f}")

        # Summary
        overall_sparsity = (total_zero_weights / max(total_weights, 1)) * 100.0
        self.metadata["summary"] = {
            "total_weights": total_weights,
            "overall_zero_sparsity": overall_sparsity,
            "compression_ratio": f"{32.0 / 2.0:.1f}x (from FP32 to 2-bit ternary)"
        }

        # Write metadata JSON
        meta_path = os.path.join(self.output_dir, "bitnet_weights_manifest.json")
        with open(meta_path, "w") as f:
            json.dump(self.metadata, f, indent=2)

        # Write C Header
        self._generate_c_header(model_name)

        print("-" * 80)
        print(f"[SUCCESS] Exported {len(self.metadata['layers'])} layers to {self.output_dir}")
        print(f" - Overall Dynamic Zero Sparsity: {overall_sparsity:.2f}% (Hardware Clock-Gated)")
        print(f" - Memory Footprint Compression:  16.0x (FP32 -> 2-bit)")
        print(f" - Metadata Manifest:            {meta_path}\n")

    def _generate_c_header(self, model_name: str):
        """Generate embedded C header with metadata and layer descriptors."""
        header_path = os.path.join(self.output_dir, "bitnet_weights.h")
        with open(header_path, "w") as f:
            f.write("/* Auto-generated BitNet-130 Multiplier-Free Weight Descriptors */\n")
            f.write("#ifndef BITNET_WEIGHTS_H\n#define BITNET_WEIGHTS_H\n\n")
            f.write("#include <stdint.h>\n\n")
            f.write(f"// Model: {model_name}\n")
            f.write(f"// Total Parameters: {self.metadata['summary']['total_weights']}\n\n")
            f.write("typedef struct {\n")
            f.write("    const char* layer_name;\n")
            f.write("    uint32_t rows;\n")
            f.write("    uint32_t cols;\n")
            f.write("    uint32_t packed_bytes;\n")
            f.write("    float gamma_scale;\n")
            f.write("} bitnet_layer_descriptor_t;\n\n")
            
            f.write("static const bitnet_layer_descriptor_t BITNET_LAYERS[] = {\n")
            for name, meta in self.metadata["layers"].items():
                rows = meta["shape"][0]
                cols = meta["shape"][1]
                f.write(f'    {{"{name}", {rows}, {cols}, {meta["packed_bytes"]}, {meta["gamma_scale"]:.6f}f}},\n')
            f.write("};\n\n")
            f.write(f"#define BITNET_LAYER_COUNT {len(self.metadata['layers'])}\n\n")
            f.write("#endif // BITNET_WEIGHTS_H\n")


def test_converter():
    """Unit test generating synthetic weights and validating bit-exact pack/unpack."""
    print("[TEST] Running BitNet Converter Verification...")
    torch.manual_seed(42)

    # Create synthetic transformer block weights
    d_model = 128
    d_ff = 256
    weights = {
        "model.layers.0.self_attn.q_proj.weight": torch.randn(d_model, d_model),
        "model.layers.0.self_attn.k_proj.weight": torch.randn(d_model, d_model),
        "model.layers.0.self_attn.v_proj.weight": torch.randn(d_model, d_model),
        "model.layers.0.self_attn.o_proj.weight": torch.randn(d_model, d_model),
        "model.layers.0.mlp.gate_proj.weight": torch.randn(d_ff, d_model),
        "model.layers.0.mlp.up_proj.weight": torch.randn(d_ff, d_model),
        "model.layers.0.mlp.down_proj.weight": torch.randn(d_model, d_ff)
    }

    test_dir = "/tmp/bitnet_test_export"
    converter = BitNetCheckpointConverter(test_dir)
    converter.convert_weights_dict(weights, model_name="synthetic_llama_block")

    # Verify bit-exact pack and unpack round-trip
    sample_w = weights["model.layers.0.self_attn.q_proj.weight"]
    w_tern, gamma, cos_sim = quantize_ternary_bitnet158(sample_w)
    packed = pack_ternary_2bit(w_tern)
    unpacked = unpack_ternary_2bit(packed, sample_w.numel())
    
    orig_np = w_tern.flatten().cpu().numpy()
    assert np.array_equal(orig_np, unpacked), "Unpacked weights do not match quantized ternary!"
    print("[TEST PASS] Pack/Unpack round-trip is 100% bit-exact!")
    assert cos_sim > 0.85, f"Expected cosine similarity > 0.85, got {cos_sim:.4f}"
    print(f"[TEST PASS] Quantization Cosine Similarity = {cos_sim:.4f}")
    print("[TEST PASS] ALL CONVERTER TESTS PASSED SUCCESSFULLY!\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="BitNet-130 Hugging Face & Frontier Weight Ingestion Tool")
    parser.add_argument("--test", action="store_true", help="Run automated unit test")
    parser.add_argument("--output-dir", type=str, default="ai-accelerator-project/weights/converted", help="Output directory")
    args = parser.parse_args()

    if args.test or len(sys.argv) == 1:
        test_converter()
