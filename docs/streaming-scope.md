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

## Open questions for the user

1. **Where do tiles come from** -- host, BL616 SD, or the FPGA's own flash? This
   sets the ceiling and the firmware work.
2. **Is 4bpp acceptable** for the doubled effective rate and smaller pool?
3. **Is "sharp where you stop, soft while you move" acceptable**, or is a hard
   limit on pan speed wanted instead?
