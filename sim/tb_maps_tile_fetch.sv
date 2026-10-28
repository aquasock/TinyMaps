// Testbench for maps_tile_fetch: one window of a source row, walked in chunks.
//
// The pool is modelled so that a value identifies *where it really came from*:
// an entry reads back as {tile_x ^ row_in_tile, tile_y ^ entry_in_tile}, using
// the slot-to-tile mapping the page table handed out at lookup time.  The
// expected value for each window entry is computed the same way from the level
// coordinate, so a chunk that starts at the right tile but the wrong row inside
// it, or that advances the window by the wrong amount, reads back as a number
// that says which of those is wrong instead of looking plausible.
//
// The page table is modelled as always-hit, because this testbench is about the
// sequence; a miss has its own case driven by a flag.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_tile_fetch;

localparam int SPAN  = 644;
localparam int TSIZE = 256;
localparam int TENT  = 128;
localparam int TW    = 8;
localparam int SLOTS = 64;                  // a small model pool
localparam int TBITS = 16;                  // 64 KiB, as the real pool is
localparam [24:0] POOL = 25'h0010_0000;

reg clk = 1'b0;
always #6.734 clk = ~clk;

reg resetn = 1'b0;
reg        start = 1'b0;
reg  [1:0] level = 2'd0;
reg [11:0] row = 12'd0;
reg [13:0] entry0 = 14'd0;
reg [15:0] span = SPAN[15:0];
wire       busy, done, miss;
wire [1:0] miss_level;
wire [14:0] miss_tx, miss_ty;
wire       we;
wire [$clog2(SPAN)-1:0] widx;
wire [15:0] wdata;

wire        lk_valid;
wire [14:0] lk_tx, lk_ty;
wire        lk_hit;
wire [24:0] lk_addr;

reg        rd_start;
reg  [24:0] rd_addr;
reg  [15:0] rd_count;
reg  [15:0] rd_data;
reg         rd_valid;

maps_tile_fetch #(.SPAN(SPAN), .TSIZE(TSIZE), .TENT(TENT), .TW(TW)) dut (
    .clk(clk), .resetn(resetn),
    .start(start), .level(level), .row(row), .entry0(entry0), .span(span),
    .busy(busy), .done(done), .miss(miss),
    .miss_level(miss_level), .miss_tx(miss_tx), .miss_ty(miss_ty),
    .we(we), .widx(widx), .wdata(wdata),
    .lk_valid(lk_valid), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .dbg_hit_level(), .dbg_hit_tx(), .dbg_hit_ty(), .dbg_hit_addr(),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid));

// ---------------------------------------------------------------- the table ---
// The model keeps the real table's latency: it registers the question, then
// registers the answer, so a hit is on the wire two cycles after `lk_valid` goes
// high.  A combinational model here would let a sequencer that samples a cycle
// early pass, which is how the first version of the sequencer passed this
// testbench while missing every tile in the renderer.
reg table_miss = 1'b0;
// or just one tile: a miss that reports its coordinates can only be checked if
// the test can say which tile missed, rather than every lookup failing
reg        miss_sel = 1'b0;
reg [14:0] miss_sel_tx = 15'd0, miss_sel_ty = 15'd0;
wire       this_misses = table_miss ||
                         (miss_sel && lk_tx == miss_sel_tx && lk_ty == miss_sel_ty);
