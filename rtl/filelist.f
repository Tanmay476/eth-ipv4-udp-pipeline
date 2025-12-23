# RTL filelist for compilation order
# TODO: Update paths as modules are implemented

# AXI-Stream interface
rtl/axi_stream/axi_stream_if.sv

# Ethernet parser
rtl/ethernet/eth_parser.sv

# IPv4 parser and checksum
rtl/ipv4/ipv4_parser.sv
rtl/ipv4/ipv4_checksum.sv

# UDP parser and checksum
rtl/udp/udp_parser.sv
rtl/udp/udp_checksum.sv

# Pipeline control
rtl/pipeline/pipeline_ctrl.sv

# Top-level
rtl/top/metadata_formatter.sv
rtl/top/packet_processor_top.sv
