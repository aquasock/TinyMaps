// Testbench for maps_tiles: the tile page table.
//
// It is a direct-mapped cache, so what has to be true is: a tile that was filled
// is found at the slot it was filled into; a tile that was never filled is a
// miss; a tile whose slot has since been filled with another tile is a miss
// rather than a false hit; and the address a hit returns is the pool base plus
// the slot times the tile size.
//
// The false hit is the one that matters. A garbage tag with its valid bit set
// would have the renderer draw another part of the map, which looks like a
// rendering fault rather than an addressing one, so the test drives a lookup
// against a slot that has never been written and checks it misses.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_tiles;

localparam int SLOTS = 512;
localparam int TBITS = 15;
localparam int POOL  = 32'h0010_0000;

reg clk = 1'b0;
always #6.734 clk = ~clk;                 // 74.25 MHz

reg resetn = 1'b0;
reg        lk_valid = 1'b0;
reg  [1:0] lk_level = 2'd0;
reg [14:0] lk_tx = 15'd0, lk_ty = 15'd0;
wire       lk_hit;
wire [24:0] lk_addr;
wire [24:0] fill_addr;

reg        fill_valid = 1'b0;
reg  [1:0] fill_level = 2'd0;
reg [14:0] fill_tx = 15'd0, fill_ty = 15'd0;


wire [15:0] hits, misses;
wire        idle;

maps_tiles #(.SLOTS(SLOTS), .TBITS(TBITS), .POOL_BASE(POOL)) dut (
    .clk(clk), .resetn(resetn),
    .lk_valid(lk_valid), .lk_level(lk_level), .lk_tx(lk_tx), .lk_ty(lk_ty),
    .lk_hit(lk_hit), .lk_addr(lk_addr),
    .fill_valid(fill_valid), .fill_level(fill_level),
    .fill_tx(fill_tx), .fill_ty(fill_ty), .fill_addr(fill_addr),
    .hits(hits), .misses(misses), .idle(idle));

integer errors = 0;

task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

// fill a tile; the slot is the table's business, and it reports the address it
// put it at in fill_addr
task automatic fill(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
begin
    @(posedge clk);
    fill_valid = 1'b1; fill_level = lvl; fill_tx = tx; fill_ty = ty;
    @(posedge clk);
    fill_valid = 1'b0;
    @(posedge clk);
end
endtask

// the slot the direct mapping assigns, for checking the address
function automatic integer slot_of(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
    slot_of = (tx + ty * 31 + lvl) % SLOTS;
endfunction

// present a lookup and return what came back
task automatic look(input [1:0] lvl, input [14:0] tx, input [14:0] ty,
                    output hit, output [24:0] addr);
begin
    @(posedge clk);
    lk_valid = 1'b1; lk_level = lvl; lk_tx = tx; lk_ty = ty;
    @(posedge clk);              // the table samples the lookup at this edge
    lk_valid = 1'b0;
    @(posedge clk);              // and answers at this one
    hit  = lk_hit;
    addr = lk_addr;
    @(posedge clk);
end
endtask

reg        hit;
reg [24:0] addr;
integer    h0, m0;

initial begin
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (2) @(posedge clk);

    // --- nothing is resident after reset, including never-written slots
    look(2'd0, 15'd5, 15'd7, hit, addr);
    want(hit == 1'b0, "a lookup before anything is filled misses");

    // --- a filled tile is found, at the address its slot implies
    fill(2'd0, 15'd5, 15'd7);
    look(2'd0, 15'd5, 15'd7, hit, addr);
    want(hit == 1'b1, "a filled tile hits");
    want(addr == POOL + (slot_of(2'd0, 15'd5, 15'd7) << TBITS),
         "the address is the pool base plus the hashed slot times the tile size");

    // --- a different tile that hashes elsewhere misses
    look(2'd0, 15'd6, 15'd7, hit, addr);
    want(hit == 1'b0, "an unfilled neighbour misses");

    // --- the level is part of the identity: same coordinates, other level
    look(2'd1, 15'd5, 15'd7, hit, addr);
    want(hit == 1'b0, "the same coordinates on another level miss");

    // --- filling a shadowing tile evicts: the old one now misses, the new hits
    //     find a pair that lands in the same slot
    begin : evict
        // slot = (tx + ty*31 + level) mod SLOTS, so a tx 512 further along lands
        // in the same slot as tx 5 with the same ty
        fill(2'd0, 15'd1029, 15'd7);
        look(2'd0, 15'd5, 15'd7, hit, addr);
        want(hit == 1'b0, "the evicted tile misses rather than falsely hitting");
        look(2'd0, 15'd1029, 15'd7, hit, addr);
        want(hit == 1'b1, "the shadowing tile hits");
    end

    // --- counters moved, and the module reports idle when nothing is asked
    h0 = hits; m0 = misses;
    want(h0 > 0 && m0 > 0, "hits and misses both counted");
    want(idle == 1'b1, "idle when no lookup is presented");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (fill, hit, miss, eviction and address)");
    $finish;
end

initial begin
    #(10e3);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
