// Adapter from the renderer's streaming row read to sdram_ctrl's video channel.
//
// The source port wants *rd_count* consecutive 16-bit entries starting at an
// arbitrary even byte address.  The video channel reads one 256-byte line of
// 128 halfwords at a time: vstart pulses with vaddr[24:8], 128 words follow on
// vvalid with their vindex, and vdone closes the line.  This issues as many
// lines as the request needs, skips the entries before the requested address on
// the first one, and forwards entries one per cycle.
//
// A request that arrives while a line is still open is held, not started.  The
// renderer's fetch engine drops f_busy on the last entry it accepts, which is
// not the last entry of the SDRAM line: the line keeps streaming for a few
// cycles and then closes with vdone.  Starting the next request on rd_start
// therefore raced that vdone -- the adapter reloaded base, skip and left under
// a line that had not closed, and the old line's vdone then read as the new
// request's end-of-line and asked for the line after it.  A row came back one
// SDRAM line out of place, which fetch it hit depended on SDRAM latency, and
// the renderer's blocking path -- three fetches back to back at the top of a
// frame and after a pan -- was the only place it could happen.  That is the
// corruption at the top of the frame: measured in simulation as ten vstarts
// during a live line in four frames before this change, none after.
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

localparam [1:0] A_IDLE = 2'd0,   // nothing open, nothing waiting
                 A_LINE = 2'd1,   // a 256-byte line is streaming
                 A_GAP  = 2'd2;   // the line closed last cycle; one clear cycle

reg [1:0]  st;
reg [24:8] base;
reg [6:0]  skip;
reg [15:0] left;

// one deep: the renderer never has two requests in flight, because f_busy gates
// it, so a single held request is enough
reg        held;
reg [24:0] h_addr;
reg [15:0] h_count;

wire        take   = (st == A_IDLE) && (rd_start || held);
wire [24:0] t_addr = held ? h_addr  : rd_addr;
wire [15:0] t_cnt  = held ? h_count : rd_count;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        st      <= A_IDLE;
        rd_data <= 16'd0; rd_valid <= 1'b0; vstart <= 1'b0; vaddr <= 17'd0;
        base    <= 17'd0; skip <= 7'd0; left <= 16'd0;
        held    <= 1'b0; h_addr <= 25'd0; h_count <= 16'd0;
    end else begin
        rd_valid <= 1'b0;
        vstart   <= 1'b0;

        // hold a request that cannot start yet
        if (rd_start && !(st == A_IDLE)) begin
            held    <= 1'b1;
            h_addr  <= rd_addr;
            h_count <= rd_count;
        end

        case (st)
        A_IDLE: if (take) begin
            base   <= t_addr[24:8];
            skip   <= t_addr[7:1];
            left   <= t_cnt;
            vaddr  <= t_addr[24:8];
            vstart <= 1'b1;
            st     <= A_LINE;
            held   <= 1'b0;
        end

        A_LINE: begin
            if (vvalid && vindex >= skip && left != 16'd0) begin
                rd_data  <= vdata;
                rd_valid <= 1'b1;
                left     <= left - 16'd1;
            end
            if (vdone) begin
                if (left != 16'd0) begin
                    base   <= base + 17'd1;
                    skip   <= 7'd0;
                    vaddr  <= base + 17'd1;
                    vstart <= 1'b1;
                end else begin
                    st <= A_GAP;
                end
            end
        end

        A_GAP: st <= A_IDLE;
        default: st <= A_IDLE;
        endcase
    end
end

endmodule
