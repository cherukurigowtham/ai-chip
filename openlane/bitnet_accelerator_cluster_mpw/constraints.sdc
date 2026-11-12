# ==============================================================================
# SDC Timing Constraints: bitnet_mpw_accelerator_macro (SkyWater Sky130)
# Target Clock: 50 MHz (20.0 ns Clock Period)
# ==============================================================================

set clk_period 20.0
set clk_port "wb_clk_i"

create_clock -name "clk" -period $clk_period [get_ports $clk_port]

# Clock Uncertainty & Jitter Margins
set_clock_uncertainty 0.25 [get_clocks "clk"]
set_clock_transition 0.15 [get_clocks "clk"]

# Input Delays (30% of clock period budget)
set_input_delay -clock [get_clocks "clk"] -max 4.0 [all_inputs -no_clocks]
set_input_delay -clock [get_clocks "clk"] -min 0.5 [all_inputs -no_clocks]

# Output Delays (30% of clock period budget)
set_output_delay -clock [get_clocks "clk"] -max 4.0 [all_outputs]
set_output_delay -clock [get_clocks "clk"] -min 0.5 [all_outputs]

# Driving Cell & Load Capacitance
set_driving_cell -lib_cell "sky130_fd_sc_hd__inv_2" -pin "Y" [all_inputs -no_clocks]
set_load 0.035 [all_outputs]
