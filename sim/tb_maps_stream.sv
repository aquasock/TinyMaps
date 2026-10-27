// Testbench for the streaming loop end to end.
//
// Everything that streaming is made of, wired the way the top will wire it: the
// renderer in tile mode, the chunk sequencer, the real page table, and the
// request queue on the link.  What is modelled is the part that is not in this
// repository yet -- the host, which answers a request with a tile.
//
// The loop this proves is the whole point of the design:
//
//   a line needs a tile that is not in the pool -> the fetch stops and says
//   which tile -> the request goes out on the link -> the host sends the tile ->
//   the loader puts it in the slot the table named and commits it -> the same
//   line draws, pixel for pixel, from the tile that just arrived.
//
// The checks are: the request names the tile that actually missed, nothing is
// drawn from a tile that never arrived, and every pixel of a line that has its
// tiles is the level's own byte at that source position.  The pool model is a
// byte array, so a pixel coming out of the wrong slot or the wrong offset is a
// wrong number rather than a plausible one.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_stream;

localparam int OUT_W = 64;
localparam int OUT_H = 48;
localparam int SPAN  = OUT_W + 4;
localparam int TSIZE = 256;                 // pixels across a tile
localparam int TBITS = 16;                  // log2 of a tile's bytes
localparam int SLOTS = 8;
localparam [24:0] POOL = 25'h0010_0000;
localparam [1:0]  LVL  = 2'd1;              // the level under test
localparam int    LVL_W = 768, LVL_H = 768; // three tiles by three

reg clk = 1'b0;
always #6.734 clk = ~clk;
reg resetn = 1'b0;

reg signed [31:0] src_x0 = 32'sd0, src_y0 = 32'sd0;
reg  [31:0] step_x = 32'd65536, step_y = 32'd65536;
reg  [10:0] cx = 11'd0;
reg  [9:0]  cy = 10'h3FF;

// ------------------------------------------------------------------ pool -----
// The level's own bytes, as a function of the level coordinate: a tile is
// addressed by its coordinates and the offset inside it, so the test can say
// what any pixel must be without keeping a copy of the level.
function automatic [7:0] tile_byte(input [1:0] lvl, input [14:0] tx,
                                   input [14:0] ty, input integer off);
    tile_byte = ((tx * 8'd41) + (ty * 8'd17) + (lvl * 8'd7) + (off * 8'd13)) & 8'hFF;
endfunction

reg [7:0] pool [0:SLOTS*65536-1];

// ------------------------------------------------------------------ DUTs -----
wire        rd_start;
wire [24:0] rd_addr;
wire [15:0] rd_count;
reg  [15:0] rd_data;
reg         rd_valid;
wire [11:0] out_x;
wire [23:0] out_rgb;
wire [7:0]  out_idx;
wire        out_valid;
wire        seq_start;
wire [13:0] seq_entry;
wire [11:0] seq_row;
wire [15:0] seq_span;
wire        seq_we;
wire [7:0]  seq_widx;
wire [15:0] seq_wdata;
wire        seq_done, seq_miss;
wire [15:0] tile_misses;
wire        seq_busy;

