//================================================================================
// File: test_error_cases.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Error-injection test cases.
//   Sends malformed or non-UDP frames and verifies they are correctly
//   dropped or flagged.
//   Included by tb_packet_processor.sv.
//================================================================================

task run_error_tests();

    // ── Non-IPv4 EtherType (ARP = 0x0806) ────────────────────────────────────
    $display("\n---- Test: Non-IPv4 EtherType (ARP, should be dropped) ----");
    begin
        automatic logic [7:0] arp_frame[];
        automatic int i;
        arp_frame = new[64];
        // Dst MAC
        arp_frame[0] = 8'hFF; arp_frame[1] = 8'hFF; arp_frame[2] = 8'hFF;
        arp_frame[3] = 8'hFF; arp_frame[4] = 8'hFF; arp_frame[5] = 8'hFF;
        // Src MAC
        arp_frame[6]  = 8'h00; arp_frame[7]  = 8'h11; arp_frame[8]  = 8'h22;
        arp_frame[9]  = 8'h33; arp_frame[10] = 8'h44; arp_frame[11] = 8'h55;
        // EtherType = ARP (0x0806)
        arp_frame[12] = 8'h08; arp_frame[13] = 8'h06;
        // Pad rest
        for (i = 14; i < 64; i++) arp_frame[i] = 8'h00;

        // No expected_packet entry → scoreboard should not fire
        // (eth_parser silently drops the frame; no meta_valid pulse)
        pkt_gen.send_raw_bytes(arp_frame, 64, 8);
    end

    // ── Non-UDP IP protocol (TCP = 0x06) ──────────────────────────────────────
    $display("\n---- Test: Non-UDP protocol (TCP, should be dropped) ----");
    begin
        automatic logic [7:0] tcp_frame[];
        tcp_frame = new[54];
        // Ethernet header
        tcp_frame[0]=8'hFF; tcp_frame[1]=8'hFF; tcp_frame[2]=8'hFF;
        tcp_frame[3]=8'hFF; tcp_frame[4]=8'hFF; tcp_frame[5]=8'hFF;
        tcp_frame[6]=8'h00; tcp_frame[7]=8'h11; tcp_frame[8]=8'h22;
        tcp_frame[9]=8'h33; tcp_frame[10]=8'h44; tcp_frame[11]=8'h55;
        tcp_frame[12]=8'h08; tcp_frame[13]=8'h00;   // IPv4
        // IPv4 header: version/IHL, DSCP, total_len=40, ID, flags, TTL, protocol=TCP
        tcp_frame[14]=8'h45; tcp_frame[15]=8'h00;
        tcp_frame[16]=8'h00; tcp_frame[17]=8'h28;   // Total length = 40
        tcp_frame[18]=8'h00; tcp_frame[19]=8'h01;
        tcp_frame[20]=8'h00; tcp_frame[21]=8'h00;   // No fragment
        tcp_frame[22]=8'h40; tcp_frame[23]=8'h06;   // TTL=64, Protocol=TCP
        tcp_frame[24]=8'h00; tcp_frame[25]=8'h00;   // Checksum (not computing here)
        tcp_frame[26]=8'hC0; tcp_frame[27]=8'hA8; tcp_frame[28]=8'h01; tcp_frame[29]=8'h01;
        tcp_frame[30]=8'hC0; tcp_frame[31]=8'hA8; tcp_frame[32]=8'h01; tcp_frame[33]=8'h02;
        // Fake TCP payload (20 bytes)
        for (int i = 34; i < 54; i++) tcp_frame[i] = 8'h00;

        pkt_gen.send_raw_bytes(tcp_frame, 54, 8);
    end

    // ── Fragmented IPv4 packet ────────────────────────────────────────────────
    $display("\n---- Test: Fragmented IPv4 packet (should be dropped) ----");
    begin
        automatic logic [7:0] frag_frame[];
        frag_frame = new[42];
        // Ethernet header
        frag_frame[0]=8'hFF; frag_frame[1]=8'hFF; frag_frame[2]=8'hFF;
        frag_frame[3]=8'hFF; frag_frame[4]=8'hFF; frag_frame[5]=8'hFF;
        frag_frame[6]=8'h00; frag_frame[7]=8'h11; frag_frame[8]=8'h22;
        frag_frame[9]=8'h33; frag_frame[10]=8'h44; frag_frame[11]=8'h55;
        frag_frame[12]=8'h08; frag_frame[13]=8'h00;
        // IPv4: MF flag set (0x20xx)
        frag_frame[14]=8'h45; frag_frame[15]=8'h00;
        frag_frame[16]=8'h00; frag_frame[17]=8'h1C;  // 28 bytes
        frag_frame[18]=8'h00; frag_frame[19]=8'h01;
        frag_frame[20]=8'h20; frag_frame[21]=8'h00;  // MF=1, offset=0
        frag_frame[22]=8'h40; frag_frame[23]=8'h11;  // TTL=64, UDP
        frag_frame[24]=8'h00; frag_frame[25]=8'h00;
        frag_frame[26]=8'hC0; frag_frame[27]=8'hA8; frag_frame[28]=8'h01; frag_frame[29]=8'h01;
        frag_frame[30]=8'hC0; frag_frame[31]=8'hA8; frag_frame[32]=8'h01; frag_frame[33]=8'h02;
        // Partial UDP header
        frag_frame[34]=8'h04; frag_frame[35]=8'hD2;  // src port 1234
        frag_frame[36]=8'h16; frag_frame[37]=8'h2E;  // dst port 5678
        frag_frame[38]=8'h00; frag_frame[39]=8'h08;
        frag_frame[40]=8'h00; frag_frame[41]=8'h00;

        pkt_gen.send_raw_bytes(frag_frame, 42, 8);
    end

    // ── Valid packet after errors (pipeline must recover) ─────────────────────
    $display("\n---- Test: Valid packet after error frames ----");
    begin
        automatic logic [7:0] recovery_payload[] = '{8'h01, 8'h02, 8'h03, 8'h04};

        sb.add_expected_packet(
            .src_ip    (32'hC0A80101),
            .dst_ip    (32'hC0A80102),
            .src_port  (16'd1111),
            .dst_port  (16'd2222),
            .udp_length(16'd12),
            .should_be_valid(1'b1)
        );

        pkt_gen.send_udp_packet(
            .dst_mac        (48'hFF_FFFF_FFFF_FF),
            .src_mac_in     (48'h00_AABB_CCDD_EE),
            .src_ip         (32'hC0A80101),
            .dst_ip         (32'hC0A80102),
            .src_port       (16'd1111),
            .dst_port       (16'd2222),
            .payload        (recovery_payload),
            .payload_len    (4),
            .gap_cycles     (8)
        );
    end

endtask
