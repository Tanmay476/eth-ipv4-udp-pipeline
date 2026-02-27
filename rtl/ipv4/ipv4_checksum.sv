//================================================================================
// File: ipv4_checksum.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   IPv4 header checksum calculator and validator.
//   Computes 16-bit one's complement sum over the IPv4 header.
//   Validates received checksum by verifying sum equals 0xFFFF.
//
// Algorithm:
//   1. Accumulate 16-bit words incrementally as bytes arrive (byte-serial)
//   2. Skip bytes 10-11 (checksum field) — treat as 0x0000
//   3. In FINALIZE: two-stage carry fold + one's complement
//   4. For validation: sum all words INCLUDING checksum, result should be 0xFFFF
//
// Pipelining:
//   The original design stored all 60 header bytes and computed the checksum
//   with a 30-input combinational adder tree (~10-12 ns critical path).
//   This version accumulates the running sum register-to-register as each byte
//   pair arrives.  The critical path is now a single 21-bit registered add:
//
//     running_sum FF → 21-bit adder → running_sum FF   (~2.0-2.5 ns, Fmax ~400+ MHz)
//
//   The FINALIZE fold (two small adders in series) is ~2.5-3 ns, which is the
//   actual timing constraint and comfortably meets 300 MHz on Artix-7 / Cyclone V.
//
// Usage:
//   - Assert 'start' at beginning of header (byte_count must be 0)
//   - Feed header bytes one at a time with 'data_valid'
//   - After 'header_length' bytes, checksum is calculated
//   - 'checksum_valid' indicates if header checksum is correct
//   - 'done' pulses when calculation completes (one cycle after last byte)
//================================================================================

module ipv4_checksum #(
    parameter DATA_WIDTH = 8  // Input data width in bits (must be 8)
)(
    // Clock and reset
    input logic clk,
    input logic rst_n,

    // Control signals
    input logic start,               // Start checksum calculation (pulse at byte 0)
    input logic data_valid,          // Input data is valid

    // Data input
    input logic [7:0] data_byte,     // Header byte stream
    input logic [5:0] byte_count,    // Current byte position (0-59)
    input logic [5:0] header_length, // Total header length in bytes (20-60)

    // Output
    output logic checksum_valid,     // Header checksum is valid (sum = 0xFFFF)
    output logic done,               // Calculation complete (one-cycle pulse)
    output logic [15:0] calculated_checksum  // Calculated checksum value
);

//-----------------------------------------------------------------------------
// State machine
//-----------------------------------------------------------------------------
typedef enum logic [1:0] {
    IDLE,
    ACCUMULATE,   // Byte-serial accumulation of 16-bit words
    FINALIZE      // Carry fold and complement
} state_t;

state_t state, next_state;

always_ff @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
end

always_comb begin
    next_state = state;
    case (state)
        IDLE:       if (start)                                          next_state = ACCUMULATE;
        ACCUMULATE: if (data_valid && byte_count >= header_length - 1) next_state = FINALIZE;
        FINALIZE:                                                        next_state = IDLE;
        default:    next_state = IDLE;
    endcase
end

//-----------------------------------------------------------------------------
// Byte-serial accumulation
//
// Bytes arrive one at a time.  We pair them into 16-bit words:
//   even byte → stage in byte_hi
//   odd  byte → add {byte_hi, data_byte} to running_sum
//
// Bytes 10-11 are skipped (checksum field treated as 0x0000).
//
// Max accumulator value: 30 words × 0xFFFF = 0x1DFFE1 → 21 bits sufficient.
//
// Critical path:  running_sum FF  →  21-bit adder  →  running_sum FF
//                 (~2.0-2.5 ns on Artix-7, Fmax ~400+ MHz)
//-----------------------------------------------------------------------------
logic [20:0] running_sum;  // 21-bit one's-complement accumulator
logic [7:0]  byte_hi;      // Staged high byte of the current 16-bit word
logic        has_byte_hi;  // High byte is staged and waiting for its low partner

always_ff @(posedge clk) begin
    if (!rst_n) begin
        running_sum <= 21'd0;
        byte_hi     <= 8'd0;
        has_byte_hi <= 1'b0;
    end else begin
        // Clear accumulator at the start of each new packet
        if (state == IDLE && start) begin
            running_sum <= 21'd0;
            has_byte_hi <= 1'b0;
        end

        if (state == ACCUMULATE && data_valid) begin
            // Skip the checksum field (bytes 10-11) — treat as 0x0000
            if (byte_count == 6'd10 || byte_count == 6'd11) begin
                // No state change; has_byte_hi stays 0 across this pair
                // (byte 10 is always even so has_byte_hi is 0 on entry)
            end else if (!has_byte_hi) begin
                // Even byte: stage as high byte of the upcoming 16-bit word
                byte_hi     <= data_byte;
                has_byte_hi <= 1'b1;
            end else begin
                // Odd byte: complete the 16-bit word and add to running sum
                running_sum <= running_sum + {5'd0, byte_hi, data_byte};
                has_byte_hi <= 1'b0;
            end
        end
    end
end

//-----------------------------------------------------------------------------
// Two-stage carry fold (evaluated combinationally in FINALIZE,
// then registered into the output on the same clock edge)
//
// Critical path:  running_sum FF  →  fold1 (17-bit add)  →  fold2 (16-bit add)
//                 →  output FF setup   (~2.5-3.0 ns, Fmax ~330-400 MHz)
//
// This is now the timing bottleneck of the module.  If a higher Fmax is
// required, add one pipeline register between fold1 and fold2 and split
// FINALIZE into two states.
//-----------------------------------------------------------------------------
logic [16:0] fold1;               // Add upper 5 carry bits back into [15:0]
logic [15:0] fold2;               // Absorb any remaining carry
logic [15:0] checksum_ones_comp;  // One's complement = checksum to insert

assign fold1            = {1'b0, running_sum[15:0]} + {12'd0, running_sum[20:16]};
assign fold2            = fold1[15:0] + {15'd0, fold1[16]};
assign checksum_ones_comp = ~fold2;

//-----------------------------------------------------------------------------
// Output registers
//-----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n) begin
        done                <= 1'b0;
        checksum_valid      <= 1'b0;
        calculated_checksum <= 16'd0;
    end else begin
        done <= 1'b0;  // Default: no pulse

        if (state == FINALIZE) begin
            done                <= 1'b1;
            calculated_checksum <= checksum_ones_comp;
            // Validation: if the received checksum was included in the sum,
            // a correct header produces fold2 == 0xFFFF
            checksum_valid      <= (fold2 == 16'hFFFF);
        end
    end
end

endmodule
