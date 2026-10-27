# Scoping: streaming map tiles

Written 2026-10-26, before any implementation. This is a proposal, not a record
of something that exists.

## What it would deliver

Today the SDRAM holds one fixed pack -- four levels of one 18.4 km square, 27.62
MiB of the dock's 32 -- and everything the user can reach is inside that square.
The goal is the opposite arrangement: a small pool of tiles that the core fills as
the view moves, so the reachable area is as large as the storage behind it, and
max zoom is available anywhere rather than only where a level happens to be
resident.

The honest description of the result is **web-map behaviour on a slow
connection**: the whole area at max detail, sharp where you have settled and
blurry while you are moving.

## The numbers we have

Measured, not assumed:

- **Link to the BL616: 431 kB/s** at 5 Mbaud with eight samples a bit, and 190
  kB/s at the board's 2 Mbaud default (both 95% of their wire rate).
- **`hclk`: 76.44 to 84.05 MHz** across eight placement seeds against 74.25, so
  new logic has roughly two megahertz to spend before it needs hoisting into its
  own cycle.
- **SDRAM: 32 MiB**, currently 27.62 MiB of pack.

Derived from those:

- A **256 x 256 tile at 8 bits per pixel is 64 KiB**; at 4 bits it is 32 KiB.
- A screen at z15, step 1.0, covers **1280 x 720 source pixels**, which is five
  tiles across and three down, about **15 to 24 tiles** counting partials.
  That is 1.0 to 1.5 MiB at 8bpp, 0.5 to 0.75 MiB at 4bpp.
- Filling one screen from the link takes **2.4 to 3.5 s at 8bpp, half that at
  4bpp**. Panning a full screen width while dragging takes a user about two
  seconds, so **the link cannot keep up with a fast pan** and the design has to
  degrade rather than wait.
- A coarse overview is cheap: at z10 a 256-pixel tile covers 39 km, so a region
  the size of the whole metro is a handful of tiles and a few hundred kilobytes.
  **That is what makes the fallback affordable.**

## The shape of the design

1. **A tile pool** in SDRAM: N slots of one tile each, and a page table in fabric
   mapping `(level, tile_x, tile_y)` to a slot plus a valid bit. N is chosen for
   a few screens of prefetch -- 64 slots at 4bpp is 2 MiB.
2. **A resident coarse pyramid** for fallback: the low zooms held permanently,
   outside the pool, because they are small and they are what the viewer sees
   while a fine tile is in flight.
3. **A fetch engine that follows the page table.** This is the whole risk, and it
   is the reason to scope before building. Today a line fetch is *one linear
   burst*: `f_base = level_base + row * level_w + col`, `SPAN` = 644 entries of
   two source pixels each, covering 1288 pixels in one stream. With tiles, a
   source row crosses a **256-pixel boundary every 256 pixels**, so one line's
   fetch becomes up to **six bursts** in different slots. The row buffers hold
   `SPAN` entries and are reused across output lines, so as long as the burst can
   restart against a new slot the rest of the pipeline is unchanged.
4. **Prefetch and eviction from the viewport**: on each line boundary, work out
   which tiles the coming screen needs, request the missing ones, and evict the
   farthest slot that is not in view.
5. **A miss draws from the next coarser level**, scaled, rather than garbage or
   black. The renderer already has bilinear scaling and a level per viewport, so
   this is a second read path rather than new arithmetic.

## Decisions taken

Settled 2026-10-26:

- **Tiles come from the SD card, served by the BL616.** No config flash. The card
  is what every other core already loads from, it holds more than any working set
  by three orders of magnitude, and the flash is *smaller* than the area
  streaming is meant to reach -- 11 to 15 MB is about 280 km2 at z15 8bpp, barely
  more than the 22 km pack that already fits. The flash only bought bandwidth for
  a store too small to stream from.
- **4 bits per pixel.** Halves the bytes in SDRAM and on the wire.
- **Sharp where the viewer stays, soft while they move.** The fallback draws the
  coarser level scaled up; nothing waits for a tile.

## The fetch is cheaper than this document first feared

Checked against the code after the decision: the video channel reads **128
halfwords, 256 bytes, per `vstart`**, and a 256-pixel tile row at one byte per
pixel is exactly 256 bytes. So a tile row is *one* SDRAM line read, one to one.
Today's line fetch is `SPAN` = 644 entries, which is 5.03 line reads. A tiled
source row crossing five tile boundaries is therefore 5 or 6 line reads -- the
same order of magnitude, not six times the work.

