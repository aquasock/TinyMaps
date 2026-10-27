// Where one chunk of a source row lives in the tile pool.
//
// The renderer fetches a source row as a window of 16-bit entries, two source
// pixels each.  With tiles, that window crosses tile boundaries, so the fetch is
// split into chunks that each stay inside one tile: a chunk starts at an entry
// and runs to the end of the tile's row, at most 128 entries because a tile row
// is 256 pixels at eight bits, 256 bytes, 128 entries -- which is exactly one
// SDRAM line, so a chunk is one line read and the video channel's own unit is
// unchanged.
//
// This module is the arithmetic alone: given the level, a source row and an
// entry, it says which tile that entry lives in, at what byte offset inside that
// tile, and how many entries may be taken before the next tile begins.  The fetch
// engine walks its window by asking about the entry it has reached and stepping
// by the count it gets back.  The fetch engine looks the tile up in
// `maps_tiles` and adds the offset to the slot's address.
//
// Nothing here multiplies two variables: the row stride inside a tile is a shift,
// the tile coordinates are a shift of the source pixel, and the offset inside the
// tile is a shift and an add.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_tile_addr #(
    parameter int TSIZE  = 256,      // pixels across a tile
    parameter int TENT   = 128,      // 16-bit entries across a tile row
    parameter int TW     = 8          // log2 of TSIZE
) (
    input  wire [1:0]  level,
    input  wire [11:0] row,          // source row within the level
    input  wire [13:0] entry,        // the entry to locate, absolute in the level

    output wire [14:0] tx,           // the tile this chunk starts in
    output wire [14:0] ty,
    output wire [15:0] byte_off,     // the chunk's first entry, inside that tile
    output wire [7:0]  entries       // entries before the next tile begins
);

// The entry is absolute in the level, not counted from the window start: chunks
// break on the tile grid, which is aligned to whole tiles, so a caller that
// stepped by a fixed stride from its window start would disagree with the grid
// at every boundary but the first.
wire [13:0] e0 = entry;

// the tile is the source pixel's 256-pixel block; an entry is two pixels
wire [14:0] pixel = {e0, 1'b0};

assign tx = {8'd0, pixel[14:TW]};
assign ty = {7'd0, row[11:TW]};

// inside the tile: a row of it is TSIZE pixels, 256 bytes, and an entry is two
// bytes, so the byte offset is the row inside the tile shifted by the tile width
// plus the entry's position within the row doubled
wire [TW-1:0] row_in_tile = row[TW-1:0];
// entries in a tile row are TENT = 2**(TW-1), so the position within the row is
// one bit narrower than the tile itself
wire [TW-2:0] ent_in_tile = e0[TW-2:0];

assign byte_off = ({8'd0, row_in_tile} << TW) + ({9'd0, ent_in_tile} << 1);

// how much of this chunk stays inside the tile; the caller clamps the last one
// to what is left of the window.
wire [7:0] room = TENT[7:0] - {1'b0, ent_in_tile};
assign entries = room;

endmodule
