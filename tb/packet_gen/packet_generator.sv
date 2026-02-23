//================================================================================
// File: packet_generator.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   AXI-Stream packet generator for testbench use.
//   Builds complete Ethernet/IPv4/UDP frames in memory then drives them
//   byte-by-byte onto the AXI-Stream master interface.
//
//   Public tasks:
//     send_udp_packet(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port,
//                     payload[], payload_len, inter_packet_gap)
//     send_raw_bytes(bytes[], num_bytes, tlast_at_end)
//
//   IPv4 and UDP checksums are computed automatically.
//================================================================================

module packet_generator (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Master output
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready
);

// ─── Internal frame buffer ───────────────────────────────────────────────────
localparam MAX_FRAME = 1536;
logic [7:0] frame_buf [0:MAX_FRAME-1];
int         frame_len;
int         send_idx;
logic       sending;

initial begin
    m_axis_tdata  = 8'd0;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    sending       = 1'b0;
    frame_len     = 0;
    send_idx      = 0;
end

// ─── Helper: compute IPv4 one's-complement checksum ──────────────────────────
function automatic logic [15:0] ipv4_checksum(
    input logic [7:0] hdr[],
    input int         hdr_len
);
    logic [31:0] s;
    int i;
    s = 32'd0;
    for (i = 0; i < hdr_len; i += 2) begin
        if (i + 1 < hdr_len)
            s = s + {16'd0, hdr[i], hdr[i+1]};
        else
            s = s + {16'd0, hdr[i], 8'd0};
    end
    // Fold carries
    s = (s >> 16) + (s & 32'hFFFF);
    s = s + (s >> 16);
    return ~s[15:0];
endfunction

// ─── Helper: compute UDP checksum (includes pseudo-header) ───────────────────
function automatic logic [15:0] udp_checksum_calc(
    input logic [31:0] src_ip,
    input logic [31:0] dst_ip,
    input logic [15:0] udp_len,
    input logic [7:0]  udp_seg[],   // UDP header + payload
    input int          seg_len
);
    logic [31:0] s;
    int i;
    s = 32'd0;
    // Pseudo-header
    s = s + {16'd0, src_ip[31:16]};
    s = s + {16'd0, src_ip[15:0]};
    s = s + {16'd0, dst_ip[31:16]};
    s = s + {16'd0, dst_ip[15:0]};
    s = s + 32'd17;                // Protocol = UDP
    s = s + {16'd0, udp_len};
    // UDP segment
    for (i = 0; i < seg_len; i += 2) begin
        if (i + 1 < seg_len)
            s = s + {16'd0, udp_seg[i], udp_seg[i+1]};
        else
            s = s + {16'd0, udp_seg[i], 8'd0};
    end
    // Fold
    s = (s >> 16) + (s & 32'hFFFF);
    s = s + (s >> 16);
    return ~s[15:0];
endfunction

// ─── Task: drive one frame ────────────────────────────────────────────────────
task automatic drive_frame(
    input int num_bytes,
    input int gap_cycles
);
    int i;
    for (i = 0; i < num_bytes; i++) begin
        @(posedge clk);
        #1;
        m_axis_tdata  <= frame_buf[i];
        m_axis_tvalid <= 1'b1;
        m_axis_tlast  <= (i == num_bytes - 1);
        // Wait for handshake
        while (!m_axis_tready) begin
            @(posedge clk);
            #1;
        end
    end
    @(posedge clk);
    #1;
    m_axis_tvalid <= 1'b0;
    m_axis_tlast  <= 1'b0;
    // Inter-packet gap
    repeat (gap_cycles) @(posedge clk);
endtask

// ─── Public task: send a UDP packet ──────────────────────────────────────────
task automatic send_udp_packet(
    input logic [47:0] dst_mac,
    input logic [47:0] src_mac_in,
    input logic [31:0] src_ip,
    input logic [31:0] dst_ip,
    input logic [15:0] src_port,
    input logic [15:0] dst_port,
    input logic [7:0]  payload [],
    input int          payload_len,
    input int          gap_cycles = 4,
    input logic        use_udp_checksum = 1'b1
);
    logic [7:0]  ip_hdr[0:19];
    logic [7:0]  udp_seg[0:65534];
    logic [15:0] udp_len;
    logic [15:0] ip_total_len;
    logic [15:0] ip_chk;
    logic [15:0] udp_chk;
    int          i, total;

    udp_len      = 16'(8 + payload_len);
    ip_total_len = 16'(20 + 8 + payload_len);

    // ── Build IPv4 header (20 bytes, no options) ─────────────────────────────
    ip_hdr[0]  = 8'h45;                          // Version=4, IHL=5
    ip_hdr[1]  = 8'h00;                          // DSCP/ECN
    ip_hdr[2]  = ip_total_len[15:8];
    ip_hdr[3]  = ip_total_len[7:0];
    ip_hdr[4]  = 8'h00;                          // ID high
    ip_hdr[5]  = 8'h01;                          // ID low
    ip_hdr[6]  = 8'h00;                          // Flags / frag offset high
    ip_hdr[7]  = 8'h00;                          // Frag offset low
    ip_hdr[8]  = 8'h40;                          // TTL = 64
    ip_hdr[9]  = 8'h11;                          // Protocol = UDP
    ip_hdr[10] = 8'h00;                          // Checksum placeholder
    ip_hdr[11] = 8'h00;
    ip_hdr[12] = src_ip[31:24];
    ip_hdr[13] = src_ip[23:16];
    ip_hdr[14] = src_ip[15:8];
    ip_hdr[15] = src_ip[7:0];
    ip_hdr[16] = dst_ip[31:24];
    ip_hdr[17] = dst_ip[23:16];
    ip_hdr[18] = dst_ip[15:8];
    ip_hdr[19] = dst_ip[7:0];

    ip_chk     = ipv4_checksum(ip_hdr, 20);
    ip_hdr[10] = ip_chk[15:8];
    ip_hdr[11] = ip_chk[7:0];

    // ── Build UDP segment (header + payload) ──────────────────────────────────
    udp_seg[0] = src_port[15:8];
    udp_seg[1] = src_port[7:0];
    udp_seg[2] = dst_port[15:8];
    udp_seg[3] = dst_port[7:0];
    udp_seg[4] = udp_len[15:8];
    udp_seg[5] = udp_len[7:0];
    udp_seg[6] = 8'h00;                          // Checksum placeholder
    udp_seg[7] = 8'h00;
    for (i = 0; i < payload_len; i++)
        udp_seg[8 + i] = payload[i];

    if (use_udp_checksum) begin
        udp_chk    = udp_checksum_calc(src_ip, dst_ip, udp_len, udp_seg, 8 + payload_len);
        udp_seg[6] = udp_chk[15:8];
        udp_seg[7] = udp_chk[7:0];
    end

    // ── Assemble full Ethernet frame ──────────────────────────────────────────
    // Ethernet header (14 bytes)
    frame_buf[0]  = dst_mac[47:40];
    frame_buf[1]  = dst_mac[39:32];
    frame_buf[2]  = dst_mac[31:24];
    frame_buf[3]  = dst_mac[23:16];
    frame_buf[4]  = dst_mac[15:8];
    frame_buf[5]  = dst_mac[7:0];
    frame_buf[6]  = src_mac_in[47:40];
    frame_buf[7]  = src_mac_in[39:32];
    frame_buf[8]  = src_mac_in[31:24];
    frame_buf[9]  = src_mac_in[23:16];
    frame_buf[10] = src_mac_in[15:8];
    frame_buf[11] = src_mac_in[7:0];
    frame_buf[12] = 8'h08;                       // EtherType = IPv4
    frame_buf[13] = 8'h00;

    // IPv4 header
    for (i = 0; i < 20; i++)
        frame_buf[14 + i] = ip_hdr[i];

    // UDP segment
    total = 8 + payload_len;
    for (i = 0; i < total; i++)
        frame_buf[34 + i] = udp_seg[i];

    frame_len = 14 + 20 + total;

    drive_frame(frame_len, gap_cycles);
endtask

// ─── Public task: send raw bytes (for error-injection) ────────────────────────
task automatic send_raw_bytes(
    input logic [7:0] bytes [],
    input int         num_bytes,
    input int         gap_cycles = 4
);
    int i;
    for (i = 0; i < num_bytes; i++)
        frame_buf[i] = bytes[i];
    frame_len = num_bytes;
    drive_frame(frame_len, gap_cycles);
endtask

endmodule
