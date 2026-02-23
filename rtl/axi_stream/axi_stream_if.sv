//================================================================================
// File: axi_stream_if.sv
// Project: Ethernet/IPv4/UDP Packet Processor
// Author: Tanmay Shukla
// Date: 2026-01-01
//
// Description:
//   AXI4-Stream interface definition.
//   Provides TDATA, TVALID, TREADY, TKEEP, TLAST, and TUSER signals.
//   Includes master, slave, and monitor modports.
//
// Parameters:
//   DATA_WIDTH - Bus width in bits (must be a multiple of 8, default 8)
//   USER_WIDTH - Width of the TUSER sideband in bits (default 1)
//================================================================================

interface axi_stream_if #(
    parameter DATA_WIDTH = 8,
    parameter USER_WIDTH = 1
)(
    input logic clk,
    input logic rst_n
);

    logic [DATA_WIDTH-1:0]       tdata;
    logic                        tvalid;
    logic                        tready;
    logic [(DATA_WIDTH/8)-1:0]   tkeep;   // Byte-enable: 1 bit per data byte
    logic                        tlast;   // End-of-frame
    logic [USER_WIDTH-1:0]       tuser;   // Sideband (e.g. error flags)

    // Master drives data toward the slave
    modport master (
        input  clk, rst_n,
        output tdata, tvalid, tkeep, tlast, tuser,
        input  tready
    );

    // Slave accepts data from the master
    modport slave (
        input  clk, rst_n,
        input  tdata, tvalid, tkeep, tlast, tuser,
        output tready
    );

    // Monitor observes without driving any signal
    modport monitor (
        input  clk, rst_n,
        input  tdata, tvalid, tready, tkeep, tlast, tuser
    );

endinterface
