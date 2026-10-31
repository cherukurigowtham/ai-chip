# ==============================================================================
# OpenSTA Static Timing & Power Analysis Script - Phase 18 Final Sign-Off
# Target: 500 MHz (2.0 ns period)
# ==============================================================================

set PDK_DIR       "ai-accelerator-project/phase18/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase18/synthesis"
set SDC_DIR       "ai-accelerator-project/phase18/sdc"
set REPORT_DIR    "ai-accelerator-project/phase18/sta_reports"

proc write_report { filename body } {
    sta::redirect_file_begin $filename
    uplevel 1 $body
    sta::redirect_file_end
}

puts "================================================================================"
puts "  PHASE 18 SIGN-OFF: OPENSTA TIMING ON FINAL PIPELINED NETLIST"
puts "================================================================================"

# 1. Read Liberty
read_liberty $PDK_DIR/nangate45.lib

# 2. Read Final Netlist
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 3. Link Design
link_design accelerator_top

# 4. Read SDC (2.0 ns target clock = 500 MHz)
read_sdc $SDC_DIR/accelerator_top.sdc

# 5. Timing Reports
puts "\n>>> Generating Timing Reports..."
write_report "$REPORT_DIR/units.rpt" { report_units }
write_report "$REPORT_DIR/clocks.rpt" { report_clock_properties }

write_report "$REPORT_DIR/timing_checks.rpt" {
    report_checks -path_delay min_max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4
}

write_report "$REPORT_DIR/top20_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

write_report "$REPORT_DIR/top20_hold_paths.rpt" {
    report_checks -path_delay min -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 20 -digits 4
}

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

write_report "$REPORT_DIR/power.rpt" {
    report_power -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA PHASE 18 FINAL SIGN-OFF COMPLETED"
puts "================================================================================"
exit 0
