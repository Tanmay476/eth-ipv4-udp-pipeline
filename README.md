# Ethernet/IPv4/UDP Packet Processor

Pipelined FPGA packet processor that parses Ethernet, IPv4, and UDP headers
at 1 packet per cycle throughput using byte-serial AXI-Stream interfaces.

## Features

- Three-stage pipeline: Ethernet → IPv4 → UDP header parsing
- AXI-Stream slave input (raw Ethernet frames, 8-bit data width)
- AXI-Stream master output (UDP payload bytes)
- Full backpressure support (TREADY/TVALID handshake throughout)
- Optional IPv4 header checksum validation (RFC 791)
- Optional UDP checksum validation (RFC 768, handles disabled checksum = 0x0000)
- Fragmented packet detection and optional drop
- Non-IPv4 and non-UDP frames are silently dropped
- Metadata sideband: source/dest MAC, source/dest IP, ports, TTL, protocol,
  UDP length, payload length, error flags — valid one cycle after first payload byte
- Target: 100 MHz on Xilinx Artix-7 / Intel Cyclone V (and above)

## Directory Structure

```
rtl/
  axi_stream/    — AXI-Stream interface definition (axi_stream_if.sv)
  ethernet/      — Ethernet frame parser (eth_parser.sv)
  ipv4/          — IPv4 header parser (ipv4_parser.sv) + checksum (ipv4_checksum.sv)
  udp/           — UDP header parser (udp_parser.sv) + checksum (udp_checksum.sv)
  pipeline/      — Pipeline controller (pipeline_ctrl.sv)
  top/           — Top-level integration (packet_processor_top.sv)
                   Metadata formatter  (metadata_formatter.sv)
  filelist.f     — RTL source file list in compilation order
tb/
  packet_gen/    — Packet generator (packet_generator.sv) + scoreboard (scoreboard.sv)
  tests/         — Test suites: test_basic_packets.sv, test_error_cases.sv,
                   test_throughput.sv
  tb_packet_processor.sv — Top-level self-checking testbench
sim/             — Simulation working directory (created by run_sim.sh)
impl/            — Synthesis/P&R output directory (created by synth.tcl)
scripts/
  simulation/    — run_sim.sh: multi-simulator simulation script
  synthesis/     — synth.tcl: Vivado synthesis and implementation script
constraints/
  timing.xdc     — Timing constraints (clock, I/O delays, multicycle paths)
docs/            — Additional documentation
```

## Pipeline Architecture

```
Raw Ethernet Frame (AXI-Stream, 8-bit)
         │
         ▼
   ┌─────────────┐
   │  eth_parser │  Stage 1 — strips 14-byte Ethernet header
   │             │  Extracts: dst_mac, src_mac, ethertype
   │             │  Drops non-IPv4 frames (ethertype ≠ 0x0800)
   └──────┬──────┘
          │ IPv4 payload stream
          ▼
   ┌──────────────────────────────────────┐
   │  ipv4_parser       ipv4_checksum     │  Stage 2
   │  (serial parse)    (optional, ║)     │  strips 20–60 byte IPv4 header
   │  Extracts: ver, IHL, protocol,       │  Drops non-UDP (proto ≠ 0x11)
   │  TTL, src_ip, dst_ip, frag flags     │  Drops fragments if DROP_FRAGMENTS=1
   └──────┬───────────────────────────────┘
          │ UDP segment stream
          ▼
   ┌──────────────────────────────────────┐
   │  udp_parser        udp_checksum      │  Stage 3
   │  (serial parse)    (optional, ║)     │  strips 8-byte UDP header
   │  Extracts: src_port, dst_port,       │  Flags checksum errors
   │  length, checksum                    │
   └──────┬───────────────────────────────┘
          │ UDP payload stream
          ▼
   UDP Payload (AXI-Stream, 8-bit)  +  Metadata sideband (parallel)
```

## Top-Level Parameters

| Parameter            | Default | Description                                      |
|----------------------|---------|--------------------------------------------------|
| `DROP_FRAGMENTS`     | `1`     | Drop fragmented IPv4 packets (1=drop, 0=forward) |
| `VALIDATE_IP_CHKSUM` | `1`     | Enable IPv4 header checksum validation           |
| `VALIDATE_UDP_CHKSUM`| `1`     | Enable UDP checksum validation                   |

## Metadata Sideband Outputs

