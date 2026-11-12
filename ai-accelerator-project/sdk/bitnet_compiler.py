"""
BitNet b1.58 Silicon Compiler & Runtime SDK
============================================
Translates floating-point neural network models into bit-exact ternary
instructions and DMA memory payloads for the 8x8 BitNet-130 AI Accelerator.

Key Capabilities:
- BitNet 1.58-bit ternary quantization: W in {-1, 0, +1}
- 8.0x compression: 8 ternary weights packed into a single 16-bit word
- Bit-exact hardware piecewise-linear Vector Activation Unit (VAU) modeling
- Ping-pong double-buffering DMA stream generator
- MMIO register driver abstraction for host microcontroller (RP2040/ESP32/PCIe)
"""

import numpy as np
from typing import Tuple, List, Dict, Optional, Union

# Hardware MMIO Register Offsets
REG_CTRL_START         = 0x00
REG_CTRL_DATAFLOW_MODE = 0x04
REG_CFG_M              = 0x08
REG_CFG_K              = 0x0C
REG_CFG_N              = 0x10
REG_CTRL_ACT_MODE      = 0x38
REG_CTRL_WEIGHT_BANK   = 0x3C
REG_CTRL_DOUBLE_BUF    = 0x40

# Activation Modes matching RTL Vector Activation Unit (VAU)
ACT_MODE_BYPASS  = 0  # Linear GEMM output (32-bit accum)
ACT_MODE_RELU    = 1  # Fused ReLU: max(0, x)
ACT_MODE_SILU    = 2  # Fused Piecewise-Linear SiLU: x * sigmoid(x)
ACT_MODE_SAT_I16 = 3  # Saturated INT16 Scaling [-32768, 32767]
ACT_MODE_SOFTMAX = 4  # Fused Fast Softmax Base-2 Exponent (FlashAttention)
ACT_MODE_MX      = 5  # OCP Micro-Scaled (MX) Vector Scaling

# Dataflow Modes matching RTL Dataflow Controller
DATAFLOW_AUTO = 0
DATAFLOW_WS   = 1  # Weight-Stationary
DATAFLOW_OS   = 2  # Output-Stationary


class BitNetCompiler:
    """
    Compiler that maps PyTorch / NumPy weight tensors and activations
    into bit-exact binary layouts for the BitNet-130 systolic array.
    """

    @staticmethod
    def quantize_weights(weights: np.ndarray) -> Tuple[np.ndarray, float]:
        """
        Quantizes floating-point weights into {-1, 0, +1} following official BitNet b1.58:
            gamma = mean(abs(W))
            W_ternary = RoundClip(W / gamma, -1, 1)
        """
        w = np.array(weights, dtype=np.float32)
        gamma = float(np.mean(np.abs(w))) + 1e-8
        scaled_w = w / gamma
        w_ternary = np.clip(np.round(scaled_w), -1.0, 1.0).astype(np.int8)
        return w_ternary, gamma

    @staticmethod
    def pack_ternary_weights(w_ternary_tile: np.ndarray) -> List[int]:
        """
        Packs an 8x8 ternary matrix (8 rows, 8 cols) into 8 x 16-bit packed words.
        Each column PE receives 2 bits:
          00 ->  0
          01 -> +1
          11 -> -1 (or 10 in standard 2's complement 2-bit)
        Bit mapping for column c:
          value = 0  -> 2'b00 (0)
          value = 1  -> 2'b01 (1)
          value = -1 -> 2'b11 (3)
        """
        assert w_ternary_tile.shape == (8, 8), f"Expected 8x8 tile, got {w_ternary_tile.shape}"
        packed_words = []
        for r in range(8):
            word16 = 0
            for c in range(8):
                val = int(w_ternary_tile[r, c])
                if val == 1:
                    code = 0b01
                elif val == -1:
                    code = 0b11
                else:
                    code = 0b00
                word16 |= (code << (c * 2))
            packed_words.append(word16 & 0xFFFF)
        return packed_words

    @staticmethod
    def quantize_activations(activations: np.ndarray, scale: float = 127.0) -> Tuple[np.ndarray, float]:
        """
        Quantizes float activations to signed 16-bit integers [-32768, 32767].
        """
        act = np.array(activations, dtype=np.float32)
        max_abs = float(np.max(np.abs(act))) + 1e-8
        act_scale = 32767.0 / max_abs
        act_int = np.clip(np.round(act * act_scale), -32768, 32767).astype(np.int16)
        return act_int, act_scale

    @staticmethod
    def pack_cs_dma_bitmap(w_ternary_tile: np.ndarray) -> Dict[str, Union[List[int], float, int]]:
        """
        Packs an 8x8 ternary matrix into CS-DMA Mode 01 (Bitmap Compression) bitstream:
          - 4 words (64 bits) of Non-Zero Bitmask
          - Packed words of non-zero ternary values (8 values x 2 bits = 16 bits per word)
        """
        assert w_ternary_tile.shape == (8, 8)
        flat = w_ternary_tile.flatten()
        mask_words = [0, 0, 0, 0]
        nz_vals = []

        for idx, val in enumerate(flat):
            word_idx = idx // 16
            bit_idx = idx % 16
            if val != 0:
                mask_words[word_idx] |= (1 << bit_idx)
                nz_vals.append(val)

        val_words = []
        for i in range(0, len(nz_vals), 8):
            chunk = nz_vals[i:i+8]
            w16 = 0
            for c_idx, c_val in enumerate(chunk):
                code = 0b01 if c_val == 1 else 0b11
                w16 |= (code << (c_idx * 2))
            val_words.append(w16 & 0xFFFF)

        total_words = mask_words + val_words
        raw_words = 8
        comp_ratio = (raw_words * 16) / max(1, len(total_words) * 16)
        return {
            "words": total_words,
            "mask_words": mask_words,
            "val_words": val_words,
            "nonzeros": len(nz_vals),
            "compression_ratio": comp_ratio
        }

    @staticmethod
    def pack_cs_dma_rle(w_ternary_tile: np.ndarray) -> Dict[str, Union[List[int], float, int]]:
        """
        Packs an 8x8 ternary matrix into CS-DMA Mode 10 (Run-Length Encoded) bitstream:
          - 3 entries per 16-bit word: {zero_run[2:0], val[1:0]} (5 bits each)
          - Bit 15 is 1'b1 on the final word.
        """
        assert w_ternary_tile.shape == (8, 8)
        flat = w_ternary_tile.flatten()
        entries = []
        curr_run = 0

        for val in flat:
            if val == 0:
                curr_run += 1
            else:
                while curr_run > 7:
                    # Overflow run if zero stretch exceeds 7
                    entries.append((7, 0))
                    curr_run -= 8
                code = 0b01 if val == 1 else 0b11
                entries.append((curr_run, code))
                curr_run = 0

        # Pack entries 3-per-word
        rle_words = []
        for i in range(0, len(entries), 3):
            chunk = entries[i:i+3]
            is_last = 1 if (i + 3 >= len(entries)) else 0
            w16 = (is_last << 15)
            for e_idx, (z_run, code) in enumerate(chunk):
                entry_val = ((z_run & 0x7) << 2) | (code & 0x3)
                w16 |= (entry_val << (e_idx * 5))
            rle_words.append(w16 & 0xFFFF)

        if not rle_words:
            rle_words = [0x8000]

        comp_ratio = 128.0 / (len(rle_words) * 16.0)
        return {
            "words": rle_words,
            "entries_count": len(entries),
            "compression_ratio": comp_ratio
        }

    @staticmethod
    def hardware_vau_eval(val: int, mode: int) -> int:
        """
        Software golden model of the on-chip Vector Activation Unit (VAU).
        Must match vector_activation_unit.sv with zero floating-point error.
        """
        val = int(val)
        if mode == ACT_MODE_BYPASS:
            return val
        elif mode == ACT_MODE_RELU:
            return val if val > 0 else 0
        elif mode == ACT_MODE_SILU:
            # RTL Hardware PWL SiLU formula:
            # if (x >= 2048)  return x;
            # if (x >= 0)     return (x * 3) / 4;  // slope = 0.75
            # if (x >= -2048) return (x * 1) / 4;  // slope = 0.25
            # else            return 0;
            if val >= 2048:
                return val
            elif val >= 0:
                return (val * 3) // 4
            elif val >= -2048:
                return (val * 1) // 4
            else:
                return 0
        elif mode == ACT_MODE_SAT_I16:
            return max(-32768, min(32767, val))
        elif mode == ACT_MODE_SOFTMAX:
            if val >= 0:
                return 1024
            elif val <= -8192:
                return 0
            else:
                neg_val = -val
                shift_amt = neg_val >> 10
                frac_amt = neg_val & 0x3FF
                return (1024 - ((frac_amt >> 1) + (frac_amt >> 3))) >> shift_amt
        elif mode == ACT_MODE_MX:
            return val >> 3
        return val


