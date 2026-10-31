read_liberty ai-accelerator-project/phase19/pdk/nangate45.lib
read_verilog ai-accelerator-project/phase19/synthesis/accelerator_top.final_hfns.v
link_design accelerator_top
read_sdc ai-accelerator-project/phase19/sdc/accelerator_top.sdc

set_wire_load_model -name "5K_hvratio_1_1"
set_wire_load_mode top

# Invalidate paths from the mode_os register
set_false_path -from [get_cells u_controller/_58293_]

puts "=== WORST SETUP SLACK WITHOUT _58293_ ==="
report_worst_slack -max -digits 4
report_wns -digits 4
report_tns -digits 4

puts "=== TOP SETUP PATH WITHOUT _58293_ ==="
report_checks -path_delay max -fields {slew cap input fanout} -format full_clock_expanded -endpoint_path_count 1 -digits 4

exit
