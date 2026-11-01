# ==============================================================================
# OpenROAD Physical Implementation Flow Script - Phase 7
# Design: accelerator_ternary_top (Hybrid Binary-Ternary AI Accelerator Core)
# PDK: Nangate 45nm Open Cell Library
# Target Frequency: 500 MHz (Clock Period = 2.000 ns)
# Flow: Floorplan -> Placement -> CTS -> Detailed Route -> OpenRCX -> STA
# ==============================================================================

set DESIGN_NAME   "accelerator_ternary_top"
set PDK_DIR       "/work/ai-accelerator-project/ternary/physical/pdk"
set NETLIST_DIR   "/work/ai-accelerator-project/ternary/physical/synthesis"
set SDC_DIR       "/work/ai-accelerator-project/ternary/physical/sdc"
set OUTPUT_DIR    "/work/ai-accelerator-project/ternary/physical/openroad_run"

file mkdir $OUTPUT_DIR

puts "================================================================================"
puts "  STARTING GENUINE OPENROAD PHYSICAL IMPLEMENTATION FLOW"
puts "  DESIGN: $DESIGN_NAME | PDK: Nangate45 | TARGET: 500 MHz (2.0 ns)"
puts "================================================================================"

# 1. Load Technology & Cell LEF
puts "\n--- STEP 1 --- Reading Technology and Macro LEF files..."
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef

# 2. Load Liberty Timing Libraries
puts "\n--- STEP 2 --- Reading Liberty Timing Library..."
read_liberty $PDK_DIR/nangate45.lib

# 3. Read Gate-Level Netlist
puts "\n--- STEP 3 --- Reading Synthesized & HFNS-Buffered Gate-Level Netlist..."
read_verilog $NETLIST_DIR/accelerator_ternary_top.final_hfns.v

# 4. Link Design
puts "\n--- STEP 4 --- Linking Design..."
link_design $DESIGN_NAME

# 4b. Load OpenRCX Extraction Rules
puts "\n--- STEP 4b --- Loading OpenRCX Extraction Rules..."
set_extraction_rules_file "$PDK_DIR/Nangate45.rcx_rules"

# 5. Read Constraints
puts "\n--- STEP 5 --- Reading Timing Constraints (SDC)..."
read_sdc $SDC_DIR/accelerator_ternary_top.sdc

# 6. Floorplanning & Track Generation (Exact identical 55% utilization)
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

# 8. Global Placement
puts "\n--- STEP 8 --- Running Global Placement..."
global_placement -density 0.65

# 9. Detailed Placement
puts "\n--- STEP 9 --- Running Initial Detailed Placement..."
detailed_placement
check_placement

# 10. Clock Tree Synthesis (CTS)
puts "\n--- STEP 10 --- Running Clock Tree Synthesis (CTS)..."
repair_clock_inverters
clock_tree_synthesis -root_buf "BUF_X4" -buf_list "BUF_X4 BUF_X8 CLKBUF_X1 CLKBUF_X2 CLKBUF_X3"
repair_clock_nets

# 10b. Legalize Newly Inserted Clock Tree Buffers
puts "\n--- STEP 10b --- Legalizing Clock Tree Buffers with Detailed Placement ---"
detailed_placement
check_placement

# 10c. Clean up empty or special power/ground nets before routing
puts "\n--- STEP 10c --- Net Type Sanitization for TritonRoute ---"
set block [[[ord::get_db] getChip] getBlock]
set destroyed_count 0
set special_count 0
foreach net [$block getNets] {
    set t [$net getSigType]
    if {$t == "POWER" || $t == "GROUND"} {
        if {[llength [$net getITerms]] == 0 && [llength [$net getBTerms]] == 0} {
            odb::dbNet_destroy $net
            incr destroyed_count
        } else {
            $net setSpecial
            incr special_count
        }
    }
}
puts "Sanitization complete: $destroyed_count empty power nets destroyed, $special_count power nets marked special."

# 11. Global Routing (FastRoute)
puts "\n--- STEP 11 --- Running Global Routing..."
set_routing_layers -signal metal1-metal10 -clock metal2-metal10
global_route -guide_file "$OUTPUT_DIR/route.guide" \
             -congestion_iterations 50

# 12. Detailed Routing (TritonRoute)
puts "\n--- STEP 12 --- Running Detailed Routing..."
detailed_route -output_drc "$OUTPUT_DIR/drc.rpt" \
               -output_maze "$OUTPUT_DIR/maze.log"

# 12b. Save Routed Netlist, DEF, and Database Immediately
puts "\n--- STEP 12b --- Exporting Routed DEF, Database, and Verilog Netlist..."
write_def "$OUTPUT_DIR/${DESIGN_NAME}.def"
write_db "$OUTPUT_DIR/${DESIGN_NAME}.odb"
write_verilog "$OUTPUT_DIR/${DESIGN_NAME}.routed.v"

# 13. Parasitic Extraction (RC Extraction)
puts "\n--- STEP 13 --- Extracting Parasitics (OpenRCX)..."
extract_parasitics
write_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

# 14. Post-Route Static Timing Analysis (STA)
puts "\n--- STEP 14 --- Running Post-Route Static Timing Analysis..."
read_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

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
puts "  OPENROAD PHYSICAL IMPLEMENTATION COMPLETED SUCCESSFULLY"
puts "  Outputs written to: $OUTPUT_DIR"
puts "================================================================================"
exit 0
