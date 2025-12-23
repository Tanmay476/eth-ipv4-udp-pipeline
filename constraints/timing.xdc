# TODO: Timing constraints for Xilinx FPGAs
# TODO: Define clock period (target 100+ MHz, e.g., 10ns for 100 MHz)
# create_clock -period 10.0 -name clk [get_ports clk]

# TODO: Set input and output delays relative to clock
# TODO: Define false paths if any
# TODO: Define multicycle paths if needed for checksum calculations

# TODO: Constrain AXI-Stream interfaces
# TODO: Add clock domain crossing constraints if multiple clocks used
