# ==============================================================================
# OpenSTA Static Timing & Power Analysis Script - Phase 17 Step 2 (HFNS Netlist)
# ==============================================================================

set PDK_DIR       "ai-accelerator-project/phase17/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase17/synthesis"
set SDC_DIR       "ai-accelerator-project/phase17/sdc"
set REPORT_DIR    "ai-accelerator-project/phase17/sta_reports"

proc write_report { filename body } {
    sta::redirect_file_begin $filename
    uplevel 1 $body
    sta::redirect_file_end
}

puts "================================================================================"
puts "  PHASE 17 STEP 2: OPENSTA TIMING ON HFNS-BUFFERED NETLIST"
puts "================================================================================"

# 1. Read Liberty
read_liberty $PDK_DIR/nangate45.lib

# 2. Read HFNS Netlist
read_verilog $NETLIST_DIR/accelerator_top.hfns.v

# 3. Link Design
link_design accelerator_top

# 4. Read SDC
read_sdc $SDC_DIR/accelerator_top.sdc

# 5. Timing Reports
puts "\n>>> Generating Timing Reports..."
write_report "$REPORT_DIR/hfns_units.rpt" { report_units }
write_report "$REPORT_DIR/hfns_clocks.rpt" { report_clock_properties }

write_report "$REPORT_DIR/hfns_timing_checks.rpt" {
    report_checks -path_delay min_max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4
}

write_report "$REPORT_DIR/hfns_top20_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

write_report "$REPORT_DIR/hfns_top20_hold_paths.rpt" {
    report_checks -path_delay min -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

write_report "$REPORT_DIR/hfns_setup_worst_slack.rpt" {
    report_worst_slack -max -digits 4
}

write_report "$REPORT_DIR/hfns_hold_worst_slack.rpt" {
    report_worst_slack -min -digits 4
}

write_report "$REPORT_DIR/hfns_wns.rpt" {
    report_wns -digits 4
}

write_report "$REPORT_DIR/hfns_tns.rpt" {
    report_tns -digits 4
}

write_report "$REPORT_DIR/hfns_clock_min_period.rpt" {
    report_clock_min_period -clocks clk
}

write_report "$REPORT_DIR/hfns_power.rpt" {
    report_power -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA HFNS TIMING ANALYSIS COMPLETED"
puts "================================================================================"
exit 0
