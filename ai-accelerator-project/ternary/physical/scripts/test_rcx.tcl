read_lef /work/ai-accelerator-project/ternary/physical/pdk/NangateOpenCellLibrary.tech.lef
read_lef /work/ai-accelerator-project/ternary/physical/pdk/NangateOpenCellLibrary.macro.lef
read_liberty /work/ai-accelerator-project/ternary/physical/pdk/nangate45.lib
read_db /work/ai-accelerator-project/ternary/physical/openroad_run/accelerator_ternary_top.odb
read_sdc /work/ai-accelerator-project/ternary/physical/sdc/accelerator_ternary_top.sdc
puts "=== Loaded routed database ==="
extract_parasitics -ext_model_file /work/ai-accelerator-project/ternary/physical/pdk/Nangate45.rcx_rules
puts "=== Extracted parasitics successfully ==="
write_spef /work/ai-accelerator-project/ternary/physical/openroad_run/accelerator_ternary_top.spef
puts "=== Wrote SPEF successfully ==="
exit 0
