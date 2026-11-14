cmake_minimum_required(VERSION 3.13)

# ==============================================================================
# BitNet-130 Carrier Board Firmware Build System (RP2040 & Host Test Harness)
# ==============================================================================

project(bitnet130_firmware C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# Check if compiling with the Raspberry Pi Pico SDK
if (DEFINED PICO_SDK_PATH OR DEFINED ENV{PICO_SDK_PATH})
    include(pico_sdk_import.cmake OPTIONAL)
    if (COMMAND pico_sdk_init)
        pico_sdk_init()

        add_executable(bitnet130_carrier_firmware
            main.c
            bitnet_asic.c
        )

        # Generate PIO header from bitnet_stream.pio
        pico_generate_pio_header(bitnet130_carrier_firmware ${CMAKE_CURRENT_LIST_DIR}/bitnet_stream.pio)

        target_include_directories(bitnet130_carrier_firmware PRIVATE
            ${CMAKE_CURRENT_LIST_DIR}
        )

        target_link_libraries(bitnet130_carrier_firmware
            pico_stdlib
            hardware_pio
            hardware_dma
            hardware_clocks
        )

        # Enable USB-CDC serial console, disable UART
        pico_enable_stdio_usb(bitnet130_carrier_firmware 1)
        pico_enable_stdio_uart(bitnet130_carrier_firmware 0)

        # Generate .uf2, .hex, and .bin for RP2040 drag-and-drop programming
        pico_add_extra_outputs(bitnet130_carrier_firmware)
    endif()
endif()

# Host-side interactive virtual console & verification executable
add_executable(bitnet_host_console
    main.c
    bitnet_asic.c
)

target_include_directories(bitnet_host_console PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}
)
