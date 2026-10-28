// Does the line engine keep up with the raster?
//
// This bench runs the renderer, the chunk sequencer and the real page table at the
// geometry the top builds -- 1280 output pixels, a 644-entry window, 128-pixel
// tiles -- and paces the row pointer like the video stage does: one new line every
// 1650 clocks.  It then counts how many lines emit their full width.
//
// The other testbenches advance one line at a time and wait as long as the design
// needs, which models a renderer with infinite time and cannot show this fault.
// Their pools also answer an entry every clock, and that is the difference the
// fault lived in: the real channel costs about two clocks an entry, and at one
// clock the old line engine kept up.  On the board the picture is stretched
// vertically, which is what a line engine that completes fewer lines than the
// raster offers looks like: the line store repeats the rows it has.
//
// The pool is pre-filled so that every fetch hits.  This measures time, not data.
//
// Verdict: the first lines are a cold start, because the row buffers begin empty,
// so what is judged is the steady state -- no short line and no blocking fetch
// from line 8 on.  Run with +trace for the per-fetch and per-line timings.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_line_budget;

localparam int OUT_W = 1280;
localparam int OUT_H = 48;
localparam int SPAN  = OUT_W / 2 + 4;      // entries, as the top passes it
// Tile size is a knob, not a claim: 128-pixel tiles fetch a line in ten chunks and
// 256 in five, and the sweep showed the chunk count barely moves the result -- the
// cost that matters is the entry rate, not the per-chunk overhead.  Build with
// -DTILE_PX=256 to compare, since a parameter cannot be a plusarg.
`ifndef TILE_PX
`define TILE_PX 128
`endif
localparam int TSIZE = `TILE_PX;
localparam int TW    = $clog2(TSIZE);
localparam int TENT  = TSIZE / 2;
localparam int SLOTS = 256;
localparam [24:0] POOL = 25'h0010_0000;
localparam [1:0]  LVL  = 2'd0;
localparam int    LVL_W = 1536, LVL_H = 1024;
localparam int    LINE_CLOCKS = 1650;      // what a 1280-pixel line has at 74.25 MHz
// A pool read is not instant.  Each chunk is its own request through the video
// channel and sdram_ctrl, so it pays the controller's latency before the first
// entry arrives -- row activation, arbitration with the video channel and the
// loader, and whatever a refresh costs.  The other benches answer on the next
// clock, which is a channel that behaves far better than the real one.
localparam int    READ_LATENCY = 12;
// ... and it does not deliver an entry every clock either.  `CHAN_CLOCKS` is how
// many clocks an entry costs once the burst is running: the handoff measures a
// 644-entry row at about 1340 clocks, which is the two-clock setting.  One clock
// is the optimistic case, where the SDRAM answers a 16-bit entry per cycle.
`ifndef CHAN_CLOCKS
`define CHAN_CLOCKS 2
`endif

reg clk = 1'b0;
always #6.734 clk = ~clk;
reg resetn = 1'b0;

reg signed [31:0] src_x0 = 32'sd0, src_y0 = 32'sd0;
reg  [31:0] step_x = 32'd65536, step_y = 32'd65536;
reg  [10:0] cx = 11'd0;
reg  [9:0]  cy = 10'h3FF;

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
wire [2:0]  dbg_state;
wire [13:0] seq_entry;
wire [11:0] seq_row;
wire [15:0] seq_span;
wire        seq_we;
wire [9:0]  seq_widx;                      // $clog2(SPAN)
wire [15:0] seq_wdata;
wire        seq_done, seq_miss;
wire [15:0] tile_misses;
wire [1:0]  seq_level;

reg pal_we = 1'b0;
reg [7:0] pal_idx = 8'd0;
reg [23:0] pal_data = 24'd0;

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(SPAN), .TILE_RETRY(64)) u_render (

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
    .stream(1'b1), .tile_level(LVL), .seq_level(seq_level), .dbg_fallback(),
    .seq_start(seq_start), .seq_entry(seq_entry),
    .seq_row(seq_row), .seq_span(seq_span),
    .seq_we(seq_we), .seq_widx(seq_widx), .seq_wdata(seq_wdata),
    .seq_done(seq_done), .seq_miss(seq_miss), .tile_misses(tile_misses));

wire        lk_valid, lk_hit;
wire [14:0] lk_tx, lk_ty;
wire [24:0] lk_addr;

maps_tile_fetch #(.SPAN(SPAN), .TSIZE(TSIZE), .TENT(TENT), .TW(TW)) u_seq (
    .clk(clk), .resetn(resetn),
    .start(seq_start), .level(seq_level), .row(seq_row), .entry0(seq_entry),
    .span(seq_span),
    .busy(), .done(seq_done), .miss(seq_miss),
    .miss_level(), .miss_tx(), .miss_ty(),
    .dbg_hit_level(), .dbg_hit_tx(), .dbg_hit_ty(), .dbg_hit_addr(),
    .we(seq_we), .widx(seq_widx), .wdata(seq_wdata),
    .lk_valid(lk_valid), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid));

reg        dl_commit = 1'b0;
reg  [1:0] fill_level = 2'd0;
reg  [14:0] fill_tx = 15'd0, fill_ty = 15'd0;
wire [24:0] fill_addr;

maps_tiles #(.SLOTS(SLOTS), .TBYTES(TSIZE * TSIZE), .TBITS(14),
             .POOL_BASE(POOL)) u_tiles (
    .clk(clk), .resetn(resetn),
    .lk_valid(lk_valid), .lk_level(seq_level), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .fill_commit(dl_commit), .fill_inval(1'b0), .fill_level(fill_level),
    .fill_tx(fill_tx), .fill_ty(fill_ty), .fill_addr(fill_addr),
    .hits(), .misses(), .idle());

// ------------------------------------------------------------------ pool -----
// content does not matter here, only that the reads complete
reg  [15:0] rd_left = 16'd0;
reg  [24:0] rd_at = 25'd0;
reg         rd_on = 1'b0;
reg  [15:0] rd_wait = 16'd0;
reg  [15:0] rd_skip = 16'd0;
integer     pi;
always @(posedge clk) begin
    rd_valid <= 1'b0;
    if (!resetn) rd_on <= 1'b0;
    else if (rd_start) begin
        rd_left <= rd_count; rd_at <= rd_addr; rd_on <= 1'b1;
        rd_wait <= READ_LATENCY[15:0];
    end else if (rd_on) begin
        // `CHAN_CLOCKS` clocks an entry: the handoff measures a 644-entry row at
        // about 1340 clocks through the video channel, which is two, and a model
        // that answers every clock is a channel twice as good as the real one.
        // The counter is what makes the sweep a measurement: an earlier version
        // only had a one-idle-cycle toggle, so every setting above two behaved
        // like two and the margin it reported was not the margin it had.
        if (rd_wait != 0) begin
            rd_wait <= rd_wait - 16'd1;
        end else if (rd_skip != 0) begin
            rd_skip <= rd_skip - 16'd1;
        end else begin
            rd_skip <= `CHAN_CLOCKS - 1;
            pi = (rd_at < POOL) ? 0 : (rd_at - POOL);
            rd_data  <= {pi[7:0], pi[15:8]};
            rd_valid <= 1'b1;
            rd_at    <= rd_at + 25'd2;
            rd_left  <= rd_left - 16'd1;
            if (rd_left == 16'd1) rd_on <= 1'b0;
        end
    end
end

// ------------------------------------------------------------- the making ---
integer errors = 0;
task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin $display("  %0s: failed", what); errors = errors + 1; end
end
endtask

integer di;
task automatic fill_tile(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
begin
    @(negedge clk);
    fill_level = lvl; fill_tx = tx; fill_ty = ty;
    @(posedge clk);
    @(negedge clk);
    dl_commit = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dl_commit = 1'b0;
end
endtask

// every tile the view can touch, fine and coarse, made resident
task automatic fill_view;
    integer t;
begin
    for (t = 0; t <= LVL_W / TSIZE; t = t + 1) begin
        fill_tile(LVL,         t[14:0], 15'd0);
        fill_tile(LVL,         t[14:0], 15'd8);
        fill_tile(LVL + 2'd1,  t[14:0], 15'd0);
        fill_tile(LVL + 2'd1,  t[14:0], 15'd4);
    end
end
endtask

// ------------------------------------------------------------------ test ----
integer y, t, n, drawn, partial, worst, cycles, first_bad;
integer line_px [0:OUT_H-1];
initial begin
    repeat (4) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    for (n = 0; n < 256; n = n + 1) begin
        pal_we = 1; pal_idx = n[7:0]; pal_data = {n[7:0], n[7:0], n[7:0]};
        @(posedge clk);
        pal_we = 0;
        @(posedge clk);
    end

    fill_view;
    $display("pool filled: %0d tiles made resident", (LVL_W / TSIZE + 1) * 4);

    // one line every LINE_CLOCKS, as the video stage offers them
    drawn = 0; partial = 0; worst = 0; first_bad = -1;
    for (y = 0; y < OUT_H; y = y + 1) begin
        @(negedge clk);
        cy = y[9:0];
        n = 0;
        cycles = 0;
        for (t = 0; t < LINE_CLOCKS; t = t + 1) begin
            cx = t[10:0];
            @(posedge clk);
            #1;
            if (out_valid) n = n + 1;
        end
        line_px[y] = n;
        if (n == OUT_W) drawn = drawn + 1;
        else begin
            partial = partial + 1;
            if (n > worst) worst = n;
            // The first lines are the cold start: the buffers begin empty, so line
            // 0 fetches its whole pair and the engine is a line or two behind
            // until the pipeline fills.  That happens once at power-up and after a
            // pan.  The fault this bench exists for was a picture that never
            // caught up, so the failure condition is a loss past warm-up.
            if ((y >= WARM) && (first_bad < 0)) first_bad = y;
        end
        $display("  line %0d: %0d of %0d pixels %0s", y, n, OUT_W,
                 (n == OUT_W) ? "complete" : "SHORT");
    end

    $display("  %0d of %0d lines complete in %0d clocks; %0d short, best short %0d",
             drawn, OUT_H, LINE_CLOCKS, partial, worst);
    $display("  blocking paths after warm-up: %0d (each one costs about three row fetches)",
             ss_bfetch);
    $display("  first short line from %0d on: %0s", WARM,
             (first_bad < 0) ? "none" : "one");
    $display("  tile misses: %0d", tile_misses);
    $display("  clocks by state: IDLE %0d PLAN %0d BFETCH %0d EMIT %0d DONE %0d ROWS %0d RADDR %0d HOLD %0d",
             st_clk[0], st_clk[1], st_clk[2], st_clk[3], st_clk[4], st_clk[5], st_clk[6], st_clk[7]);
    $display("  entered: IDLE %0d BFETCH %0d EMIT %0d (one EMIT per line drawn)",
             st_enter[0], st_enter[2], st_enter[3]);
    $display("  emits start %0d apart at best, %0d at worst (the raster offers 1650)",
             em_dmin, em_dmax);
    $display("  row fetch: %0d done, mean %0d clocks, min %0d, max %0d, issue gap %0d..%0d",
             f_n, (f_n == 0) ? 0 : f_sum / f_n, (f_n == 0) ? 0 : f_min, f_max,
             f_gap_min, f_gap_max);
    if ((first_bad >= 0) || (ss_bfetch != 0))
        $display("RESULT: FAIL (the line engine does not keep up with the raster)");
    else
        $display("RESULT: PASS (every line from %0d on completes inside its %0d clocks)",
                 WARM, LINE_CLOCKS);
    $finish;
end

// Where the line engine spends its clocks.  S_EMIT is the 1280 pixels and is
// unavoidable; S_BFETCH is the blocking path, and every clock spent there is a
// clock the next line loses.
integer st_clk [0:7];
integer st_enter [0:7];
reg [2:0] st_prev = 3'd0;
integer si;
// blocking paths once the pipeline has filled: this is the number that says the
// line engine has lost its place in the raster rather than started cold
localparam int WARM = 8;  // past the cold start: what follows is the steady state
integer ss_bfetch = 0;
initial for (si = 0; si < 8; si = si + 1) begin st_clk[si] = 0; st_enter[si] = 0; end
always @(posedge clk) begin
    st_clk[dbg_state] = st_clk[dbg_state] + 1;
    if (dbg_state != st_prev) begin
        st_enter[dbg_state] = st_enter[dbg_state] + 1;
        if ((dbg_state == 3'd2) && (cy >= WARM)) ss_bfetch = ss_bfetch + 1;
    end
    st_prev <= dbg_state;
end

// How long a row fetch actually takes, measured on the sequencer's own
// handshake, and how much of a line it overlaps.
integer f_t0 = 0, f_cyc = 0, f_n = 0, f_max = 0, f_min = 999999, f_sum = 0;
integer f_last_issue = 0, f_gap_min = 999999, f_gap_max = 0;
integer t_show = 0;
// when each line's emit starts, so drift against the 1650-clock raster is visible
reg [2:0] em_prev = 3'd0;
integer em_n = 0, em_last = 0, em_dmin = 999999, em_dmax = 0;
always @(posedge clk) begin
    if (dbg_state == 3'd3 && em_prev != 3'd3) begin
        em_n = em_n + 1;
        if (em_n > 1) begin
            if ((f_cyc - em_last) < em_dmin) em_dmin = f_cyc - em_last;
            if ((f_cyc - em_last) > em_dmax) em_dmax = f_cyc - em_last;
            if (em_n <= 48) $display("    emit %0d starts at %0d (+%0d since the last, phase %0d)",
                                    em_n, f_cyc, f_cyc - em_last, f_cyc % LINE_CLOCKS);
        end
        em_last = f_cyc;
    end
    em_prev <= dbg_state;
end
always @(posedge clk) begin
    f_cyc = f_cyc + 1;
    if (seq_start) begin
        f_t0 = f_cyc;
        if (f_last_issue != 0) begin
            if ((f_cyc - f_last_issue) < f_gap_min) f_gap_min = f_cyc - f_last_issue;
            if ((f_cyc - f_last_issue) > f_gap_max) f_gap_max = f_cyc - f_last_issue;
        end
        f_last_issue = f_cyc;
    end
    if (seq_done) begin
        f_n = f_n + 1;
        f_sum = f_sum + (f_cyc - f_t0);
        if ((f_cyc - f_t0) > f_max) f_max = f_cyc - f_t0;
        if ((f_cyc - f_t0) < f_min) f_min = f_cyc - f_t0;
        if (($test$plusargs("trace") != 0) && (t_show < 20)) begin
            t_show = t_show + 1;
            $display("    fetch %0d: issued %0d, done %0d, %0d clocks",
                     f_n, f_t0, f_cyc, f_cyc - f_t0);
        end
    end
end

initial begin
    #(200e6);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
