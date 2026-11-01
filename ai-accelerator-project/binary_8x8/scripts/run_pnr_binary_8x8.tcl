# ==============================================================================
# OpenROAD Physical Implementation Flow Script - 8x8 Binary Baseline
# Design: accelerator_top (64 PEs, 8x8 Adaptive Systolic Array)
# PDK: Nangate 45nm Open Cell Library
# Target Frequency: 500 MHz (Clock Period = 2.000 ns, 50 ps uncertainty)
# Flow: Floorplan (55% util) -> Placement -> CTS -> Timing Repair -> Detailed Route
#       -> OpenRCX -> Signoff STA & Power
# ==============================================================================

set DESIGN_NAME   "accelerator_top"
set PDK_DIR       "/work/ai-accelerator-project/ternary/physical/pdk"
set NETLIST_DIR   "/work/ai-accelerator-project/binary_8x8/synthesis"
set SDC_DIR       "/work/ai-accelerator-project/ternary/physical/sdc"
set OUTPUT_DIR    "/work/ai-accelerator-project/binary_8x8/openroad_8x8_run"

file mkdir $OUTPUT_DIR

puts "================================================================================"
puts "  STARTING OPENROAD PHYSICAL IMPLEMENTATION FOR 8x8 BINARY BASELINE"
puts "  DESIGN: $DESIGN_NAME | 64 PEs | PDK: Nangate45 | TARGET: 500 MHz (2.0 ns)"
puts "================================================================================"

# 1. Load Technology & Cell LEF
puts "\n--- STEP 1 --- Reading Technology and Macro LEF files..."
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef

# 2. Load Liberty Timing Libraries
puts "\n--- STEP 2 --- Reading Liberty Timing Library..."
read_liberty $PDK_DIR/nangate45.lib

# 3. Read Gate-Level Netlist
puts "\n--- STEP 3 --- Reading Synthesized & HFNS-Buffered 8x8 Binary Netlist..."
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 4. Link Design
puts "\n--- STEP 4 --- Linking Design..."
link_design $DESIGN_NAME

# 4b. Load OpenRCX Extraction Rules
puts "\n--- STEP 4b --- Loading OpenRCX Extraction Rules..."
set_extraction_rules_file "$PDK_DIR/Nangate45.rcx_rules"

# 5. Read Constraints
puts "\n--- STEP 5 --- Reading Timing Constraints (SDC)..."
read_sdc $SDC_DIR/accelerator_ternary_top.sdc

# 6. Floorplanning & Track Generation (Identical 55% utilization)
puts "\n--- STEP 6 --- Floorplanning and Core Definition (55% utilization)..."
initialize_floorplan -utilization 55 \
                     -aspect_ratio 1.0 \
                     -core_space 10.0 \
                     -site FreePDK45_38x28_10R_NP_162NW_34O

puts "\n--- STEP 6b --- Generating Routing Tracks from Nangate45 Specification..."
make_tracks metal1 -x_offset 0.095 -x_pitch 0.190 -y_offset 0.070 -y_pitch 0.140
make_tracks metal2 -x_offset 0.095 -x_pitch 0.190 -y_offset 0.070 -y_pitch 0.140
make_tracks metal3 -x_offset 0.095 -x_pitch 0.190 -y_offset 0.070 -y_pitch 0.140
make_tracks metal4 -x_offset 0.095 -x_pitch 0.280 -y_offset 0.070 -y_pitch 0.280
make_tracks metal5 -x_offset 0.095 -x_pitch 0.280 -y_offset 0.070 -y_pitch 0.280
make_tracks metal6 -x_offset 0.095 -x_pitch 0.280 -y_offset 0.070 -y_pitch 0.280
make_tracks metal7 -x_offset 0.095 -x_pitch 0.800 -y_offset 0.070 -y_pitch 0.800
make_tracks metal8 -x_offset 0.095 -x_pitch 0.800 -y_offset 0.070 -y_pitch 0.800
make_tracks metal9 -x_offset 0.095 -x_pitch 1.600 -y_offset 0.070 -y_pitch 1.600
make_tracks metal10 -x_offset 0.095 -x_pitch 1.600 -y_offset 0.070 -y_pitch 1.600

# 7. Place IO Pins
puts "\n--- STEP 7 --- Placing IO Pins..."
place_pins -hor_layers metal3 -ver_layers metal2

