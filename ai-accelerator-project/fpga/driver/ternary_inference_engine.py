#!/usr/bin/env python3
"""
==============================================================================
Module: ternary_inference_engine.py
Description: Python Host Runtime & Inference API for 8x8 Ternary AI Accelerator
             Supports BitNet b1.58 Quantized Linear Layers, Tiling, Packing,
             and Hardware Emulation / System Verification.
==============================================================================
"""

import numpy as np
from typing import Tuple, Optional, Dict, Any

class BitNetQuantizer:
    """BitNet b1.58 Ternary Weight Quantizer and 2-Bit Hardware Packer."""

    @staticmethod
    def quantize(weights: np.ndarray) -> Tuple[np.ndarray, float]:
        """
        Quantizes FP32 weights into ternary {-1, 0, +1} using BitNet b1.58 formula:
          scale = mean(abs(weights))
          W_ternary = clip(round(weights / scale), -1, 1)
        """
        scale = float(np.mean(np.abs(weights)))
        if scale == 0:
            scale = 1.0
        w_scaled = weights / scale
        w_quant = np.clip(np.round(w_scaled), -1, 1).astype(np.int8)
        return w_quant, scale

    @staticmethod
    def pack_2bit(w_ternary: np.ndarray) -> np.ndarray:
        """
        Packs (K, N) ternary matrix into 16-bit words (8 weights per word).
        Hardware encoding:
          2'b00:  0
          2'b01: +1
          2'b10: -1
        """
        K, N = w_ternary.shape
        assert N % 8 == 0, f"N={N} must be a multiple of 8"
        packed_words = np.zeros((K, N // 8), dtype=np.uint16)

        for r in range(K):
            for c_blk in range(N // 8):
                word = np.uint16(0)
                for b in range(8):
                    val = w_ternary[r, c_blk * 8 + b]
                    if val == 1:
                        code = 0x1
                    elif val == -1:
                        code = 0x2
                    else:
                        code = 0x0
                    word |= np.uint16(code << (b * 2))
                packed_words[r, c_blk] = word
        return packed_words

    @staticmethod
    def unpack_2bit(packed_words: np.ndarray, K: int, N: int) -> np.ndarray:
        """Unpacks 16-bit words back to (K, N) ternary array."""
        w_unpacked = np.zeros((K, N), dtype=np.int8)
        for r in range(K):
            for c_blk in range(N // 8):
                word = packed_words[r, c_blk]
                for b in range(8):
                    code = (word >> (b * 2)) & 0x3
                    if code == 0x1:
                        w_unpacked[r, c_blk * 8 + b] = 1
                    elif code == 0x2:
                        w_unpacked[r, c_blk * 8 + b] = -1
                    else:
                        w_unpacked[r, c_blk * 8 + b] = 0
        return w_unpacked


class TernaryAcceleratorEngine:
    """
    Host Driver & Hardware Simulator for the 8x8 Ternary Systolic Array SoC.
    Emulates AXI-Lite MMIO, AXI-Stream DMA, WS/OS dynamic selection, and zero-skip telemetry.
    """

    def __init__(self, array_rows: int = 8, array_cols: int = 8):
        self.ROWS = array_rows
        self.COLS = array_cols
        self.total_zero_skips = 0
        self.total_compute_cycles = 0
        self.total_mac_ops = 0

    def reset_telemetry(self):
        self.total_zero_skips = 0
        self.total_compute_cycles = 0
        self.total_mac_ops = 0

    def run_tile_8x8(self, act_tile: np.ndarray, w_packed_tile: np.ndarray, mode: str = "auto") -> np.ndarray:
        """
        Executes a single 8x8 tile on the hardware model.
        act_tile: (8, 8) int16 activations
        w_packed_tile: (8,) uint16 packed weights
        """
        assert act_tile.shape == (8, 8)
        assert w_packed_tile.shape == (8,)

        # Unpack weights to ternary
        w_unpacked = np.zeros((8, 8), dtype=np.int8)
        for r in range(8):
            word = int(w_packed_tile[r])
            for c in range(8):
                code = (word >> (c * 2)) & 0x3
                if code == 0x1:
                    w_unpacked[r, c] = 1
                elif code == 0x2:
                    w_unpacked[r, c] = -1
                else:
                    w_unpacked[r, c] = 0

        # Bit-exact Ternary Matrix Multiply: C = A @ W (int32 accumulation)
        out_tile = np.zeros((8, 8), dtype=np.int32)
        zero_skips = 0
        for m in range(8):
            for n in range(8):
                acc = 0
                for k in range(8):
                    w = int(w_unpacked[k, n])
                    a = int(act_tile[m, k])
                    if w == 0:
                        zero_skips += 1
                    elif w == 1:
                        acc += a
                    elif w == -1:
                        acc -= a
                out_tile[m, n] = acc

        # Update telemetry
        self.total_zero_skips += zero_skips
        self.total_mac_ops += 64 * 8
        # Array latency = ROWS + COLS + M + 1 = 8 + 8 + 8 + 1 = 25 cycles
        self.total_compute_cycles += 25
        return out_tile

    def tiled_gemm(self, activations: np.ndarray, packed_weights: np.ndarray,
                   M: int, K: int, N: int) -> np.ndarray:
        """
        Executes tiled matrix multiplication for arbitrary matrix dimensions:
        C = activations @ unpacked(packed_weights)
        Pads M, K, N to multiples of 8.
        """
        orig_M, orig_N = M, N
        pad_M = (8 - (M % 8)) % 8
        pad_K = (8 - (K % 8)) % 8
        pad_N = (8 - (N % 8)) % 8

        A_padded = np.pad(activations, ((0, pad_M), (0, pad_K)), mode='constant').astype(np.int16)
        W_unpacked = BitNetQuantizer.unpack_2bit(packed_weights, K, N)
        W_padded = np.pad(W_unpacked, ((0, pad_K), (0, pad_N)), mode='constant').astype(np.int8)
        W_packed_padded = BitNetQuantizer.pack_2bit(W_padded)

        M_p, K_p = A_padded.shape
        _, N_p = W_padded.shape
        C_padded = np.zeros((M_p, N_p), dtype=np.int32)

        # Tile across 8x8 blocks
        for ti in range(0, M_p, 8):
            for tj in range(0, N_p, 8):
                accum_tile = np.zeros((8, 8), dtype=np.int32)
                for tk in range(0, K_p, 8):
                    a_chunk = A_padded[ti:ti+8, tk:tk+8]
                    w_chunk = W_packed_padded[tk:tk+8, tj//8]
                    accum_tile += self.run_tile_8x8(a_chunk, w_chunk)
                C_padded[ti:ti+8, tj:tj+8] = accum_tile

        return C_padded[:orig_M, :orig_N]

    def get_telemetry(self) -> Dict[str, Any]:
        sparsity = (self.total_zero_skips / max(1, self.total_mac_ops)) * 100.0
        return {
            "total_mac_ops": self.total_mac_ops,
            "total_zero_skips": self.total_zero_skips,
            "zero_skip_sparsity_percent": round(sparsity, 2),
            "total_compute_cycles": self.total_compute_cycles,
            "throughput_gops_at_100mhz": round((self.total_mac_ops * 2 / max(1, self.total_compute_cycles)) * 0.1, 3)
        }
