# ==============================================================================
# OpenROAD Physical Implementation Flow Script - Phase 19
# Complete RTL-to-GDSII Physical Implementation Script for 45nm Nangate PDK
# Target Clock: 500 MHz (2.0 ns period)
# ==============================================================================

set DESIGN_NAME   "accelerator_top"
set PDK_DIR       "ai-accelerator-project/phase19/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase19/synthesis"
set SDC_DIR       "ai-accelerator-project/phase19/sdc"
set OUTPUT_DIR    "ai-accelerator-project/phase19/pnr_output"

file mkdir $OUTPUT_DIR

puts "================================================================================"
puts "  STARTING OPENROAD PHYSICAL IMPLEMENTATION FLOW"
puts "  DESIGN: $DESIGN_NAME | PDK: Nangate45 | TARGET: 500 MHz (2.0 ns)"
puts "================================================================================"

# 1. Load Technology & Cell LEF
puts "\n[STEP 1] Reading Technology and Macro LEF files..."
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef

# 2. Load Liberty Timing Libraries
puts "\n[STEP 2] Reading Liberty Timing Library..."
read_liberty $PDK_DIR/nangate45.lib

# 3. Read Gate-Level Netlist
puts "\n[STEP 3] Reading Synthesized & HFNS-Buffered Gate-Level Netlist..."
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 4. Link Design
puts "\n[STEP 4] Linking Design..."
link_design $DESIGN_NAME

# 5. Read Constraints
puts "\n[STEP 5] Reading Timing Constraints (SDC)..."
read_sdc $SDC_DIR/accelerator_top.sdc

# 6. Floorplanning
# Accelerator standard cell area is ~143,920 um^2.
# Setting core utilization to 65% gives core area ~221,415 um^2 (approx 470 um x 470 um).
puts "\n[STEP 6] Floorplanning and Core Definition..."
initialize_floorplan -utilization 65 \
                     -aspect_ratio 1.0 \
                     -core_space 10.0 \
                     -site FreePDK45_38x28_10R_NP_162NW_34O

# 7. Place IO Pins
puts "\n[STEP 7] Placing IO Pins..."
place_pins -hor_layers metal3 -ver_layers metal2

# 8. Insert Tapcells and Endcaps
puts "\n[STEP 8] Inserting Well Taps and Endcap Cells..."
tapcell -endcap_cpp 1 \
        -distance 120 \
        -tapcell_master "TAPCELL_X1" \
        -endcap_master "TAPCELL_X1"

# 9. Global Placement
puts "\n[STEP 9] Running Global Placement..."
global_placement -density 0.70 -pad_left 2 -pad_right 2

# 10. Detailed Placement
puts "\n[STEP 10] Running Detailed Placement..."
detailed_placement

# 11. Clock Tree Synthesis (CTS)
puts "\n[STEP 11] Running Clock Tree Synthesis (CTS)..."
repair_clock_inverters
clock_tree_synthesis -root_buf "BUF_X4" -buf_list "BUF_X4 BUF_X8 CLKBUF_X1 CLKBUF_X2 CLKBUF_X3"
repair_clock_nets

# 12. Global Routing (FastRoute)
puts "\n[STEP 12] Running Global Routing..."
global_route -guide_file "$OUTPUT_DIR/route.guide" \
             -congestion_iterations 50

# 13. Detailed Routing (TritonRoute)
puts "\n[STEP 13] Running Detailed Routing..."
detailed_route -output_drc "$OUTPUT_DIR/drc.rpt" \
               -output_maze "$OUTPUT_DIR/maze.log"

# 14. Parasitic Extraction (RC Extraction)
puts "\n[STEP 14] Extracting Parasitics (SPEF)..."
extract_parasitics -ext_model_file "$PDK_DIR/NangateOpenCellLibrary.tech.lef"
write_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

# 15. Post-Route Static Timing Analysis (STA)
puts "\n[STEP 15] Running Post-Route Static Timing Analysis..."
read_spef "$OUTPUT_DIR/${DESIGN_NAME}.spef"

report_checks -path_delay min_max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 > "$OUTPUT_DIR/post_route_timing.rpt"
report_worst_slack -max -digits 4 > "$OUTPUT_DIR/post_route_wns.rpt"
report_worst_slack -min -digits 4 > "$OUTPUT_DIR/post_route_hold.rpt"
report_tns -digits 4 > "$OUTPUT_DIR/post_route_tns.rpt"
report_power -digits 4 > "$OUTPUT_DIR/post_route_power.rpt"

# 16. Write Routed Netlist and DEF
write_def "$OUTPUT_DIR/${DESIGN_NAME}.def"
write_verilog "$OUTPUT_DIR/${DESIGN_NAME}.routed.v"

puts "\n================================================================================"
puts "  OPENROAD PHYSICAL IMPLEMENTATION COMPLETED SUCCESSFULLY"
puts "  Outputs written to: $OUTPUT_DIR"
puts "================================================================================"
exit 0
