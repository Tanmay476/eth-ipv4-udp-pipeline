# Ethernet/IPv4/UDP Packet Processor

Pipelined packet processor for parsing Ethernet, IPv4, and UDP headers with high throughput.

## Features
- Multi-stage pipeline design for 1-packet-per-cycle throughput
- AXI-Stream interfaces for input/output
- IPv4 and UDP checksum validation
- Metadata extraction (IP addresses, ports)
- Error detection for malformed packets
- Target: 100+ MHz on FPGA

## Directory Structure
```
rtl/
  axi_stream/    - AXI-Stream interface definitions
  ethernet/      - Ethernet frame parser
  ipv4/          - IPv4 header parser and checksum
  udp/           - UDP header parser and checksum
  pipeline/      - Pipeline control logic
  top/           - Top-level integration
tb/              - Testbenches
  packet_gen/    - Packet generator and scoreboard
  tests/         - Test cases
sim/             - Simulation working directory
scripts/         - Build and simulation scripts
constraints/     - Timing constraints for synthesis
docs/            - Additional documentation
```

## TODO: Implementation Tasks
- [ ] Implement AXI-Stream interface
- [ ] Implement Ethernet parser
- [ ] Implement IPv4 parser with checksum
- [ ] Implement UDP parser with checksum
- [ ] Implement pipeline controller
- [ ] Integrate all modules in top-level
- [ ] Create comprehensive testbench
- [ ] Verify timing closure at 100+ MHz
- [ ] Optimize for target FPGA

## TODO: Getting Started
Instructions for simulation and synthesis will be added here.
