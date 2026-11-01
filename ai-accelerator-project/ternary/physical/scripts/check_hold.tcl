set PDK_DIR /work/ai-accelerator-project/ternary/physical/pdk
read_lef $PDK_DIR/NangateOpenCellLibrary.tech.lef
read_lef $PDK_DIR/NangateOpenCellLibrary.macro.lef
read_liberty $PDK_DIR/nangate45.lib
read_db /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/accelerator_ternary_top.odb
read_sdc /work/ai-accelerator-project/ternary/physical/sdc/accelerator_ternary_top.sdc
read_spef /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/accelerator_ternary_top.spef
set_propagated_clock [all_clocks]

puts "=== WORST 5 REG-TO-REG HOLD CHECKS ==="
report_checks -path_delay min -from [all_registers] -to [all_registers -data_pins] -endpoint_path_count 5 -digits 4

exit
