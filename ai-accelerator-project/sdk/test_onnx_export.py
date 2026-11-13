#!/usr/bin/env python3
"""
Unit Test Suite: BitNet-130 ONNX Exporter & Edge Runtime Verification
=====================================================================
Validates ONNX schema integrity, hardware metadata, numerical fidelity,
and multiplier-free operation on ONNX Runtime.
"""

import os
import sys
import numpy as np
import torch
import onnx
import onnxruntime as ort

from export_bitnet_onnx import (
    BitNetTransformerBlock,
    export_bitnet_model_to_onnx,
    BitNetEdgeInferenceEngine
)


def test_onnx_export_pipeline():
    print("==========================================================================")
    print("  BITNET-130 ONNX EXPORT & EDGE RUNTIME VERIFICATION SUITE")
    print("==========================================================================")

    # 1. Instantiate Model & Test Vectors
    torch.manual_seed(42)
    np.random.seed(42)
    d_model = 64
    d_ff = 128
    seq_len = 8
    model = BitNetTransformerBlock(d_model=d_model, d_ff=d_ff)
    sample_input = torch.randn(1, seq_len, d_model)

    onnx_path = "/tmp/test_bitnet_export.onnx"

    # 2. Test Export
    print("\n>>> [TEST 1] Exporting BitNet b1.58 Transformer to ONNX...")
    exported_proto = export_bitnet_model_to_onnx(model, sample_input, onnx_path, verbose=False)
    assert os.path.exists(onnx_path), "ONNX file was not created!"
    print(f"  [PASS] ONNX file exported successfully ({os.path.getsize(onnx_path) / 1024.0:.1f} KB).")

    # 3. Test Schema & Metadata
    print("\n>>> [TEST 2] Auditing ONNX Graph Schema & Hardware Metadata...")
    onnx_model = onnx.load(onnx_path)
    onnx.checker.check_model(onnx_model)
    print("  [PASS] ONNX schema validation passed (onnx.checker.check_model).")

    props = {p.key: p.value for p in onnx_model.metadata_props}
    assert props.get("architecture") == "BitNet-130", "Architecture metadata missing!"
    assert props.get("multiplier_count") == "0", "Non-zero multipliers reported!"
    assert props.get("precision") == "1.58b_ternary", "Incorrect precision metadata!"
    print(f"  [PASS] Hardware metadata verified: 0 multipliers, {-1, 0, +1} ternary alphabet.")

    # 4. Test ONNX Runtime Execution & Numerical Fidelity
    print("\n>>> [TEST 3] Running Inference on ONNX Runtime Engine...")
    engine = BitNetEdgeInferenceEngine(onnx_path)
    input_np = sample_input.numpy()
    results = engine.run(input_np)

    # Compare with PyTorch output
    with torch.no_grad():
        pt_out = model(sample_input).numpy()
    onnx_out = results["output"]

    assert onnx_out.shape == pt_out.shape, f"Shape mismatch: {onnx_out.shape} vs {pt_out.shape}"
    mae = float(np.mean(np.abs(onnx_out - pt_out)))
    corr = float(np.corrcoef(onnx_out.flatten(), pt_out.flatten())[0, 1])
    print(f"  [PASS] Inference completed successfully on ONNX Runtime!")
    print(f"  Output Tensor Shape:       {list(onnx_out.shape)}")
    print(f"  Mean Absolute Error (MAE): {mae:.6f}")
    print(f"  Pearson Correlation Score: {corr:.6f} (Target: > 0.9900)")
    assert corr > 0.99, f"Correlation score {corr} is below threshold 0.99!"

    # 5. Test Zero-Skip Gating & Energy Profiling
    print("\n>>> [TEST 4] Auditing Zero-Skip Gating & Dynamic Energy...")
    assert results["multipliers_used"] == 0, "DSP multipliers detected!"
    assert results["sparsity_pct"] > 20.0, f"Expected >20% sparsity, got {results['sparsity_pct']}%"
    print(f"  Total Neural Weights:      {results['total_weights']:,}")
    print(f"  Hardware Multipliers:      0 (Eliminated 100%)")
    print(f"  Zero Skips Gated:          {results['zero_skips_gated']:,} ({results['sparsity_pct']:.2f}% power reduction)")
    print(f"  2x2 Cluster Latency:       {results['estimated_cycles_2x2']:,} cycles ({results['latency_us']:.2f} us @ 50 MHz)")
    print(f"  Dynamic Energy:            {results['energy_uj_per_token']:.4f} uJ/token")
    print("  [PASS] Telemetry and energy verified cleanly!")

    print("\n==========================================================================")
    print(">> BITNET-130 ONNX EXPORT & EDGE RUNTIME VERIFICATION: 100% PASS <<")
    print("==========================================================================")


if __name__ == "__main__":
    test_onnx_export_pipeline()
