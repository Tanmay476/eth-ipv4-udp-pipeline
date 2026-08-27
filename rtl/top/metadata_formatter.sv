//================================================================================
// File: metadata_formatter.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Collects header metadata from the three parser stages and presents a
//   structured, stable output alongside the UDP payload stream.
//
//   The metadata is latched once the UDP parser begins forwarding payload
//   (udp_header_valid rising edge) and held until the frame ends
//   (payload_tlast accepted).  A one-cycle meta_valid pulse is emitted at
//   the start of each valid packet's payload.
//
// Output metadata fields
//   src_ip       - IPv4 source address
//   dst_ip       - IPv4 destination address
//   src_port     - UDP source port
//   dst_port     - UDP destination port
//   udp_length   - UDP length field (header + payload, in bytes)
//   payload_len  - UDP payload length (udp_length - 8)
//   src_mac      - Ethernet source MAC address
//   dst_mac      - Ethernet destination MAC address
//   error_flags  - Aggregated error bits from pipeline_ctrl
//================================================================================

`timescale 1ns/1ps

module metadata_formatter (
    input  logic        clk,
    input  logic        rst_n,

    // ── Parser metadata inputs ────────────────────────────────────────────────
    input  logic [47:0] eth_src_mac,
    input  logic [47:0] eth_dst_mac,

    input  logic [31:0] ip_src_addr,
    input  logic [31:0] ip_dst_addr,
    input  logic [7:0]  ip_ttl,
    input  logic [7:0]  ip_protocol,

    input  logic [15:0] udp_src_port,
    input  logic [15:0] udp_dst_port,
    input  logic [15:0] udp_length,
    input  logic        udp_header_valid, // Rising edge → latch and emit

    // ── Error flags from pipeline_ctrl ───────────────────────────────────────
    input  logic [3:0]  error_flags,
    input  logic        packet_valid,

    // ── Payload stream monitor ────────────────────────────────────────────────
    input  logic        payload_tvalid,
    input  logic        payload_tready,
    input  logic        payload_tlast,

    // ── Structured metadata outputs ───────────────────────────────────────────
    output logic        meta_valid,       // One-cycle pulse: metadata is ready
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

// ─── Edge-detect udp_header_valid ────────────────────────────────────────────
logic udp_hdr_valid_prev;

always_ff @(posedge clk) begin
    if (!rst_n) udp_hdr_valid_prev <= 1'b0;
    else        udp_hdr_valid_prev <= udp_header_valid;
end

wire udp_hdr_valid_rise = udp_header_valid & ~udp_hdr_valid_prev;

// ─── Latch metadata on rising edge of udp_header_valid ───────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        meta_valid       <= 1'b0;
        meta_src_mac     <= 48'd0;
        meta_dst_mac     <= 48'd0;
        meta_src_ip      <= 32'd0;
        meta_dst_ip      <= 32'd0;
        meta_ttl         <= 8'd0;
        meta_protocol    <= 8'd0;
        meta_src_port    <= 16'd0;
        meta_dst_port    <= 16'd0;
        meta_udp_length  <= 16'd0;
        meta_payload_len <= 16'd0;
        meta_error_flags <= 4'd0;
        meta_packet_valid <= 1'b0;
    end else begin
        meta_valid <= 1'b0;  // Default: no pulse

        if (udp_hdr_valid_rise) begin
            meta_valid        <= 1'b1;
            meta_src_mac      <= eth_src_mac;
            meta_dst_mac      <= eth_dst_mac;
            meta_src_ip       <= ip_src_addr;
            meta_dst_ip       <= ip_dst_addr;
            meta_ttl          <= ip_ttl;
            meta_protocol     <= ip_protocol;
            meta_src_port     <= udp_src_port;
            meta_dst_port     <= udp_dst_port;
            meta_udp_length   <= udp_length;
            // UDP payload length = UDP length field - 8 (header bytes)
            meta_payload_len  <= (udp_length >= 16'd8) ? udp_length - 16'd8 : 16'd0;
            meta_error_flags  <= error_flags;
            meta_packet_valid <= packet_valid;
        end
    end
end

endmodule