class BitNetHardwareEmulator:
    """
    Cycle-accurate and bit-exact emulator for the 8x8 BitNet-130 core.
    Executes multi-layer networks with zero external EDA tool dependencies.
    """

    def __init__(self):
        self.regs = {
            REG_CTRL_START: 0,
            REG_CTRL_DATAFLOW_MODE: DATAFLOW_WS,
            REG_CFG_M: 8,
            REG_CFG_K: 8,
            REG_CFG_N: 8,
            REG_CTRL_ACT_MODE: ACT_MODE_BYPASS,
            REG_CTRL_WEIGHT_BANK: 0,
            REG_CTRL_DOUBLE_BUF: 0,
        }
        self.weight_bank_0 = np.zeros((8, 8), dtype=np.int8)
        self.weight_bank_1 = np.zeros((8, 8), dtype=np.int8)
        self.zero_skips = 0
        self.compute_cycles = 0

    def write_reg(self, addr: int, val: int):
        self.regs[addr] = val

    def load_weight_tile(self, tile: np.ndarray, bank: int = 0):
        assert tile.shape == (8, 8)
        if bank == 0:
            self.weight_bank_0 = tile.copy()
        else:
            self.weight_bank_1 = tile.copy()

    def run_gemm(self, act_tile: np.ndarray) -> np.ndarray:
        """
        Executes an 8x8 GEMM on the active weight bank and applies VAU activation.
        Returns: 8x8 int32 accumulator output.
        """
        assert act_tile.shape == (8, 8)
        active_bank = self.regs[REG_CTRL_WEIGHT_BANK]
        w = self.weight_bank_0 if active_bank == 0 else self.weight_bank_1
        act_mode = self.regs[REG_CTRL_ACT_MODE]

        out = np.zeros((8, 8), dtype=np.int32)
        skips = 0

        # Bit-exact integer systolic accumulation
        for m in range(8):
            for n in range(8):
                accum = 0
                for k in range(8):
                    a_val = int(act_tile[m, k])
                    w_val = int(w[k, n])
                    if a_val == 0 or w_val == 0:
                        skips += 1
                        continue
                    if w_val == 1:
                        accum += a_val
                    elif w_val == -1:
                        accum -= a_val
                # Pass through VAU
                out[m, n] = BitNetCompiler.hardware_vau_eval(accum, act_mode)

        self.zero_skips += skips
        # Systolic timing: Preload + Compute + Array latency + Drain = ~200 cycles per tile
        self.compute_cycles += (8 + 8 + 16 + 64)
        return out
