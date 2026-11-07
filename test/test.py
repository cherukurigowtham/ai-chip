# SPDX-FileCopyrightText: © 2026 Cherukuri Gowtham
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


def build_uio(weight=0, weight_load=0, mode_os=0, accum_clear=0, enable=0, byte_sel=0):
    """Encodes control signals into uio_in[7:0]."""
    val = (weight & 0x03)
    if weight_load:
        val |= (1 << 2)
    if mode_os:
        val |= (1 << 3)
    if accum_clear:
        val |= (1 << 4)
    if enable:
        val |= (1 << 5)
    val |= ((byte_sel & 0x03) << 6)
    return val


def to_signed_8(val):
    """Converts a signed Python integer to an 8-bit unsigned representation for Verilog."""
    return val & 0xFF


async def reset_dut(dut):
    """Applies active-low reset to the DUT."""
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def read_accum_24(dut):
    """Reads back the 24-bit signed accumulator across the 3 bytes via byte_select."""
    # Byte 0 (LSB)
    dut.uio_in.value = build_uio(byte_sel=0)
    await ClockCycles(dut.clk, 1)
    b0 = int(dut.uo_out.value)

    # Byte 1 (Mid)
    dut.uio_in.value = build_uio(byte_sel=1)
    await ClockCycles(dut.clk, 1)
    b1 = int(dut.uo_out.value)

    # Byte 2 (MSB)
    dut.uio_in.value = build_uio(byte_sel=2)
    await ClockCycles(dut.clk, 1)
    b2 = int(dut.uo_out.value)

    raw = b0 | (b1 << 8) | (b2 << 16)
    # Sign extend 24-bit to Python signed integer
    if raw & 0x800000:
        raw -= 0x1000000
    return raw


@cocotb.test()
async def test_reset_and_init(dut):
    """Verify reset state and default output values."""
    clock = Clock(dut.clk, 20, unit="ns")  # 50 MHz
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    accum = await read_accum_24(dut)
    assert accum == 0, f"Expected 0 after reset, got {accum}"
    dut._log.info("Reset test passed cleanly: accum = 0")


@cocotb.test()
async def test_weight_stationary_mode(dut):
    """Verify Weight-Stationary (WS) execution with +1, -1, and 0 weights."""
    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # 1. Latch stationary weight +1 (2'b01) in WS mode (mode_os=0)
    dut._log.info("Loading WS weight = +1")
    dut.uio_in.value = build_uio(weight=0b01, weight_load=1, mode_os=0)
    await ClockCycles(dut.clk, 1)

    # 2. Stream activations with compute enabled: 15, 30, -10, 45
    # Expected sum = 15 + 30 - 10 + 45 = 80
    activations = [15, 30, -10, 45]
    for act in activations:
        dut.ui_in.value = to_signed_8(act)
        dut.uio_in.value = build_uio(weight=0b01, weight_load=0, mode_os=0, enable=1)
        await ClockCycles(dut.clk, 1)

    # Disable compute
    dut.uio_in.value = build_uio(mode_os=0, enable=0)
    await ClockCycles(dut.clk, 1)

    accum = await read_accum_24(dut)
    assert accum == 80, f"WS accumulation failure: expected 80, got {accum}"
    dut._log.info(f"WS (+1) stream passed: accum = {accum}")

    # 3. Latch negative weight -1 (2'b10) without clearing accumulator
    dut._log.info("Loading WS weight = -1")
    dut.uio_in.value = build_uio(weight=0b10, weight_load=1, mode_os=0)
    await ClockCycles(dut.clk, 1)

    # Stream activations: 20, 35
    # Expected sum = 80 - 20 - 35 = 25
    for act in [20, 35]:
        dut.ui_in.value = to_signed_8(act)
        dut.uio_in.value = build_uio(weight=0b10, weight_load=0, mode_os=0, enable=1)
        await ClockCycles(dut.clk, 1)

    dut.uio_in.value = build_uio(mode_os=0, enable=0)
    await ClockCycles(dut.clk, 1)

    accum = await read_accum_24(dut)
    assert accum == 25, f"WS (-1) accumulation failure: expected 25, got {accum}"
    dut._log.info(f"WS (-1) stream passed: accum = {accum}")


