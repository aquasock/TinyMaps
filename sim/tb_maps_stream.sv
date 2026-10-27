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
localparam int TSIZE = 128;                 // pixels across a tile, as the top builds it
localparam int TW    = 7;                   // log2 of it
localparam int TENT  = TSIZE / 2;           // 16-bit entries across a tile row
localparam int TBITS = 16;                  // log2 of a tile's bytes
localparam int SLOTS = 64;                  // the top's pool: a window has to fit
localparam [24:0] POOL = 25'h0010_0000;
localparam [1:0]  LVL  = 2'd1;              // the level under test
localparam int    LVL_W = 768, LVL_H = 768; // three tiles by three
// The level below is half the size, as the pack's levels are: a request for a
// tile outside a level's own grid cannot be answered by anything, so the bench
// counts them.
localparam int    LVL_GRID_X = (LVL_W + TSIZE - 1) / TSIZE;
localparam int    LVL_GRID_Y = (LVL_H + TSIZE - 1) / TSIZE;
localparam int    CRS_GRID_X = (LVL_W / 2 + TSIZE - 1) / TSIZE;
localparam int    CRS_GRID_Y = (LVL_H / 2 + TSIZE - 1) / TSIZE;
localparam int    TILE_RETRY_TB = 200;      // the epoch, short enough to watch

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

