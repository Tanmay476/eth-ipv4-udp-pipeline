//================================================================================
// File: scoreboard.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   Self-checking scoreboard.  The testbench pushes expected packet descriptors
//   via add_expected_packet(); the scoreboard monitors the DUT outputs and
//   compares each received metadata beat against the next expected entry.
//
//   Collected statistics:
//     packets_checked  – total comparisons made
//     packets_passed   – comparisons that matched
//     packets_failed   – comparisons that did not match
//================================================================================

`timescale 1ns/1ps

module scoreboard (
    input logic clk,
    input logic rst_n,

    // ── DUT metadata outputs to monitor ──────────────────────────────────────
    input logic        meta_valid,
    input logic [31:0] meta_src_ip,
    input logic [31:0] meta_dst_ip,
    input logic [15:0] meta_src_port,
    input logic [15:0] meta_dst_port,
    input logic [15:0] meta_udp_length,
    input logic        meta_packet_valid,
    input logic [3:0]  meta_error_flags,

    // ── DUT payload stream ────────────────────────────────────────────────────
    input logic [7:0]  payload_tdata,
    input logic        payload_tvalid,
    input logic        payload_tready,
    input logic        payload_tlast
);

// ─── Expected packet descriptor ──────────────────────────────────────────────
typedef struct {
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic [15:0] src_port;
    logic [15:0] dst_port;
    logic [15:0] udp_length;
    logic        should_be_valid;   // 1 = expect packet_valid; 0 = expect drop/error
} pkt_desc_t;

localparam MAX_QUEUE = 64;
pkt_desc_t exp_queue [0:MAX_QUEUE-1];
int        eq_wr_ptr;
int        eq_rd_ptr;

// ─── Counters ─────────────────────────────────────────────────────────────────
int packets_checked;
int packets_passed;
int packets_failed;

initial begin
    eq_wr_ptr       = 0;
    eq_rd_ptr       = 0;
    packets_checked = 0;
    packets_passed  = 0;
    packets_failed  = 0;
end

// ─── Public task: push an expected entry ─────────────────────────────────────
task automatic add_expected_packet(
    input logic [31:0] src_ip,
    input logic [31:0] dst_ip,
    input logic [15:0] src_port,
    input logic [15:0] dst_port,
    input logic [15:0] udp_length,
    input logic        should_be_valid = 1'b1
);
    exp_queue[eq_wr_ptr].src_ip         = src_ip;
    exp_queue[eq_wr_ptr].dst_ip         = dst_ip;
    exp_queue[eq_wr_ptr].src_port       = src_port;
    exp_queue[eq_wr_ptr].dst_port       = dst_port;
    exp_queue[eq_wr_ptr].udp_length     = udp_length;
    exp_queue[eq_wr_ptr].should_be_valid = should_be_valid;
    eq_wr_ptr = (eq_wr_ptr + 1) % MAX_QUEUE;
endtask

// ─── Monitor DUT metadata outputs ────────────────────────────────────────────
always @(posedge clk) begin
    if (meta_valid) begin
        if (eq_rd_ptr == eq_wr_ptr) begin
            $display("[SCOREBOARD] ERROR: received unexpected metadata (queue empty)  t=%0t", $time);
            packets_failed++;
        end else begin
            automatic pkt_desc_t exp = exp_queue[eq_rd_ptr];
            eq_rd_ptr = (eq_rd_ptr + 1) % MAX_QUEUE;
            packets_checked++;

            if (exp.should_be_valid && !meta_packet_valid) begin
                $display("[SCOREBOARD] FAIL t=%0t: expected valid packet but packet_valid=0", $time);
                $display("             src_ip=%h dst_ip=%h src_port=%0d dst_port=%0d",
                         meta_src_ip, meta_dst_ip, meta_src_port, meta_dst_port);
                packets_failed++;
            end else if (!exp.should_be_valid && meta_packet_valid) begin
                $display("[SCOREBOARD] FAIL t=%0t: expected invalid/dropped packet but packet_valid=1", $time);
                packets_failed++;
            end else if (exp.should_be_valid) begin
                // Check field values
                automatic logic pass = 1'b1;

                if (meta_src_ip   !== exp.src_ip)    begin $display("[SCOREBOARD] FAIL src_ip:   got %h, exp %h",   meta_src_ip, exp.src_ip);    pass = 0; end
                if (meta_dst_ip   !== exp.dst_ip)    begin $display("[SCOREBOARD] FAIL dst_ip:   got %h, exp %h",   meta_dst_ip, exp.dst_ip);    pass = 0; end
                if (meta_src_port !== exp.src_port)  begin $display("[SCOREBOARD] FAIL src_port: got %0d, exp %0d", meta_src_port, exp.src_port); pass = 0; end
                if (meta_dst_port !== exp.dst_port)  begin $display("[SCOREBOARD] FAIL dst_port: got %0d, exp %0d", meta_dst_port, exp.dst_port); pass = 0; end
                if (meta_udp_length !== exp.udp_length) begin $display("[SCOREBOARD] FAIL udp_len: got %0d, exp %0d", meta_udp_length, exp.udp_length); pass = 0; end

                if (pass) begin
                    $display("[SCOREBOARD] PASS t=%0t: src_ip=%h dst_ip=%h src_port=%0d dst_port=%0d udp_len=%0d",
                             $time, meta_src_ip, meta_dst_ip, meta_src_port, meta_dst_port, meta_udp_length);
                    packets_passed++;
                end else begin
                    packets_failed++;
                end
            end else begin
                // Correctly dropped packet
                $display("[SCOREBOARD] PASS t=%0t: packet correctly dropped/errored (error_flags=%b)", $time, meta_error_flags);
                packets_passed++;
            end
        end
    end
end

// ─── Public task: print summary ──────────────────────────────────────────────
task automatic print_summary();
    $display("=================================================");
    $display(" SCOREBOARD SUMMARY");
    $display("   Checked : %0d", packets_checked);
    $display("   Passed  : %0d", packets_passed);
    $display("   Failed  : %0d", packets_failed);
    if (eq_rd_ptr != eq_wr_ptr)
        $display("   WARNING : %0d expected entries not consumed", (eq_wr_ptr - eq_rd_ptr + MAX_QUEUE) % MAX_QUEUE);
    if (packets_failed == 0)
        $display("   RESULT  : *** ALL TESTS PASSED ***");
    else
        $display("   RESULT  : *** %0d TESTS FAILED ***", packets_failed);
    $display("=================================================");
endtask

endmodule
