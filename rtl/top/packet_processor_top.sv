//================================================================================
// File: packet_processor_top.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Top-level integration module.  Connects the three-stage parser pipeline:
//     Stage 1 – eth_parser    : strip 14-byte Ethernet header
//     Stage 2 – ipv4_parser   : strip 20-60-byte IPv4 header
//     Stage 3 – udp_parser    : strip 8-byte UDP header, forward payload
//
//   Optional checksum validation modules are also instantiated.
//
//   AXI-Stream data path (8-bit):
//     s_axis (raw frame) → eth → ipv4 → udp → m_axis (UDP payload)
//
//   Metadata sideband (parallel bus, valid one cycle after first payload byte):
//     meta_valid, meta_src_ip, meta_dst_ip, meta_src_port, meta_dst_port,
//     meta_udp_length, meta_payload_len, meta_src_mac, meta_dst_mac,
//     meta_error_flags, meta_packet_valid
//
// Parameters:
//   DROP_FRAGMENTS      – 1: drop fragmented IP packets  0: forward them
//   VALIDATE_IP_CHKSUM  – 1: enable IPv4 header checksum validation
//   VALIDATE_UDP_CHKSUM – 1: enable UDP checksum validation
//================================================================================

`timescale 1ns/1ps

module packet_processor_top #(
    parameter DROP_FRAGMENTS      = 1,
    parameter VALIDATE_IP_CHKSUM  = 1,
    parameter VALIDATE_UDP_CHKSUM = 1
)(
    input  logic        clk,
    input  logic        rst_n,

    // ── AXI-Stream Slave (raw Ethernet frame input) ───────────────────────────
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // ── AXI-Stream Master (UDP payload output) ────────────────────────────────
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    // ── Packet metadata sideband ──────────────────────────────────────────────
    output logic        meta_valid,
    output logic [47:0] meta_src_mac,
    output logic [47:0] meta_dst_mac,
    output logic [31:0] meta_src_ip,
    output logic [31:0] meta_dst_ip,
    output logic [7:0]  meta_ttl,
    output logic [7:0]  meta_protocol,
    output logic [15:0] meta_src_port,
    output logic [15:0] meta_dst_port,
    output logic [15:0] meta_udp_length,
    output logic [15:0] meta_payload_len,
    output logic [3:0]  meta_error_flags,
    output logic        meta_packet_valid
);

// ─── Stage interconnect wires ─────────────────────────────────────────────────

// eth_parser → ipv4_parser
logic [7:0]  eth_m_tdata;
logic        eth_m_tvalid;
logic        eth_m_tlast;
logic        eth_m_tready;

// ipv4_parser → udp_parser
logic [7:0]  ip_m_tdata;
logic        ip_m_tvalid;
logic        ip_m_tlast;
logic        ip_m_tready;

// ─── Metadata wires ───────────────────────────────────────────────────────────

// Ethernet metadata
logic [47:0] eth_dst_mac;
logic [47:0] eth_src_mac;
logic [15:0] eth_ether_type;

// IPv4 metadata
logic [3:0]  ip_version;
logic [3:0]  ip_ihl;
logic [7:0]  ip_protocol;
logic [7:0]  ip_ttl;
logic [15:0] ip_total_length;
logic [31:0] ip_src_addr;
logic [31:0] ip_dst_addr;
logic        ip_header_valid;
logic        ip_is_fragment;

// UDP metadata
logic [15:0] udp_src_port;
logic [15:0] udp_dst_port;
logic [15:0] udp_length;
logic [15:0] udp_checksum;
logic        udp_header_valid;
logic        udp_checksum_disabled;

// Checksum module wires
logic        ip_chk_valid;
logic        ip_chk_done;
logic [15:0] ip_chk_calculated;

// IPv4 checksum byte counter (driven in top-level, fed to ipv4_checksum)
logic [5:0]  ip_chk_byte_cnt;
logic        ip_chk_counting;

logic        udp_chk_valid;
logic        udp_chk_done;

// Pipeline controller outputs
logic        pkt_valid;
logic        pkt_error;
logic [3:0]  pkt_error_flags;

// ─── Stage 1: Ethernet parser ────────────────────────────────────────────────
eth_parser #(
    .DATA_BUS_WIDTH (8),
    .ENABLE_VLAN    (0),
    .CHECK_FCS      (0)
) u_eth_parser (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tlast   (s_axis_tlast),
    .s_axis_tready  (s_axis_tready),
    .m_axis_tdata   (eth_m_tdata),
    .m_axis_tvalid  (eth_m_tvalid),
    .m_axis_tlast   (eth_m_tlast),
    .m_axis_tready  (eth_m_tready),
    .dest_mac       (eth_dst_mac),
    .src_mac        (eth_src_mac),
    .ether_type     (eth_ether_type)
);

// ─── Stage 2: IPv4 parser ─────────────────────────────────────────────────────
ipv4_parser #(
    .DATA_BUS_WIDTH    (8),
    .VALIDATE_CHECKSUM (0),          // Checksum handled separately
    .DROP_FRAGMENTS    (DROP_FRAGMENTS)
) u_ipv4_parser (
    .clk              (clk),
    .rst_n            (rst_n),
    .s_axis_tdata     (eth_m_tdata),
    .s_axis_tvalid    (eth_m_tvalid),
    .s_axis_tlast     (eth_m_tlast),
    .s_axis_tready    (eth_m_tready),
    .m_axis_tdata     (ip_m_tdata),
    .m_axis_tvalid    (ip_m_tvalid),
    .m_axis_tlast     (ip_m_tlast),
    .m_axis_tready    (ip_m_tready),
    .ip_version       (ip_version),
    .ip_ihl           (ip_ihl),
    .ip_protocol      (ip_protocol),
    .ip_ttl           (ip_ttl),
    .ip_total_length  (ip_total_length),
    .ip_src_addr      (ip_src_addr),
    .ip_dest_addr     (ip_dst_addr),
    .ip_header_valid  (ip_header_valid),
    .is_fragment      (ip_is_fragment)
);

// ─── Stage 3: UDP parser ──────────────────────────────────────────────────────
udp_parser #(
    .DATA_BUS_WIDTH (8)
) u_udp_parser (
    .clk              (clk),
    .rst_n            (rst_n),
    .s_axis_tdata     (ip_m_tdata),
    .s_axis_tvalid    (ip_m_tvalid),
    .s_axis_tlast     (ip_m_tlast),
    .s_axis_tready    (ip_m_tready),
    .m_axis_tdata     (m_axis_tdata),
    .m_axis_tvalid    (m_axis_tvalid),
    .m_axis_tlast     (m_axis_tlast),
    .m_axis_tready    (m_axis_tready),
    .udp_src_port     (udp_src_port),
    .udp_dst_port     (udp_dst_port),
    .udp_length       (udp_length),
    .udp_checksum     (udp_checksum),
    .udp_header_valid (udp_header_valid),
    .checksum_disabled(udp_checksum_disabled)
);

// ─── Optional: IPv4 checksum validator ───────────────────────────────────────
// The ipv4_checksum module is fed by the eth_parser's output stream which
// carries the raw IPv4 header bytes.  A start pulse is generated on the
// rising edge of eth_m_tvalid.  An external byte counter tracks the position
// within the IPv4 header and is passed to ipv4_checksum.
//
// Note: ipv4_checksum.sv skips bytes 10-11 (checksum field) when accumulating,
// so its 'calculated_checksum' output is the correct checksum to INSERT.
// For VALIDATION, compare calculated_checksum against the received checksum
// captured from bytes 10-11 of the IPv4 header.

logic eth_m_valid_prev;
logic ip_chk_start;
logic [7:0] ip_rcv_chk_hi;   // Received checksum bytes from IPv4 header
logic [7:0] ip_rcv_chk_lo;

always_ff @(posedge clk) begin
    if (!rst_n) eth_m_valid_prev <= 1'b0;
    else        eth_m_valid_prev <= eth_m_tvalid;
end

// Qualified with ~ip_chk_counting so a mid-frame TVALID gap cannot re-trigger
// 'start' and restart the accumulation partway through the header.
assign ip_chk_start = eth_m_tvalid & ~eth_m_valid_prev & ~ip_chk_counting;

// Byte counter for the IPv4 checksum module.
// Header byte 0 is ALREADY on the bus during the 'start' cycle (eth_parser
// forwards it in the same cycle it raises TVALID), so the counter advances to 1
// here.  Setting it to 0 instead would make byte_count lag the bus by one and
// read the checksum field from bytes 11-12 rather than 10-11.
always_ff @(posedge clk) begin
    if (!rst_n) begin
        ip_chk_byte_cnt  <= 6'd0;
        ip_chk_counting  <= 1'b0;
        ip_rcv_chk_hi    <= 8'd0;
        ip_rcv_chk_lo    <= 8'd0;
    end else begin
        if (ip_chk_start) begin
            ip_chk_byte_cnt <= 6'd1;      // byte 0 is consumed this cycle
            ip_chk_counting <= 1'b1;
        end else if (ip_chk_counting && eth_m_tvalid && eth_m_tready) begin
            // Capture received checksum at bytes 10-11
            if (ip_chk_byte_cnt == 6'd10) ip_rcv_chk_hi <= eth_m_tdata;
            if (ip_chk_byte_cnt == 6'd11) ip_rcv_chk_lo <= eth_m_tdata;

            if (ip_chk_byte_cnt >= ({ip_ihl, 2'b00} - 6'd1)) begin
                ip_chk_counting <= 1'b0;
                ip_chk_byte_cnt <= 6'd0;  // re-arm: next frame's byte 0 needs cnt==0
            end else begin
                ip_chk_byte_cnt <= ip_chk_byte_cnt + 6'd1;
            end
        end
    end
end

generate
    if (VALIDATE_IP_CHKSUM) begin : gen_ip_chksum
        logic [15:0] ip_calc_chk;
        logic        ip_chk_done_i;

        ipv4_checksum #(
            .DATA_WIDTH (8)
        ) u_ipv4_checksum (
            .clk                (clk),
            .rst_n              (rst_n),
            .start              (ip_chk_start),
            .data_valid         (eth_m_tvalid & eth_m_tready),
            .data_byte          (eth_m_tdata),
            .byte_count         (ip_chk_byte_cnt),
            .header_length      ({ip_ihl, 2'b00}),
            .checksum_valid     (/* unused; compare below */),
            .done               (ip_chk_done_i),
            .calculated_checksum(ip_calc_chk)
        );

        assign ip_chk_done = ip_chk_done_i;

        // Validate: the calculated checksum must match the received one.
        // Deliberately COMBINATIONAL, not registered.  pipeline_ctrl samples
        // this on the same cycle ip_chk_done is asserted, and ip_calc_chk is
        // already final on that cycle ('done' and 'calculated_checksum' are
        // registered together inside ipv4_checksum).  Registering the compare
        // here would hand pipeline_ctrl the PREVIOUS packet's verdict.
        assign ip_chk_valid = (ip_calc_chk == {ip_rcv_chk_hi, ip_rcv_chk_lo});

        assign ip_chk_calculated = ip_calc_chk;
    end else begin : gen_ip_chksum_bypass
        assign ip_chk_valid       = 1'b1;
        assign ip_chk_done        = 1'b0;
        assign ip_chk_calculated  = 16'd0;
    end
endgenerate

// ─── Optional: UDP checksum validator ────────────────────────────────────────
// Starts when udp_header_valid first rises (payload stream begins).
logic udp_hdr_prev;
logic udp_chk_start;

always_ff @(posedge clk) begin
    if (!rst_n) udp_hdr_prev <= 1'b0;
    else        udp_hdr_prev <= udp_header_valid;
end

assign udp_chk_start = udp_header_valid & ~udp_hdr_prev;

generate
    if (VALIDATE_UDP_CHKSUM) begin : gen_udp_chksum
        udp_checksum u_udp_checksum (
            .clk               (clk),
            .rst_n             (rst_n),
            .start             (udp_chk_start),
            .data_valid        (m_axis_tvalid & m_axis_tready),
            .is_last           (m_axis_tlast),
            .ip_src_addr       (ip_src_addr),
            .ip_dst_addr       (ip_dst_addr),
            .udp_total_length  (udp_length),
            .udp_src_port      (udp_src_port),
            .udp_dst_port      (udp_dst_port),
            .received_checksum (udp_checksum),
            .data_byte         (m_axis_tdata),
            .checksum_valid    (udp_chk_valid),
            .done              (udp_chk_done)
        );
    end else begin : gen_udp_chksum_bypass
        assign udp_chk_valid = 1'b1;
        assign udp_chk_done  = 1'b0;
    end
endgenerate

// ─── Pipeline controller ──────────────────────────────────────────────────────
pipeline_ctrl u_pipeline_ctrl (
    .clk              (clk),
    .rst_n            (rst_n),
    .ip_header_valid  (ip_header_valid),
    .is_fragment      (ip_is_fragment),
    .ip_chk_valid     (ip_chk_valid),
    .ip_chk_done      (ip_chk_done),
    .udp_header_valid (udp_header_valid),
    .udp_chk_valid    (udp_chk_valid),
    .udp_chk_done     (udp_chk_done),
    .checksum_disabled(udp_checksum_disabled),
    .payload_tvalid   (m_axis_tvalid),
    .payload_tready   (m_axis_tready),
    .payload_tlast    (m_axis_tlast),
    .packet_valid     (pkt_valid),
    .packet_error     (pkt_error),
    .error_flags      (pkt_error_flags)
);

// ─── Metadata formatter ───────────────────────────────────────────────────────
metadata_formatter u_meta_fmt (
    .clk              (clk),
    .rst_n            (rst_n),
    .eth_src_mac      (eth_src_mac),
    .eth_dst_mac      (eth_dst_mac),
    .ip_src_addr      (ip_src_addr),
    .ip_dst_addr      (ip_dst_addr),
    .ip_ttl           (ip_ttl),
    .ip_protocol      (ip_protocol),
    .udp_src_port     (udp_src_port),
    .udp_dst_port     (udp_dst_port),
    .udp_length       (udp_length),
    .udp_header_valid (udp_header_valid),
    .error_flags      (pkt_error_flags),
    .packet_valid     (pkt_valid),
    .payload_tvalid   (m_axis_tvalid),
    .payload_tready   (m_axis_tready),
    .payload_tlast    (m_axis_tlast),
    .meta_valid       (meta_valid),
    .meta_src_mac     (meta_src_mac),
    .meta_dst_mac     (meta_dst_mac),
    .meta_src_ip      (meta_src_ip),
    .meta_dst_ip      (meta_dst_ip),
    .meta_ttl         (meta_ttl),
    .meta_protocol    (meta_protocol),
    .meta_src_port    (meta_src_port),
    .meta_dst_port    (meta_dst_port),
    .meta_udp_length  (meta_udp_length),
    .meta_payload_len (meta_payload_len),
    .meta_error_flags (meta_error_flags),
    .meta_packet_valid(meta_packet_valid)
);

endmodule
