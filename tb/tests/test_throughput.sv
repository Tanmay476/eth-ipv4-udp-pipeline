//================================================================================
// File: test_throughput.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Throughput and backpressure tests.
//   - Burst of back-to-back packets with no inter-packet gap.
//   - Backpressure: TREADY deasserted mid-stream to verify no data loss.
//   - Latency measurement: clock cycles from first input byte to meta_valid.
//   Included by tb_packet_processor.sv.
//================================================================================

task run_throughput_tests();
    automatic int i;

    // ── Burst: 10 packets with zero inter-packet gap ──────────────────────────
    $display("\n---- Test: Burst of 10 packets (gap=0) ----");
    begin
        automatic logic [7:0] pay[] = '{8'hDE, 8'hAD, 8'hBE, 8'hEF};

        for (i = 0; i < 10; i++) begin
            sb.add_expected_packet(
                .src_ip    (32'h0A0B0C0D),
                .dst_ip    (32'h0A0B0C0E),
                .src_port  (16'(5000 + i)),
                .dst_port  (16'(6000 + i)),
                .udp_length(16'd12),
                .should_be_valid(1'b1)
            );
        end

        for (i = 0; i < 10; i++) begin
            // Override src/dst port for each packet by rebuilding
            automatic logic [7:0] p[] = '{8'hDE, 8'hAD, 8'hBE, 8'hEF};
            pkt_gen.send_udp_packet(
                .dst_mac        (48'hFF_FFFF_FFFF_FF),
                .src_mac_in     (48'h00_1234_5678_9A),
                .src_ip         (32'h0A0B0C0D),
                .dst_ip         (32'h0A0B0C0E),
                .src_port       (16'(5000 + i)),
                .dst_port       (16'(6000 + i)),
                .payload        (p),
                .payload_len    (4),
                .gap_cycles     (0)
            );
        end
    end

    // Wait for all packets to flush
    repeat (200) @(posedge clk);

    // ── Backpressure test: TREADY deasserted during payload ───────────────────
    $display("\n---- Test: Backpressure (TREADY toggled) ----");
    // This test is driven by the testbench forking the TREADY toggling and
    // the packet send concurrently.  The scoreboard verifies correctness.
    begin
        automatic logic [7:0] bp_pay[];
        bp_pay = new[32];
        for (i = 0; i < 32; i++) bp_pay[i] = 8'(i + 1);

        sb.add_expected_packet(
            .src_ip    (32'hC0A80201),
            .dst_ip    (32'hC0A80202),
            .src_port  (16'd9000),
            .dst_port  (16'd9001),
            .udp_length(16'd40),
            .should_be_valid(1'b1)
        );

        // Drive real backpressure: bp_enable hands m_axis_tready over to the
        // toggling block in tb_packet_processor (deasserted every 5th cycle).
        // Without this the flag stays 0, TREADY is stuck high, and this test
        // silently exercises no backpressure at all.
        bp_enable = 1'b1;

        pkt_gen.send_udp_packet(
            .dst_mac        (48'hFF_FFFF_FFFF_FF),
            .src_mac_in     (48'h00_CAFE_BABE_12),
            .src_ip         (32'hC0A80201),
            .dst_ip         (32'hC0A80202),
            .src_port       (16'd9000),
            .dst_port       (16'd9001),
            .payload        (bp_pay),
            .payload_len    (32),
            .gap_cycles     (4)
        );

        // Let the frame drain through the pipeline before restoring TREADY.
        repeat (100) @(posedge clk);
        bp_enable = 1'b0;
    end

    // ── Latency measurement ───────────────────────────────────────────────────
    $display("\n---- Test: Latency measurement ----");
    begin
        automatic logic [7:0] lat_pay[] = '{8'hAB, 8'hCD};
        automatic longint     t_start, t_meta;

        sb.add_expected_packet(
            .src_ip    (32'h01020304),
            .dst_ip    (32'h05060708),
            .src_port  (16'd100),
            .dst_port  (16'd200),
            .udp_length(16'd10),
            .should_be_valid(1'b1)
        );

        @(posedge clk); #1;
        t_start = $time;

        // meta_valid pulses WHILE the frame is still streaming (it is emitted
        // with the first payload byte), so the wait must be armed before the
        // send - waiting after send_udp_packet returns would miss the pulse
        // and block until the watchdog fires.
        fork
            begin
                @(posedge meta_valid_mon);
                t_meta = $time;
            end

            pkt_gen.send_udp_packet(
                .dst_mac        (48'hFF_FFFF_FFFF_FF),
                .src_mac_in     (48'h00_0102_0304_05),
                .src_ip         (32'h01020304),
                .dst_ip         (32'h05060708),
                .src_port       (16'd100),
                .dst_port       (16'd200),
                .payload        (lat_pay),
                .payload_len    (2),
                .gap_cycles     (8)
            );
        join
        $display("[THROUGHPUT] Pipeline latency (start→meta_valid): %0d cycles",
                 (t_meta - t_start) / `CLK_PERIOD);
    end

endtask
