// Testbench for maps_tile_addr: the chunk arithmetic the tile fetch is built on.
//
// A window of entries is walked in chunks that each stay inside one tile, and
// what has to be true is: the chunk's tile is the tile the source pixel falls in,
// the byte offset inside that tile addresses the chunk's first entry, and the
// entry count available stops at the tile boundary so the next chunk starts a new
// tile.  Walking the whole window must therefore account for exactly the entries
// the window asks for, and every chunk must be addressable.
//
// The check that catches the most likely mistake is the recomposition: walk the
// window, and for each chunk turn (tile, byte offset) back into a level
// coordinate and confirm it is the entry the chunk should start at.  A byte
// offset that is out by a factor of two -- the row stride inside a tile is 256
// bytes, not 128 -- passes every shape check and fails that one.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_tile_addr;

localparam int TSIZE = 256;
localparam int TENT  = 128;
localparam int TW    = 8;

reg  [1:0]  level = 2'd0;
reg  [11:0] row = 12'd0;
reg  [13:0] entry = 14'd0;

wire [14:0] tx, ty;
wire [15:0] byte_off;
wire [7:0]  entries;

maps_tile_addr #(.TSIZE(TSIZE), .TENT(TENT), .TW(TW)) dut (
    .level(level), .row(row), .entry(entry),
    .tx(tx), .ty(ty), .byte_off(byte_off), .entries(entries));

integer errors = 0;

task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed (row %0d entry %0d -> tx %0d ty %0d off %0d n %0d)",
                 what, row, entry, tx, ty, byte_off, entries);
        errors = errors + 1;
    end
end
endtask

// walk a window of `span` entries from entry `start` on source row `r`, and
// check every chunk against what the level coordinate says it should be
task automatic walk(input [11:0] r, input [12:0] start, input integer span);
    integer want_e, k, guard;
begin
    row = r;
    want_e = start;
    k = 0;
    guard = 0;
    while (want_e < start + span && guard < 64) begin
        guard = guard + 1;
        entry = want_e[13:0];
        #1;
        want(tx == (want_e * 2) / TSIZE, "chunk starts in the tile of its source pixel");
        want(ty == r / TSIZE, "chunk is in the row's tile");
        want(byte_off == ((r % TSIZE) * TSIZE) + ((want_e % TENT) * 2),
             "byte offset is the row inside the tile and the entry within it");
        want(entries == TENT - (want_e % TENT),
             "the count runs to the tile boundary");
        if (entries < span - (want_e - start)) want_e = want_e + entries;
        else                                  want_e = start + span;
        k = k + 1;
    end
    want(want_e == start + span, "the walk covers exactly the window");
end
endtask

initial begin
    // a window that starts inside a tile and runs across several
    row = 12'd300;
    walk(12'd300, 13'd40, 644);

    // a window that starts exactly on a tile boundary
    walk(12'd128, 13'd0, 644);

    // a window entirely inside one tile
    walk(12'd513, 13'd16, 64);

    // the last row of a tile, and the first of the next
    walk(12'd255, 13'd100, 300);
    walk(12'd256, 13'd100, 300);

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (chunks walk their window and stay inside their tiles)");
    $finish;
end

initial begin
    #(10e3);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
