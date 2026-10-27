// The tile page table: which tile is in which slot of the pool.
//
// A tile is 256 by 256 pixels at four bits, 32 KiB, and a slot is one tile.  The
// pool is addressed by slot, so the fetch engine asks this module "where is tile
// (level, tx, ty)?" and gets a byte address or a miss.
//
// It is a **direct-mapped cache**, not a fully associative table: the slot is a
// hash of the tile's coordinates, and one tag per slot says which tile that slot
// holds.  That is one comparator and one memory read per lookup instead of a
// search across every slot, and the semantics are the ones a cache has -- a tile
// whose slot has since been filled with something else is simply a miss, and the
// fetch asks for it again.  A fully associative table would need SLOTS
// comparators against a 32-bit tag, which is not worth it for a window of a few
// dozen tiles.
//
// The tags live in block RAM, written and read on this one clock; this project
// never writes block RAM on one clock and reads it on another, because Apicula
// reads that back wrong on the GW5AST-138.  A lookup therefore takes a cycle:
// present the coordinates, take `hit` and `addr` on the next one.
//
// The valid bits are flip-flops and not part of the tag, so that reset clears
// them.  A block RAM's contents at power-up are not something to depend on: a
// garbage tag with its valid bit set would be a false hit, which is the one
// failure this design cannot tolerate, and relying on an initial block to clear
// 512 entries is relying on the toolchain to initialise memory it may not.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_tiles #(
    parameter int SLOTS     = 512,          // tiles the pool holds
    parameter int TBYTES    = 32768,        // bytes in one tile
    parameter int TBITS     = 15,           // log2 of TBYTES
    parameter int POOL_BASE = 32'h0010_0000 // where the pool starts in SDRAM
) (
    input  wire        clk,
    input  wire        resetn,

    // where is this tile?  present it one cycle, take the answer the next
    input  wire        lk_valid,
    input  wire [1:0]  lk_level,
    input  wire [14:0] lk_tx,
    input  wire [14:0] lk_ty,
    output reg         lk_hit,
    output reg  [24:0] lk_addr,

    // a tile has landed; the slot is the hash of its coordinates, so the loader
    // is told where to put the bytes rather than choosing a slot itself
    input  wire        fill_valid,
    input  wire [1:0]  fill_level,
    input  wire [14:0] fill_tx,
    input  wire [14:0] fill_ty,
    output reg  [24:0] fill_addr,      // where those bytes belong in the pool

    // how often it has answered either way, for the link's status command
    output reg  [15:0] hits,
    output reg  [15:0] misses,
    output wire        idle
);

localparam int SW = $clog2(SLOTS);

// A tag is the identity of the tile in a slot: its level and both coordinates.
wire [31:0] lk_tag   = {14'd0, lk_level, lk_tx, lk_ty};
wire [31:0] fill_tag = {14'd0, fill_level, fill_tx, fill_ty};

// A hash that spreads a local window: the tiles a viewport touches are adjacent
// in tx and ty, so mixing both coordinates before truncating keeps them apart.
function automatic [SW-1:0] slot_of(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
    reg [21:0] h;
    begin
        h = {7'd0, tx} + ({7'd0, ty} * 22'd31) + {20'd0, lvl};
        slot_of = h[SW-1:0];
    end
endfunction

wire [SW-1:0] lk_slot     = slot_of(lk_level, lk_tx, lk_ty);
wire [SW-1:0] fill_slot_h = slot_of(fill_level, fill_tx, fill_ty);

reg [31:0]   tag [0:SLOTS-1];      // block RAM: which tile a slot holds
reg [SLOTS-1:0] vbit;              // flip-flops: whether it holds anything

reg          pend = 1'b0;          // a lookup was presented last cycle
reg [SW-1:0] pend_slot = '0;
reg [31:0]   pend_tag = 32'd0;

always @(posedge clk) begin
    if (!resetn) begin
        pend <= 1'b0;
        vbit <= '0;
        fill_addr <= 25'd0;
        lk_hit <= 1'b0; lk_addr <= 25'd0;
        hits <= 16'd0; misses <= 16'd0;
    end else begin
        if (lk_valid) begin
            pend      <= 1'b1;
            pend_slot <= lk_slot;
            pend_tag  <= lk_tag;
        end else begin
            pend <= 1'b0;
        end

        if (fill_valid) begin
            tag[fill_slot_h]  <= fill_tag;
            vbit[fill_slot_h] <= 1'b1;
            fill_addr <= POOL_BASE[24:0] + (fill_slot_h << TBITS);
        end

        lk_hit <= 1'b0;
        if (pend) begin
            // the tag read this cycle is the one at pend_slot; a fill in the
            // same cycle lands after it, which is the ordering a cache promises
            if (vbit[pend_slot] && tag[pend_slot] == pend_tag) begin
                lk_hit  <= 1'b1;
                lk_addr <= POOL_BASE[24:0] + (pend_slot << TBITS);
                hits    <= hits + 16'd1;
            end else begin
                misses <= misses + 16'd1;
            end
        end
    end
end

assign idle = !pend && !lk_valid;

endmodule
