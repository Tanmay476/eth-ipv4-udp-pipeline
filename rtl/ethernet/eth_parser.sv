//================================================================================
// File: eth_parser.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Ethernet frame parser - Pipeline stage 1
//   Parses 14-byte Ethernet header, extracts destination MAC, source MAC, and
//   EtherType. Forwards IPv4 packets (EtherType = 0x0800) to downstream IPv4
//   parser. Drops all non-IPv4 frames.
//
// Features:
//   - AXI Stream interface (8-bit data width)
//   - State machine-based parsing
//   - Automatic frame filtering based on EtherType
//   - Proper backpressure handling
//
// Future Enhancements:
//   - Frame size validation (64-1518 bytes)
//   - VLAN tagging support (802.1Q)
//   - FCS/CRC validation
//================================================================================

module eth_parser(
    parameter DATA_BUS_WIDTH = 8, // Width of the data bus in bits
    parameter ENABLE_VLAN = 0,// 
    parameter CHECK_FCS = 0, // Validate CRC
    parameter MIN_FRAME_SIZE = 8 // Minimum Ethernet frame size in bytes
)(
    input logic clk,
    input logic rst_n,
    input logic[7:0] s_axis_tdata,
    input logic s_axis_tlast,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    output logic[7:0] m_axis_tdata,
    output logic m_axis_tvalid,
    output logic m_axis_tlast,
    input logic m_axis_tready,
    output logic[47:0] dest_mac,
    output logic[47:0] src_mac,
    output logic[15:0] ether_type
);

typedef enum logic[2:0]{
    IDLE,
    PARSE_HEADER,
    CHECK_ETHERTYPE,
    DROP_FRAME,
    FORWARD_PAYLOAD
} state_t;

state_t state;
state_t next_state;
logic[$clog2(15):0] byte_count;
logic[47:0] dest_mac_buffer;
logic[47:0] src_mac_buffer;
logic[15:0] ether_type_buffer;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= IDLE;
        next_state <= IDLE;
    end else begin
        state <= next_state;
    end
end

always_comb begin
    case(state)
    IDLE: 
        if (s_axis_tvalid) begin
            next_state = PARSE_HEADER;
        end else begin
            next_state = IDLE;
        end
    PARSE_HEADER:
        if (byte_count == 14) begin
            next_state = CHECK_ETHERTYPE;
        end else begin
            next_state = PARSE_HEADER;
        end
    CHECK_ETHERTYPE:
        if (ether_type == 16'h0800) begin
            next_state = FORWARD_PAYLOAD;
        end else begin
            next_state = DROP_FRAME;
        end
    DROP_FRAME:
        if (s_axis_tlast) begin
            next_state = IDLE;
        end else begin
            next_state = DROP_FRAME;
        end
    FORWARD_PAYLOAD:
        if (s_axis_tlast) begin
            next_state = IDLE;
        end else begin
            next_state = FORWARD_PAYLOAD;
        end
    default:
        next_state = IDLE;      
    endcase
end

always_ff(@posedge clk) begin
    if (!rst_n) begin
        byte_count <= 0;
        dest_mac_buffer <= 0;
        src_mac_buffer <= 0;
        ether_type_buffer <= 0;
        m_axis_tdata <= 0;
        m_axis_tlast <= 0;
    end else begin
        // Reset byte_count when returning to IDLE
        if (state == IDLE) begin
            byte_count <= 0;
        end

        if (s_axis_tvalid && s_axis_tready) begin
            if (byte_count < 6) begin
                dest_mac_buffer[47-(byte_count*8) -: 8] <= s_axis_tdata;
            end else if((byte_count >= 6) && (byte_count < 12)) begin
                src_mac_buffer[47-((byte_count-6)*8) -: 8] <= s_axis_tdata;
            end else if (byte_count == 12) begin
                ether_type_buffer[15:8] <= s_axis_tdata;
            end else if (byte_count == 13) begin
                ether_type_buffer[7:0] <= s_axis_tdata;
            end else if (byte_count > 13) begin
                if (state == FORWARD_PAYLOAD) begin
                    if (m_axis_tready) begin
                        m_axis_tdata <= s_axis_tdata;
                        m_axis_tlast <= s_axis_tlast;
                    end
                end
            end
            byte_count <= byte_count + 1;
        end else begin
            // Clear tlast when not actively transferring
            if (!s_axis_tvalid || state == IDLE) begin
                m_axis_tlast <= 0;
            end
        end
    end
end

always_comb begin
    // Default assignments
    dest_mac = dest_mac_buffer;
    src_mac = src_mac_buffer;
    ether_type = ether_type_buffer;

    // Control signals based on state
    case(state)
        IDLE: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1; // Ready to accept new frame
        end
        PARSE_HEADER: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1; // Ready to accept header bytes
        end
        CHECK_ETHERTYPE: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0; // Not ready while checking
        end
        FORWARD_PAYLOAD: begin
            m_axis_tvalid = s_axis_tvalid; // Pass through valid signal
            s_axis_tready = m_axis_tready; // Backpressure from downstream
        end
        DROP_FRAME: begin
            m_axis_tvalid = 1'b0; // Don't forward data
            s_axis_tready = 1'b1; // Accept data to drain the frame
        end
        default: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0;
        end
    endcase
end