reg [7:0] pool [0:SLOTS*TSIZE*TSIZE-1];

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
wire [1:0]  seq_level;
wire [2:0]  dbg_state;
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

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(SPAN),
                 .TILE_RETRY(TILE_RETRY_TB)) u_render (
    .clk(clk), .resetn(resetn),
    .src_x0(src_x0), .src_y0(src_y0), .step_x(step_x), .step_y(step_y),
    .bilinear(1'b0),
    .level_base(25'd0), .level_w(LVL_W[15:0]), .level_h(LVL_H[15:0]),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(cy),
    .fetch_count(), .dbg_state(dbg_state),
    .out_x(out_x), .out_rgb(out_rgb), .out_idx(out_idx), .out_valid(out_valid),
    .stream(1'b1), .tile_level(LVL),
    .seq_level(seq_level),
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

maps_tile_fetch #(.SPAN(SPAN), .TSIZE(TSIZE), .TENT(TENT), .TW(TW)) u_seq (
    .clk(clk), .resetn(resetn),
    .start(seq_start), .level(seq_level), .row(seq_row), .entry0(seq_entry),
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

maps_tiles #(.SLOTS(SLOTS), .TBYTES(TSIZE * TSIZE), .TBITS(14), .POOL_BASE(POOL)) u_tiles (
    .clk(clk), .resetn(resetn),
    .lk_valid(lk_valid), .lk_level(seq_level), .lk_tx(lk_tx), .lk_ty(lk_ty),
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
integer    oob = 0;                     // requests for tiles outside the level
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
                // a tile past its own level's grid is a request nothing can answer
                if (fbuf[4][1:0] == LVL
                        ? ({fbuf[6][6:0], fbuf[5]} >= LVL_GRID_X ||
                           {fbuf[8][6:0], fbuf[7]} >= LVL_GRID_Y)
                        : ({fbuf[6][6:0], fbuf[5]} >= CRS_GRID_X ||
                           {fbuf[8][6:0], fbuf[7]} >= CRS_GRID_Y)) begin
                    oob = oob + 1;
                    $display("  request outside the grid: L%0d tx %0d ty %0d",
                             fbuf[4][1:0], {fbuf[6][6:0], fbuf[5]},
                             {fbuf[8][6:0], fbuf[7]});
                end
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
    for (di = 0; di < TSIZE * TSIZE; di = di + 1)
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
integer bad_fine = 0, bad_coarse = 0;
integer y;
integer scol, srow, ccol, crow;
integer dbg = 0;
reg [7:0] exp_f, exp_c;
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
    bad_fine = 0; bad_coarse = 0;
    for (t = 0; t < clocks; t = t + 1) begin
        cx = t[10:0];
        @(posedge clk);
        #1;
        if (out_valid) begin
            seen = seen + 1;
            // A line is legitimate in two forms and no others: drawn from the
            // view's own level, or drawn from the level below with each of its
            // pixels covering two by two of these.  Anything else is a wrong
            // slot, a wrong offset or a mixed line.
            scol = (src_x0 >>> 16) + out_x;
            srow = (src_y0 >>> 16) + row;
            exp_f = tile_byte(LVL, scol[14:TW], srow[14:TW],
                              ((srow[TW-1:0]) * TSIZE) + scol[TW-1:0]);
            ccol = scol >> 1;
            crow = srow >> 1;
            exp_c = tile_byte(LVL + 2'd1, ccol[14:TW], crow[14:TW],
                              ((crow[TW-1:0]) * TSIZE) + ccol[TW-1:0]);
            if (out_idx !== exp_f)   bad_fine   = bad_fine + 1;
            if (out_idx !== exp_c)   bad_coarse = bad_coarse + 1;
            if (dbg && out_x < 6)
                $display("  [tb] x %0d idx %02h fine %02h coarse %02h (scol %0d srow %0d)",
                         out_x, out_idx, exp_f, exp_c, scol, srow);
            if (out_idx !== exp_f && out_idx !== exp_c && (bad_fine + bad_coarse) == 1)
                $display("  row %0d x %0d: index %02h, want %02h or %02h",
                         row, out_x, out_idx, exp_f, exp_c);
        end
    end
end
endtask

// hand every queued request to the host and let it answer
integer k, delivered, seen_col;
// `coarse_only` answers just the requests from the level below, which is how the
// fallback test keeps the fine tiles away
integer coarse_only = 0;
task automatic serve_all;
begin
    delivered = 0;
    for (k = 0; k < req_n; k = k + 1) begin
        if (!coarse_only || q_level[k] != LVL) begin
            deliver(q_level[k], q_tx[k], q_ty[k]);
            delivered = delivered + 1;
        end
    end
    req_n = 0;
end
endtask

// Keep drawing the line and answering what it asks for until it comes out
// whole.  One fetch stops at the first tile it does not have, so a line that
// spans three new tiles takes three answers -- which is what the board will do,
// and the point is that it converges on the level's own pixels.
// Converge on a clean line: whole, exact, and with nothing left outstanding.  A
// line only settles once the tiles it asked for while drawing the previous one
// have been answered, so "no requests left" is part of the condition -- without
// it the loop stops on a good line and the next one asks again.
integer att, settled;
task automatic settle_line(input integer row, input bit want_fine);
begin
    settled = 0;
    for (att = 0; att < 12 && !settled; att = att + 1) begin
        run_line(row, 900);
        if (seen == OUT_W && req_n == 0 &&
            (want_fine ? (bad_fine == 0) : (bad_fine == 0 || bad_coarse == 0)))
            settled = 1;
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

    for (n = 0; n < SLOTS*TSIZE*TSIZE; n = n + 1) pool[n] = 8'h00;

    // palette: identity, so a pixel's index is its own colour and this bench can
    // judge what comes out
    for (n = 0; n < 256; n = n + 1) begin
        pal_we = 1; pal_idx = n[7:0]; pal_data = {n[7:0], n[7:0], n[7:0]};
        @(posedge clk);
        pal_we = 0;
        @(posedge clk);
    end

    // 1. an empty pool: the line cannot draw, and the miss becomes a request for
    //    the tile its first pixel lives in
    $display("--- test 1: an empty pool, a line that misses");
    miss_before = tile_misses;
    run_line(0, 600);
    want(tile_misses > miss_before, "the line missed a tile it did not have");
    want(seen == 0, "nothing was drawn with an empty pool");
    repeat (200) @(posedge clk);
    want(req_n > 0, "the miss reached the link as a request");
    want(q_level[0] === LVL && q_tx[0] === 15'd0 && q_ty[0] === 15'd0,
         "the first request is for the view's own level, at its first tile");
    $display("  %0d request(s) after one line", req_n);

    // 2. the host answers, and the picture converges on the view's own level
    $display("--- test 2: the host answers, the line sharpens");
    serve_all;
    settle_line(0, 1'b1);
    want(settled == 1, "the line draws once its tiles have arrived");
    want(seen == OUT_W, "the line emitted its pixels once its tiles were in");
    for (att = 0; att < 6 && bad_fine != 0; att = att + 1) begin
        repeat (TILE_RETRY_TB + 20) @(posedge clk);
        run_line(0, 900);
        serve_all;
    end
    want(bad_fine == 0, "every pixel is the view's own level once it is resident");
    miss_before = tile_misses;
    run_line(0, 700);
    want(seen == OUT_W && bad_fine == 0, "the same line draws again, sharp");
    want(tile_misses == miss_before, "no tile was missed with the tiles in");

    // 3. the fallback: a view whose fine tiles were never sent, but whose coarse
    //    ones were.  The line must draw, blocky and exact, from the level below
    //    rather than stalling or showing a hole.
    $display("--- test 3: the coarse fallback");
    @(negedge clk);
    src_x0 = 32'sd384 * 32'sd65536;         // a tile along, inside the level
    miss_before = tile_misses;
    run_line(0, 700);
    want(tile_misses > miss_before, "the new view missed its fine tiles");
    repeat (200) @(posedge clk);
    // answer only the coarse requests
    // keep the fine tiles away for the whole settle, or the picture sharpens and
    // there is no fallback left to look at
    coarse_only = 1;
    serve_all;
    settle_line(0, 1'b0);
    coarse_only = 0;
    want(settled == 1, "the line draws from the level below");
    want(seen == OUT_W, "the fallback line emitted its pixels");
    want(bad_coarse == 0, "every pixel is the coarse level's, two by two");
    want(bad_fine != 0, "and it is coarser than the view's own level");
    $display("  fallback line: %0d coarse mismatches, %0d fine", bad_coarse, bad_fine);

    // 4. send the fine tiles for that view: the picture sharpens
    $display("--- test 4: the fine tiles arrive late");
    for (att = 0; att < 8 && bad_fine != 0; att = att + 1) begin
        run_line(0, 700);
        serve_all;
        repeat (TILE_RETRY_TB + 20) @(posedge clk);
    end
    want(bad_fine == 0, "the picture sharpened once the fine tiles arrived");
    settle_line(0, 1'b1);              // answer whatever the sharpening still wants
    want(bad_fine == 0, "the settled line is sharp");

    // 6. a view against the level's right edge: the fetch window is wider than
    //    the level from here, so half of it is outside.  The line must still be
    //    exact, and nothing may be asked for that the level does not have.
    $display("--- test 6: a view against the right edge");
    @(negedge clk);
    src_x0 = 32'sd704 * 32'sd65536;        // 64 pixels of level to the right
    oob = 0;
    settle_line(0, 1'b1);
    want(settled == 1, "the line at the right edge draws");
    want(bad_fine == 0, "every pixel is the level's own byte at the edge");
    want(oob == 0, "no tile outside the grid was asked for");
    $display("  at the edge: %0d pixels, %0d outside the grid", seen, oob);

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
