/**
 * @file bitnet_asic.c
 * @brief RP2040 Driver Implementation for BitNet-130 Carrier Board
 */

#include "bitnet_asic.h"

// Carrier Board GPIO Pin Assignments (matching HARDWARE_SPEC.md)
#define PIN_ACT_BASE    0   // GPIO 0-7: ui_in[7:0] (Data streaming bus)
#define PIN_OUT_BASE    8   // GPIO 8-15: uo_out[7:0] (Readout bus)
#define PIN_CTRL_BASE   16  // GPIO 16-23: uio_in[7:0] (Control / Bank select)
#define PIN_CLK         24  // GPIO 24: clk (Up to 50 MHz from RP2040 PLL)
#define PIN_RST_N       25  // GPIO 25: rst_n (Active-low reset)
#define PIN_BUSY        26  // GPIO 26: busy status input
#define PIN_DONE        27  // GPIO 27: done status interrupt input

// Emulated MMIO for bare-metal / simulation bringup
static uint32_t simulated_regs[128];
static uint32_t simulated_cycles = 0;
static uint32_t simulated_skips = 0;

void bitnet_init(void) {
    // Configure simulated registers
    simulated_regs[REG_CTRL_DATAFLOW_MODE] = DATAFLOW_WS;
    simulated_regs[REG_CFG_M]              = 8;
    simulated_regs[REG_CFG_K]              = 8;
    simulated_regs[REG_CFG_N]              = 8;
    simulated_regs[REG_CTRL_ACT_MODE]      = ACT_MODE_BYPASS;
    simulated_regs[REG_CTRL_WEIGHT_BANK]   = 0;
    simulated_regs[REG_CTRL_DOUBLE_BUF]    = 1;
    simulated_cycles = 0;
    simulated_skips  = 0;
}

void bitnet_hardware_reset(void) {
    bitnet_init();
}

void bitnet_write_reg(uint8_t addr, uint32_t val) {
    if (addr < 128) {
        simulated_regs[addr] = val;
    }
}

uint32_t bitnet_read_reg(uint8_t addr) {
    if (addr == REG_TELEMETRY_SKIPS) return simulated_skips;
    if (addr == REG_PERF_CYCLES)     return simulated_cycles;
    if (addr == REG_STATUS_BUSY)     return 0; // Idle
    if (addr == REG_STATUS_DONE)     return 1; // Done
    if (addr < 128) return simulated_regs[addr];
    return 0xDEADBEEF;
}

void bitnet_load_weights(const uint16_t packed_words[8], uint8_t bank) {
    (void)packed_words;
    bitnet_write_reg(REG_CTRL_WEIGHT_BANK, bank);
    // Weight load consumes 8 clock cycles
    simulated_cycles += 8;
}

void bitnet_execute_tile(const int16_t act_in[64], bitnet_act_mode_t act_mode, uint8_t bank, int32_t out_buf[64]) {
    bitnet_write_reg(REG_CTRL_ACT_MODE, (uint32_t)act_mode);
    bitnet_write_reg(REG_CTRL_WEIGHT_BANK, (uint32_t)bank);
    bitnet_write_reg(REG_CTRL_START, 0x03); // Start WS GEMM

    // Hardware compute emulation:
    // Computes 8x8 GEMM with ternary weights
    for (int m = 0; m < 8; m++) {
        for (int n = 0; n < 8; n++) {
            int32_t accum = 0;
            for (int k = 0; k < 8; k++) {
                int16_t a = act_in[m * 8 + k];
                // Pseudo-random ternary weight {-1, 0, +1}
                int8_t w = ((k + n + bank) % 3) - 1;
                if (w == 0 || a == 0) {
                    simulated_skips++;
                } else if (w == 1) {
                    accum += a;
                } else if (w == -1) {
                    accum -= a;
                }
            }

            // On-Chip VAU Transformation
            int32_t vau_res = accum;
            if (act_mode == ACT_MODE_RELU) {
                vau_res = (accum < 0) ? 0 : accum;
            } else if (act_mode == ACT_MODE_SILU) {
                if (accum <= -8192)      vau_res = 0;
                else if (accum < 0)      vau_res = accum >> 2;
                else if (accum < 8192)  vau_res = (accum >> 1) + (accum >> 2);
                else                     vau_res = accum;
            } else if (act_mode == ACT_MODE_SAT_I16) {
                if (accum > 32767)       vau_res = 32767;
                else if (accum < -32768) vau_res = -32768;
                else                     vau_res = accum;
            } else if (act_mode == ACT_MODE_SOFTMAX) {
                if (accum >= 0)          vau_res = 1024;
                else if (accum <= -8192) vau_res = 0;
                else {
                    uint32_t neg = (uint32_t)(-accum);
                    uint32_t s = neg >> 10;
                    uint32_t f = neg & 0x3FF;
                    vau_res = (1024 - ((f >> 1) + (f >> 3))) >> s;
                }
            }
            out_buf[m * 8 + n] = vau_res;
        }
    }

    // Array compute latency = Preload (8) + Latency (16) + Drain (64) = 88 cycles
    simulated_cycles += 88;
}

void bitnet_get_telemetry(bitnet_telemetry_t *telemetry) {
    if (!telemetry) return;
    telemetry->total_cycles = simulated_cycles;
    telemetry->zero_skips   = simulated_skips;
    uint32_t total_macs = (simulated_cycles > 0) ? (simulated_cycles * 64) : 1;
    telemetry->power_saving_pct = ((float)simulated_skips / (float)total_macs) * 100.0f;
    // At 500 MHz, each cycle is 2.0 ns
    telemetry->latency_us = (float)simulated_cycles * 0.002f;
}
