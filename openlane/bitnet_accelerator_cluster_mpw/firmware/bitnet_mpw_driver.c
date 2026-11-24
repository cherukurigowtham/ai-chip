// ==============================================================================
// Source: bitnet_mpw_driver.c
// Description: Implementation of Bare-Metal Driver for BitNet Gen-3 Silicon Macro.
// ==============================================================================

#include "bitnet_mpw_driver.h"

#ifndef REG_READ32
#define REG_READ32(addr) (*((volatile uint32_t *)(addr)))
#endif

#ifndef REG_WRITE32
#define REG_WRITE32(addr, val) (*((volatile uint32_t *)(addr)) = (val))
#endif

void bitnet_init(void) {
    REG_WRITE32(BITNET_REG_CTRL, 0x00000000);
    bitnet_clear_accumulators();
}

void bitnet_set_precision(uint8_t precision) {
    uint32_t val = REG_READ32(BITNET_REG_CTRL);
    val &= ~(0x03 << 2);              // Clear bits [3:2]
    val |= ((precision & 0x03) << 2); // Set precision mode
    REG_WRITE32(BITNET_REG_CTRL, val);
}

void bitnet_enable_systolic(bool enable, bool mode_os) {
    uint32_t val = REG_READ32(BITNET_REG_CTRL);
    if (enable)  val |= (1 << 0); else val &= ~(1 << 0);
    if (mode_os) val |= (1 << 1); else val &= ~(1 << 1);
    REG_WRITE32(BITNET_REG_CTRL, val);
}

void bitnet_clear_accumulators(void) {
    uint32_t val = REG_READ32(BITNET_REG_CTRL);
    REG_WRITE32(BITNET_REG_CTRL, val | (1 << 5)); // Pulse accum_clear bit
    REG_WRITE32(BITNET_REG_CTRL, val & ~(1 << 5));
}

int32_t bitnet_sparse_2_4_dot(uint8_t w0, uint8_t w1, uint8_t pattern, int16_t act0, int16_t act1) {
    // 1. Pack activations into REG_SPARSE_DOT input (0x0C)
    uint32_t act_packed = ((uint32_t)(uint16_t)act1 << 16) | (uint16_t)act0;
    REG_WRITE32(BITNET_REG_SPARSE_DOT, act_packed);

    // 2. Configure 2:4 sparsity pattern and weights at 0x14
    uint32_t cfg = ((pattern & 0x07) << 4) | ((w1 & 0x03) << 2) | (w0 & 0x03);
    REG_WRITE32(BITNET_BASE_ADDR + 0x14, cfg);

    // 3. Read 1-cycle combinational dot product result
    return (int32_t)REG_READ32(BITNET_REG_SPARSE_DOT);
}

bool bitnet_trigger_speculation(uint8_t *committed_count_out) {
    REG_WRITE32(BITNET_REG_SPEC_CTRL, 0x01);

    uint32_t status;
    uint32_t timeout = 1000;
    do {
        status = REG_READ32(BITNET_REG_SPEC_CTRL);
        timeout--;
    } while (!(status & (1 << 1)) && timeout > 0);

    if (timeout == 0) return false;

    if (committed_count_out) {
        *committed_count_out = (uint8_t)((status >> 2) & 0x07);
    }
    return true;
}

float bitnet_get_effective_speedup(void) {
    uint32_t val = REG_READ32(BITNET_REG_SPEEDUP_Q8);
    uint16_t speedup_q8 = (uint16_t)(val & 0xFFFF);
    return (float)speedup_q8 / 256.0f;
}

bool bitnet_is_d2d_link_up(void) {
    uint32_t status = REG_READ32(BITNET_REG_SYS_STATUS);
    return (status & (1 << 9)) != 0;
}

uint8_t bitnet_get_power_state(void) {
    uint32_t status = REG_READ32(BITNET_REG_SYS_STATUS);
    return (uint8_t)((status >> 6) & 0x03);
}

uint32_t bitnet_get_zero_skips(void) {
    return REG_READ32(BITNET_REG_ZERO_SKIPS);
}

uint8_t bitnet_get_kv_sequence_len(void) {
    uint32_t status = REG_READ32(BITNET_REG_KV_STATUS);
    return (uint8_t)(status & 0x7F);
}
