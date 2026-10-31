# ==============================================================================
# OpenSTA Comprehensive Timing Analysis - Phase 20
# Wire-Load Model: 5K_hvratio_1_1 | Target: 500 MHz (2.0 ns)
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
puts "  PHASE 20: OPENSTA TIMING ON OPTIMIZED LOCALIZED-CONTROL NETLIST"
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

# ------------------------------------------------------------------------------
# Analysis A: Full Unconstrained Single-Cycle Timing (Including Quasi-Static Mode Regs)
# ------------------------------------------------------------------------------
puts "\n>>> Analysis A: Single-Cycle Timing (All Paths Unconstrained)..."
write_report "$REPORT_DIR/unconstrained_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/unconstrained_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/unconstrained_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/unconstrained_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/unconstrained_power.rpt"       { report_power -digits 4 }
write_report "$REPORT_DIR/unconstrained_top5_setup.rpt"  {
    report_checks -path_delay max -fields {slew cap input fanout} -format full_clock_expanded -endpoint_path_count 5 -digits 4
}

# ------------------------------------------------------------------------------
# Analysis B: Live Active Datapath Timing (Quasi-Static Mode Defined as Multi-Cycle)
# ------------------------------------------------------------------------------
puts "\n>>> Analysis B: Active Datapath Timing (Live Compute Cycles)..."
# Multi-cycle path on quasi-static mode registers
set_multicycle_path 2 -setup -from [get_pins -hier */mode_os*/Q]

write_report "$REPORT_DIR/live_datapath_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/live_datapath_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/live_datapath_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/live_datapath_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/live_datapath_top5_setup.rpt"  {
    report_checks -path_delay max -fields {slew cap input fanout} -format full_clock_expanded -endpoint_path_count 5 -digits 4
}

puts "\n================================================================================"
puts "  OPENSTA PHASE 20 COMPREHENSIVE ANALYSIS COMPLETED"
puts "================================================================================"
exit 0
