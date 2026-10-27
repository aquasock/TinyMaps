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
- **Done: the request out** (`maps_tile_req.sv`) -- the sequencer's miss, with
  the tile's coordinates registered alongside it, goes into a short queue and
  comes out as a frame on the link's transmitter.  Requests for the same tile in
  the queue fold into one, because a line misses in chunks and would otherwise
  ask eight times; the same tile asked for again after its request has gone is a
  second request, which is the only retry this design has.  The transmitter is
  shared with the loader's answers, so a frame is offered only while the arbiter
  grants it, keeps the grant for the whole frame, and re-offers a byte until the
  arbiter takes it -- a frame with a byte missing is worse than a frame that is
  late.  `sim/tb_maps_tile_req.sv` models the transmitter and the arbiter and
  decodes every byte back into a frame: dedupe, ordering, a queue that fills and
  drops with a sticky flag, a loader that holds the line, and a loader that asks
  mid-frame and does not get it.
- **Done: the reply** -- command `0x1D`, one block of one tile, handled by
  `maps_link_rx` next to the image and palette commands.  Nine header bytes, the
  block, four CRC bytes; little-endian throughout.  The write goes to the address
  the page table derives from the coordinates, so the host never learns the slot
  and the cache's replacement policy stays in the cache.  Filling is now two
  things instead of one: `fill_addr` is a function of the coordinates and is
  available before the bytes exist, and `fill_commit` is the event that makes a
  tile resident -- marking it resident when the address was handed out would make
  a half-written tile a hit, which is a hit on somebody else's picture.  A block
  is refused with NAK `'D'` for a bad CRC, a zero or misaligned count, a
  misaligned offset, or a block that would run past the end of the tile; its bytes
  have already been written, and re-sending is idempotent, but nothing is
  committed and nothing is acknowledged until every write the block caused has
  been taken by the port.  `sim/tb_maps_link_rx.sv` sends real blocks through the
  real frame parser and checks where the bytes landed, that a middle block does
  not make a tile resident, that the block which ends the tile commits it once
  with its own coordinates, that a corrupt block commits nothing, and that a
  refused block writes nothing.
- **Done: the pool has a home, and the table is in the top.** The pack's last
  level ends at `0x01B9DBD8`, 27.62 MiB in, so the pool takes the four megabytes
  above 28 and ends exactly at the top of the part: `POOL_BASE = 0x01C0_0000`,
  64 slots of 64 KiB.  That is sixteen tiles more than a 1280x720 screen of z15
  needs counting partials, which is room for a prefetch to be ahead of the
  picture.  `tinymaps_top` instantiates `maps_tiles` with the loader's fill ports
  and turns `TILES` on, so a tile the host sends now lands in that reserved region
  and is committed to the table.  Nothing looks a tile up yet -- the renderer
  still fetches linearly -- so the table answers the loader and remembers.
- **The hash stopped multiplying.** `slot_of` computed `ty * 31`, which was free
  while `fill_addr` was a register; the loader now takes the address before the
  bytes arrive, so it is combinational and feeds the SDRAM controller's address
  mux.  That one multiplier took the whole design from 84.35 to 70.15 MHz at seed
  1 and failed seven of eight seeds.  Written as a shift and a subtract it is the
  same hash and the same slots, and the sweep is back to 75.46 through 88.40.
- **Done: the loop closes.** `sim/tb_maps_stream.sv` wires the renderer in tile
  mode, the chunk sequencer, the real page table and the request queue the way the
  top will, and models the only part that does not exist yet -- the host, which
  answers a request with a tile.  A line over an empty pool misses, the request
  goes out naming the tile the line's first pixel lives in, the host's answer is
  written where the table says and committed, and the same line then draws, pixel
  for pixel, from the tile that just arrived.  Tiles that are three columns or one
  row away are covered, and so is a pan: the picture converges as answers arrive,
  because one fetch stops at the first tile it does not have and there are more
  tiles than one answer.
- **A miss used to be a permanent stall.** The blocking fetch waits for `f_ack`,
  and a miss never raises it, so once a fetch was refused the line engine waited
  for ever: no pixels, no second request, nothing.  The miss now sets a flag the
  blocking path sees and starts a retry timer (`TILE_RETRY`, 2^21 clocks, about
  28 ms at 74.25 MHz, roughly a fifth of the time a 64 KiB tile takes over the
  link).  Without that timer a miss would re-ask once per line and fill the queue
  with duplicates; without any retry at all a tile that arrived late would leave
  the picture waiting on nothing.
- **The top still has `TILED` off.** With tiling on and no coarse fallback, an
  empty pool at boot means every line stalls on its retry timer and the screen
  shows nothing -- worse than not streaming at all.  The fallback is what turns it
  on, so it is the next piece.
