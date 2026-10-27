// Testbench for the tiled fetch path end to end.
//
// The renderer is built with TILED=1, so its fetch engine asks maps_tile_fetch
// for each window instead of computing a linear address; the sequencer splits the
// window into per-tile chunks, asks maps_tiles where the tile is, and reads the
// chunk from a pool model.  A level of one tile is made resident first, so the
// only thing being tested is the path itself.
//
// What has to be true: every output line emits OUT_W pixels, and each pixel is
// the index the level actually holds at that source position.  A pixel that
// comes out of the wrong part of the pool, or a line that never completes,
// fails here.  The level is filled with a pattern that depends on both the row
// and the column so that either being wrong is visible.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_render_tiled;

localparam int OUT_W  = 64;
localparam int OUT_H  = 48;
localparam int SPAN   = OUT_W + 4;   // a whole line at step 1.0, plus slack
localparam int TSIZE  = 256;
localparam int TENT   = 128;
localparam int TBITS  = 16;
localparam int SLOTS  = 8;
localparam [24:0] POOL = 25'h0010_0000;

reg clk = 1'b0;
always #6.734 clk = ~clk;
reg resetn = 1'b0;

reg signed [31:0] src_x0, src_y0;
reg  [31:0] step_x, step_y;
reg         bilinear;
reg  [24:0] level_base;
reg  [15:0] level_w, level_h;
reg  [10:0] cx, cy;

wire        rd_start;
wire [24:0] rd_addr;
wire [15:0] rd_count;
reg  [15:0] rd_data;
reg         rd_valid;
wire [11:0] out_x;
wire [23:0] out_rgb;
wire [7:0]  out_idx;
wire        out_valid;
wire [15:0] fetch_count;

reg pal_we = 0; reg [7:0] pal_idx = 0; reg [23:0] pal_data = 0;

// tile mode's own ports
wire        seq_start;
wire [13:0] seq_entry;
wire [11:0] seq_row;
wire [15:0] seq_span;
wire        seq_we;
wire [$clog2(SPAN)-1:0] seq_widx;
wire [15:0] seq_wdata;
wire        seq_done, seq_miss;
wire [15:0] tile_misses;
wire [15:0] t_hits, t_misses;
reg        fill_valid = 1'b0;
reg [14:0] fill_tx = 15'd0, fill_ty = 15'd0;
wire        lk_valid;
wire [14:0] lk_tx, lk_ty;
wire        lk_hit;
wire [24:0] lk_addr;

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(SPAN), .TILED(1'b1)) dut (
    .clk(clk), .resetn(resetn),
    .src_x0(src_x0), .src_y0(src_y0), .step_x(step_x), .step_y(step_y),
    .bilinear(bilinear),
    .level_base(level_base), .level_w(level_w), .level_h(level_h),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(cy),
    .fetch_count(fetch_count),
    .out_x(out_x), .out_rgb(out_rgb), .out_idx(out_idx), .out_valid(out_valid),
    .tile_level(2'd0),
    .seq_start(seq_start), .seq_entry(seq_entry),
    .seq_row(seq_row), .seq_span(seq_span),
    .seq_we(seq_we), .seq_widx(seq_widx), .seq_wdata(seq_wdata),
    .seq_done(seq_done), .seq_miss(seq_miss),
    .tile_misses(tile_misses));

maps_tile_fetch #(.SPAN(SPAN), .TSIZE(TSIZE), .TENT(TENT), .TW(8)) u_seq (
    .clk(clk), .resetn(resetn),
    .start(seq_start), .level(2'd0), .row(seq_row), .entry0(seq_entry),
    .span(seq_span),
    .busy(), .done(seq_done), .miss(seq_miss),
    .we(seq_we), .widx(seq_widx), .wdata(seq_wdata),
    .lk_valid(lk_valid), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid));

// the page table: everything resident, one slot per tile of this small level
maps_tiles #(.SLOTS(SLOTS), .TBITS(TBITS), .POOL_BASE(POOL)) u_tiles (
    .clk(clk), .resetn(resetn),
    .lk_valid(lk_valid), .lk_level(2'd0), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .fill_valid(fill_valid), .fill_level(2'd0),
    .fill_tx(fill_tx), .fill_ty(fill_ty),
    .fill_addr(),
    .hits(t_hits), .misses(t_misses), .idle());

