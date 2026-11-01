"""
ternary_gemm_sim.py - Matrix Multiplication Simulator comparing:
1. FP32 Continuous Reference
2. INT16 Binary Baseline (16-bit MAC)
3. Ternary Weight Quantization (2-bit weight {-1, 0, +1} * alpha, 16-bit activation)

Measures:
- Cosine Similarity & Relative Error
- Sparsity & Zero-skip rate
- Estimated Arithmetic Switching Reduction
"""

import numpy as np
from ternary_quant import quantize_ternary_weights, decode_hardware_weight

def run_gemm_benchmark(m: int = 64, k: int = 64, n: int = 64, seed: int = 42):
    np.random.seed(seed)
    
    # Generate realistic weight and activation distributions (Gaussian / standard normal)
    W_fp32 = np.random.randn(k, n).astype(np.float32) * 0.1
    A_fp32 = np.random.randn(m, k).astype(np.float32)
    
    # 1. FP32 Reference Output
    Y_fp32 = np.matmul(A_fp32, W_fp32)
    
    # 2. Binary INT16 Baseline
    # Quantize activations to INT16
    a_scale = 32767.0 / (np.max(np.abs(A_fp32)) + 1e-8)
    A_int16 = np.clip(np.round(A_fp32 * a_scale), -32768, 32767).astype(np.int16)
    
    # Quantize weights to INT16
    w_scale = 32767.0 / (np.max(np.abs(W_fp32)) + 1e-8)
    W_int16 = np.clip(np.round(W_fp32 * w_scale), -32768, 32767).astype(np.int16)
    
    # Integer MAC computation with 32-bit accumulator
    Y_int32 = np.matmul(A_int16.astype(np.int32), W_int16.astype(np.int32))
    Y_int16_dequant = Y_int32 / (a_scale * w_scale)
    
    # 3. Ternary Weight Quantization
    W_ternary, alpha, W_encoded = quantize_ternary_weights(W_fp32)
    
    # Hardware bit-exact ternary systolic array output:
    # A_int16 (16-bit) x W_ternary ({-1, 0, 1}) -> INT32 accumulator
    Y_ternary_int32 = np.matmul(A_int16.astype(np.int32), W_ternary.astype(np.int32))
    
    # Scaled output to compare against FP32
    Y_ternary_dequant = (Y_ternary_int32 / a_scale) * alpha
    
    # Accuracy and Numerical Quality Metrics
    cos_sim_int16 = np.dot(Y_fp32.flatten(), Y_int16_dequant.flatten()) / (
        np.linalg.norm(Y_fp32.flatten()) * np.linalg.norm(Y_int16_dequant.flatten())
    )
    cos_sim_ternary = np.dot(Y_fp32.flatten(), Y_ternary_dequant.flatten()) / (
        np.linalg.norm(Y_fp32.flatten()) * np.linalg.norm(Y_ternary_dequant.flatten())
    )
    
    nmse_ternary = np.mean((Y_fp32 - Y_ternary_dequant) ** 2) / np.var(Y_fp32)
    
    # Hardware efficiency metrics
    zero_weights = np.sum(W_ternary == 0)
    pos_weights = np.sum(W_ternary == 1)
    neg_weights = np.sum(W_ternary == -1)
    total_weights = W_ternary.size
    sparsity_pct = (zero_weights / total_weights) * 100.0
    
    # Memory footprint comparison
    binary_weight_bits = total_weights * 16
    ternary_weight_bits = total_weights * 2
    bandwidth_compression = binary_weight_bits / ternary_weight_bits  # 8x compression!
    
    results = {
        "m": m, "k": k, "n": n,
        "total_ops": m * k * n,
        "sparsity_pct": sparsity_pct,
        "zero_weight_count": int(zero_weights),
        "pos_weight_count": int(pos_weights),
        "neg_weight_count": int(neg_weights),
        "cosine_sim_int16": float(cos_sim_int16),
        "cosine_sim_ternary": float(cos_sim_ternary),
        "nmse_ternary": float(nmse_ternary),
        "bandwidth_compression_factor": float(bandwidth_compression),
        "binary_weight_kbytes": binary_weight_bits / 8192.0,
        "ternary_weight_kbytes": ternary_weight_bits / 8192.0,
    }
    return results

if __name__ == "__main__":
    res = run_gemm_benchmark(64, 64, 64)
    print("=" * 60)
    print("  TERNARY WEIGHT QUANTIZATION & GEMM SIMULATION RESULTS")
    print("=" * 60)
    for k, v in res.items():
        if isinstance(v, float):
            print(f"  {k:30s}: {v:10.4f}")
        else:
            print(f"  {k:30s}: {v}")
    print("=" * 60)
