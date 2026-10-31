# Check datapath-only setup paths in OpenSTA under wire load 5K
read_liberty ai-accelerator-project/phase19/pdk/nangate45.lib
read_verilog ai-accelerator-project/phase19/synthesis/accelerator_top.final_hfns.v
link_design accelerator_top
read_sdc ai-accelerator-project/phase19/sdc/accelerator_top.sdc

set_wire_load_model -name "5K_hvratio_1_1"
set_wire_load_mode top

# Report top setup paths excluding u_controller/_58293_
puts ">>> TOP SETUP PATHS NOT STARTING AT _58293_:"
report_checks -path_delay max -from [get_pins u_controller/u_systolic_core/* -filter "direction == out"] -endpoint_path_count 5 -digits 4

# Report paths from PE registers
puts ">>> TOP SETUP PATHS FROM PE FLIP-FLOPS:"
report_checks -path_delay max -from [get_pins u_controller/u_systolic_core/gen_row*.gen_col*.u_pe/* -filter "is_hierarchical == false"] -endpoint_path_count 5 -digits 4

exit
