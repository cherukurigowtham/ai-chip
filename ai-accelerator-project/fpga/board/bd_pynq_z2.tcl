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

# -----------------------------------------------------------------------------
# Pre-Flight Git Provenance & Source-Tree Cleanliness Guard
# -----------------------------------------------------------------------------
set git_commit "unknown"
set git_branch "unknown"
set git_dirty "unknown"

catch {
    set git_commit [string trim [exec git rev-parse HEAD]]
    set git_branch [string trim [exec git rev-parse --abbrev-ref HEAD]]
    set git_status_output [string trim [exec git status --porcelain]]
    if {$git_status_output eq ""} {
        set git_dirty "false"
    } else {
        set git_dirty "true"
    }
}

puts "Git Source Provenance:"
puts "  Branch: $git_branch"
puts "  Commit: $git_commit"
puts "  Dirty:  $git_dirty"

if {$git_dirty eq "true"} {
    puts "================================================================="
    puts "  [FATAL ERROR] Working tree is DIRTY (uncommitted changes detected)."
    puts "  Physical build provenance requires a clean Git working tree."
    puts "  Please commit or stash changes before running Vivado implementation."
    puts "================================================================="
    exit 1
}

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

# Generate Block Design Targets & Constraints
generate_target all [get_files ./$DESIGN_NAME/$DESIGN_NAME.srcs/sources_1/bd/design_1/design_1.bd]

# Generate Wrapper
make_wrapper -files [get_files ./$DESIGN_NAME/$DESIGN_NAME.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse ./$DESIGN_NAME/$DESIGN_NAME.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v
update_compile_order -fileset sources_1

puts "--- Launching Implementation & Bitstream Generation ---"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Check implementation run progress
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed to complete successfully."
    exit 1
}

# -----------------------------------------------------------------------------
# Generate Comprehensive Physical Signoff Reports
# -----------------------------------------------------------------------------
puts "--- Generating Physical Signoff Reports ---"
open_run impl_1
file mkdir "./reports"

# 1. Utilization Report (LUT, FF, BRAM, DSP)
report_utilization -file "./reports/synthesis_utilization.rpt"

# 2. Timing Summary & Slack (with verbose constraint checking)
report_timing_summary -check_timing_verbose -max_paths 10 -file "./reports/post_impl_timing_summary.rpt"

# 3. Timing Exceptions & Ignored Paths Analysis
report_exceptions -coverage -file "./reports/post_impl_timing_exceptions.rpt"

# 4. Clock Interaction & Cross-Domain Analysis
report_clock_interaction -delay_type min_max -file "./reports/post_impl_clock_interaction.rpt"

# 5. DRC Report
report_drc -file "./reports/post_impl_drc.rpt"

# Extract WNS, TNS, WHS metrics
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]

# Generate Reproducibility & Environment Manifest
set manifest_file [open "./reports/build_manifest.json" "w"]
puts $manifest_file "{"
puts $manifest_file "  \"tool\": \"Vivado [version -short]\","
puts $manifest_file "  \"build_timestamp\": \"[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]\","
puts $manifest_file "  \"target_part\": \"$PART\","
puts $manifest_file "  \"design_name\": \"$DESIGN_NAME\","
puts $manifest_file "  \"git_commit\": \"$git_commit\","
puts $manifest_file "  \"git_branch\": \"$git_branch\","
puts $manifest_file "  \"git_dirty\": $git_dirty,"
puts $manifest_file "  \"setup_wns_ns\": \"$wns\","
puts $manifest_file "  \"setup_tns_ns\": \"$tns\","
puts $manifest_file "  \"hold_whs_ns\": \"$whs\""
puts $manifest_file "}"
close $manifest_file
puts "  [PASS] Reproducibility manifest written: ./reports/build_manifest.json (Commit: $git_commit, Dirty: $git_dirty)"

puts "================================================================="
puts "  PHYSICAL IMPLEMENTATION SIGNOFF SUMMARY (100 MHz Target)"
puts "  Setup WNS: $wns ns"
puts "  Setup TNS: $tns ns"
puts "  Hold  WHS: $whs ns"
puts "================================================================="

# Copy bitstream and hardware handoff file to board directory
set bit_files [glob -nocomplain ./$DESIGN_NAME/$DESIGN_NAME.runs/impl_1/*.bit]
if {[llength $bit_files] > 0} {
    file copy -force [lindex $bit_files 0] ./ternary_pynq_soc.bit
    puts "  [PASS] Bitstream exported: ./ternary_pynq_soc.bit"
}

set hwh_files [glob -nocomplain ./$DESIGN_NAME/$DESIGN_NAME.gen/sources_1/bd/design_1/hw_handoff/*.hwh]
if {[llength $hwh_files] > 0} {
    file copy -force [lindex $hwh_files 0] ./ternary_pynq_soc.hwh
    puts "  [PASS] Hardware handoff exported: ./ternary_pynq_soc.hwh"
}

# Validate bitstream size and presence
if {[file exists "./ternary_pynq_soc.bit"] && [file size "./ternary_pynq_soc.bit"] > 1000000} {
    puts "  [PASS] Bitstream validated on disk ([file size ./ternary_pynq_soc.bit] bytes)."
} else {
    puts "  [ERROR] Bitstream file missing or invalid file size!"
    exit 1
}

puts "================================================================="
puts "  BITSTREAM GENERATION COMPLETED SUCCESSFULLY"
puts "================================================================="