wire [5:0] lk_slot = (lk_tx[5:0] + lk_ty[5:0] * 6'd3) % SLOTS[5:0];
reg [1:0]  lk_pipe = 2'd0;                  // {answer, question}
reg [5:0]  lk_slot_q = 6'd0;
reg        miss_q = 1'b0;
always @(posedge clk) begin
    if (!resetn) begin
        lk_pipe <= 2'd0; lk_slot_q <= 6'd0; miss_q <= 1'b0;
    end else begin
        lk_pipe   <= {lk_pipe[0], lk_valid};
        lk_slot_q <= lk_slot;
        miss_q    <= this_misses;
    end
end
assign lk_hit  = lk_pipe[1] && !miss_q;
assign lk_addr = POOL + ({19'd0, lk_slot_q} << TBITS);

reg [14:0] slot_tx [0:SLOTS-1];
reg [14:0] slot_ty [0:SLOTS-1];
always @(posedge clk) if (lk_valid) begin
    slot_tx[lk_slot] <= lk_tx;
    slot_ty[lk_slot] <= lk_ty;
end

// ------------------------------------------------------------ the pool model ---
reg  [15:0] rd_left = 16'd0;
reg  [24:0] rd_at = 25'd0;
reg         rd_on = 1'b0;
integer     s_i, off;
always @(posedge clk) begin
    rd_valid <= 1'b0;
    if (!resetn) begin
        rd_on <= 1'b0;
    end else if (rd_start) begin
        rd_left <= rd_count;
        rd_at   <= rd_addr;
        rd_on   <= 1'b1;
    end else if (rd_on) begin
        // decode the pool address back into a slot and an offset in the tile
        s_i = (rd_at - POOL) >> TBITS;
        off = (rd_at - POOL) & ((1 << TBITS) - 1);
        rd_data  <= {slot_tx[s_i][7:0] ^ off[15:8],
                     slot_ty[s_i][7:0] ^ off[7:1]};
        rd_valid <= 1'b1;
        rd_at    <= rd_at + 25'd2;
        rd_left  <= rd_left - 16'd1;
        if (rd_left == 16'd1) rd_on <= 1'b0;
    end
end

// ------------------------------------------------------------------ the test ---
logic [15:0] got [0:SPAN-1];
integer ngot = 0, errors = 0;
integer k;

// a miss is one cycle; the waiting loop in fetch_window samples it there rather
// than a latch written from another process, which is a race the simulator is
// free to resolve the other way
reg        saw_miss = 1'b0;
reg [1:0]  cap_level = 2'd0;
reg [14:0] cap_tx = 15'd0, cap_ty = 15'd0;

always @(posedge clk)
    if (we && ngot < SPAN) begin got[ngot] = wdata; ngot = ngot + 1; end

task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

task automatic fetch_window(input [11:0] r0, input [13:0] e0, input [15:0] n);
    integer guard;
begin
    ngot = 0;
    saw_miss = 1'b0;
    @(posedge clk);
    row = r0; entry0 = e0; span = n;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    guard = 0;
    while (guard < 20000) begin
        @(posedge clk);
        guard = guard + 1;
        if (miss) begin
            saw_miss  = 1'b1;
            cap_level = miss_level;
            cap_tx    = miss_tx;
            cap_ty    = miss_ty;
        end
        if (done || miss) guard = 20000;
    end
    repeat (4) @(posedge clk);
end
endtask

// what the pool should return for window entry k of this window
// both halves are declared at eight bits: concatenating two 32-bit integers and
// assigning the result to sixteen bits keeps the wrong half, which reads as a
// model that disagrees with itself rather than as a width bug
function automatic [15:0] expect_entry(input integer r0, input integer e0, input integer k);
    reg [13:0] e;
    reg [7:0]  tx, ty, row_in, ent_in;
begin
    e      = e0[13:0] + k[13:0];
    tx     = (e * 2) / TSIZE;
    ty     = r0 / TSIZE;
    row_in = r0 % TSIZE;
    ent_in = e % TENT;
    expect_entry = {tx ^ row_in, ty ^ ent_in};
end
endfunction

integer i;

initial begin
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (2) @(posedge clk);

    // a window starting inside a tile and running across four boundaries
    fetch_window(12'd300, 14'd40, SPAN[15:0]);
    want(ngot == SPAN, "the window filled completely");
    for (i = 0; i < SPAN && i < ngot; i = i + 1)
        if (got[i] !== expect_entry(300, 40, i)) begin
            if (errors < 4)
                $display("  entry %0d: got %04h want %04h", i, got[i], expect_entry(300, 40, i));
            errors = errors + 1;
        end

    // a window starting exactly on a tile boundary
    fetch_window(12'd128, 14'd0, SPAN[15:0]);
    want(ngot == SPAN, "the aligned window filled completely");
    for (i = 0; i < SPAN && i < ngot; i = i + 1)
        if (got[i] !== expect_entry(128, 0, i)) errors = errors + 1;

    // a miss stops the fetch rather than completing it
    table_miss = 1'b1;
    fetch_window(12'd200, 14'd10, SPAN[15:0]);
    want(ngot < SPAN, "a miss stops the window short");
    table_miss = 1'b0;

    // and it says which tile was missing.  Entry 600 is inside tile 4 (1200
    // pixels over, 512 pixels into the tile), and the chunk runs to the tile
    // boundary at entry 640, so tile 5 is the one this window needs next.
    level = 2'd2;
    miss_sel = 1'b1; miss_sel_tx = 15'd5; miss_sel_ty = 15'd1;
    fetch_window(12'd300, 14'd600, SPAN[15:0]);
    want(saw_miss === 1'b1, "the fetch missed");
    want(cap_level === 2'd2, "the miss names the level");
    want(cap_tx === 15'd5, "the miss names the tile's x");
    want(cap_ty === 15'd1, "the miss names the tile's y");
    miss_sel = 1'b0;
    level = 2'd0;

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (windows walk their chunks and land in order)");
    $finish;
end

initial begin
    #(500e3);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
