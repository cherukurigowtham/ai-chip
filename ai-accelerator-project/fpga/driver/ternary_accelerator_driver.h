// ==============================================================================
// Header: ternary_accelerator_driver.h
// Description: Host C Driver for 8x8 Ternary AI Accelerator FPGA Prototype
//              Supports Xilinx Zynq-7000 (ARM Cortex-A9) and Zynq MPSoC (A53)
// ==============================================================================

#ifndef TERNARY_ACCELERATOR_DRIVER_H
#define TERNARY_ACCELERATOR_DRIVER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Register Offsets (AXI4-Lite Slave MMIO)
#define TERNARY_REG_CTRL         0x00  // [0]: start, [2:1]: mode (01: WS, 10: OS, 00: Auto)
#define TERNARY_REG_STATUS       0x04  // [0]: busy, [1]: done, [2]: active_dataflow (0:WS, 1:OS)
#define TERNARY_REG_CFG_M        0x08  // Activation rows M
#define TERNARY_REG_CFG_K        0x0C  // Reduction dimension K
#define TERNARY_REG_CFG_N        0x10  // Weight columns N
#define TERNARY_REG_TILE_M       0x14  // Tile M
#define TERNARY_REG_TILE_K       0x18  // Tile K
#define TERNARY_REG_TILE_N       0x1C  // Tile N
#define TERNARY_REG_ZERO_SKIPS   0x20  // Telemetry: Total Zero-Skips tracked
#define TERNARY_REG_PERF_CYCLES  0x24  // Hardware Execution Cycles

// Dataflow Modes
#define DATAFLOW_AUTO            0x00
#define DATAFLOW_FORCE_WS        0x01
#define DATAFLOW_FORCE_OS        0x02

// Driver Context Handle
typedef struct {
    volatile uint32_t *mmio_base;
    volatile uint32_t *dma_mm2s_base; // AXI DMA MM2S (Host -> Accel)
    volatile uint32_t *dma_s2mm_base; // AXI DMA S2MM (Accel -> Host)
    uint32_t total_zero_skips;
    uint32_t total_cycles;
} ternary_accel_t;

// Initialization
int ternary_accel_init(ternary_accel_t *dev, void *mmio_vaddr, void *dma_mm2s_vaddr, void *dma_s2mm_vaddr);

// 2-Bit Ternary Weight Packing Helper
// Packs signed ternary values (-1, 0, +1) into 2-bit codes:
//   00 -> 0,  01 -> +1,  10 -> -1
int ternary_pack_weights(const int8_t *w_in, uint16_t *w_packed, int rows, int cols);

// Execute a single 8x8 tile GEMM
int ternary_run_tile(ternary_accel_t *dev,
                     const int16_t *act_tile,     // 8x8 activations (16-bit)
                     const uint16_t *packed_w,    // 8x8 packed weights (8x 16-bit words)
                     int32_t *out_tile,           // 8x8 outputs (32-bit)
                     uint8_t mode);

// High-Level Tiled GEMM: arbitrary (M x K) @ (K x N)
int ternary_gemm(ternary_accel_t *dev,
                 const int16_t *A,                // M x K activations
                 const uint16_t *packed_W,        // K x N packed weights
                 int32_t *C,                      // M x N outputs
                 int M, int K, int N);

// Telemetry & Profiling
uint32_t ternary_get_zero_skips(ternary_accel_t *dev);
uint32_t ternary_get_cycles(ternary_accel_t *dev);
float ternary_get_sparsity_ratio(ternary_accel_t *dev, int M, int K, int N);

#ifdef __cplusplus
}
#endif

#endif // TERNARY_ACCELERATOR_DRIVER_H
