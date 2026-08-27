//================================================================================
// File: ipv4_parser.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   IPv4 header parser - Pipeline stage 2
//   Parses variable-length IPv4 header (20-60 bytes), extracts version, IHL,
//   protocol, TTL, source/dest IP addresses. Forwards UDP packets (protocol =
//   0x11) to UDP parser. Drops non-UDP packets and fragmented packets.
//
// Features:
//   - AXI Stream interface (8-bit data width)
//   - Variable header length handling (IHL field)
//   - Fragmentation detection and filtering
//   - Protocol-based packet filtering
//   - Proper backpressure handling
//
//================================================================================

`timescale 1ns/1ps

module ipv4_parser #(
    parameter DATA_BUS_WIDTH = 8,      // Width of the data bus in bits
    parameter VALIDATE_CHECKSUM = 0,   // Enable header checksum validation
    parameter DROP_FRAGMENTS = 1       // Drop fragmented packets (1) or forward them (0)
)(
    // Clock and reset
    input logic clk,
    input logic rst_n,

    // AXI Stream Slave Interface (from Ethernet parser)
    input logic [7:0] s_axis_tdata,    // Input data byte
    input logic s_axis_tvalid,          // Input data valid
    input logic s_axis_tlast,           // End of frame
    output logic s_axis_tready,         // Ready to accept data

    // AXI Stream Master Interface (to UDP parser)
    output logic [7:0] m_axis_tdata,   // Output data byte
    output logic m_axis_tvalid,         // Output data valid
    output logic m_axis_tlast,          // End of payload
    input logic m_axis_tready,          // Downstream ready

    // Extracted IPv4 Header Fields
    output logic [3:0] ip_version,      // IP version (should be 4)
    output logic [3:0] ip_ihl,          // Internet Header Length (in 32-bit words)
    output logic [7:0] ip_protocol,     // Protocol (0x11 = UDP)
    output logic [7:0] ip_ttl,          // Time to Live
    output logic [15:0] ip_total_length, // Total packet length (header + payload)
    output logic [31:0] ip_src_addr,    // Source IP address
    output logic [31:0] ip_dest_addr,   // Destination IP address

    // Status/Control Signals
    output logic ip_header_valid,       // Header passed validation
    output logic is_fragment            // Packet is fragmented
);

typedef enum logic[2:0] {
    IDLE,
    PARSE_HEADER,
    VALIDATE_HEADER,
    FORWARD_PAYLOAD,
    DROP_PACKET
} state_t;

state_t state;
state_t next_state;

// Internal registers
logic [5:0] byte_count;                 // Count bytes (max 60 for IPv4 header)
logic [5:0] header_length_bytes;        // Calculated header length in bytes

// Buffer registers for header fields
logic [3:0] ip_version_buffer;
logic [3:0] ip_ihl_buffer;
logic [7:0] ip_protocol_buffer;
logic [7:0] ip_ttl_buffer;
logic [15:0] ip_total_length_buffer;
logic [31:0] ip_src_addr_buffer;
logic [31:0] ip_dest_addr_buffer;

// Fragmentation fields
logic [7:0] flags_and_offset_high;      // Byte 6
logic [7:0] offset_low;                 // Byte 7
logic [12:0] fragment_offset;
logic more_fragments;
logic is_fragment_buffer;

// State machine - sequential logic
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state <= IDLE;
    end else begin
        state <= next_state;
    end
end

// State machine - combinational logic
always_comb begin
    case(state)
        IDLE: begin
            if (s_axis_tvalid) begin
                next_state = PARSE_HEADER;
            end else begin
                next_state = IDLE;
            end
        end

        PARSE_HEADER: begin
            // Leave PARSE_HEADER on the cycle the LAST header byte is accepted
            // (byte_count == header_length_bytes - 1).  Comparing
            // byte_count >= header_length_bytes instead would keep TREADY high
            // for one extra cycle and silently swallow the first payload byte.
            if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
                // Frame ended mid-header (truncated, or a bogus IHL that the
                // byte count can never reach) - abort rather than wedge here.
                next_state = IDLE;
            end else if (s_axis_tvalid && s_axis_tready &&
                         (header_length_bytes > 0) &&
                         (byte_count == header_length_bytes - 6'd1)) begin
                next_state = VALIDATE_HEADER;
            end else begin
                next_state = PARSE_HEADER;
            end
        end

        VALIDATE_HEADER: begin
            // Check: version=4, IHL valid, protocol=UDP, not fragmented (if DROP_FRAGMENTS=1)
            if ((ip_version_buffer == 4'd4) &&
                (ip_ihl_buffer >= 4'd5) &&
                (ip_protocol_buffer == 8'h11) &&
                (!(is_fragment_buffer && DROP_FRAGMENTS))) begin
                next_state = FORWARD_PAYLOAD;
            end else begin
                next_state = DROP_PACKET;
            end
        end

        FORWARD_PAYLOAD: begin
            if (s_axis_tlast && s_axis_tvalid && s_axis_tready) begin
                next_state = IDLE;
            end else begin
                next_state = FORWARD_PAYLOAD;
            end
        end

        DROP_PACKET: begin
            if (s_axis_tlast && s_axis_tvalid) begin
                next_state = IDLE;
            end else begin
                next_state = DROP_PACKET;
            end
        end

        default: begin
            next_state = IDLE;
        end
    endcase
end

// Data path - sequential logic
always_ff @(posedge clk) begin
    if (!rst_n) begin
        byte_count <= 0;
        header_length_bytes <= 0;
        ip_version_buffer <= 0;
        ip_ihl_buffer <= 0;
        ip_protocol_buffer <= 0;
        ip_ttl_buffer <= 0;
        ip_total_length_buffer <= 0;
        ip_src_addr_buffer <= 0;
        ip_dest_addr_buffer <= 0;
        flags_and_offset_high <= 0;
        offset_low <= 0;
        fragment_offset <= 0;
        more_fragments <= 0;
        is_fragment_buffer <= 0;
    end else begin
        // Reset byte_count when returning to IDLE
        if (state == IDLE) begin
            byte_count <= 0;
            header_length_bytes <= 0;
        end

        if (s_axis_tvalid && s_axis_tready) begin
            // Parse header bytes.  IDLE is included because the upstream stage
            // presents the first header byte in the same cycle it raises TVALID,
            // while this stage is still in IDLE with TREADY asserted.  Parsing
            // only in PARSE_HEADER would drop that byte.
            if (state == IDLE || state == PARSE_HEADER) begin
                case (byte_count)
                    0: begin
                        ip_version_buffer <= s_axis_tdata[7:4];
                        ip_ihl_buffer <= s_axis_tdata[3:0];
                        // Calculate header length immediately
                        header_length_bytes <= {s_axis_tdata[3:0], 2'b00}; // IHL * 4
                    end
                    2: begin
                        ip_total_length_buffer[15:8] <= s_axis_tdata;
                    end
                    3: begin
                        ip_total_length_buffer[7:0] <= s_axis_tdata;
                    end
                    6: begin
                        flags_and_offset_high <= s_axis_tdata;
                        more_fragments <= s_axis_tdata[5]; // MF flag
                    end
                    7: begin
                        offset_low <= s_axis_tdata;
                        fragment_offset <= {flags_and_offset_high[4:0], s_axis_tdata};
                        // Packet is fragmented if MF=1 OR offset!=0
                        is_fragment_buffer <= more_fragments || (fragment_offset != 13'd0);
                    end
                    8: begin
                        ip_ttl_buffer <= s_axis_tdata;
                    end
                    9: begin
                        ip_protocol_buffer <= s_axis_tdata;
                    end
                    12: begin
                        ip_src_addr_buffer[31:24] <= s_axis_tdata;
                    end
                    13: begin
                        ip_src_addr_buffer[23:16] <= s_axis_tdata;
                    end
                    14: begin
                        ip_src_addr_buffer[15:8] <= s_axis_tdata;
                    end
                    15: begin
                        ip_src_addr_buffer[7:0] <= s_axis_tdata;
                    end
                    16: begin
                        ip_dest_addr_buffer[31:24] <= s_axis_tdata;
                    end
                    17: begin
                        ip_dest_addr_buffer[23:16] <= s_axis_tdata;
                    end
                    18: begin
                        ip_dest_addr_buffer[15:8] <= s_axis_tdata;
                    end
                    19: begin
                        ip_dest_addr_buffer[7:0] <= s_axis_tdata;
                    end
                    // Bytes 20+ are options (if IHL > 5), we just skip them
                    default: begin
                        // Continue parsing until header_length_bytes
                    end
                endcase
                byte_count <= byte_count + 1;
            end

        end
    end
end

// Output assignments - combinational logic
always_comb begin
    // Default: assign buffered values to outputs
    ip_version = ip_version_buffer;
    ip_ihl = ip_ihl_buffer;
    ip_protocol = ip_protocol_buffer;
    ip_ttl = ip_ttl_buffer;
    ip_total_length = ip_total_length_buffer;
    ip_src_addr = ip_src_addr_buffer;
    ip_dest_addr = ip_dest_addr_buffer;
    is_fragment = is_fragment_buffer;

    // Payload path is a combinational pass-through: TDATA/TLAST must be
    // presented in the SAME cycle as TVALID (see eth_parser for rationale).
    m_axis_tdata = s_axis_tdata;
    m_axis_tlast = s_axis_tlast;

    // Control signals based on state
    case(state)
        IDLE: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1;       // Ready to accept new packet
            ip_header_valid = 1'b0;
        end

        PARSE_HEADER: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1;       // Ready to accept header bytes
            ip_header_valid = 1'b0;
        end

        VALIDATE_HEADER: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0;       // Not ready while validating
            // Set valid flag based on checks
            ip_header_valid = ((ip_version_buffer == 4'd4) &&
                              (ip_ihl_buffer >= 4'd5) &&
                              (ip_protocol_buffer == 8'h11) &&
                              (!(is_fragment_buffer && DROP_FRAGMENTS)));
        end

        FORWARD_PAYLOAD: begin
            m_axis_tvalid = s_axis_tvalid;  // Pass through valid signal
            s_axis_tready = m_axis_tready;  // Backpressure from downstream
            ip_header_valid = 1'b1;         // Header was valid
        end

        DROP_PACKET: begin
            m_axis_tvalid = 1'b0;           // Don't forward data
            s_axis_tready = 1'b1;           // Accept data to drain
            ip_header_valid = 1'b0;         // Header was invalid
        end

        default: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0;
            ip_header_valid = 1'b0;
        end
    endcase
end

endmodule
