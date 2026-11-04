// ==============================================================================
// Source: ternary_accelerator_driver.c
// Description: Implementation of Host C Driver for 8x8 Ternary AI Accelerator
// ==============================================================================

#include "ternary_accelerator_driver.h"
#include <stdio.h>
#include <string.h>

// AXI DMA Direct Register Map (Simplified Simple Mode DMA)
#define DMA_MM2S_DMACR         0x00
#define DMA_MM2S_DMASR         0x04
#define DMA_MM2S_SA            0x18
#define DMA_MM2S_LENGTH        0x28

#define DMA_S2MM_DMACR         0x30
#define DMA_S2MM_DMASR         0x34
#define DMA_S2MM_DA            0x48
#define DMA_S2MM_LENGTH        0x58

#define DMA_CR_RS              0x00000001
#define DMA_CR_RESET           0x00000004
#define DMA_SR_IDLE            0x00000002

int ternary_accel_init(ternary_accel_t *dev, void *mmio_vaddr, void *dma_mm2s_vaddr, void *dma_s2mm_vaddr) {
    if (!dev || !mmio_vaddr) return -1;
    dev->mmio_base     = (volatile uint32_t *)mmio_vaddr;
    dev->dma_mm2s_base = (volatile uint32_t *)dma_mm2s_vaddr;
    dev->dma_s2mm_base = (volatile uint32_t *)dma_s2mm_vaddr;
    dev->total_zero_skips = 0;
    dev->total_cycles     = 0;
    return 0;
}

int ternary_pack_weights(const int8_t *w_in, uint16_t *w_packed, int rows, int cols) {
    if (!w_in || !w_packed || (cols % 8 != 0)) return -1;

    for (int r = 0; r < rows; r++) {
        for (int c_blk = 0; c_blk < (cols / 8); c_blk++) {
            uint16_t word = 0;
            for (int b = 0; b < 8; b++) {
                int8_t val = w_in[r * cols + c_blk * 8 + b];
                uint16_t code = 0;
                if (val == 1)       code = 0x1; // 2'b01 (+1)
                else if (val == -1) code = 0x2; // 2'b10 (-1)
                else                code = 0x0; // 2'b00 (0)
                word |= (code << (b * 2));
            }
            w_packed[r * (cols / 8) + c_blk] = word;
        }
    }
    return 0;
}

int ternary_run_tile(ternary_accel_t *dev,
                     const int16_t *act_tile,
                     const uint16_t *packed_w,
                     int32_t *out_tile,
                     uint8_t mode) {
    if (!dev || !act_tile || !packed_w || !out_tile) return -1;

    // 1. Program Matrix Dimensions for single 8x8 tile
    dev->mmio_base[TERNARY_REG_CFG_M / 4] = 8;
    dev->mmio_base[TERNARY_REG_CFG_K / 4] = 8;
    dev->mmio_base[TERNARY_REG_CFG_N / 4] = 8;

    // 2. Program Control: start pulse + dataflow mode
    uint32_t ctrl_val = (mode << 1) | 0x1;
    dev->mmio_base[TERNARY_REG_CTRL / 4] = ctrl_val;

    // 3. Emulate / Wait for completion via status register polling
    // In real hardware with AXI DMA, MM2S and S2MM channels execute here.
    while (dev->mmio_base[TERNARY_REG_STATUS / 4] & 0x1) {
        // Polling busy bit
    }

    // 4. Update telemetry
    dev->total_zero_skips += dev->mmio_base[TERNARY_REG_ZERO_SKIPS / 4];
    dev->total_cycles     += dev->mmio_base[TERNARY_REG_PERF_CYCLES / 4];

    return 0;
}

int ternary_gemm(ternary_accel_t *dev,
                 const int16_t *A,
                 const uint16_t *packed_W,
                 int32_t *C,
                 int M, int K, int N) {
    if (!dev || !A || !packed_W || !C) return -1;
    if ((M % 8 != 0) || (K % 8 != 0) || (N % 8 != 0)) return -2;

    memset(C, 0, sizeof(int32_t) * M * N);

    int16_t act_tile[64];
    uint16_t w_tile[8];
    int32_t out_tile[64];

    // Tiled execution across 8x8 blocks
    for (int ti = 0; ti < M; ti += 8) {
        for (int tj = 0; tj < N; tj += 8) {
            for (int tk = 0; tk < K; tk += 8) {
                // Copy activation tile (8x8)
                for (int r = 0; r < 8; r++) {
                    for (int c = 0; c < 8; c++) {
                        act_tile[r * 8 + c] = A[(ti + r) * K + (tk + c)];
                    }
                }

                // Copy packed weight tile (8 words = 64 weights)
                for (int r = 0; r < 8; r++) {
                    w_tile[r] = packed_W[(tk + r) * (N / 8) + (tj / 8)];
                }

                // Autonomous or selected mode
                uint8_t mode = (K > M) ? DATAFLOW_FORCE_OS : DATAFLOW_FORCE_WS;
                ternary_run_tile(dev, act_tile, w_tile, out_tile, mode);

                // Accumulate partial tile into C
                for (int r = 0; r < 8; r++) {
                    for (int c = 0; c < 8; c++) {
                        C[(ti + r) * N + (tj + c)] += out_tile[r * 8 + c];
                    }
                }
            }
        }
    }
    return 0;
}

uint32_t ternary_get_zero_skips(ternary_accel_t *dev) {
    return dev ? dev->total_zero_skips : 0;
}

uint32_t ternary_get_cycles(ternary_accel_t *dev) {
    return dev ? dev->total_cycles : 0;
}

float ternary_get_sparsity_ratio(ternary_accel_t *dev, int M, int K, int N) {
    if (!dev || M <= 0 || K <= 0 || N <= 0) return 0.0f;
    uint64_t total_ops = (uint64_t)M * K * N;
    return (float)dev->total_zero_skips / (float)total_ops;
}
