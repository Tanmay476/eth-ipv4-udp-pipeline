//================================================================================
// File: test_basic_packets.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Basic packet tests.
//   Verifies correct metadata extraction for single and back-to-back valid
//   Ethernet/IPv4/UDP frames.
//   Included by tb_packet_processor.sv; uses pkt_gen and sb handles from that
//   scope.
//================================================================================

task run_basic_tests();
    automatic logic [7:0] payload[];
    automatic int         i;

    $display("\n---- Test: Single UDP packet ----");
    payload = new[8];
    for (i = 0; i < 8; i++) payload[i] = 8'(i + 1);

    sb.add_expected_packet(
        .src_ip    (32'hC0A80101),   // 192.168.1.1
        .dst_ip    (32'hC0A80102),   // 192.168.1.2
        .src_port  (16'd1234),
        .dst_port  (16'd5678),
        .udp_length(16'd16),         // 8 header + 8 payload
        .should_be_valid(1'b1)
    );

    pkt_gen.send_udp_packet(
        .dst_mac        (48'hFFFF_FFFF_FFFF),
        .src_mac_in     (48'h0011_2233_4455),
        .src_ip         (32'hC0A80101),
        .dst_ip         (32'hC0A80102),
        .src_port       (16'd1234),
        .dst_port       (16'd5678),
        .payload        (payload),
        .payload_len    (8),
        .gap_cycles     (8)
    );

    // ── Three back-to-back packets ────────────────────────────────────────────
    $display("\n---- Test: Back-to-back UDP packets ----");
    repeat (3) begin
        static logic [7:0] pay[] = '{8'hAA, 8'hBB, 8'hCC, 8'hDD};

        sb.add_expected_packet(
            .src_ip    (32'h0A000001),
            .dst_ip    (32'h0A000002),
            .src_port  (16'd4000),
            .dst_port  (16'd4001),
            .udp_length(16'd12),
            .should_be_valid(1'b1)
        );

        pkt_gen.send_udp_packet(
            .dst_mac        (48'hFF_FFFF_FFFF_FF),
            .src_mac_in     (48'hDE_ADBE_EFCA_FE),
            .src_ip         (32'h0A000001),
            .dst_ip         (32'h0A000002),
            .src_port       (16'd4000),
            .dst_port       (16'd4001),
            .payload        (pay),
            .payload_len    (4),
            .gap_cycles     (2)
        );
    end

    // ── Minimum-size payload (1 byte) ─────────────────────────────────────────
    $display("\n---- Test: Minimum payload (1 byte) ----");
    begin
        automatic logic [7:0] min_pay[] = '{8'hFF};
        sb.add_expected_packet(
            .src_ip    (32'h7F000001),
            .dst_ip    (32'h7F000001),
            .src_port  (16'd9),
            .dst_port  (16'd9),
            .udp_length(16'd9),
            .should_be_valid(1'b1)
        );
        pkt_gen.send_udp_packet(
            .dst_mac        (48'h00_0000_0000_01),
            .src_mac_in     (48'h00_0000_0000_02),
            .src_ip         (32'h7F000001),
            .dst_ip         (32'h7F000001),
            .src_port       (16'd9),
            .dst_port       (16'd9),
            .payload        (min_pay),
            .payload_len    (1),
            .gap_cycles     (8)
        );
    end

    // ── Larger payload (64 bytes) ─────────────────────────────────────────────
    $display("\n---- Test: 64-byte payload ----");
    begin
        automatic logic [7:0] big_pay[];
        big_pay = new[64];
        for (i = 0; i < 64; i++) big_pay[i] = 8'(i);

        sb.add_expected_packet(
            .src_ip    (32'hAC100001),
            .dst_ip    (32'hAC1000FF),
            .src_port  (16'd8080),
            .dst_port  (16'd80),
            .udp_length(16'd72),
            .should_be_valid(1'b1)
        );
        pkt_gen.send_udp_packet(
            .dst_mac        (48'hFF_FFFF_FFFF_FF),
            .src_mac_in     (48'h00_1122_3344_55),
            .src_ip         (32'hAC100001),
            .dst_ip         (32'hAC1000FF),
            .src_port       (16'd8080),
            .dst_port       (16'd80),
            .payload        (big_pay),
            .payload_len    (64),
            .gap_cycles     (8)
        );
    end
endtask
