# ==============================================================================
# Constraints for 8x8 Ternary AI Accelerator (Xilinx 7-Series / UltraScale+)
# Target: Out-of-Context (OOC) IP Integration / Board Top-Level
# Target Clock: 100 MHz (10.000 ns) - Standard Zynq AXI FCLK
# ==============================================================================

# Primary System Clock
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]

# Clock Uncertainty & Jitter
set_clock_uncertainty 0.200 [get_clocks clk]

# Input / Output Delays for AXI4-Lite & AXI4-Stream (Assuming 30% bus budget)
set_input_delay -clock clk -max 3.000 [get_ports {s_axil_* s_axis_* rst_n}]
set_input_delay -clock clk -min 0.500 [get_ports {s_axil_* s_axis_* rst_n}]

set_output_delay -clock clk -max 3.000 [get_ports {s_axil_* m_axis_* irq_done}]
set_output_delay -clock clk -min 0.500 [get_ports {s_axil_* m_axis_* irq_done}]
