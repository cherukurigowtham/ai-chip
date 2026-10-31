# ==============================================================================
# Synopsys Design Constraints (SDC) for accelerator_top
# Target Platform: Nangate 45nm Open Cell Library
# Target Clock Frequency: 500 MHz (Clock Period = 2.000 ns)
# Capacitive load units: fF (matching nangate45.lib: 1,ff)
# ==============================================================================

# Define Primary Clock (500 MHz, 2.000 ns period, 50% duty cycle)
create_clock -name clk -period 2.000 -waveform {0.000 1.000} [get_ports clk]

# Clock Network Constraints
set_clock_uncertainty 0.050 [get_clocks clk]
set_clock_transition 0.020 [get_clocks clk]

# Input Delay Constraints (20% of clock period = 0.400 ns)
set_input_delay -clock clk -max 0.400 [all_inputs -no_clocks]
set_input_delay -clock clk -min 0.050 [all_inputs -no_clocks]

# Output Delay Constraints (20% of clock period = 0.400 ns)
set_output_delay -clock clk -max 0.400 [all_outputs]
set_output_delay -clock clk -min 0.050 [all_outputs]

# Input Drive Constraints (Standard inverter INV_X2 driving inputs)
set_driving_cell -lib_cell INV_X2 [all_inputs -no_clocks]

# Output Load Capacitance (10 fF = 10.0 fF load)
set_load 10.0 [all_outputs]

# Reset path false path (asynchronous active-low reset assertion/deassertion)
set_false_path -from [get_ports rst_n]