- **Done: the coarse fallback.** A line whose own level cannot answer is drawn
  from the level below, and the way it is done is deliberately dull: the coarse
  pass takes the row, the window's first entry and the pixel's position as the
  fine ones halved, so two output pixels share one coarse pixel and the pixel
  pipeline is untouched -- it magnifies by any step already.  A row buffer
  remembers which level it came from, a line only mixes rows that agree, and a
  buffer only satisfies a row if the level matches, because otherwise a coarse
  row would satisfy a fine line for ever: the epoch would end, the picture would
  ask for its own level, and every buffer would say it already had that row.
  `TILE_RETRY` clocks after the first miss the epoch ends at a line boundary, the
  next line tries the view's own level again, and the picture sharpens when that
  fetch lands -- which is "sharp where you stay, soft while you move" falling out
  of the same machinery.
- **Done: the streaming path is in the top, behind a switch.**  The sequencer,
  the page table and the request queue are instantiated beside the renderer, the
  video channel is muxed between the renderer's own linear fetch and the
  sequencer's chunk read, and the two share the link's transmitter with the
  loader's answers having priority.  The switch is command `0x1E`, one byte, and
  it defaults to the pack -- because the pool cannot answer itself: until the host
  serves tiles, streaming mode is an empty pool and a blank picture, so the mode
  belongs to the host and not to the bitstream.  Two things had to change for the
  transmitter to be shared safely.  A frame keeps the line from the first byte the
  arbiter actually takes, not from the offer, so a lost offer does not stall the
  answer that won; and the loader now waits for the line before it offers a reply
  byte, which is what stops an ACK starting inside a request frame.
- **Done: a pack the fabric can read, and a server that answers.**  `maps_pack.py
  tiles --bits=8` writes one 256-entry palette for the whole pack -- the table the
  fabric's pixel path already reads -- and 64 KiB records with no per-tile
  palette.  455 tiles over four levels, 28.44 MiB, and `verify-tiles` decodes every
  one against its source: worst tile 4.0/255, against 9-10 for the four-bit pack,
  which is what 256 colours buys.  Four bits a pixel is still written and still
  verified; it waits for the pixel path to learn nibbles.  `tools/serve_tiles.py`
  is the host half: it loads the pack's palette with command `0x08`, switches the
  picture source with `0x1E`, then answers `0x1C` requests with `0x1D` blocks,
  waiting for each ACK and re-sending a refused block.  It refuses a four-bit pack
  outright rather than serving one the pixel path would paint with the wrong
  twelve colours.
- **The pool's hash was wrong, and it took hardware to see it.**  It was
  `tx + 31*ty + level` truncated to the slot count, and 31 is -1 modulo 64, so a
  screen row moved the slot *backwards* by one: row 0 used slots 3 to 8, row 1
  used 2 to 7, row 2 used 1 to 6.  The rows of one screen overlapped almost
  completely, so every tile the host delivered evicted one the next row was about
  to need, the renderer asked again, the answer evicted something else, and no
  frame ever finished -- a livelock, which is what "serving more tiles" could not
  cure.  Thirteen is coprime with 64, so a row moves the slot on by thirteen and a
  screen's eighteen tiles get eighteen slots; it also multiplies out as three adds,
  which is cheaper than the shift and subtract it replaced.  Everything in
  simulation had passed with the old hash because the testbench's own pool copy had
  the same slot arithmetic, and its window was small enough to fit anyway.
- **Two things the hardware run exposed and this cycle did not fix.**  The fetch
  window is a fixed span of entries -- 644, where a level can be 832 pixels wide --
  so the tail of a line asks for tiles past the level's right edge, which cannot
  exist; on the pack path those reads are invisible, and in streaming they block
  the line on an answer that never comes.  And the request queue dedupes only
  against entries still in the queue, so the three rows of one blocking fetch ask
  for the same tile two or three times and get it two or three times.  Both are
  known and written down here; the clamp and the pending set are the next cycle.
- **And one the clamp led to.**  With the fetch count clamped at the level's edge,
  the fallback's arithmetic stops being right: the emit stage subtracts `k0_pf`,
  the *fine* window start, from an entry index computed at the coarse scale.  At
  the old geometry it happened to pass; the fix is a one-liner (`k0 <= k0_e`) but
  the testbench has to model level bounds before it can be trusted, and that is a
  bigger change than this cycle had room for.  The clamp and the `k0` fix belong in
  the same cycle as the bench that can judge them.
