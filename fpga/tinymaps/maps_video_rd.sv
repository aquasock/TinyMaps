// Adapter from the renderer's streaming row read to sdram_ctrl's video channel.
//
// The source port wants *rd_count* consecutive 16-bit entries starting at an
// arbitrary even byte address.  The video channel reads one 256-byte line of
// 128 halfwords at a time: vstart pulses with vaddr[24:8], 128 words follow on
// vvalid with their vindex, and vdone closes the line.  This issues as many
// lines as the request needs, skips the entries before the requested address on
// the first one, and forwards entries one per cycle.
//
// Both sides are on the same clock: sdram_ctrl and the renderer both run on the
// pixel clock, so there is no crossing here and no block RAM written on one
// clock and read on another -- the combination Apicula reads back wrong on the
// GW5AST-138.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_video_rd (
    input  wire        clk,
    input  wire        resetn,

    // renderer side
    input  wire        rd_start,
    input  wire [24:0] rd_addr,
    input  wire [15:0] rd_count,
    output reg  [15:0] rd_data,
    output reg         rd_valid,

    // sdram_ctrl video channel
    output reg         vstart,
    output reg  [24:8] vaddr,
    input  wire        vvalid,
    input  wire [6:0]  vindex,
    input  wire [15:0] vdata,
    input  wire        vdone
);

reg [24:8] base;
reg [6:0]  skip;
reg [15:0] left;
reg        active;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        rd_data <= 16'd0; rd_valid <= 1'b0; vstart <= 1'b0; vaddr <= 17'd0;
        base <= 17'd0; skip <= 7'd0; left <= 16'd0; active <= 1'b0;
    end else begin
        rd_valid <= 1'b0;
        vstart   <= 1'b0;

        if (rd_start) begin
            base   <= rd_addr[24:8];
            skip   <= rd_addr[7:1];
            left   <= rd_count;
            vstart <= 1'b1;
            vaddr  <= rd_addr[24:8];
            active <= 1'b1;
        end else if (active) begin
            if (vvalid && vindex >= skip && left != 16'd0) begin
                rd_data  <= vdata;
                rd_valid <= 1'b1;
                left     <= left - 16'd1;
            end
            if (vdone) begin
                if (left != 16'd0) begin
                    base   <= base + 17'd1;
                    skip   <= 7'd0;
                    vstart <= 1'b1;
                    vaddr  <= base + 17'd1;
                end else begin
                    active <= 1'b0;
                end
            end
        end
    end
end

endmodule
