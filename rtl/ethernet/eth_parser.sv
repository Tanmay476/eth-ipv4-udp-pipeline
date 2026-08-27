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

`timescale 1ns/1ps

module eth_parser #(
    parameter DATA_BUS_WIDTH = 8, // Width of the data bus in bits
    parameter ENABLE_VLAN    = 0, // VLAN tagging support (not implemented)
    parameter CHECK_FCS      = 0, // Validate CRC (not implemented)
    parameter MIN_FRAME_SIZE = 64 // Minimum Ethernet frame size in bytes
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Slave Interface
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,

    // AXI-Stream Master Interface (IPv4 payload)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    // Extracted Ethernet Header Fields
    output logic [47:0] dest_mac,
    output logic [47:0] src_mac,
    output logic [15:0] ether_type
);

// ─── State machine ────────────────────────────────────────────────────────────
typedef enum logic [2:0] {
    IDLE,
    PARSE_HEADER,
    CHECK_ETHERTYPE,
    DROP_FRAME,
    FORWARD_PAYLOAD
} state_t;

state_t state, next_state;

// ─── Internal registers ───────────────────────────────────────────────────────
logic [3:0]  byte_count;          // 4 bits: counts 0-13 for 14-byte header
logic [47:0] dest_mac_buf;
logic [47:0] src_mac_buf;
logic [15:0] ether_type_buf;

// ─── State register ───────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
end

// ─── Next-state logic ─────────────────────────────────────────────────────────
always_comb begin
    next_state = state;
    case (state)
        IDLE:
            next_state = s_axis_tvalid ? PARSE_HEADER : IDLE;

        PARSE_HEADER:
            // Transition after byte 13 (the last header byte) is accepted
            next_state = (byte_count == 4'd13 && s_axis_tvalid && s_axis_tready)
                         ? CHECK_ETHERTYPE : PARSE_HEADER;

        CHECK_ETHERTYPE:
            next_state = (ether_type_buf == 16'h0800) ? FORWARD_PAYLOAD : DROP_FRAME;

        DROP_FRAME:
            next_state = (s_axis_tlast && s_axis_tvalid && s_axis_tready)
                         ? IDLE : DROP_FRAME;

        FORWARD_PAYLOAD:
            next_state = (s_axis_tlast && s_axis_tvalid && s_axis_tready)
                         ? IDLE : FORWARD_PAYLOAD;

        default:
            next_state = IDLE;
    endcase
end

// ─── Data path ────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        byte_count    <= 4'd0;
        dest_mac_buf  <= 48'd0;
        src_mac_buf   <= 48'd0;
        ether_type_buf <= 16'd0;
    end else begin
        // Reset byte counter when the current transfer finishes (next state = IDLE)
        if (next_state == IDLE)
            byte_count <= 4'd0;

        if (s_axis_tvalid && s_axis_tready) begin
            case (state)
                // In IDLE the first payload byte is already valid; treat it as byte 0
                IDLE, PARSE_HEADER: begin
                    if      (byte_count < 4'd6)
                        dest_mac_buf[47 - (byte_count * 8) -: 8] <= s_axis_tdata;
                    else if (byte_count < 4'd12)
                        src_mac_buf[47 - ((byte_count - 4'd6) * 8) -: 8] <= s_axis_tdata;
                    else if (byte_count == 4'd12)
                        ether_type_buf[15:8] <= s_axis_tdata;
                    else if (byte_count == 4'd13)
                        ether_type_buf[7:0]  <= s_axis_tdata;

                    byte_count <= byte_count + 4'd1;
                end

                default: ;
            endcase
        end
    end
end

// ─── Output assignments ───────────────────────────────────────────────────────
always_comb begin
    dest_mac   = dest_mac_buf;
    src_mac    = src_mac_buf;
    ether_type = ether_type_buf;

    // Payload path is a combinational pass-through: TDATA/TLAST must be
    // presented in the SAME cycle as TVALID.  Registering them here while
    // driving TVALID combinationally would skew data one cycle behind valid
    // and, critically, would prevent TLAST from ever coinciding with TVALID
    // at the downstream stage (leaving it stuck in FORWARD_PAYLOAD forever).
    m_axis_tdata = s_axis_tdata;
    m_axis_tlast = s_axis_tlast;

    case (state)
        IDLE: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1;
        end
        PARSE_HEADER: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1;
        end
        CHECK_ETHERTYPE: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0;   // Stall upstream while deciding
        end
        FORWARD_PAYLOAD: begin
            m_axis_tvalid = s_axis_tvalid;
            s_axis_tready = m_axis_tready;
        end
        DROP_FRAME: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b1;   // Drain the frame
        end
        default: begin
            m_axis_tvalid = 1'b0;
            s_axis_tready = 1'b0;
        end
    endcase
end

endmodule
