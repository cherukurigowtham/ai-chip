# ==============================================================================
# Script: run_vivado.tcl
# Description: Automated Vivado Batch Synthesis, Placement, and Routing Flow
#              for the 8x8 Ternary AI Accelerator FPGA Prototype.
# Supports:
#   - Zynq-7000: xc7z020clg400-1 (PYNQ-Z1 / PYNQ-Z2 / ZedBoard)
#   - Zynq UltraScale+: xczu7ev-ffvc1156-2-e (ZCU104 / ZCU102)
# ==============================================================================

set PART "xc7z020clg400-1"
if {[info exists env(FPGA_PART)]} {
    set PART $env(FPGA_PART)
}

puts "================================================================="
puts "  STARTING VIVADO IMPLEMENTATION FOR 8x8 TERNARY ACCELERATOR"
puts "  Target Part: $PART"
puts "================================================================="

set OUTPUT_DIR "vivado_output"
file mkdir $OUTPUT_DIR

# Read RTL files
set RTL_FILES [list \
    "../rtl/dynamic_config_reg.sv" \
    "../rtl/pe_ternary.sv" \
    "../rtl/ternary_weight_unpacker.sv" \
    "../rtl/ternary_weight_buffer.sv" \
    "../rtl/systolic_array_ternary.sv" \
    "../rtl/ternary_controller.sv" \
    "../rtl/accelerator_ternary_top.sv" \
    "../rtl/axi_lite_slave.sv" \
    "../rtl/axi_stream_dma_adapter.sv" \
    "../rtl/accelerator_ternary_axi_top.sv" \
]

foreach f $RTL_FILES {
    read_verilog -sv $f
}

# Read Constraints
read_xdc "constraints.xdc"

# Run Out-Of-Context (OOC) Synthesis
puts "--- Running Synthesis ---"
synth_design -top accelerator_ternary_axi_top -part $PART -mode out_of_context

# Optimization
puts "--- Running Logic Optimization ---"
opt_design

# Placement
puts "--- Running Placement ---"
place_design

# Physical Optimization
phys_opt_design

# Routing
puts "--- Running Detailed Routing ---"
route_design

# Generate Reports
puts "--- Generating Physical Reports ---"
report_utilization -file "${OUTPUT_DIR}/utilization_post_route.rpt"
report_timing_summary -file "${OUTPUT_DIR}/timing_post_route.rpt" -delay_type min_max -max_paths 10
report_power -file "${OUTPUT_DIR}/power_post_route.rpt"
report_drc -file "${OUTPUT_DIR}/drc_post_route.rpt"

# Export Design Checkpoint
write_checkpoint -force "${OUTPUT_DIR}/post_route.dcp"

puts "================================================================="
puts "  VIVADO IMPLEMENTATION COMPLETED SUCCESSFULLY"
puts "  Reports saved in: $OUTPUT_DIR"
puts "================================================================="
