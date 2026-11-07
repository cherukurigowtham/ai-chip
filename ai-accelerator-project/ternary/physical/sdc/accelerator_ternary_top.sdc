# SDC Timing Constraints for 8x8 Ternary Accelerator @ 500 MHz (2.0 ns)
create_clock -name clk -period 2.000 [get_ports clk]
set_clock_uncertainty 0.050 [all_clocks]
set_input_delay 0.200 -clock clk [all_inputs -no_clocks]
set_output_delay 0.200 -clock clk [all_outputs]
