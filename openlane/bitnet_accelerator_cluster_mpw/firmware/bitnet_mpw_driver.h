// ==============================================================================
// Header: bitnet_mpw_driver.h
// Description: Production-Grade Bare-Metal C SDK / Driver for SkyWater Sky130
//              BitNet Gen-3 Silicon Ultra-Macro on Efabless Caravel SoC.
// ==============================================================================

#ifndef BITNET_MPW_DRIVER_H
#define BITNET_MPW_DRIVER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Base address in Caravel Wishbone memory map
#define BITNET_BASE_ADDR            0x30000000UL

// Register Memory Map Offsets
#define BITNET_REG_CTRL             (BITNET_BASE_ADDR + 0x00)
#define BITNET_REG_SPEC_CTRL        (BITNET_BASE_ADDR + 0x04)
#define BITNET_REG_SPEEDUP_Q8       (BITNET_BASE_ADDR + 0x08)
#define BITNET_REG_SPARSE_DOT       (BITNET_BASE_ADDR + 0x0C)
#define BITNET_REG_ACCUM_OUT_0      (BITNET_BASE_ADDR + 0x10)
#define BITNET_REG_ACCUM_OUT_1      (BITNET_BASE_ADDR + 0x14)
#define BITNET_REG_KV_STATUS        (BITNET_BASE_ADDR + 0x18)
#define BITNET_REG_ZERO_SKIPS       (BITNET_BASE_ADDR + 0x20)
#define BITNET_REG_SYS_STATUS       (BITNET_BASE_ADDR + 0x24)
#define BITNET_REG_NOC_INJECT       (BITNET_BASE_ADDR + 0x30)

// Precision Mode Constants
#define BITNET_PRECISION_TERNARY    0x00 // 1.58-bit {-1, 0, +1}
#define BITNET_PRECISION_INT8       0x01 // 8-bit integer
#define BITNET_PRECISION_INT16      0x02 // 16-bit high-precision

// DVFS Power States
#define BITNET_PWR_BURST            0x00
#define BITNET_PWR_ECO              0x01
#define BITNET_PWR_RETENTION        0x02
#define BITNET_PWR_SLEEP            0x03

// Core Driver API
void     bitnet_init(void);
void     bitnet_set_precision(uint8_t precision);
void     bitnet_enable_systolic(bool enable, bool mode_os);
void     bitnet_clear_accumulators(void);

// 2:4 Semi-Structured Sparsity Engine
int32_t  bitnet_sparse_2_4_dot(uint8_t w0, uint8_t w1, uint8_t pattern, int16_t act0, int16_t act1);

// Autonomous Speculative Decoding Co-Processor
bool     bitnet_trigger_speculation(uint8_t *committed_count_out);
float    bitnet_get_effective_speedup(void);

// Interconnect & Power Telemetry
bool     bitnet_is_d2d_link_up(void);
uint8_t  bitnet_get_power_state(void);
uint32_t bitnet_get_zero_skips(void);
uint8_t  bitnet_get_kv_sequence_len(void);

#ifdef __cplusplus
}
#endif

#endif // BITNET_MPW_DRIVER_H