@cocotb.test()
async def test_output_stationary_mode(dut):
    """Verify Output-Stationary (OS) execution with dynamic per-cycle streaming weights."""
    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Sync clear accumulator
    dut.uio_in.value = build_uio(accum_clear=1, mode_os=1)
    await ClockCycles(dut.clk, 1)

    # Dynamic (activation, weight) sequence:
    # 1. act = 25,  w = +1 (0b01) -> +25
    # 2. act = 50,  w = -1 (0b10) -> -50
    # 3. act = 100, w = 0  (0b00) -> 0 (Zero skip)
    # 4. act = -30, w = -1 (0b10) -> +30
    # 5. act = 12,  w = +1 (0b01) -> +12
    # Expected total = 25 - 50 + 0 + 30 + 12 = 17
    vectors = [
        (25, 0b01),
        (50, 0b10),
        (100, 0b00),
        (-30, 0b10),
        (12, 0b01),
    ]

    dut._log.info("Streaming OS matrix-vector dot product")
    for act, w in vectors:
        dut.ui_in.value = to_signed_8(act)
        dut.uio_in.value = build_uio(weight=w, mode_os=1, enable=1)
        await ClockCycles(dut.clk, 1)

    dut.uio_in.value = build_uio(mode_os=1, enable=0)
    await ClockCycles(dut.clk, 1)

    accum = await read_accum_24(dut)
    assert accum == 17, f"OS dynamic dot-product failure: expected 17, got {accum}"
    dut._log.info(f"OS dynamic dot-product passed: accum = {accum}")


@cocotb.test()
async def test_zero_skipping_and_telemetry(dut):
    """Verify operand isolation, zero-skipping flag, and energy telemetry counter."""
    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Clear accumulator and zero-skip count
    dut.uio_in.value = build_uio(accum_clear=1, mode_os=1)
    await ClockCycles(dut.clk, 1)

    # Stream 6 zero-weighted operations
    dut._log.info("Streaming 6 zero-weight operations")
    for i in range(6):
        dut.ui_in.value = to_signed_8(10 + i * 5)
        # Weight 0b00 (Zero) and 0b11 (NOP)
        w = 0b00 if i % 2 == 0 else 0b11
        dut.uio_in.value = build_uio(weight=w, mode_os=1, enable=1)
        await ClockCycles(dut.clk, 1)

    # Disable compute and read telemetry status byte (byte_select=3)
    dut.uio_in.value = build_uio(byte_sel=3)
    await ClockCycles(dut.clk, 1)
    status_byte = int(dut.uo_out.value)

    # In status byte: [7:4] = zero_skips_count[3:0], [0] = is_zero
    zero_skips = (status_byte >> 4) & 0x0F
    dut._log.info(f"Telemetry status byte: 0x{status_byte:02x}, zero skips recorded: {zero_skips}")

    assert zero_skips == 6, f"Expected 6 zero skips recorded in telemetry, got {zero_skips}"

    # Verify accumulator remained strictly zero
    accum = await read_accum_24(dut)
    assert accum == 0, f"Accumulator should remain 0 on zero skips, got {accum}"
    dut._log.info("Zero-skipping and telemetry verification passed 100%!")


@cocotb.test()
async def test_negative_accumulator_two_complement(dut):
    """Verify negative two's complement accumulator handling and sign extension."""
    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Clear accumulator
    dut.uio_in.value = build_uio(accum_clear=1, mode_os=0)
    await ClockCycles(dut.clk, 1)

    # Latch -1 weight
    dut.uio_in.value = build_uio(weight=0b10, weight_load=1, mode_os=0)
    await ClockCycles(dut.clk, 1)

    # Feed act = 50 -> accum = -50
    dut.ui_in.value = to_signed_8(50)
    dut.uio_in.value = build_uio(weight=0b10, mode_os=0, enable=1)
    await ClockCycles(dut.clk, 1)

    # Disable compute
    dut.uio_in.value = build_uio(mode_os=0, enable=0)
    await ClockCycles(dut.clk, 1)

    accum = await read_accum_24(dut)
    assert accum == -50, f"Expected accum = -50, got {accum}"
    dut._log.info(f"Two's complement test passed: accum = {accum}")