reg pal_we = 1'b0;
reg [7:0] pal_idx = 8'd0;
reg [23:0] pal_data = 24'd0;

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(SPAN), .TILED(1'b1),
                 .TILE_RETRY(64)) u_render (
    .clk(clk), .resetn(resetn),
    .src_x0(src_x0), .src_y0(src_y0), .step_x(step_x), .step_y(step_y),
    .bilinear(1'b0),
    .level_base(25'd0), .level_w(LVL_W[15:0]), .level_h(LVL_H[15:0]),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(cy),
    .fetch_count(), .dbg_state(),
    .out_x(out_x), .out_rgb(out_rgb), .out_idx(out_idx), .out_valid(out_valid),
    .tile_level(LVL),
    .seq_start(seq_start), .seq_entry(seq_entry),
    .seq_row(seq_row), .seq_span(seq_span),
    .seq_we(seq_we), .seq_widx(seq_widx), .seq_wdata(seq_wdata),
    .seq_done(seq_done), .seq_miss(seq_miss), .tile_misses(tile_misses));

wire        lk_valid;
wire [14:0] lk_tx, lk_ty;
wire [1:0]  miss_level;
wire [14:0] miss_tx, miss_ty;
wire        lk_hit;
wire [24:0] lk_addr;

maps_tile_fetch #(.SPAN(SPAN), .TSIZE(TSIZE), .TENT(128), .TW(8)) u_seq (
    .clk(clk), .resetn(resetn),
    .start(seq_start), .level(LVL), .row(seq_row), .entry0(seq_entry),
    .span(seq_span),
    .busy(seq_busy), .done(seq_done), .miss(seq_miss),
    .miss_level(miss_level), .miss_tx(miss_tx), .miss_ty(miss_ty),
    .we(seq_we), .widx(seq_widx), .wdata(seq_wdata),
    .lk_valid(lk_valid), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid));

// the loader's side of the table, modelled: present coordinates, take the
// address, and commit when the tile is whole
reg         dl_commit = 1'b0;
reg  [1:0]  fill_level = 2'd0;
reg  [14:0] fill_tx = 15'd0, fill_ty = 15'd0;
wire [24:0] fill_addr;

maps_tiles #(.SLOTS(SLOTS), .TBITS(TBITS), .POOL_BASE(POOL)) u_tiles (
    .clk(clk), .resetn(resetn),
    .lk_valid(lk_valid), .lk_level(LVL), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .fill_commit(dl_commit), .fill_level(fill_level),
    .fill_tx(fill_tx), .fill_ty(fill_ty), .fill_addr(fill_addr),
    .hits(), .misses(), .idle());

// ------------------------------------------------------------------ link -----
wire        tx_start;
wire [7:0]  tx_data;
wire [7:0]  req_count;
wire        req_overflow;

integer gap = 0;
wire tx_ready = (gap == 0);
wire tx_ack   = tx_start && tx_ready;

maps_tile_req #(.DEPTH(8)) u_req (
    .clk(clk), .resetn(resetn),
    .miss(seq_miss), .miss_level(miss_level),
    .miss_tx(miss_tx), .miss_ty(miss_ty),
    .tx_grant(1'b1), .tx_ready(tx_ready), .tx_ack(tx_ack),
    .tx_start(tx_start), .tx_data(tx_data), .req_hold(),
    .count(req_count), .overflow(req_overflow));

// The request frames, decoded.  A frame is AA 00 06 1C L TXL TXH TYL TYH.
integer    req_n = 0;
reg [1:0]  q_level [0:63];
reg [14:0] q_tx    [0:63];
reg [14:0] q_ty    [0:63];
integer    fidx = 0;
reg [7:0]  fbuf [0:8];

