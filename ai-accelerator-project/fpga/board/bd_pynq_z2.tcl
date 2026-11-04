# ==============================================================================
# Script: bd_pynq_z2.tcl
# Description: Automated Vivado Block Design generation for PYNQ-Z2 (xc7z020)
#              Integrates Zynq-7000 Processing System, AXI DMA, Interconnect,
#              and 8x8 Ternary Accelerator SoC IP block.
# ==============================================================================

set DESIGN_NAME "ternary_pynq_soc"
set PART        "xc7z020clg400-1"

puts "================================================================="
puts "  CREATING PYNQ-Z2 BLOCK DESIGN: $DESIGN_NAME"
puts "  Target Part: $PART"
puts "================================================================="

create_project -force $DESIGN_NAME ./$DESIGN_NAME -part $PART

# Add RTL Source Files
set RTL_DIR "../rtl"
set TERNARY_DIR "../../ternary/rtl"

add_files -norecurse [list \
    "${TERNARY_DIR}/dynamic_config_reg.sv" \
    "${TERNARY_DIR}/pe_ternary.sv" \
    "${TERNARY_DIR}/ternary_weight_unpacker.sv" \
    "${TERNARY_DIR}/ternary_weight_buffer.sv" \
    "${TERNARY_DIR}/systolic_array_ternary.sv" \
    "${TERNARY_DIR}/ternary_controller.sv" \
    "${TERNARY_DIR}/accelerator_ternary_top.sv" \
    "${RTL_DIR}/axi_lite_slave.sv" \
    "${RTL_DIR}/axi_stream_dma_adapter.sv" \
    "${RTL_DIR}/accelerator_ternary_axi_top.sv" \
]
update_compile_order -fileset sources_1

# Create Block Design
create_bd_design "design_1"

# 1. Instantiate Zynq-7000 Processing System (PS7)
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] $ps7

# 2. Instantiate AXI DMA (Simple Mode, No Scatter-Gather)
set axi_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
] $axi_dma

# 3. Instantiate 8x8 Ternary AI Accelerator Module
set accel [create_bd_cell -type module -reference accelerator_ternary_axi_top accel_0]

# 4. Instantiate Interconnects & Reset Controller
set rst_gen [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_gen]
set axi_ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {2}] $axi_ic_gp0

set axi_ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_SI {2}] $axi_ic_hp0

# -----------------------------------------------------------------------------
# Clock & Reset Connections (100 MHz System Domain)
# -----------------------------------------------------------------------------
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins rst_gen/slowest_sync_clk] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma/s_axi_lite_aclk] \
    [get_bd_pins axi_dma/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma/m_axi_s2mm_aclk] \
    [get_bd_pins accel_0/clk] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins axi_ic_gp0/M01_ACLK] \
    [get_bd_pins axi_ic_hp0/ACLK] \
    [get_bd_pins axi_ic_hp0/S00_ACLK] \
    [get_bd_pins axi_ic_hp0/S01_ACLK] \
    [get_bd_pins axi_ic_hp0/M00_ACLK]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_gen/ext_reset_in]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] \
    [get_bd_pins accel_0/rst_n] \
    [get_bd_pins axi_dma/axi_resetn] \
    [get_bd_pins axi_ic_gp0/ARESETN] \
    [get_bd_pins axi_ic_gp0/S00_ARESETN] \
    [get_bd_pins axi_ic_gp0/M00_ARESETN] \
    [get_bd_pins axi_ic_gp0/M01_ARESETN] \
    [get_bd_pins axi_ic_hp0/ARESETN] \
    [get_bd_pins axi_ic_hp0/S00_ARESETN] \
    [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]

# -----------------------------------------------------------------------------
# AXI Data & Stream Channels
# -----------------------------------------------------------------------------
# Host CPU -> AXI-Lite MMIO (Control & DMA registers)
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] [get_bd_intf_pins axi_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M01_AXI] [get_bd_intf_pins accel_0/s_axil]

# Accelerator DMA AXI-Stream Channels
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXIS_MM2S] [get_bd_intf_pins accel_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins accel_0/m_axis] [get_bd_intf_pins axi_dma/S_AXIS_S2MM]

# DMA -> Zynq High-Performance DDR Port (HP0)
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_MM2S] [get_bd_intf_pins axi_ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_S2MM] [get_bd_intf_pins axi_ic_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

# Interrupt
connect_bd_net [get_bd_pins accel_0/irq_done] [get_bd_pins ps7/IRQ_F2P]

# -----------------------------------------------------------------------------
# Address Space Mapping
# -----------------------------------------------------------------------------
assign_bd_address [get_bd_addr_segs {axi_dma/S_AXI_LITE/Reg }]
assign_bd_address [get_bd_addr_segs {accel_0/s_axil/reg0 }]
assign_bd_address [get_bd_addr_segs {ps7/S_AXI_HP0/HP0_DDR_LOWOCM }]

save_bd_design
validate_bd_design

# Generate Wrapper and Bitstream
make_wrapper -files [get_files ./$DESIGN_NAME/$DESIGN_NAME.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse ./$DESIGN_NAME/$DESIGN_NAME.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v
update_compile_order -fileset sources_1

puts "--- Launching Implementation & Bitstream Generation ---"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "================================================================="
puts "  BITSTREAM GENERATION COMPLETED"
puts "================================================================="