- **Done: streaming works on the board.**  The hash fix went on and the picture
  still asked for nothing, which the new status bytes answered in one read --
  `source = tile pool`, `renderer = blocking fetch`, `requests = 0` and not one
  byte on the wire.  So the miss never reached the queue: the renderer was wedged.
  The cause was the runtime source switch.  The video channel is muxed on the same
  signal the renderer watches, so switching while a *linear* fetch was in flight
  sent that fetch's completion to the sequencer instead, `f_busy` never cleared,
  the fetch engine never issued again, and the board drew nothing and asked for
  nothing.  Timing-dependent, which is why switching while idle worked and the
  later attempts did not.  A source change now abandons whatever was in flight,
  and with it the same view, pack and server that had produced silence asked for
  `L3 0,0` onwards, took each 64 KiB tile in 0.32 s, and drew.  The user's verdict
  was pass.
- **The port moved.**  The Tang came back as `/dev/ttyACM2` -- a Pico2 and an
  ESP32 took the lower numbers -- and the tools default to `/dev/ttyACM0`, so two
  attempts went to the wrong device.  Everything takes `--port`; picking the
  device by its `/dev/serial/by-id` name would be the fix in the tools.
- **Done: the window stops at the level's edge, and the fallback's base follows
  the rows it actually got.**  The fetch count is `min(SPAN, level_width/2 -
  window_start)` -- in entries, with no straddle slack at the edge, because one
  entry of slack asks for the first tile of the level next door, which does not
  exist either -- and the coarse pass halves the limit again because its level is
  half as wide.  The bench had to learn the level's bounds first: it now models
  the grid of both levels and counts any request outside it, and before the clamp
  it reproduced the board exactly, asking for `L1 3,0` where the grid is three
  wide.  The bigger find was underneath.  `k0`, the window base the emit stage
  subtracts, was latched one state before the blocking fetch, and a miss there
  changes the scale -- so the fetch landed coarse rows under a fine base, `rd_idx`
  underflowed, and every pixel of a fallback line came from 33 entries away.  It
  now follows the window the rows actually came from (`k0 <= f_col` when they
  land), which is right for both paths and both scales.  The fallback line is
  pixel-exact in simulation for the first time since it was written.
- **Still open:** the request queue asking two or three times for a tile already
  on its way, prefetch and eviction, and 4bpp.  Also: the switch-mid-fetch repair
  is **not** covered by simulation -- the bench passes with the guard and without
  it, and driving `stream` from a register made the whole bench fail for reasons
  not chased, so hardware was the only judge of that one.
- **Next:** the clamp and the pending set, then a fine level where the pool cannot
  hold the view, which is what the fallback and the re-requests exist for.

**A note on 4bpp and the fetch.** A 16-bit entry carries two 8-bit indices today.
At 4bpp it would carry four pixels, and the pixel pipeline -- which extracts the
low and high byte by parity -- would need nibble extraction instead. So the first
streaming path uses **8bpp tiles**, where a tile row is 256 bytes, exactly one
SDRAM line and 128 entries, which is the geometry the video channel already has;
4bpp then changes the packing and the pixel path, not the fetch.

## The request frame

The core asks for a tile with the same frame shape the host sends it, so one
parser covers both directions: `0xAA`, a big-endian length, a command, then the
payload.  The command is `0x1C` and the length counts the command with the
payload, so it is six:

    AA 00 06 1C L TXL TXH TYL TYH

`L` is the level, 0 to 3 as the level table orders them, finest first.  `TX` and
`TY` are the tile's coordinates in the level's own tile grid, fifteen bits each
in a sixteen-bit little-endian pair -- the payloads are little-endian throughout
this protocol; only the frame's own length is big-endian.  Nothing is answered
with an acknowledgement: the reply is the tile's bytes, and a tile that never
arrives is asked for again the next time a line needs it.

A frame cannot be longer than 2047 bytes -- the receiver's length field is eleven
bits plus a guard -- so a 32 KiB tile cannot be one frame.  That is why the reply
is a run of blocks.

## The reply: one block of one tile

Command `0x1D`, little-endian, answered ACK or NAK `'D'`:

    u8  level        which level's tile grid
    u16 tx, ty       the tile, fifteen bits each in sixteen
    u16 offset       byte offset inside the tile, a multiple of eight
    u16 count        bytes in this block, nonzero and a multiple of eight
    count bytes      the tile's own bytes, in storage order
    u32 crc          CRC-32 over every byte above, complemented

Whole words and no tail is a deliberate constraint: it is what lets the pool be
written through the same port the image loader uses without a lane mask, and it
costs the host nothing, since a tile's size is a multiple of eight and the host
chooses the block size.  1024-byte blocks are what the core has been tested with,
which is 64 blocks for a 64 KiB 8bpp tile.

The core adds `offset` to the address the page table derives from the
coordinates.  The host sends coordinates, never a destination.

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
