"""
ternary_quant.py - Ternary Weight Quantization & Bit-Exact Arithmetic Simulator.

Implements:
1. Ternary Weight Quantization (TWN - Ternary Weight Networks):
   - Computes optimal threshold Delta = 0.7 * E[|W|]
   - Maps continuous weights W to {-1, 0, +1} * alpha
   - Optimal scaling factor alpha = mean_{|W| > Delta}(|W|)
2. Hardware 2-bit Encoding:
   - 2'b00 : Zero (Skip update / operand isolate)
   - 2'b01 : +1   (Add activation)
   - 2'b10 : -1   (Subtract activation)
   - 2'b11 : Reserved / Nop (decoded as 0)
3. Bit-Exact Fixed-Point PE MAC Reference Model:
   - 16-bit signed activations (INT16: [-32768, 32767])
   - 2-bit ternary weights
   - 32-bit signed partial sums (INT32: [-2^31, 2^31 - 1])
"""

import numpy as np
from typing import Tuple, Dict, Any, List

# Hardware 2-bit encoding constants
ENC_ZERO     = 0b00  # 0: Skip update
ENC_POS_ONE  = 0b01  # +1: Add activation
ENC_NEG_ONE  = 0b10  # -1: Subtract activation
ENC_RESERVED = 0b11  # Reserved / NOP (treated as 0)

def quantize_ternary_weights(weights: np.ndarray) -> Tuple[np.ndarray, float, np.ndarray]:
    """
    Quantizes continuous/FP32 weights to ternary {-1, 0, +1} with a full-tensor scaling factor alpha.
    
    Formula:
        Delta = 0.7 * (1/n) * sum(|W_i|)
        W_ternary = +1 if W > Delta
                  = -1 if W < -Delta
                  =  0 if |W| <= Delta
        alpha = (1 / |I_Delta|) * sum_{i in I_Delta} |W_i|
    
    Returns:
        w_ternary: int8 array with values in {-1, 0, +1}
        alpha: float scaling factor
        w_encoded: uint8 array with 2-bit hardware encoding (00, 01, 10)
    """
    abs_w = np.abs(weights)
    delta = 0.7 * np.mean(abs_w)
    
    w_ternary = np.zeros_like(weights, dtype=np.int8)
    w_ternary[weights > delta] = 1
    w_ternary[weights < -delta] = -1
    
    non_zeros = np.abs(w_ternary) > 0
    if np.sum(non_zeros) > 0:
        alpha = float(np.mean(abs_w[non_zeros]))
    else:
        alpha = 1.0

    # Map to 2-bit hardware encoding
    w_encoded = np.zeros_like(weights, dtype=np.uint8)
    w_encoded[w_ternary == 1]  = ENC_POS_ONE  # 0b01
    w_encoded[w_ternary == -1] = ENC_NEG_ONE  # 0b10
    w_encoded[w_ternary == 0]  = ENC_ZERO     # 0b00
    
    return w_ternary, alpha, w_encoded

def decode_hardware_weight(code: int) -> int:
    """Decodes a 2-bit hardware weight into signed ternary integer (-1, 0, 1)."""
    code = code & 0x3
    if code == ENC_POS_ONE:
        return 1
    elif code == ENC_NEG_ONE:
        return -1
    else:
        return 0

def bit_exact_pe_step(
    act_in: int,
    weight_code: int,
    psum_in: int,
    enable: bool = True,
    weight_load: bool = False,
    weight_in_code: int = 0,
    current_w_reg: int = 0
) -> Tuple[int, int, int, Dict[str, Any]]:
    """
    Cycle-accurate, bit-exact hardware model of the Ternary Processing Element.
    
    Inputs:
        act_in: 16-bit signed activation (-32768 to 32767)
        weight_code: 2-bit encoded current stationary weight (stored in w_reg)
        psum_in: 32-bit signed partial sum (-2^31 to 2^31 - 1)
        enable: clock enable
        weight_load: latch new stationary weight
        weight_in_code: 2-bit code to latch into w_reg
        current_w_reg: current 2-bit code in w_reg
        
    Returns:
        next_w_reg: updated 2-bit weight register
        act_out: registered activation output (16-bit signed)
        psum_out: registered partial sum output (32-bit signed)
        telemetry: execution telemetry (zero_skipped, operation, effective_addend)
    """
    # Clamp inputs to bit-widths
    act_16 = np.int16(act_in)
    psum_32 = np.int32(psum_in)
    w_reg = current_w_reg & 0x3
    
    if weight_load:
        w_reg = weight_in_code & 0x3
        
    w_val = decode_hardware_weight(w_reg)
    zero_skipped = (w_val == 0)
    
    if w_val == 1:
        effective_addend = np.int32(act_16)
        op_str = "ADD"
    elif w_val == -1:
        effective_addend = np.int32(-int(act_16))
        op_str = "SUB"
    else:
        effective_addend = np.int32(0)
        op_str = "SKIP"
        
    next_psum = np.int32(psum_32 + effective_addend)
    
    telemetry = {
        "op": op_str,
        "zero_skipped": zero_skipped,
        "weight_val": w_val,
        "effective_addend": int(effective_addend)
    }
    
    if not enable:
        # Frozen state
        return current_w_reg, 0, 0, {"op": "STALL", "zero_skipped": True, "weight_val": 0, "effective_addend": 0}
        
    return w_reg, int(act_16), int(next_psum), telemetry