// the pool: an entry is {row, entry index}, so a wrong row, a wrong entry and the
// wrong half of the right entry are three different numbers, and the tile is the
// only one there is
reg  [15:0] rd_left = 16'd0;
reg  [24:0] rd_at = 25'd0;
reg         rd_on = 1'b0;
integer     off_i, row_i, ent_i;
always @(posedge clk) begin
    rd_valid <= 1'b0;
    if (!resetn) rd_on <= 1'b0;
    else if (rd_start) begin
        rd_left <= rd_count; rd_at <= rd_addr; rd_on <= 1'b1;
    end else if (rd_on) begin
        off_i = rd_at - POOL;
        row_i = off_i[15:8];
        ent_i = off_i[7:1];
        // entry = {row, column index}: the low byte is the entry's own index and
        // the high byte its row, so a wrong row, a wrong entry and the wrong half
        // of a right entry are all different values
        rd_data  <= {row_i[7:0], ent_i[7:0]};
        rd_valid <= 1'b1;
        rd_at    <= rd_at + 25'd2;
        rd_left  <= rd_left - 16'd1;
        if (rd_left == 16'd1) rd_on <= 1'b0;
    end
end

integer errors = 0;
integer bad = 0;
reg [7:0] row_b;
reg [7:0] exp;
integer seen = 0;
integer n_start = 0, n_lk = 0, n_hit = 0, n_we = 0, n_done = 0;
always @(posedge clk) begin
    if (seq_start) n_start = n_start + 1;
    if (lk_valid)  n_lk    = n_lk + 1;
    if (lk_hit)    n_hit   = n_hit + 1;
    if (seq_we)    n_we    = n_we + 1;
    if (seq_done)  n_done  = n_done + 1;
end

task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

// make the single tile of this level resident
task automatic fill_tile;
begin
    // held high across a whole cycle, and moved with nonblocking assignments:
    // a blocking clear in the edge's own time step races the design's sample of
    // it, and the fill silently does not happen
    fill_tx = 15'd0; fill_ty = 15'd0;
    @(posedge clk);
    fill_valid <= 1'b1;
    @(posedge clk);
    fill_valid <= 1'b0;
    repeat (2) @(posedge clk);
end
endtask

integer t, y, p;

initial begin
    // the geometry is set before reset is released: a renderer that comes out of
    // reset with a zero-height level prefetches the row below its own bottom,
    // clamps to -1 and asks for a tile that does not exist.  That is a real hole
    // in the renderer's clamping, and it is not what this test is measuring, so
    // the test starts the way the video stage would -- configured, then running
    level_base = 25'd0; level_w = TSIZE; level_h = TSIZE;
    cx = 11'd0; cy = 11'h3FF;      // parked off the end while the pool loads
    src_x0 = 32'sd0; src_y0 = 32'sd0;
    step_x = 32'd65536; step_y = 32'd65536;
    bilinear = 1'b0;

    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // the tile first: the renderer starts asking for rows as soon as reset is
    // released and does not retry a missed one, so a pool that is empty while
    // the palette loads would be a miss in the first line of the test
    fill_tile;

    for (t = 0; t < 256; t = t + 1) begin
        pal_we = 1; pal_idx = t[7:0];
        pal_data = {t[7:0], t[7:0], t[7:0]};
        @(posedge clk);
        pal_we = 0;
        @(posedge clk);
    end

    // three lines, each of which must emit OUT_W pixels
    for (y = 0; y < 3; y = y + 1) begin
        cy = y[9:0];
        row_b = y[7:0];
        seen = 0;
        for (p = 0; p < 400; p = p + 1) begin
            cx = p[10:0];
            @(posedge clk);
            if (out_valid) begin
                seen = seen + 1;
                // the pool's byte at (row, col): an entry is two pixels, its low
                // byte the entry index and its high byte the row.  The expected
                // value comes from `out_x`, which travels with the pixel, not from
                // the loop's column, which the pipeline has already run ahead of.
                exp = (out_x[0] == 1'b0) ? {1'b0, out_x[10:1]} : row_b;
                if (out_idx !== exp) begin
                    if (bad == 0)
                        $display("  line %0d x %0d: index %02h, level holds %02h",
                                 y, out_x, out_idx, exp);
                    bad = bad + 1;
                end
            end
        end
        want(seen == OUT_W, "the line emitted OUT_W pixels");
    end

    $display("  starts %0d  lookups %0d  hits %0d  writes %0d  dones %0d  misses %0d  table h/m %0d/%0d",
             n_start, n_lk, n_hit, n_we, n_done, tile_misses, t_hits, t_misses);
    $display("  pixel mismatches %0d", bad);
    want(tile_misses == 16'd0, "no tile was missed with the level resident");
    want(fetch_count >= 16'd3, "the fetch counted its rows");
    want(bad == 0, "every pixel is the index the level holds there");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (a tiled build emits every line's pixels)");
    $finish;
end

initial begin
    #(500e3);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