# 8. Standard Cell Placement
puts "\n--- STEP 8 --- Running Global Placement..."
global_placement -density 0.55 \
                 -bin_grid_count 64 \
                 -overflow 0.10 \
                 -routability_driven

# 9. Clock Tree Synthesis (TritonCTS)
puts "\n--- STEP 9 --- Running Clock Tree Synthesis (TritonCTS)..."
clock_tree_synthesis -root_buf CLKBUF_X3 \
                     -buf_list {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3} \
                     -sink_clustering_enable \
                     -sink_clustering_size 16 \
                     -sink_clustering_max_diameter 50.0

set_propagated_clock [all_clocks]

# 10. Detailed Placement Legalization
puts "\n--- STEP 10 --- Legalizing Placement..."
detailed_placement
check_placement

# 10b. Clean up empty power/ground nets
set block [[[ord::get_db] getChip] getBlock]
foreach net [$block getNets] {
    set t [$net getSigType]
    if {$t == "POWER" || $t == "GROUND"} {
        if {[llength [$net getITerms]] == 0 && [llength [$net getBTerms]] == 0} {
            odb::dbNet_destroy $net
        } else {
            $net setSpecial
        }
    }
}

# 11. Pre-Route Timing Repair
puts "\n--- STEP 11 --- Setting Wire RC & Pre-Route Timing Repair..."
set_wire_rc -layer metal3
estimate_parasitics -placement
repair_timing -setup -verbose
repair_timing -hold -verbose
detailed_placement
check_placement

# 12. Global Routing
puts "\n--- STEP 12 --- Running Global Routing (FastRoute)..."
set_routing_layers -signal metal1-metal10 -clock metal2-metal10
global_route -guide_file "$OUTPUT_DIR/route.guide" \
             -congestion_iterations 50

# 13. Detailed Routing (TritonRoute)
puts "\n--- STEP 13 --- Running Detailed Routing (TritonRoute)..."
detailed_route -output_drc "$OUTPUT_DIR/drc.rpt" \
               -output_maze "$OUTPUT_DIR/maze.log"

# 14. Save Legalized Database, DEF, and Gate-Level Netlist
puts "\n--- STEP 14 --- Writing Def, DB, and Routed Verilog Netlist..."
write_def "$OUTPUT_DIR/${DESIGN_NAME}.def"
write_db  "$OUTPUT_DIR/${DESIGN_NAME}.odb"
write_verilog -include_pwr_gnd "$OUTPUT_DIR/${DESIGN_NAME}.routed.v"

# 15. Parasitic Extraction (OpenRCX)
puts "\n--- STEP 15 --- Extracting Parasitics via OpenRCX..."
extract_parasitics -ext_model_file "$PDK_DIR/Nangate45.rcx_rules" \
                   -spef_file "$OUTPUT_DIR/${DESIGN_NAME}.spef"
write_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

# 16. Post-Route Timing Analysis (Propagated Clocks & Parasitic SPEF)
puts "\n--- STEP 16 --- Signoff Timing Analysis..."
read_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"
set_propagated_clock [all_clocks]

puts "=== TOP 10 REGISTER-TO-REGISTER SETUP PATHS ==="
report_checks -path_delay max -to [all_registers -data_pins] -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 -endpoint_count 10 > "$OUTPUT_DIR/top10_reg2reg_paths.rpt"

report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 -endpoint_count 10 > "$OUTPUT_DIR/top10_setup_paths.rpt"
report_worst_slack -max -digits 4 > "$OUTPUT_DIR/post_route_constrained_wns.rpt"
report_tns -digits 4 > "$OUTPUT_DIR/post_route_constrained_tns.rpt"
report_worst_slack -min -digits 4 > "$OUTPUT_DIR/post_route_constrained_hold.rpt"
report_clock_skew -digits 4 > "$OUTPUT_DIR/post_route_clock_skew.rpt"
write_sdf "$OUTPUT_DIR/${DESIGN_NAME}.sdf"

# 17. Power Estimation
puts "\n--- STEP 17 --- Signoff Power Analysis..."
report_power > "$OUTPUT_DIR/post_route_power.rpt"

puts "\n================================================================================"
puts "  OPENROAD 8x8 BINARY PHYSICAL IMPLEMENTATION COMPLETED!"
puts "================================================================================"
exit