What tiled fetching costs is not more reads but **page misses**: today's five
lines are mostly consecutive addresses inside one SDRAM page, while tiles land in
arbitrary slots. A row activation is a few clocks at 74 MHz, so going from about
three activations to five or six costs on the order of a dozen clocks out of the
1650 a line has.

`maps_video_rd` already does what the tiled fetch needs -- start at an arbitrary
entry within a 256-byte line and read N of them. The change is that `f_cnt` and
`f_base` become per-chunk quantities recomputed from the page table, with the
entry counter continuous across chunks, in both the rotating path and the
blocking one.

## The four decisions

**A. Where do tiles come from?** This is the decision that sets the ceiling,
because the renderer work is the same in every case.

- **The host over the existing link** -- 431 kB/s. No new hardware, no firmware
  work beyond a tile server on the PC; the pack files already exist on this
  machine. Costs 2.4 to 3.5 s per screen at 8bpp and needs the PC attached.
- **The BL616 reading its own SD card** -- same link, so the same 431 kB/s, but
  self-contained once the firmware serves tiles. It is a TinyTang cycle.
- **The FPGA reading its own configuration flash** -- 15 MB free, SPI at
  3 to 6 MB/s, no host at all. Needs an SPI master in fabric and a way to write
  the flash, and 15 MB is only about 380 km2 at 8bpp z15, though the coarse
  levels fit easily. This is the one that would make the core stand alone.
- **The FPGA reading an SD card on a header** -- 1 to 3 MB/s, new hardware.

**B. Tile size and format.** 256 px is the natural unit because the pack is
already cut on 256-pixel tiles. 4bpp halves every byte on the wire and in
SDRAM, at the cost of a 16-colour palette per tile and a small quality loss; it
is the cheapest large multiplier available and it is independent of everything
else here.

**C. Pool size and eviction.** Given (A), how many slots and what policy. The
simple policy is furthest-from-the-view-centre first, which needs no history.

**D. Who computes the tile list?** The fabric can do it from the viewport with a
small amount of arithmetic, which keeps the host or firmware dumb: it answers
requests rather than predicting them.

## Work breakdown

| piece | size | risk |
|---|---|---|
| Fetch engine following a page table, with a testbench | large | **the whole risk** |
| Tile pool, page table, valid bits in fabric | medium | low |
| Request protocol and a host-side tile server | medium | low |
| Prefetch and eviction from the viewport | medium | low |
| Coarse pyramid resident and miss fallback | medium | medium |
| 4bpp pack variant and palette handling | medium | low, independent |
| Loading the pool over the link at speed | small | none, measured |

## What I would prove first

**A testbench for the fetch engine alone**, before touching the renderer that
currently works: drive it with a synthetic tile map, walk a source row across
five slot boundaries, and show that the burst restart costs nothing in the
per-line budget. Two questions decide whether the design is viable at all:

1. Can a line's fetch complete within the 1650 clocks a raster line gives it
   when it is up to six bursts in different slots, given the SDRAM's row
   activations? Today one burst of 644 entries fits with room; six bursts of
   about 100 entries pay six row activations instead of one.
2. Does the address arithmetic (tile -> slot -> row within the tile) fit in the
   margin we have, or does it need the same hoisting into its own cycle that the
   row pair, the fetch base and the pan candidates each needed?

If either answer is no, the design changes -- a bigger tile, a wider fetch, or a
line cache instead of a row cache -- and it is much cheaper to learn that from a
testbench than from a rebuilt renderer.

## What this does not solve

- **The link is still the ceiling.** Streaming makes the area unlimited; it does
  not make loading fast. A pan faster than 431 kB/s will outrun it, and the
  fallback is what the user sees.
- **Quality on the fallback is the coarser level scaled up**, which is honest but
  visibly soft.
- **Nothing about the pack's palette changes** unless 4bpp is taken, and then
  per-tile palettes are a real change to the index pipeline.
- **The two open defects are untouched**: the status readback's top byte above
  16 MB, and the zoom ceiling on the finest level.

## Answered

1. **Where do tiles come from** -- the SD card, served by the BL616. No flash.
2. **Is 4 bits per pixel acceptable** -- yes.
3. **Is "sharp where you stay, soft while you move" acceptable** -- yes.

## Progress

