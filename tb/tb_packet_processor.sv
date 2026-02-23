//================================================================================
// File: tb_packet_processor.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Top-level self-checking testbench for packet_processor_top.
//   Instantiates the DUT, packet generator, and scoreboard.
//   Runs three test suites: basic, error-injection, throughput.
//================================================================================

`timescale 1ns/1ps

`define CLK_PERIOD 10   // 10 ns = 100 MHz

module tb_packet_processor;

// ─── Clock and reset ──────────────────────────────────────────────────────────
logic clk;
logic rst_n;

initial clk = 1'b0;
always #(`CLK_PERIOD/2) clk = ~clk;

initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
end

// ─── DUT interface signals ────────────────────────────────────────────────────
logic [7:0]  s_axis_tdata;
logic        s_axis_tvalid;
logic        s_axis_tlast;
logic        s_axis_tready;

logic [7:0]  m_axis_tdata;
logic        m_axis_tvalid;
logic        m_axis_tlast;
logic        m_axis_tready;

// Metadata
logic        meta_valid;
logic [47:0] meta_src_mac;
logic [47:0] meta_dst_mac;
logic [31:0] meta_src_ip;
logic [31:0] meta_dst_ip;
logic [7:0]  meta_ttl;
logic [7:0]  meta_protocol;
logic [15:0] meta_src_port;
logic [15:0] meta_dst_port;
logic [15:0] meta_udp_length;
logic [15:0] meta_payload_len;
logic [3:0]  meta_error_flags;
logic        meta_packet_valid;

// ─── DUT ─────────────────────────────────────────────────────────────────────
packet_processor_top #(
    .DROP_FRAGMENTS      (1),
    .VALIDATE_IP_CHKSUM  (1),
    .VALIDATE_UDP_CHKSUM (1)
) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .s_axis_tdata     (s_axis_tdata),
    .s_axis_tvalid    (s_axis_tvalid),
    .s_axis_tlast     (s_axis_tlast),
    .s_axis_tready    (s_axis_tready),
    .m_axis_tdata     (m_axis_tdata),
    .m_axis_tvalid    (m_axis_tvalid),
    .m_axis_tlast     (m_axis_tlast),
    .m_axis_tready    (m_axis_tready),
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

// ─── Packet generator ─────────────────────────────────────────────────────────
packet_generator pkt_gen (
    .clk           (clk),
    .rst_n         (rst_n),
    .m_axis_tdata  (s_axis_tdata),
    .m_axis_tvalid (s_axis_tvalid),
    .m_axis_tlast  (s_axis_tlast),
    .m_axis_tready (s_axis_tready)
);

// ─── Scoreboard ───────────────────────────────────────────────────────────────
scoreboard sb (
    .clk              (clk),
    .rst_n            (rst_n),
    .meta_valid       (meta_valid),
    .meta_src_ip      (meta_src_ip),
    .meta_dst_ip      (meta_dst_ip),
    .meta_src_port    (meta_src_port),
    .meta_dst_port    (meta_dst_port),
    .meta_udp_length  (meta_udp_length),
    .meta_packet_valid(meta_packet_valid),
    .meta_error_flags (meta_error_flags),
    .payload_tdata    (m_axis_tdata),
    .payload_tvalid   (m_axis_tvalid),
    .payload_tready   (m_axis_tready),
    .payload_tlast    (m_axis_tlast)
);

// ─── Default downstream TREADY (accept all) ───────────────────────────────────
initial m_axis_tready = 1'b1;

// ─── Monitor signal for latency measurement ───────────────────────────────────
logic meta_valid_mon;
assign meta_valid_mon = meta_valid;

// ─── Backpressure generation for throughput test ──────────────────────────────
// Toggle TREADY every 5 cycles during the backpressure test window.
// Controlled by a flag set from the test task.
logic bp_enable;
initial bp_enable = 1'b0;

always @(posedge clk) begin
    if (bp_enable) begin
        static int cnt = 0;
        cnt++;
        m_axis_tready <= (cnt % 5 != 0);   // Deassert every 5th cycle
    end else begin
        m_axis_tready <= 1'b1;
    end
end

// ─── Include test suites ──────────────────────────────────────────────────────
`include "tests/test_basic_packets.sv"
`include "tests/test_error_cases.sv"
`include "tests/test_throughput.sv"

// ─── VCD dump (optional, comment out for batch runs) ─────────────────────────
initial begin
    $dumpfile("sim/tb_packet_processor.vcd");
    $dumpvars(0, tb_packet_processor);
end

// ─── Main stimulus ────────────────────────────────────────────────────────────
initial begin
    // Wait for reset to de-assert
    @(posedge rst_n);
    repeat (4) @(posedge clk);

    // ── Suite 1: Basic packets ────────────────────────────────────────────────
    $display("\n========================================");
    $display(" SUITE 1: Basic Packets");
    $display("========================================");
    run_basic_tests();

    repeat (20) @(posedge clk);

    // ── Suite 2: Error cases ──────────────────────────────────────────────────
    $display("\n========================================");
    $display(" SUITE 2: Error Cases");
    $display("========================================");
    run_error_tests();

    repeat (20) @(posedge clk);

    // ── Suite 3: Throughput ───────────────────────────────────────────────────
    $display("\n========================================");
    $display(" SUITE 3: Throughput");
    $display("========================================");
    run_throughput_tests();

    repeat (50) @(posedge clk);

    // ── Print results ─────────────────────────────────────────────────────────
    sb.print_summary();

    $finish;
end

// ─── Timeout watchdog ─────────────────────────────────────────────────────────
initial begin
    #5_000_000;  // 5 ms at 1 ns resolution
    $display("[WATCHDOG] Simulation timeout!");
    $finish;
end

endmodule
