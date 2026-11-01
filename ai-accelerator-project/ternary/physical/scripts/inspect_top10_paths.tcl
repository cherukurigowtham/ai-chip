# ==============================================================================
# inspect_top10_paths.tcl - Inspect Worst 10 Setup Timing Paths in OpenROAD
# ==============================================================================

set DESIGN_NAME   "accelerator_ternary_top"
set PDK_DIR       "/work/ai-accelerator-project/ternary/physical/pdk"
set OUTPUT_DIR    "/work/ai-accelerator-project/ternary/physical/openroad_run"
set SDC_DIR       "/work/ai-accelerator-project/ternary/physical/sdc"

read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef
read_liberty $PDK_DIR/nangate45.lib
read_db $OUTPUT_DIR/${DESIGN_NAME}.odb
read_sdc $SDC_DIR/${DESIGN_NAME}.sdc
read_spef $OUTPUT_DIR/${DESIGN_NAME}.spef

set mode_cells [get_cells -hier * -filter "full_name =~ *_53135_* || full_name =~ *selected_mode_os* || full_name =~ *mode_os_reg*"]
if {[llength $mode_cells] > 0} {
    set_multicycle_path 2 -setup -from $mode_cells
    set_multicycle_path 1 -hold  -from $mode_cells
}

puts "\n================================================================================"
puts "  WORST 10 SETUP PATHS DETAILED REPORT"
puts "================================================================================"
report_checks -path_delay max -fields {slew cap input fanout} -format full_clock_expanded -digits 4 -endpoint_count 10 > "$OUTPUT_DIR/top10_setup_paths.rpt"

report_worst_slack -max -digits 4
report_tns -digits 4

exit 0