- **Done: the tile pack** (item 1) -- `maps_pack.py tiles` writes 256-pixel tiles
  at 4bpp with per-tile palettes, 14.24 MiB against 27.62 for the same ground, and
  `verify-tiles` decodes every tile against its source.
- **Done: the page table** (`maps_tiles.sv`) -- a direct-mapped cache of 256 slots
  holding 32-bit tags in block RAM with the valid bits in flip-flops so reset
  clears them, because a garbage tag with its valid bit set would be a false hit
  and the renderer would draw another part of the map.  `fill_addr` is an output:
  the hash chooses the slot, so the loader is told where the bytes belong.
- **Done: the fetch arithmetic** (`maps_tile_addr.sv`) -- given a row and an
  absolute entry, which tile it is in, the byte offset inside that tile and how
  many entries run to the tile boundary.  Absolute, not a stride from the window
  start: chunks break on the tile grid, so a fixed stride disagrees with it at
  every boundary but the first.
- **Done: the chunk sequence** (`maps_tile_fetch.sv`) -- one window of a source
  row walked in chunks that each stay inside a tile, looked up per chunk, with a
  miss reported rather than papered over.  The page table's answer is two cycles
  behind its question -- it registers the lookup, then registers the verdict --
  so the sequence has a lookup state and two wait states between chunks.  One
  wait state is not enough, and the first version had one: it sampled a cycle
  early, read the stale zero, and reported a miss for a tile that was resident.
  `sim/tb_maps_tile_fetch.sv` did not catch it because its page-table model
  answered combinationally; the model now carries the real two-cycle latency, so
  the mistake cannot come back through that door.
- **Corrected: a tile is 64 KiB, not 32.** A 256-pixel row is 256 bytes and there
  are 256 rows, so 8bpp tiles are 64 KiB and a 16 MiB pool is 256 slots.  Both the
  page table and the fetch testbench had it as 32 KiB, and the testbench caught it
  by reading a tile offset out of range.
- **Done: the renderer's tile path** (`maps_render.sv` with `TILED`) -- the fetch
  engine stops computing a linear byte address and asks `maps_tile_fetch` for the
  window, taking its entries one at a time instead of from `rd_valid`.  The
  linear path is untouched and stays the default, so the two are built from the
  same module and can be compared.  `sim/tb_maps_render_tiled.sv` runs the
  renderer, the sequencer and the real page table together against a pool model
  whose entries are `{row, entry index}`, so a wrong row, a wrong entry and the
  wrong half of the right entry are three different numbers; all three lines it
  draws are pixel-exact, every fetch hits, and no tile is missed.  Building it
  also answered a question the sequencer's own testbench could not: the renderer
  starts fetching the moment reset is released, so a pool that is not yet
  resident is a miss in the first line, and a missed row is not retried.
- **Next: the request protocol and the TinyTang tile server**, then prefetch,
  eviction and the coarse fallback on a miss (which is what makes that
  no-retry behaviour harmless), then 4bpp in the pixel path.

**A note on 4bpp and the fetch.** A 16-bit entry carries two 8-bit indices today.
At 4bpp it would carry four pixels, and the pixel pipeline -- which extracts the
low and high byte by parity -- would need nibble extraction instead. So the first
streaming path uses **8bpp tiles**, where a tile row is 256 bytes, exactly one
SDRAM line and 128 entries, which is the geometry the video channel already has;
4bpp then changes the packing and the pixel path, not the fetch.

## Implementation order

1. **Tile-indexed pack format**, 4bpp, on the card: a header with the level table
   and a tile directory, one 32 KiB record per tile, each tile carrying its own
   16-colour palette. `tools/maps_pack.py` grows a `tiles` mode.
2. **Page table and tile pool in fabric**: N slots of 32 KiB in SDRAM, a
   `(level, tx, ty) -> slot` table with valid bits, and the fetch engine reading
   it per chunk.
3. **Chunked fetch in the renderer**, with a testbench that walks a source row
   across five slot boundaries and checks the entries land in the right order and
   the line still completes inside its budget.
4. **Request and reply over the link**: the fabric asks for a tile, the BL616
   answers from the card. A TinyTang cycle.
5. **Prefetch, eviction and the coarse fallback**, which needs (1) to (4).
6. **4bpp in the pixel path**: the index pipeline takes a 4-bit index and a
   per-tile palette instead of one shared 256-entry table.