always @(posedge clk) begin
    if (!resetn) begin
        gap <= 0;
    end else if (tx_ack) begin
        gap <= 4;
        if (fidx == 0 && tx_data !== 8'hAA) begin
            // hunting: a frame that was cut short cannot shift the next one
        end else begin
        fbuf[fidx] = tx_data;
        fidx = fidx + 1;
        if (fidx == 9) begin
            fidx = 0;
            if (fbuf[0] !== 8'hAA || fbuf[1] !== 8'h00 || fbuf[2] !== 8'd6 ||
                fbuf[3] !== 8'h1C) begin
                $display("  bad request frame: %02h %02h %02h %02h",
                         fbuf[0], fbuf[1], fbuf[2], fbuf[3]);
            end
            if (req_n < 64) begin
                q_level[req_n] = fbuf[4][1:0];
                q_tx[req_n]    = {fbuf[6][6:0], fbuf[5]};
                q_ty[req_n]    = {fbuf[8][6:0], fbuf[7]};
            end
            req_n = req_n + 1;
        end
        end
    end else if (gap > 0) begin
        gap <= gap - 1;
    end
end

// ------------------------------------------------------------ pool and read ---
// The sequencer's view of the pool: an entry at a byte address is two bytes.
reg  [15:0] rd_left = 16'd0;
reg  [24:0] rd_at = 25'd0;
reg         rd_on = 1'b0;
integer     pi;
always @(posedge clk) begin
    rd_valid <= 1'b0;
    if (!resetn) rd_on <= 1'b0;
    else if (rd_start) begin
        rd_left <= rd_count; rd_at <= rd_addr; rd_on <= 1'b1;
    end else if (rd_on) begin
        pi = rd_at - POOL;
        rd_data  <= {pool[pi + 1], pool[pi]};
        rd_valid <= 1'b1;
        rd_at    <= rd_at + 25'd2;
        rd_left  <= rd_left - 16'd1;
        if (rd_left == 16'd1) rd_on <= 1'b0;
    end
end

integer errors = 0;
task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

// the host answering a request: the tile's bytes go where the table says, and
// the table is told the tile is whole only once they are all in
integer di;
task automatic deliver(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
    integer base;
begin
    @(negedge clk);
    fill_level = lvl; fill_tx = tx; fill_ty = ty;
    @(posedge clk);
    #1;
    base = fill_addr - POOL;
    for (di = 0; di < 65536; di = di + 1)
        pool[base + di] = tile_byte(lvl, tx, ty, di);
    @(negedge clk);
    dl_commit = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dl_commit = 1'b0;
    repeat (2) @(posedge clk);
end
endtask

// run one output line and count its pixels; returns through `seen`
integer seen = 0;
integer bad  = 0;
integer y;
integer scol, srow;
reg [7:0] exp;
task automatic run_line(input integer row, input integer clocks);
    integer t;
begin
    // off the bottom first: the line engine starts a line when the row pointer
    // moves, so running the same row twice would run nothing the second time
    @(negedge clk);
    cy = 10'h3FF;
    @(negedge clk);
    cy = row[9:0];
    seen = 0;
    bad  = 0;
    for (t = 0; t < clocks; t = t + 1) begin
        cx = t[10:0];
        @(posedge clk);
        #1;
        if (out_valid) begin
            seen = seen + 1;
            // where this pixel comes from: the viewport's origin plus the output
            // column, at step 1.0
            scol = (src_x0 >>> 16) + out_x;
            srow = (src_y0 >>> 16) + row;
            exp  = tile_byte(LVL, scol[14:8], srow[14:8],
                             ((srow[7:0]) * 256) + scol[7:0]);
            if (out_idx !== exp) begin
                if (bad == 0)
                    $display("  row %0d x %0d: index %02h, want %02h",
                             row, out_x, out_idx, exp);
                bad = bad + 1;
            end
        end
    end
end
endtask

// hand every queued request to the host and let it answer
integer k, delivered, seen_col;
task automatic serve_all;
begin
    delivered = 0;
    for (k = 0; k < req_n; k = k + 1) begin
        deliver(q_level[k], q_tx[k], q_ty[k]);
        delivered = delivered + 1;
    end
    req_n = 0;
end
endtask

// Keep drawing the line and answering what it asks for until it comes out
// whole.  One fetch stops at the first tile it does not have, so a line that
// spans three new tiles takes three answers -- which is what the board will do,
// and the point is that it converges on the level's own pixels.
integer att, settled;
task automatic settle_line(input integer row);
begin
    settled = 0;
    for (att = 0; att < 8 && !settled; att = att + 1) begin
        run_line(row, 700);
        if (seen == OUT_W && bad == 0) settled = 1;
        else serve_all;
    end
    serve_all;
end
endtask

integer n, miss_before;
initial begin
    repeat (4) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    for (n = 0; n < SLOTS*65536; n = n + 1) pool[n] = 8'h00;

    // palette: identity, so a pixel's index is its own colour and this bench can
    // judge what comes out
    for (n = 0; n < 256; n = n + 1) begin
        pal_we = 1; pal_idx = n[7:0]; pal_data = {n[7:0], n[7:0], n[7:0]};
        @(posedge clk);
        pal_we = 0;
        @(posedge clk);
    end

    // 1. an empty pool: the line misses, and the request names the tile that
    //    the line's first pixel lives in
    $display("--- test 1: an empty pool, a line that misses");
    miss_before = tile_misses;
    run_line(0, 600);
    want(tile_misses > miss_before, "the line missed a tile it did not have");
    want(bad == 0, "nothing was drawn from a tile that never arrived");
    repeat (200) @(posedge clk);
    want(req_n > 0, "the miss reached the link as a request");
    want(q_level[0] === LVL && q_tx[0] === 15'd0 && q_ty[0] === 15'd0,
         "the first request is the tile the line's first pixel is in");
    $display("  %0d request(s) after one line", req_n);

    // 2. the host answers; the same line now draws exactly
    $display("--- test 2: the host answers, the line draws");
    serve_all;
    settle_line(0);
    want(settled == 1, "the line draws once its tiles have arrived");
    want(seen == OUT_W, "the line emitted its pixels once its tiles were in");
    want(bad == 0, "every pixel is the level's own byte");
    miss_before = tile_misses;
    run_line(0, 700);
    want(seen == OUT_W, "the same line draws again");
    want(bad == 0, "and is still exact");
    want(tile_misses == miss_before, "no tile was missed with the tiles in");
    $display("  %0d pixels, %0d attempt(s)", seen, att);

    // 3. a row in the next tile down: the tile grid is vertical as well as
    //    horizontal, and a row that crosses it asks for a different tile
    $display("--- test 3: a view starting in the tile below");
    serve_all;
    @(negedge clk);
    src_y0 = 32'sd256 * 32'sd65536;        // source row 256 is in the next tile
    miss_before = tile_misses;
    run_line(0, 700);
    want(tile_misses > miss_before, "the lower view missed its tiles");
    want(bad == 0, "nothing was drawn from a tile that never arrived");
    repeat (200) @(posedge clk);
    want(req_n > 0, "the lower view asked for its tiles");
    want(q_ty[0] === 15'd1, "the request names the tile one row down");
    serve_all;
    settle_line(0);
    want(settled == 1, "the lower view draws once its tiles have arrived");
    @(negedge clk);
    src_y0 = 32'sd0;
    settle_line(0);
    want(settled == 1, "and the view back at the top still draws");

    // 4. pan two tiles to the right: the tiles the line needs now are not in the
    //    pool, so it misses, asks, and then draws
    $display("--- test 4: pan onto tiles that are not resident");
    @(negedge clk);
    src_x0 = 32'sd512 * 32'sd65536;         // 512 source pixels right
    serve_all;
    miss_before = tile_misses;
    run_line(0, 700);
    want(tile_misses > miss_before, "the panned line missed the tiles it needed");
    want(bad == 0, "nothing was drawn from a tile that never arrived");
    repeat (200) @(posedge clk);
    want(req_n > 0, "the panned line asked for its tiles");
    seen_col = 0;
    for (k = 0; k < req_n; k = k + 1) if (q_tx[k] >= 15'd1) seen_col = 1;
    want(seen_col == 1, "the requests are for the tiles the pan moved onto");
    settle_line(0);
    want(settled == 1, "the panned line draws once its tiles have arrived");
    want(bad == 0, "every pixel of the panned line is exact");
    miss_before = tile_misses;
    run_line(0, 700);
    want(seen == OUT_W && bad == 0, "and draws again without help");
    want(tile_misses == miss_before, "the panned line needed no new tiles");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (a miss becomes a request, an answer becomes a line)");
    $finish;
end

initial begin
    #(2000e6);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
