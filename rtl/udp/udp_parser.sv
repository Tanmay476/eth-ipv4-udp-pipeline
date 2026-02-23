//================================================================================
// File: udp_parser.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   UDP header parser - Pipeline stage 3
//   Parses the fixed 8-byte UDP header:
//     Bytes 0-1 : Source port
//     Bytes 2-3 : Destination port
//     Bytes 4-5 : UDP length (header + payload, in bytes)
//     Bytes 6-7 : Checksum
//   Forwards the payload to the output AXI-Stream interface.
//
// Features:
//   - AXI-Stream interface (8-bit data width)
//   - State machine-based parsing
//   - Proper backpressure handling
//   - Zero-checksum detection (RFC 768: checksum=0 means disabled)
//================================================================================

module udp_parser #(
    parameter DATA_BUS_WIDTH = 8  // Width of the data bus in bits
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Slave Interface (from IPv4 parser)
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // AXI-Stream Master Interface (UDP payload output)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    // Extracted UDP Header Fields
    output logic [15:0] udp_src_port,
    output logic [15:0] udp_dst_port,
    output logic [15:0] udp_length,
    output logic [15:0] udp_checksum,

    // Status
    output logic        udp_header_valid,  // High while forwarding payload
    output logic        checksum_disabled   // UDP checksum field is zero
);

// ─── State machine ────────────────────────────────────────────────────────────
typedef enum logic [1:0] {
    IDLE,
    PARSE_HEADER,
    FORWARD_PAYLOAD,
    DROP_PACKET
} state_t;

state_t state, next_state;

// ─── Internal registers ───────────────────────────────────────────────────────
logic [2:0]  byte_count;          // 3 bits: counts 0-7 for 8-byte UDP header
logic [15:0] src_port_buf;
logic [15:0] dst_port_buf;
logic [15:0] length_buf;
logic [15:0] checksum_buf;

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
            // Transition after byte 7 (the last header byte) is accepted
            next_state = (byte_count == 3'd7 && s_axis_tvalid && s_axis_tready)
                         ? FORWARD_PAYLOAD : PARSE_HEADER;

        FORWARD_PAYLOAD:
            next_state = (s_axis_tlast && s_axis_tvalid && s_axis_tready)
                         ? IDLE : FORWARD_PAYLOAD;

        DROP_PACKET:
            next_state = (s_axis_tlast && s_axis_tvalid) ? IDLE : DROP_PACKET;

        default:
            next_state = IDLE;
    endcase
end

// ─── Data path ────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        byte_count   <= 3'd0;
        src_port_buf <= 16'd0;
        dst_port_buf <= 16'd0;
        length_buf   <= 16'd0;
        checksum_buf <= 16'd0;
        m_axis_tdata <= 8'd0;
        m_axis_tlast <= 1'b0;
    end else begin
        if (next_state == IDLE)
            byte_count <= 3'd0;

        if (s_axis_tvalid && s_axis_tready) begin
            case (state)
                // Byte 0 can arrive while still in IDLE
                IDLE, PARSE_HEADER: begin
                    case (byte_count)
                        3'd0: src_port_buf[15:8] <= s_axis_tdata;
                        3'd1: src_port_buf[7:0]  <= s_axis_tdata;
                        3'd2: dst_port_buf[15:8] <= s_axis_tdata;
                        3'd3: dst_port_buf[7:0]  <= s_axis_tdata;
                        3'd4: length_buf[15:8]   <= s_axis_tdata;
                        3'd5: length_buf[7:0]    <= s_axis_tdata;
                        3'd6: checksum_buf[15:8] <= s_axis_tdata;
                        3'd7: checksum_buf[7:0]  <= s_axis_tdata;
                        default: ;
                    endcase
                    byte_count <= byte_count + 3'd1;
                end

                FORWARD_PAYLOAD: begin
                    if (m_axis_tready) begin
                        m_axis_tdata <= s_axis_tdata;
                        m_axis_tlast <= s_axis_tlast;
                    end
                end

                default: ;
            endcase
        end else begin
            if (state == IDLE)
                m_axis_tlast <= 1'b0;
        end
    end
end

// ─── Output assignments ───────────────────────────────────────────────────────
always_comb begin
    udp_src_port      = src_port_buf;
    udp_dst_port      = dst_port_buf;
    udp_length        = length_buf;
    udp_checksum      = checksum_buf;
    checksum_disabled = (checksum_buf == 16'd0);

    case (state)
        IDLE: begin
            m_axis_tvalid    = 1'b0;
            s_axis_tready    = 1'b1;
            udp_header_valid = 1'b0;
        end
        PARSE_HEADER: begin
            m_axis_tvalid    = 1'b0;
            s_axis_tready    = 1'b1;
            udp_header_valid = 1'b0;
        end
        FORWARD_PAYLOAD: begin
            m_axis_tvalid    = s_axis_tvalid;
            s_axis_tready    = m_axis_tready;
            udp_header_valid = 1'b1;
        end
        DROP_PACKET: begin
            m_axis_tvalid    = 1'b0;
            s_axis_tready    = 1'b1;
            udp_header_valid = 1'b0;
        end
        default: begin
            m_axis_tvalid    = 1'b0;
            s_axis_tready    = 1'b0;
            udp_header_valid = 1'b0;
        end
    endcase
end

endmodule
