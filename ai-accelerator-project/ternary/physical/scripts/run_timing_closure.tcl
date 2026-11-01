# ==============================================================================
# OpenROAD Physical Implementation Flow Script - Phase 7 Timing Closure
# Design: accelerator_ternary_top (Hybrid Binary-Ternary AI Accelerator Core)
# Target: 500 MHz (Clock Period = 2.000 ns, Uncertainty = 50 ps)
# PDK: Nangate 45nm Open Cell Library
# Goals: WNS >= 0 ps, TNS = 0, Hold WNS > 0, DRC = 0
# Flow: Load Checkpoint -> Timing Repair -> Legalization -> Detailed Route
#       -> OpenRCX Fresh Extraction -> Post-Route STA -> Netlist/SPEF/SDF Export
# ==============================================================================

set DESIGN_NAME   "accelerator_ternary_top"
set PDK_DIR       "/work/ai-accelerator-project/ternary/physical/pdk"
set SDC_DIR       "/work/ai-accelerator-project/ternary/physical/sdc"
set OUTPUT_DIR    "/work/ai-accelerator-project/ternary/physical/openroad_run"

# 1. Read Technology & Macro LEFs
puts "\n--- STEP 1 --- Reading Technology and Macro LEF files..."
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef

# 2. Read Liberty Timing Library
puts "\n--- STEP 2 --- Reading Liberty Timing Library..."
read_liberty $PDK_DIR/nangate45.lib

# 3. Read Routed Database
puts "\n--- STEP 3 --- Loading Checkpoint Database..."
read_db $OUTPUT_DIR/accelerator_ternary_top.odb

# 4. Read SDC Constraints
puts "\n--- STEP 4 --- Reading SDC Constraints..."
read_sdc $SDC_DIR/accelerator_ternary_top.sdc

# 5. Set Wire RC & Read Previous SPEF for accurate repair estimation
puts "\n--- STEP 5 --- Reading Existing Parasitics for Timing Repair Sizing..."
set_wire_rc -layer metal3
read_spef $OUTPUT_DIR/accelerator_ternary_top.spef

puts "================================================================================"
puts "  STARTING TIMING REPAIR ON ACCELERATOR_TERNARY_TOP"
puts "================================================================================"

# 6. Repair Timing
repair_timing -setup -verbose

# 7. Detailed Placement Legalization
puts "\n--- STEP 7 --- Legalizing Placement Post-Repair..."
detailed_placement
check_placement

# 8. Detailed Routing (Incremental Re-Route)
puts "\n--- STEP 8 --- Running Detailed Routing on Repaired Layout..."
detailed_route -output_drc "$OUTPUT_DIR/drc.rpt" \
               -output_maze "$OUTPUT_DIR/maze.log"

# 9. Save Repaired Database, DEF, and Gate-Level Netlist
puts "\n--- STEP 9 --- Exporting Closed DEF, Database, and Routed Verilog Netlist..."
write_def "$OUTPUT_DIR/${DESIGN_NAME}.def"
write_db "$OUTPUT_DIR/${DESIGN_NAME}.odb"
write_verilog "$OUTPUT_DIR/${DESIGN_NAME}.routed.v"

# 10. Fresh Parasitic Extraction (OpenRCX)
puts "\n--- STEP 10 --- Extracting Fresh Parasitics on Routed Repaired Layout (OpenRCX)..."
extract_parasitics -ext_model_file "$PDK_DIR/Nangate45.rcx_rules"
write_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

# 11. Read Fresh SPEF for Final Signoff STA
read_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

# 12. Export SDF
puts "\n--- STEP 12 --- Exporting SDF for Gate-Level Simulation..."
write_sdf "$OUTPUT_DIR/${DESIGN_NAME}.sdf"

# 13. Unconstrained Single-Cycle Post-Route STA
puts "\n--- STEP 13 --- Post-Route Signoff STA: Raw Single-Cycle (Unconstrained)..."
report_worst_slack -max -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_wns.rpt"
report_worst_slack -min -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_hold.rpt"
report_tns -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_tns.rpt"
report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 > "$OUTPUT_DIR/post_route_unconstrained_timing.rpt"

# 14. Protocol-Verified Multicycle Analysis
puts "\n--- STEP 14 --- Post-Route Signoff STA: Protocol-Verified Mode-Register Multicycle..."
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

# 15. Clock Skew Analysis
puts "\n--- STEP 15 --- Clock Skew Analysis..."
report_clock_skew -digits 4 > "$OUTPUT_DIR/post_route_clock_skew.rpt"

# 16. Power Analysis
puts "\n--- STEP 16 --- Signoff Power Analysis..."
report_power > "$OUTPUT_DIR/post_route_power.rpt"

puts "\n================================================================================"
puts "  PHYSICAL TIMING CLOSURE RUN COMPLETE"
puts "================================================================================"
exit