All signals are valid for one cycle when `meta_valid` is asserted, coinciding
with the first byte of the UDP payload on `m_axis`.

| Port              | Width  | Description                        |
|-------------------|--------|------------------------------------|
| `meta_valid`      | 1      | Metadata valid strobe              |
| `meta_packet_valid`| 1     | 1 = packet passed all checks       |
| `meta_src_mac`    | 48     | Ethernet source MAC address        |
| `meta_dst_mac`    | 48     | Ethernet destination MAC address   |
| `meta_src_ip`     | 32     | IPv4 source address                |
| `meta_dst_ip`     | 32     | IPv4 destination address           |
| `meta_ttl`        | 8      | IPv4 TTL field                     |
| `meta_protocol`   | 8      | IPv4 protocol field (always 0x11)  |
| `meta_src_port`   | 16     | UDP source port                    |
| `meta_dst_port`   | 16     | UDP destination port               |
| `meta_udp_length` | 16     | UDP length field (header + payload)|
| `meta_payload_len`| 16     | UDP payload length (udp_length − 8)|
| `meta_error_flags`| 4      | `[0]` IP header invalid, `[1]` fragmented, `[2]` UDP checksum error, `[3]` reserved |

## Simulation

### Prerequisites

Install one of the following simulators:

- **Verilator** (recommended, open-source): `apt install verilator` or build from source
- **Icarus Verilog** (open-source fallback): `apt install iverilog`
- **Questa / ModelSim**: requires a Mentor/Siemens license
- **VCS**: requires a Synopsys license

### Running the testbench

```bash
# Auto-detect simulator, run all test suites
./scripts/simulation/run_sim.sh

# Choose simulator explicitly
./scripts/simulation/run_sim.sh --sim iverilog

# Enable VCD waveform dump
./scripts/simulation/run_sim.sh --wave

# Open waveform in GTKWave
gtkwave sim/tb_packet_processor.vcd

# Clean simulation artifacts before running
./scripts/simulation/run_sim.sh --clean
```

### Test suites

The testbench runs three suites automatically:

| Suite       | File                          | What it covers                                           |
|-------------|-------------------------------|----------------------------------------------------------|
| **basic**   | `tb/tests/test_basic_packets.sv`  | Single packet, back-to-back, min/max payload, metadata   |
| **error**   | `tb/tests/test_error_cases.sv`    | Non-IPv4, non-UDP, fragments, bad IHL/version, bad checksum |
| **throughput** | `tb/tests/test_throughput.sv`  | 10-packet burst, backpressure (TREADY toggling), latency |

## Synthesis (Xilinx Vivado)

### Prerequisites

- Xilinx Vivado 2021.2 or later (free WebPACK edition supports Artix-7)

### Running synthesis

```bash
# From the project root (targets xc7a100tcsg324-1 by default)
vivado -mode batch -source scripts/synthesis/synth.tcl

# Override part and parallelism
vivado -mode batch -source scripts/synthesis/synth.tcl \
       -tclargs --part xc7k160tffg676-2 --jobs 8
```

Outputs are written to `impl/`:

| File                        | Description                          |
|-----------------------------|--------------------------------------|
| `impl/post_synth.dcp`       | Post-synthesis checkpoint            |
| `impl/post_impl.dcp`        | Post-implementation checkpoint       |
| `impl/timing_summary.rpt`   | Setup / hold timing summary          |
| `impl/utilization.rpt`      | LUT / FF / BRAM utilization          |
| `impl/power.rpt`            | Power estimate                       |
| `impl/route_status.rpt`     | Routing completion status            |
| `impl/drc.rpt`              | Design rule check results            |

### Bitstream generation

Bitstream generation requires board-specific pin assignment constraints.
Add your I/O assignments to `constraints/pinout.xdc`, then uncomment the
`write_bitstream` call at the bottom of `scripts/synthesis/synth.tcl`.

## Timing Constraints Summary

The `constraints/timing.xdc` file defines:

- **Clock**: 10.0 ns (100 MHz) on `clk`
- **I/O delays**: 2.0 ns max / 0.5 ns min setup/hold on all ports
- **False path**: asynchronous `rst_n` assertion
- **Multicycle paths**: 2-cycle relaxation for checksum carry-fold registers
  in `ipv4_checksum` and `udp_checksum` — enables 400+ MHz checksum paths

Adjust the `create_clock -period` value to target higher frequencies
(e.g., `8.0` for 125 MHz, `5.0` for 200 MHz).
