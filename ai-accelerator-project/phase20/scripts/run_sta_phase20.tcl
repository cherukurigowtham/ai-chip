# ==============================================================================
# OpenSTA Static Timing & Power Analysis Script - Phase 20 Optimization
# Target: 500 MHz (2.0 ns period) with 5K Wire-Load Model (Nangate 45nm)
# ==============================================================================

set PDK_DIR       "ai-accelerator-project/phase20/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase20/synthesis"
set SDC_DIR       "ai-accelerator-project/phase20/sdc"
set REPORT_DIR    "ai-accelerator-project/phase20/sta_reports"

proc write_report { filename body } {
    sta::redirect_file_begin $filename
    uplevel 1 $body
    sta::redirect_file_end
}

puts "================================================================================"
puts "  PHASE 20 SIGN-OFF: OPENSTA TIMING WITH LOCALIZED MODE REGISTERS"
puts "  WIRE-LOAD MODEL: 5K_hvratio_1_1 | TARGET: 500 MHz (2.0 ns)"
puts "================================================================================"

# 1. Read Liberty
read_liberty $PDK_DIR/nangate45.lib

# 2. Read Final Netlist
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 3. Link Design
link_design accelerator_top

# 4. Read SDC (2.0 ns target clock = 500 MHz)
read_sdc $SDC_DIR/accelerator_top.sdc

# 5. Apply standard 5K wire load model
set_wire_load_model -name "5K_hvratio_1_1"
set_wire_load_mode top

# 6. Timing Reports under Wire-Load
puts "\n>>> Generating Timing Reports under 5K Wire-Load..."
write_report "$REPORT_DIR/setup_worst_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/hold_worst_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/wns.rpt"               { report_wns -digits 4 }
write_report "$REPORT_DIR/tns.rpt"               { report_tns -digits 4 }
write_report "$REPORT_DIR/power.rpt"             { report_power -digits 4 }

write_report "$REPORT_DIR/top10_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input fanout} -format full_clock_expanded -endpoint_path_count 10 -digits 4
}

write_report "$REPORT_DIR/top5_hold_paths.rpt" {
    report_checks -path_delay min -fields {slew cap input fanout} -format full_clock_expanded -endpoint_path_count 5 -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA PHASE 20 EVALUATION COMPLETED"
puts "================================================================================"
exit 0
