//================================================================================
// File: udp_checksum.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   UDP checksum validator.
//   Computes the 16-bit one's complement checksum over:
//     - IPv4 pseudo-header: [src_ip][dst_ip][0x00][0x11][udp_length]
//     - UDP header:         [src_port][dst_port][udp_length][received_checksum]
//     - UDP payload:        variable-length byte stream
//
//   For validation: sum of all words (including the received checksum field)
//   must equal 0xFFFF after carry folding. Special case: a received checksum
//   of 0x0000 means checksum was disabled (RFC 768), so checksum_valid=1.
//
// Usage:
//   1. Assert 'start' for one cycle. At the same time provide the IPv4
//      pseudo-header fields and the UDP header fields.
//   2. Feed payload bytes one at a time with data_valid=1.
//   3. Assert is_last on the final byte.
//   4. 'done' pulses for one cycle; 'checksum_valid' holds the result.
//================================================================================

module udp_checksum (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        start,          // Pulse to begin; latch header fields
    input  logic        data_valid,     // Payload byte is valid
    input  logic        is_last,        // Last payload byte

    // IPv4 pseudo-header inputs (stable when start pulses)
    input  logic [31:0] ip_src_addr,
    input  logic [31:0] ip_dst_addr,
    input  logic [15:0] udp_total_length, // UDP length field (header + data)

    // UDP header fields (stable when start pulses)
    input  logic [15:0] udp_src_port,
    input  logic [15:0] udp_dst_port,
    input  logic [15:0] received_checksum, // The checksum stored in the UDP header

    // Payload byte stream
    input  logic [7:0]  data_byte,

    // Outputs
    output logic        checksum_valid, // 1 if checksum passes (or was disabled)
    output logic        done            // One-cycle pulse when result is ready
);

// ─── State machine ────────────────────────────────────────────────────────────
typedef enum logic [1:0] {
    IDLE,
    ACCUMULATE,
    FINALIZE
} state_t;

state_t state, next_state;

// ─── Accumulator ──────────────────────────────────────────────────────────────
// Maximum accumulator width:
//   Pseudo-header : 6 × 0xFFFF = 6×65535 = 393210 (~19 bits)
//   UDP header    : 4 × 0xFFFF = 262140
//   Payload       : up to (65535-8)/2 ≈ 32763 × 0xFFFF
//   Grand total fits in 32 bits comfortably; we use 32 bits.
logic [31:0] running_sum;

// Byte-pair staging for odd-length payloads
logic [7:0]  byte_hi;
logic        has_byte_hi;

// ─── Combinational fold for finalization ─────────────────────────────────────
logic [31:0] pre_fold_sum;
logic [16:0] fold1;
logic [15:0] fold2;

assign pre_fold_sum = has_byte_hi
                    ? running_sum + {24'd0, byte_hi}  // pad odd byte at MSB position
                    : running_sum;

// Two-stage carry folding: any 32-bit sum → 16-bit
assign fold1 = {1'b0, pre_fold_sum[15:0]} + {1'b0, pre_fold_sum[31:16]};
assign fold2 = fold1[15:0] + {15'd0, fold1[16]};

// ─── State register ───────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
end

// ─── Next-state logic ─────────────────────────────────────────────────────────
always_comb begin
    next_state = state;
    case (state)
        IDLE:        if (start)                    next_state = ACCUMULATE;
        ACCUMULATE:  if (data_valid && is_last)    next_state = FINALIZE;
        FINALIZE:                                  next_state = IDLE;
        default:                                   next_state = IDLE;
    endcase
end

// ─── Datapath ─────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        running_sum    <= 32'd0;
        byte_hi        <= 8'd0;
        has_byte_hi    <= 1'b0;
        done           <= 1'b0;
        checksum_valid <= 1'b0;
    end else begin
        done <= 1'b0;  // Default: no pulse

        case (state)
            IDLE: begin
                if (start) begin
                    // Pre-load: sum of IPv4 pseudo-header + UDP header
                    // Pseudo-header (12 bytes = 6 words):
                    //   src_ip[31:16], src_ip[15:0],
                    //   dst_ip[31:16], dst_ip[15:0],
                    //   {0x00, 0x11},  udp_length
                    // UDP header (8 bytes = 4 words):
                    //   src_port, dst_port, udp_length, received_checksum
                    running_sum <= {16'd0, ip_src_addr[31:16]}
                                 + {16'd0, ip_src_addr[15:0]}
                                 + {16'd0, ip_dst_addr[31:16]}
                                 + {16'd0, ip_dst_addr[15:0]}
                                 + 32'd17                          // protocol = 0x11
                                 + {16'd0, udp_total_length}
                                 + {16'd0, udp_src_port}
                                 + {16'd0, udp_dst_port}
                                 + {16'd0, udp_total_length}
                                 + {16'd0, received_checksum};     // include for validation
                    has_byte_hi <= 1'b0;
                end
            end

            ACCUMULATE: begin
                if (data_valid) begin
                    if (!has_byte_hi) begin
                        if (is_last) begin
                            // Odd-length payload: pad final byte at high position
                            running_sum <= running_sum + {24'd0, data_byte} << 8;
                            has_byte_hi <= 1'b0;
                        end else begin
                            // Stage the high byte
                            byte_hi     <= data_byte;
                            has_byte_hi <= 1'b1;
                        end
                    end else begin
                        // Complete the 16-bit word
                        running_sum <= running_sum + {16'd0, byte_hi, data_byte};
                        has_byte_hi <= 1'b0;
                    end
                end
            end

            FINALIZE: begin
                done <= 1'b1;
                // If received checksum is 0, UDP checksum is disabled (always valid)
                if (received_checksum == 16'd0)
                    checksum_valid <= 1'b1;
                else
                    checksum_valid <= (fold2 == 16'hFFFF);
            end

            default: ;
        endcase
    end
end

endmodule
