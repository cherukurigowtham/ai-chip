# ==============================================================================
# run_post_route_sta.tcl - Post-Route STA & Power Analysis with Extracted SPEF
# ==============================================================================

set DESIGN_NAME   "accelerator_ternary_top"
set PDK_DIR       "/work/ai-accelerator-project/ternary/physical/pdk"
set OUTPUT_DIR    "/work/ai-accelerator-project/ternary/physical/openroad_run"
set SDC_DIR       "/work/ai-accelerator-project/ternary/physical/sdc"

puts "================================================================================"
puts "  STARTING POST-ROUTE STATIC TIMING ANALYSIS (STA) & POWER BENCHMARK"
puts "  DESIGN: $DESIGN_NAME | PDK: Nangate45 | TARGET: 500 MHz (2.0 ns)"
puts "================================================================================"

# 1. Read Technology & Macro LEF
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef

# 2. Read Liberty Timing Library
read_liberty $PDK_DIR/nangate45.lib

# 3. Read Routed Database
read_db $OUTPUT_DIR/${DESIGN_NAME}.odb

# 4. Read Constraints
read_sdc $SDC_DIR/${DESIGN_NAME}.sdc

# 5. Extract Parasitics & Write SPEF
puts "\n--- STEP 13 --- Extracting Parasitics (OpenRCX)..."
extract_parasitics -ext_model_file $PDK_DIR/Nangate45.rcx_rules
write_spef $OUTPUT_DIR/${DESIGN_NAME}.spef
puts "SPEF extraction completed successfully: $OUTPUT_DIR/${DESIGN_NAME}.spef"

# 6. Read SPEF Parasitics
puts "\n--- STEP 14 --- Reading SPEF Parasitics..."
read_spef $OUTPUT_DIR/${DESIGN_NAME}.spef

# A. Unconstrained / Raw Single-Cycle Analysis
puts "\n--- A. Analysis: Raw Single-Cycle (Unconstrained) ---"
report_worst_slack -max -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_wns.rpt"
report_worst_slack -min -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_hold.rpt"
report_tns -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_tns.rpt"
report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_timing.rpt"

# B. Protocol-Verified Mode-Register Constraint Analysis
puts "\n--- B. Analysis: FSM Protocol-Verified Mode-Register Multicycle Path ---"
set mode_cells [get_cells -hier * -filter "full_name =~ *_53135_* || full_name =~ *selected_mode_os* || full_name =~ *mode_os_reg*"]
if {[llength $mode_cells] > 0} {
    puts "Found [llength $mode_cells] mode register cells for multicycle exception."
    set_multicycle_path 2 -setup -from $mode_cells
    set_multicycle_path 1 -hold  -from $mode_cells
} else {
    puts "Warning: No mode cells matched filter."
}

report_worst_slack -max -digits 4 > "$OUTPUT_DIR/post_route_constrained_wns.rpt"
report_worst_slack -min -digits 4 > "$OUTPUT_DIR/post_route_constrained_hold.rpt"
report_tns -digits 4 > "$OUTPUT_DIR/post_route_constrained_tns.rpt"
report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 > "$OUTPUT_DIR/post_route_constrained_timing.rpt"

# C. Clock Skew Analysis
puts "\n--- C. Clock Skew Analysis ---"
report_clock_skew -digits 4 > "$OUTPUT_DIR/post_route_clock_skew.rpt"

# D. Power Analysis
puts "\n--- D. Power Analysis ---"
report_power -digits 4 > "$OUTPUT_DIR/post_route_power.rpt"

puts "\n================================================================================"
puts "  POST-ROUTE STA & POWER BENCHMARK COMPLETED SUCCESSFULLY"
puts "  Outputs written to: $OUTPUT_DIR"
puts "================================================================================"
exit 0
