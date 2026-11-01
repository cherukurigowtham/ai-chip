read_lef /work/ai-accelerator-project/ternary/physical/pdk/NangateOpenCellLibrary.tech.lef
read_lef /work/ai-accelerator-project/ternary/physical/pdk/NangateOpenCellLibrary.macro.lef
read_liberty /work/ai-accelerator-project/ternary/physical/pdk/nangate45.lib
read_db /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/accelerator_ternary_top.odb
read_sdc /work/ai-accelerator-project/ternary/physical/sdc/accelerator_ternary_top.sdc
read_spef /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/accelerator_ternary_top.spef

puts "=== TOP 10 SETUP PATHS ==="
report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 -endpoint_count 10 > /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/top10_setup_paths.rpt

puts "=== TOP 10 REGISTER-TO-REGISTER SETUP PATHS ==="
report_checks -path_delay max -to [all_registers -data_pins] -fields {slew cap input nets fanout} -format full_clock_expanded -digits 4 -endpoint_count 10 > /work/ai-accelerator-project/ternary/physical/openroad_8x8_run/top10_reg2reg_paths.rpt

puts "=== WNS REPORT ==="
report_worst_slack -max -digits 4
report_tns -digits 4
exit
