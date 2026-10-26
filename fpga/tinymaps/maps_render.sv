// TinyMaps renderer, nearest-neighbour.
//
// Draws one output line from one source row of the selected pack level, with
// the viewport expressed in that level's own pixel space.  A source row's
// window is fetched into block RAM as 16-bit entries of two adjacent 8-bit
// pixels, and the pixel path reads one entry per output pixel and selects one
// of its two bytes, so nearest resampling costs one block RAM read per pixel.
//
// Bilinear is NOT implemented.  The plan calls for it, and it needs both source
// rows live plus an entry history on each (with step_x < 2 the entry index
// advances by at most one per pixel, so a single previous-entry register per
// row is enough).  That pipeline is a separate piece of work; this module
// resamples nearest only.
//
// Phase scope, stated plainly: this version fetches the row window at the start
// of every output line and only then emits the line, so at OUT_W = 1280 a line
// costs 1282 fetch cycles plus 1280 emit cycles against 1650 pixel clocks.
// That is correct but NOT real time.  Real time needs the next line's fetch to
// run while the current line emits, and a source row reused when two output
// lines map to it; neither is here yet.
//
// SPDX-License-Identifier: GPL-3.0-only

`timescale 1ns / 1ps

module maps_render #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    // entries fetched per row; one entry is two source pixels.  With step_x < 2
    // a line spans at most 2*OUT_W source pixels, i.e. OUT_W entries, and one
    // more covers the straddle at the right edge.
    parameter integer SPAN  = OUT_W + 2
) (
    input  wire        clk,
    input  wire        resetn,

    // viewport, in the level's pixel space, Q16.16
    input  wire signed [31:0] src_x0,     // source x at output x = 0
    input  wire signed [31:0] src_y0,     // source y at output y = 0
    input  wire        [31:0] step_x,     // source px per output px, in [1,2)
    input  wire        [31:0] step_y,
    input  wire [24:0] level_base,        // SDRAM byte address of level pixel (0,0)
    input  wire [15:0] level_w,
    input  wire [15:0] level_h,

    // source port: a 16-bit word at an even byte address, one cycle of latency
    output reg  [24:0] rd_addr,
    output reg         rd_req,
    input  wire [15:0] rd_data,
    input  wire        rd_valid,

    // palette
    input  wire        pal_we,
    input  wire [7:0]  pal_idx,
    input  wire [23:0] pal_data,

    // raster position, from the HDMI counters
    input  wire [10:0] cx,
    input  wire [9:0]  cy,

    // output stream; out_x is the output column out_rgb belongs to
    output reg  [11:0] out_x,
    output reg  [23:0] out_rgb,
    output reg         out_valid
);

localparam integer AIDX = $clog2(SPAN);

// ------------------------------------------------------------------ palette --
reg [23:0] pal [0:255];
always @(posedge clk) if (pal_we) pal[pal_idx] <= pal_data;

// ------------------------------------------------------------- line buffer ---
reg [15:0] lbuf [0:SPAN-1];

// ------------------------------------------------------------------- engine --
localparam [2:0] S_IDLE = 3'd0, S_SETUP = 3'd1, S_FETCH = 3'd2,
                 S_EMIT = 3'd3, S_DONE  = 3'd4;

reg [2:0]  st;
reg [9:0]  cy_d;
reg [31:0] acc_y;
reg [31:0] r0;
reg [31:0] base_a;
reg [31:0] k0;                 // entry index of the first entry fetched
reg [31:0] fetch_j;
reg [15:0] emit_x;
reg [31:0] acc_x;
reg [AIDX-1:0] rd_idx;
reg [15:0] qa;
reg        fetch_wait;

// pixel pipeline
reg        p1_v;
reg [11:0] p1_x;
reg        p1_odd;
reg        p1b_v, p1b_odd;
reg [11:0] p1b_x;
reg        p2_v;
reg [11:0] p2_x;
reg [7:0]  p2_idx;
reg        p3_v;
reg [11:0] p3_x;
reg [7:0]  p3_idx;

integer k;
always @(posedge clk) qa <= lbuf[rd_idx];

// entry holding source column col, and which of its two bytes:
//   entry  = col >> 1
//   byte   = col[0]
wire [31:0] entry_now = (acc_x >>> 17);            // (col >> 1)
wire         byte_now  = acc_x[16];                // col[0]

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        st <= S_IDLE; cy_d <= 10'h3FF; acc_y <= 32'd0; r0 <= 32'd0;
        base_a <= 25'd0; k0 <= 32'd0; fetch_j <= 32'd0;
        emit_x <= 16'd0; acc_x <= 32'd0; rd_idx <= {AIDX{1'b0}};
        rd_addr <= 25'd0; rd_req <= 1'b0; qa <= 16'd0; fetch_wait <= 1'b0;
        p1_v <= 1'b0; p1_x <= 12'd0; p1_odd <= 1'b0;
        p1b_v <= 1'b0; p1b_odd <= 1'b0; p1b_x <= 12'd0;
        p2_v <= 1'b0; p2_x <= 12'd0; p2_idx <= 8'd0;
        p3_v <= 1'b0; p3_x <= 12'd0; p3_idx <= 8'd0;
        out_x <= 12'd0; out_rgb <= 24'd0; out_valid <= 1'b0;
        for (k = 0; k < SPAN; k = k + 1) lbuf[k] <= 16'd0;
    end else begin
        rd_req    <= 1'b0;
        out_valid <= 1'b0;
        p1_v <= 1'b0;

        // three-stage pixel pipeline, one output pixel started per cycle
        p1b_v   <= p1_v;
        p1b_odd <= p1_odd;
        p1b_x   <= p1_x;
        p2_v <= p1b_v;
        if (p1b_v) begin
            p2_idx <= p1b_odd ? qa[15:8] : qa[7:0];
            p2_x   <= p1b_x;
        end
        p3_v   <= p2_v;
        p3_idx <= p2_idx;
        p3_x   <= p2_x;
        if (p3_v) begin
            out_rgb   <= pal[p3_idx];
            out_x     <= p3_x;
            out_valid <= 1'b1;
        end

        case (st)
        // cy == 0 is a frame start: the vertical accumulator reloads from the
        // viewport rather than carrying the last frame's value
        S_IDLE: if (cy != cy_d) begin
            cy_d <= cy;
            if (cy == 0) begin
                r0    <= src_y0 >>> 16;
                acc_y <= src_y0 + step_y;
            end else begin
                r0    <= acc_y >>> 16;
                acc_y <= acc_y + step_y;
            end
            // only the visible lines are drawn; the accumulator still advances
            // so the viewport stays in step with the raster
            if (cy < OUT_H) st <= S_SETUP;
        end

        S_SETUP: begin
            k0     <= (src_x0 >>> 17);            // entry of the first column
            base_a <= level_base + (r0 * level_w) + {1'b0, (src_x0 >>> 17), 1'b0};
            fetch_j <= 32'd0;
            fetch_wait <= 1'b0;
            st     <= S_FETCH;
        end

        // one read outstanding at a time: the address must not move while a
        // read is in flight, or the data that comes back belongs to a later
        // entry than the one it is stored at
        S_FETCH: begin
            if (!fetch_wait) begin
                rd_addr    <= base_a + {fetch_j[22:0], 1'b0};
                rd_req     <= 1'b1;
                fetch_wait <= 1'b1;
            end else if (rd_valid) begin
                lbuf[fetch_j[AIDX-1:0]] <= rd_data;
                fetch_wait <= 1'b0;
                if (fetch_j == SPAN - 1) begin
                    emit_x <= 16'd0;
                    acc_x  <= src_x0;
                    st     <= S_EMIT;
                end else fetch_j <= fetch_j + 32'd1;
            end
        end

        S_EMIT: begin
            // the read port runs one pixel ahead of the latch below
            rd_idx <= (entry_now - k0);
            acc_x  <= acc_x + step_x;

            p1_v   <= 1'b1;
            p1_x   <= {1'b0, emit_x[10:0]};
            p1_odd <= byte_now;

            emit_x <= emit_x + 16'd1;
            if (emit_x == OUT_W - 1) st <= S_DONE;
        end

        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
