#!/usr/bin/env python3
"""
==============================================================================
Module: ternary_pynq_overlay.py
Description: Physical PYNQ-Z2 / ZedBoard Hardware Overlay Driver for the
             8x8 Ternary AI Accelerator SoC.
             Directly controls physical AXI DMA and MMIO registers via PYNQ APIs.
==============================================================================
"""

import time
import numpy as np
from typing import Tuple, Dict, Any

try:
    from pynq import Overlay, allocate
    PYNQ_AVAILABLE = True
except ImportError:
    PYNQ_AVAILABLE = False
    print("[WARNING] PYNQ package not installed on host machine. Running in emulation mode.")


class TernaryPYNQOverlay:
    """
    Production Hardware Overlay Driver for PYNQ-Z2 / ZedBoard.
    Manages physical bitstream loading, contiguous DMA buffers, and AXI-Lite MMIO.
    """

    def __init__(self, bitstream_path: str = "ternary_pynq_soc.bit"):
        self.bitstream_path = bitstream_path
        if PYNQ_AVAILABLE:
            print(f"[PYNQ] Loading bitstream: {bitstream_path} ...")
            self.overlay = Overlay(bitstream_path)
            self.dma = self.overlay.axi_dma
            self.accel = self.overlay.accel_0
            print("[PYNQ] Bitstream programmed successfully.")
        else:
            self.overlay = None
            self.dma = None
            self.accel = None

    def run_tile_dma(self, act_tile: np.ndarray, packed_weights: np.ndarray) -> np.ndarray:
        """
        Executes a single 8x8 tile GEMM over physical AXI DMA:
        1. Allocates physically contiguous non-cached buffers (CMA).
        2. Transfers weights and activations via DMA MM2S channel.
        3. Programs AXI-Lite MMIO to trigger autonomous systolic execution.
        4. Receives 64 accumulated output words via DMA S2MM channel.
        """
        assert act_tile.shape == (8, 8), "Activation tile must be 8x8"
        assert packed_weights.shape == (8,), "Weights must be 8x packed words"

        if not PYNQ_AVAILABLE:
            # Fallback bit-exact software emulation if run off-board
            w_unpacked = np.zeros((8, 8), dtype=np.int8)
            for r in range(8):
                word = int(packed_weights[r])
                for c in range(8):
                    code = (word >> (c * 2)) & 0x3
                    if code == 0x1:
                        w_unpacked[r, c] = 1
                    elif code == 0x2:
                        w_unpacked[r, c] = -1
                    else:
                        w_unpacked[r, c] = 0
            return np.matmul(act_tile.astype(np.int32), w_unpacked.astype(np.int32))

        # 1. Allocate contiguous DMA buffers
        # Ingress: 4 words weights (32-bit) + 32 words activations (32-bit) = 36x 32-bit words
        in_buf = allocate(shape=(36,), dtype=np.uint32)
        out_buf = allocate(shape=(64,), dtype=np.int32)

        # Pack weights into first 4 32-bit DMA words
        for w in range(4):
            val0 = int(packed_weights[w * 2])
            val1 = int(packed_weights[w * 2 + 1])
            in_buf[w] = (val1 << 16) | (val0 & 0xFFFF)

        # Pack activations into next 32 32-bit DMA words
        buf_idx = 4
        for m in range(8):
            for k in range(0, 8, 2):
                a0 = int(act_tile[m, k]) & 0xFFFF
                a1 = int(act_tile[m, k + 1]) & 0xFFFF
                in_buf[buf_idx] = (a1 << 16) | a0
                buf_idx += 1

        # 2. Configure AXI-Lite MMIO dimensions (M=8, K=8, N=8)
        self.accel.write(0x08, 8)
        self.accel.write(0x0C, 8)
        self.accel.write(0x10, 8)

        # 3. Arm DMA Receive Channel (S2MM)
        self.dma.recvchannel.transfer(out_buf)

        # 4. Trigger Accelerator Start (Control = 0x03 -> WS mode, Start)
        self.accel.write(0x00, 0x03)

        # 5. Send Ingress Stream (MM2S)
        self.dma.sendchannel.transfer(in_buf)
        self.dma.sendchannel.wait()

        # 6. Wait for DMA Receive & Accelerator Completion
        self.dma.recvchannel.wait()

        # Read back results
        result = np.array(out_buf).reshape((8, 8))

        # Free contiguous buffers
        in_buf.freebuffer()
        out_buf.freebuffer()

        return result

    def get_board_telemetry(self) -> Dict[str, Any]:
        """Queries hardware performance counters via AXI-Lite."""
        if not PYNQ_AVAILABLE:
            return {"zero_skips": 0, "cycles": 0, "status": 0}

        status_val = self.accel.read(0x04)
        zero_skips = self.accel.read(0x20)
        cycles = self.accel.read(0x24)
        return {
            "status": status_val,
            "zero_skips": zero_skips,
            "cycles": cycles
        }
