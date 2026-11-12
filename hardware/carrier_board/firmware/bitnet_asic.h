/**
 * @file bitnet_asic.h
 * @brief Embedded Firmware Driver for BitNet-130 AI Accelerator
 *        Target Platform: Raspberry Pi RP2040 (Dual ARM Cortex-M0+ @ 133 MHz)
 *        Interface: 28-Pin High-Speed GPIO / PIO Streaming Bus
 */

#ifndef BITNET_ASIC_H
#define BITNET_ASIC_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// MMIO Control Registers
#define REG_CTRL_START         0x00
#define REG_CTRL_DATAFLOW_MODE 0x04
#define REG_CFG_M              0x08
#define REG_CFG_K              0x0C
#define REG_CFG_N              0x10
#define REG_CTRL_ACT_MODE      0x38
#define REG_CTRL_WEIGHT_BANK   0x3C
#define REG_CTRL_DOUBLE_BUF    0x40
#define REG_STATUS_BUSY        0x60
#define REG_STATUS_DONE        0x64
#define REG_TELEMETRY_SKIPS    0x70
#define REG_PERF_CYCLES        0x74

// Activation Modes (matching on-chip VAU)
typedef enum {
    ACT_MODE_BYPASS  = 0, // Linear 32-bit GEMM
    ACT_MODE_RELU    = 1, // Fused ReLU: max(0, x)
    ACT_MODE_SILU    = 2, // Fused Piecewise-Linear SiLU / SwiGLU
    ACT_MODE_SAT_I16 = 3, // Saturated INT16 Scaling [-32768, 32767]
    ACT_MODE_SOFTMAX = 4, // Fused Fast Base-2 Softmax Attention
    ACT_MODE_MX      = 5  // OCP Micro-Scaling Block Dequantization
} bitnet_act_mode_t;

// Dataflow Selection
typedef enum {
    DATAFLOW_AUTO = 0,
    DATAFLOW_WS   = 1, // Weight-Stationary (Best for small M)
    DATAFLOW_OS   = 2  // Output-Stationary (Best for deep K)
} bitnet_dataflow_t;

// Telemetry Snapshot Struct
typedef struct {
    uint32_t total_cycles;
    uint32_t zero_skips;
    float    power_saving_pct;
    float    latency_us;
} bitnet_telemetry_t;

/**
 * @brief Initializes RP2040 GPIOs, PIO state machines, and power rails.
 */
void bitnet_init(void);

/**
 * @brief Hardware resets the BitNet-130 ASIC via rst_n pin.
 */
void bitnet_hardware_reset(void);

/**
 * @brief Writes a 32-bit value to an ASIC MMIO register.
 */
void bitnet_write_reg(uint8_t addr, uint32_t val);

/**
 * @brief Reads a 32-bit value from an ASIC MMIO register.
 */
uint32_t bitnet_read_reg(uint8_t addr);

/**
 * @brief Preloads an 8x8 ternary weight tile into Bank A (0) or Bank B (1).
 * @param packed_words 8x 16-bit packed ternary words (8 weights per word).
 * @param bank 0 for Bank A, 1 for Bank B.
 */
void bitnet_load_weights(const uint16_t packed_words[8], uint8_t bank);

/**
 * @brief Streams input activations, executes GEMM, and captures output logits.
 * @param act_in 64x int16 input activations.
 * @param act_mode Activation function mode.
 * @param bank Active weight bank to multiply against.
 * @param out_buf Buffer to store 64x int32 output results.
 */
void bitnet_execute_tile(const int16_t act_in[64], bitnet_act_mode_t act_mode, uint8_t bank, int32_t out_buf[64]);

/**
 * @brief Reads hardware performance and dynamic energy zero-skip telemetry.
 */
void bitnet_get_telemetry(bitnet_telemetry_t *telemetry);

#ifdef __cplusplus
}
#endif

#endif // BITNET_ASIC_H
