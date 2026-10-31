# ==============================================================================
# OpenSTA Physical Parasitic Sensitivity Script - Phase 19 Validation
# Target Clock: 500 MHz (2.0 ns period)
# ==============================================================================

set PDK_DIR       "ai-accelerator-project/phase19/pdk"
set NETLIST_DIR   "ai-accelerator-project/phase19/synthesis"
set SDC_DIR       "ai-accelerator-project/phase19/sdc"
set REPORT_DIR    "ai-accelerator-project/phase19/sta_reports"

proc write_report { filename body } {
    sta::redirect_file_begin $filename
    uplevel 1 $body
    sta::redirect_file_end
}

puts "================================================================================"
puts "  PHASE 19 TIMING SENSITIVITY: PRE-ROUTE VS WIRE-LOAD PHYSICAL PARASITICS"
puts "================================================================================"

# 1. Read Liberty
read_liberty $PDK_DIR/nangate45.lib

# 2. Read Final Netlist
read_verilog $NETLIST_DIR/accelerator_top.final_hfns.v

# 3. Link Design
link_design accelerator_top

# 4. Read SDC (2.0 ns target clock = 500 MHz)
read_sdc $SDC_DIR/accelerator_top.sdc

# ------------------------------------------------------------------------------
# Run 1: Zero Wire-Load Model (Pre-Route Baseline)
# ------------------------------------------------------------------------------
puts "\n>>> Evaluating Baseline (Pre-Route Zero-Interconnect)..."
write_report "$REPORT_DIR/preroute_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/preroute_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/preroute_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/preroute_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/preroute_power.rpt"       { report_power -digits 4 }

# ------------------------------------------------------------------------------
# Run 2: Wire-Load Model 1K_hvratio_1_1 (Short Interconnect / Small Die)
# ------------------------------------------------------------------------------
puts "\n>>> Evaluating Wire-Load 1K_hvratio_1_1..."
set_wire_load_model -name "1K_hvratio_1_1"
set_wire_load_mode top
write_report "$REPORT_DIR/wireload_1k_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/wireload_1k_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/wireload_1k_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/wireload_1k_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/wireload_1k_power.rpt"       { report_power -digits 4 }

# ------------------------------------------------------------------------------
# Run 3: Wire-Load Model 3K_hvratio_1_1 (Medium Interconnect)
# ------------------------------------------------------------------------------
puts "\n>>> Evaluating Wire-Load 3K_hvratio_1_1..."
set_wire_load_model -name "3K_hvratio_1_1"
set_wire_load_mode top
write_report "$REPORT_DIR/wireload_3k_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/wireload_3k_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/wireload_3k_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/wireload_3k_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/wireload_3k_power.rpt"       { report_power -digits 4 }

# ------------------------------------------------------------------------------
# Run 4: Wire-Load Model 5K_hvratio_1_1 (Nangate Default Interconnect)
# ------------------------------------------------------------------------------
puts "\n>>> Evaluating Wire-Load 5K_hvratio_1_1..."
set_wire_load_model -name "5K_hvratio_1_1"
set_wire_load_mode top
write_report "$REPORT_DIR/wireload_5k_setup_slack.rpt" { report_worst_slack -max -digits 4 }
write_report "$REPORT_DIR/wireload_5k_hold_slack.rpt"  { report_worst_slack -min -digits 4 }
write_report "$REPORT_DIR/wireload_5k_wns.rpt"         { report_wns -digits 4 }
write_report "$REPORT_DIR/wireload_5k_tns.rpt"         { report_tns -digits 4 }
write_report "$REPORT_DIR/wireload_5k_power.rpt"       { report_power -digits 4 }

# Critical path inspection under 5K wire load
write_report "$REPORT_DIR/wireload_5k_top5_setup_paths.rpt" {
    report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -endpoint_path_count 5 -digits 4
}

puts "\n================================================================================"
puts "  PHASE 19 TIMING SENSITIVITY ANALYSIS COMPLETED"
puts "================================================================================"
exit 0
