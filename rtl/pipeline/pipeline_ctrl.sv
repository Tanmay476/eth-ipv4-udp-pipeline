//================================================================================
// File: pipeline_ctrl.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Pipeline controller for the three-stage Ethernet/IPv4/UDP parser pipeline.
//   The three parsers (eth_parser, ipv4_parser, udp_parser) are connected in a
//   direct AXI-Stream chain and handle their own handshaking.  This module
//   aggregates the per-stage validity / error signals and produces packet-level
//   status outputs that are synchronised with the payload stream leaving the
//   last stage.
//
//   Error sources tracked:
//     - Non-IPv4 EtherType   → eth_parser drops the frame (no explicit signal)
//     - Bad IP version / IHL → ip_header_valid = 0
//     - Non-UDP protocol     → ip_header_valid = 0
//     - Fragmented packet    → ip_header_valid = 0  (when DROP_FRAGMENTS=1)
//     - UDP checksum error   → udp_chk_valid = 0    (optional)
//================================================================================

module pipeline_ctrl (
    input  logic clk,
    input  logic rst_n,

    // ── Status inputs from individual parser stages ──────────────────────────
    input  logic ip_header_valid,    // From ipv4_parser: IP header passed checks
    input  logic is_fragment,        // From ipv4_parser: packet is fragmented
    input  logic udp_header_valid,   // From udp_parser:  forwarding UDP payload
    input  logic udp_chk_valid,      // From udp_checksum: UDP checksum correct
    input  logic udp_chk_done,       // From udp_checksum: checksum result ready
    input  logic checksum_disabled,  // From udp_parser:   checksum field = 0

    // ── Payload stream monitor (from udp_parser output) ──────────────────────
    input  logic payload_tvalid,
    input  logic payload_tready,
    input  logic payload_tlast,

    // ── Packet-level status outputs ───────────────────────────────────────────
    output logic packet_valid,       // Current packet passed all checks
    output logic packet_error,       // Current packet has at least one error
    output logic [3:0] error_flags   // Detailed error flags (see bit map below)
    // error_flags[0] : IP header invalid (bad version / IHL / protocol / fragment)
    // error_flags[1] : IP packet is fragmented
    // error_flags[2] : UDP checksum error
    // error_flags[3] : reserved
);

// ─── Latched status registers ─────────────────────────────────────────────────
// These are set when the header-valid pulses propagate through the pipeline
// and cleared when the frame ends (payload_tlast accepted).

logic ip_ok_lat;
logic frag_lat;
logic udp_chk_ok_lat;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        ip_ok_lat     <= 1'b0;
        frag_lat      <= 1'b0;
        udp_chk_ok_lat <= 1'b1;
    end else begin
        // Latch IP validity when the IP header stage completes
        if (ip_header_valid)
            ip_ok_lat <= 1'b1;

        // Latch fragmentation flag alongside IP validity
        if (ip_header_valid || is_fragment)
            frag_lat <= is_fragment;

        // Latch UDP checksum result when it arrives
        if (udp_chk_done)
            udp_chk_ok_lat <= udp_chk_valid || checksum_disabled;

        // Clear all latches at end-of-frame
        if (payload_tvalid && payload_tready && payload_tlast) begin
            ip_ok_lat      <= 1'b0;
            frag_lat       <= 1'b0;
            udp_chk_ok_lat <= 1'b1;  // Default: assume OK for next packet
        end
    end
end

// ─── Combinational output ─────────────────────────────────────────────────────
always_comb begin
    error_flags    = 4'd0;
    error_flags[0] = ~ip_ok_lat;
    error_flags[1] = frag_lat;
    error_flags[2] = ~udp_chk_ok_lat;

    packet_valid   = udp_header_valid && ip_ok_lat && udp_chk_ok_lat && !frag_lat;
    packet_error   = |error_flags;
end

endmodule
