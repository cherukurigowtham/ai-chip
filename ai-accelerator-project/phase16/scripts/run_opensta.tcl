# ==============================================================================
# OpenSTA Sign-Off Static Timing & Power Analysis Script
# Project: 4x4 Systolic Array AI Accelerator (accelerator_top)
# Platform: Nangate 45nm Open Cell Library
# ==============================================================================

set PDK_DIR       "ai-accelerator-project/phase16/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase16/netlist"
set SDC_DIR       "ai-accelerator-project/phase16/sdc"
set REPORT_DIR    "ai-accelerator-project/phase16/sta_reports"

proc write_report { filename body } {
    sta::redirect_file_begin $filename
    uplevel 1 $body
    sta::redirect_file_end
}

puts "================================================================================"
puts "  PHASE 16: REAL EDA OPENSTA TIMING AND POWER VALIDATION"
puts "================================================================================"

# 1. Read Liberty Timing and Power Models
puts "\n>>> Reading Liberty Library..."
read_liberty $PDK_DIR/nangate45.lib

# 2. Read Synthesized Gate-Level Verilog Netlist
puts "\n>>> Reading Gate-Level Verilog Netlist..."
read_verilog $NETLIST_DIR/accelerator_top.netlist.v

# 3. Link Design Hierarchy
puts "\n>>> Linking Design Hierarchy..."
link_design accelerator_top

# 4. Read Synopsys Design Constraints (SDC)
puts "\n>>> Reading SDC Constraints..."
read_sdc $SDC_DIR/accelerator_top.sdc

# 5. Units & Clock Configuration
puts "\n>>> Reporting Units & Clocks..."
write_report "$REPORT_DIR/units.rpt" {
    report_units
}
write_report "$REPORT_DIR/clocks.rpt" {
    report_clock_properties
}

# 6. Detailed Timing Checks
puts "\n>>> Generating Detailed Timing Checks..."
write_report "$REPORT_DIR/timing_checks.rpt" {
    report_checks -path_delay min_max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4
}

write_report "$REPORT_DIR/top20_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_count 20 -digits 4
}

write_report "$REPORT_DIR/top20_hold_paths.rpt" {
    report_checks -path_delay min -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_count 20 -digits 4
}

# 7. Slack, WNS, TNS & Clock Min Period
puts "\n>>> Reporting Slacks, WNS, TNS & Minimum Period..."
write_report "$REPORT_DIR/setup_worst_slack.rpt" {
    report_worst_slack -max -digits 4
}

write_report "$REPORT_DIR/hold_worst_slack.rpt" {
    report_worst_slack -min -digits 4
}

write_report "$REPORT_DIR/wns.rpt" {
    report_wns -digits 4
}

write_report "$REPORT_DIR/tns.rpt" {
    report_tns -digits 4
}

write_report "$REPORT_DIR/clock_min_period.rpt" {
    report_clock_min_period -clocks clk
}

# 8. Sanity Check Setup
puts "\n>>> Checking Design & Timing Constraints..."
write_report "$REPORT_DIR/check_setup.rpt" {
    check_setup -verbose
}

# 9. Power Analysis
puts "\n>>> Running Power Analysis..."
write_report "$REPORT_DIR/power.rpt" {
    report_power -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA EXECUTION COMPLETED SUCCESSFULLY"
puts "================================================================================"
exit 0
