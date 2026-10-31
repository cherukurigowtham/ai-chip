# ==============================================================================
# OpenSTA Static Timing & Power Analysis Script - Phase 17 Sign-Off
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
puts "  PHASE 17 FINAL SIGN-OFF: OPENSTA TIMING ON OPTIMIZED NETLIST"
puts "================================================================================"

# 1. Read Liberty
read_liberty $PDK_DIR/nangate45.lib

# 2. Read Final Netlist
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 3. Link Design
link_design accelerator_top

# 4. Read SDC (2.0 ns target clock)
read_sdc $SDC_DIR/accelerator_top.sdc

# 5. Timing Reports
puts "\n>>> Generating Sign-Off Timing Reports..."
write_report "$REPORT_DIR/signoff_units.rpt" { report_units }
write_report "$REPORT_DIR/signoff_clocks.rpt" { report_clock_properties }

write_report "$REPORT_DIR/signoff_top20_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

write_report "$REPORT_DIR/signoff_top20_hold_paths.rpt" {
    report_checks -path_delay min -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

write_report "$REPORT_DIR/signoff_setup_worst_slack.rpt" {
    report_worst_slack -max -digits 4
}

write_report "$REPORT_DIR/signoff_hold_worst_slack.rpt" {
    report_worst_slack -min -digits 4
}

write_report "$REPORT_DIR/signoff_wns.rpt" {
    report_wns -digits 4
}

write_report "$REPORT_DIR/signoff_tns.rpt" {
    report_tns -digits 4
}

write_report "$REPORT_DIR/signoff_clock_min_period.rpt" {
    report_clock_min_period -clocks clk
}

write_report "$REPORT_DIR/signoff_power.rpt" {
    report_power -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA SIGN-OFF COMPLETED"
puts "================================================================================"
exit 0
