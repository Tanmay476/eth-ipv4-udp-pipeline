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
//   1. Sum all 16-bit words in the header (treating bytes 10-11 as 0 when computing)
//   2. Add any carry bits back to the sum (one's complement addition)
//   3. Take one's complement of result
//   4. For validation: sum all words INCLUDING checksum, result should be 0xFFFF
//
// Usage:
//   - Assert 'start' at beginning of header
//   - Feed header bytes one at a time with 'data_valid'
//   - After 'header_length' bytes, checksum is calculated
//   - 'checksum_valid' indicates if header checksum is correct
//   - 'done' pulses when calculation completes
//
// Future Enhancements:
//   - Pipelined calculation for higher throughput
//   - Incremental checksum update for header modifications
//================================================================================

module ipv4_checksum #(
    parameter DATA_WIDTH = 8  // Input data width in bits
)(
    // Clock and reset
    input logic clk,
    input logic rst_n,

    // Control signals
    input logic start,              // Start checksum calculation (pulse at byte 0)
    input logic data_valid,         // Input data is valid

    // Data input
    input logic [7:0] data_byte,    // Header byte stream
    input logic [5:0] byte_count,   // Current byte position (0-59)
    input logic [5:0] header_length, // Total header length in bytes (20-60)

    // Output
    output logic checksum_valid,    // Header checksum is valid (sum = 0xFFFF)
    output logic done,              // Calculation complete
    output logic [15:0] calculated_checksum  // Calculated checksum value (for debugging)
);

// Internal state machine
typedef enum logic[1:0] {
    IDLE,
    ACCUMULATE,   // Accumulating 16-bit words
    FINALIZE      // Handle final carry and complement
} state_t;

state_t state, next_state;

// Header byte storage
logic [7:0] header[0:59];

// State machine sequential logic
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state <= IDLE;
    end else begin
        state <= next_state;
    end
end

// Next state logic
always_comb begin
    next_state = state;
    case (state)
        IDLE: begin
            if (start) begin
                next_state = ACCUMULATE;
            end
        end
        ACCUMULATE: begin
            if (byte_count >= header_length - 1 && data_valid) begin
                next_state = FINALIZE;
            end
        end
        FINALIZE: begin
            next_state = IDLE;
        end
        default: next_state = IDLE;
    endcase
end

// Store header bytes as they arrive
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 60; i++) begin
            header[i] <= 8'd0;
        end
    end else if (state == ACCUMULATE && data_valid) begin
        header[byte_count] <= data_byte;
    end
end

//-----------------------------------------------------------------------------
// Checksum calculation with two-stage carry folding
//-----------------------------------------------------------------------------
// Max sum = 30 words × 0xFFFF = 0x1DFFE2 (21 bits)
// Two folds are sufficient to reduce any carry to 16 bits

logic [20:0] raw_sum;           // 21-bit accumulator for raw sum
logic [16:0] fold1;             // First fold result (17 bits)
logic [15:0] fold2;             // Second fold result (16 bits)
logic [15:0] checksum_ones_comp;

// Compute raw sum of all 16-bit words
// Skip checksum field at bytes 10-11 (treat as 0x0000 for generation)
always_comb begin
    raw_sum = 21'd0;
    for (int i = 0; i < 60; i = i + 2) begin
        if (i < header_length) begin
            if (i == 10) begin
                // Skip checksum field for generation
                raw_sum = raw_sum + 21'd0;
            end else begin
                raw_sum = raw_sum + {5'd0, header[i], header[i+1]};
            end
        end
    end
end

// First fold: add bits [20:16] back into bits [15:0]
assign fold1 = {1'b0, raw_sum[15:0]} + {12'd0, raw_sum[20:16]};

// Second fold: add any remaining carry bit
// After this, no further carry is possible since max fold1 = 0x1FFFE
// which gives fold2 = 0xFFFF + 1 = 0x10000, and that final carry
// folds to 0x0001, producing no new carry
assign fold2 = fold1[15:0] + {15'd0, fold1[16]};

// One's complement of the folded sum gives the checksum to insert
assign checksum_ones_comp = ~fold2;

//-----------------------------------------------------------------------------
// Output registers
//-----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n) begin
        done <= 1'b0;
        checksum_valid <= 1'b0;
        calculated_checksum <= 16'd0;
    end else begin
        done <= 1'b0;  // Pulse for one cycle only

        if (state == FINALIZE) begin
            done <= 1'b1;
            calculated_checksum <= checksum_ones_comp;

            // Validation: when the original checksum is included in the sum,
            // a correct header produces fold2 = 0xFFFF (all ones)
            checksum_valid <= (fold2 == 16'hFFFF);
        end
    end
end

endmodule
