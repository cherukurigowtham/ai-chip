#!/usr/bin/env python3
"""
Golden Software Reference for BitNet b1.58 End-to-End Transformer Block.
Executes:
  1. Layer 1: X (8x8) @ W1 (8x8) -> Z1
  2. On-Chip VAU: A1 = SiLU_PWL(Z1) with INT16 Saturated Quantization
  3. 1-Cycle Shadow Swap: Switch to W2 (8x8)
  4. Layer 2: A1 (8x8) @ W2 (8x8) -> Output Z2
"""

import numpy as np

np.random.seed(1337)

def pwl_silu(x):
    """Piecewise-Linear SiLU matching the hardware VAU."""
    x = np.int64(x)
    out = np.zeros_like(x)
    
    mask1 = x <= -8192
    mask2 = (x > -8192) & (x < 0)
    mask3 = (x >= 0) & (x < 8192)
    mask4 = x >= 8192
    
    out[mask1] = 0
    out[mask2] = (x[mask2] >> 2)
    out[mask3] = (x[mask3] >> 1) + (x[mask3] >> 2)
    out[mask4] = x[mask4]
    
    # Saturated INT16 clamp
    return np.clip(out, -32768, 32767).astype(np.int16)

def generate_transformer_golden():
    # 8 Tokens with 8-dimensional embedding
    X = np.random.randint(-1000, 1001, size=(8, 8), dtype=np.int16)
    
    # Ternary weights for Layer 1 (Bank A) and Layer 2 (Bank B)
    W1 = np.random.choice([-1, 0, 1], size=(8, 8), p=[0.25, 0.50, 0.25]).astype(np.int8)
    W2 = np.random.choice([-1, 0, 1], size=(8, 8), p=[0.30, 0.40, 0.30]).astype(np.int8)
    
    # Layer 1 GEMM
    Z1 = np.dot(X.astype(np.int32), W1.astype(np.int32))
    
    # Layer 1 Activation (SwiGLU SiLU)
    A1 = pwl_silu(Z1)
    
    # Layer 2 GEMM (using intermediate activations A1)
    Z2 = np.dot(A1.astype(np.int32), W2.astype(np.int32))
    
    print("=== Transformer Golden Reference Computed ===")
    print(f"Input X shape:  {X.shape} | Range: [{np.min(X)}, {np.max(X)}]")
    print(f"Layer 1 Z1 range: [{np.min(Z1)}, {np.max(Z1)}]")
    print(f"Activated A1 range: [{np.min(A1)}, {np.max(A1)}]")
    print(f"Layer 2 Z2 range: [{np.min(Z2)}, {np.max(Z2)}]")
    
    return X, W1, W2, Z1, A1, Z2

if __name__ == "__main__":
    generate_transformer_golden()
