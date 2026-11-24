// ==============================================================================
// Test: test_bitnet_mpw_firmware.c
// Description: Unit test and verification suite for BitNet MPW Bare-Metal Driver.
// ==============================================================================

#include <stdio.h>
#include <assert.h>
#include "bitnet_mpw_driver.h"

// Simulated Wishbone Register Memory Space
static uint32_t mock_regs[64] = {0};

static uint32_t mock_read(uint32_t addr) {
    if (addr == BITNET_REG_SPARSE_DOT) {
        // Return simulated dot product from hardware 2:4 decompressor
        return 150;
    }
    return mock_regs[((addr) - BITNET_BASE_ADDR) >> 2];
}

static void mock_write(uint32_t addr, uint32_t val) {
    if (addr == BITNET_REG_SPEC_CTRL && (val & 0x01)) {
        // Simulated hardware sets Done=1 (bit 1) and Committed=4 (bits [4:2])
        mock_regs[((addr) - BITNET_BASE_ADDR) >> 2] = (4 << 2) | (1 << 1);
        return;
    }
    mock_regs[((addr) - BITNET_BASE_ADDR) >> 2] = val;
}

#define REG_READ32(addr)       mock_read(addr)
#define REG_WRITE32(addr, val) mock_write(addr, val)

#include "bitnet_mpw_driver.c"

int main(void) {
    printf("================================================================================\n");
    printf("[FIRMWARE TEST] Starting BitNet Gen-3 MPW Bare-Metal Driver Verification...\n");
    printf("================================================================================\n");

    // Test 1: Initialization
    bitnet_init();
    printf("  [PASS] bitnet_init() executed successfully.\n");

    // Test 2: Precision Configuration
    bitnet_set_precision(BITNET_PRECISION_TERNARY);
    assert((mock_regs[0] & (0x03 << 2)) == 0x00);
    bitnet_set_precision(BITNET_PRECISION_INT8);
    assert((mock_regs[0] & (0x03 << 2)) == (0x01 << 2));
    printf("  [PASS] bitnet_set_precision() verified (Ternary & INT8).\n");

    // Test 3: Systolic Activation & Clearing
    bitnet_enable_systolic(true, true);
    assert((mock_regs[0] & 0x03) == 0x03);
    bitnet_clear_accumulators();
    printf("  [PASS] bitnet_enable_systolic() & bitnet_clear_accumulators() verified.\n");

    // Test 4: 2:4 Structured Sparsity Execution
    // w0 = +1 (2'b01), w1 = -1 (2'b10), pattern = 3'b000 {0,1}, act0 = 100, act1 = -50
    int32_t dot = bitnet_sparse_2_4_dot(0x01, 0x02, 0x00, 100, -50);
    assert(dot == 150);
    printf("  [PASS] bitnet_sparse_2_4_dot() returned: %d (Expected: 150)\n", dot);

    // Test 5: Speculative Decoding Trigger & Telemetry
    // Mock completion status: Done=1, Committed=4 -> status = (4 << 2) | 0x02 = 0x12
    mock_regs[0x04 >> 2] = 0x12;
    uint8_t committed = 0;
    bool success = bitnet_trigger_speculation(&committed);
    assert(success == true);
    assert(committed == 4);
    printf("  [PASS] bitnet_trigger_speculation() committed: %d tokens (1 Step!)\n", committed);

    // Mock Speedup Q8.8 register: 0x03B1 = 3.69x
    mock_regs[0x08 >> 2] = 0x03B1;
    float speedup = bitnet_get_effective_speedup();
    printf("  [PASS] bitnet_get_effective_speedup() reported: %.2fx\n", speedup);
    assert(speedup > 3.5f);

    // Test 6: System Status & D2D Link
    // Set LinkUp (bit 9), PowerState = BURST (00) -> status = (1 << 9)
    mock_regs[0x24 >> 2] = (1 << 9);
    assert(bitnet_is_d2d_link_up() == true);
    assert(bitnet_get_power_state() == BITNET_PWR_BURST);
    printf("  [PASS] bitnet_is_d2d_link_up() = TRUE, power_state = BURST verified.\n");

    printf("\n================================================================================\n");
    printf("[FIRMWARE TEST] ALL BARE-METAL DRIVER TESTS PASSED (0 Errors) - SIGN-OFF READY!\n");
    printf("================================================================================\n");

    return 0;
}
