# TODO: Timing constraints for Xilinx FPGAs
# TODO: Define clock period (target 100+ MHz, e.g., 10ns for 100 MHz)
# create_clock -period 10.0 -name clk [get_ports clk]

set_input_delay -clock [get_clocks clk] -max 2.0 [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay -clock [get_clocks clk] -min 0.5 [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock [get_clocks clk] -max 2.0 [all_outputs]
set_output_delay -clock [get_clocks clk] -min 0.5 [all_outputs]
# TODO: Define false paths if any
# TODO: Define multicycle paths if needed for checksum calculations

# TODO: Constrain AXI-Stream interfaces
# TODO: Add clock domain crossing constraints if multiple clocks used
