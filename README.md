# TinyMaps

A map viewer core for TinyTang. Pan and zoom a pre-rendered OpenTopoMap-style
raster held in the dock SDRAM, at 1280x720.

Target: GW5AST-LV138PG484AC1/I0, revision C, open flow (yosys, nextpnr-himbaechel
and the apicula fork).

## State

Phases 0 to 3 are done and verified by simulation. The integration is written
and committed but **does not close timing** -- `hclk` reaches 66.16 MHz against
the 74.25 MHz a 720p line needs -- so no bitstream exists and nothing has been
deployed. `docs/integration-blocker.md` holds the measurements;
`docs/HANDOFF.md` holds the state, the decisions and the next action.

## Building

    tools/build_maps_core_open.sh

Needs oss-cad-suite, the nextpnr-himbaechel fork built against a regenerated
GW5AST-138C database, and the apicula fork. The defaults are this machine's:

- `NEXTPNR_BUILD=/home/vash/tools/nextpnr-mathieufro`
- `APICULA_FORK=/run/media/vash/GIT/apicula-mathieufro`

The flow refuses to pack a netlist with setup or hold violations. Artefacts
land in `build/tinymaps/open-s<seed>/`, named after their own sha256 prefix.

`fpga/tinymaps/tinymaps_top.sv` is a skeleton: clocks, 720p HDMI, and a colour
bar pattern. The load receiver `maps_link_rx.sv` and the renderer
`maps_render.sv` are written and proven in simulation, and `sdram_ctrl.sv` (vended
from TinyNES's `ahb_sdram.sv`, renamed only) is the SDRAM engine. None of the
three is instantiated yet.

## Simulation

    tools/run_sim.sh                 # every sim/tb_*.sv
    tools/run_sim.sh tb_maps_link_rx

Verilator `--binary --timing`; each testbench prints `RESULT: PASS` or
`RESULT: FAIL` and the script's exit code follows it.

## Load receiver

`maps_link_rx` takes the BL616's command `0x07` payload stream after
`iosys_bl616`'s `0xAA` frame parser and runs TinyNES's load semantics with the
destination being an SDRAM byte address:

    header, 5 words little-endian
      0 magic 'TML1' (0x314c4d54)   1 SDRAM byte address (8-byte aligned)
      2 length                      3 image CRC-32 (complemented)
      4 header CRC-32 over the first 16 bytes (complemented)
    then ceil(length / 8192) blocks, each up to 8192 bytes + its CRC-32

Answered ACK 0x06 or NAK 0x15 then a letter: 'H' header CRC, 'C' block CRC,
'I' image CRC, 'T' timeout. A NAKed block is re-sent from its own address.

## Map packs

`tools/maps_pack.py` builds a pack from OpenTopoMap tiles.

    tools/maps_pack.py plan      # level table and SDRAM budget, no network
    tools/maps_pack.py fetch     # populate ~/.cache/tinymaps/tiles
    tools/maps_pack.py pack      # build work/pack/phoenix-18km.tmpk
    tools/maps_pack.py verify <pack>
    tools/maps_pack.py preview <pack>

A pack holds four tile-aligned levels of one 18.4 km square, finest first, as
8-bit indices into one shared 256-entry palette:

| level | zoom | merc m/px | raster | size |
|---|---|---|---|---|
| L0 | z15 | 4.777 | 4608x4608 | 20.25 MiB |
| L1 | z14 | 9.555 | 2304x2560 | 5.62 MiB |
| L2 | z13 | 19.109 | 1280x1280 | 1.56 MiB |
| L3 | z12 | 38.219 | 768x768 | 0.56 MiB |

28.00 MiB total, 87.5% of the dock's 32 MiB SDRAM.

Pack layout, little-endian:

    0    u32  magic 'TMPK'
    4    u16  version = 1
    6    u16  level count
    8    u32  palette offset
    12   u32  palette length
    16   u32  total bytes
    20   u32  header CRC-32 (over the header with this field zeroed,
                             plus the level table and the palette)
    24   u8   name[32]
    56   level table, 40 bytes each:
           u32 data offset, u32 width, u32 height, u32 m/px Q16.16,
           u32 zoom, i32 origin 3857 x, i32 origin 3857 y,
           u32 tiles x, u32 tiles y, u32 raster CRC-32
    then the palette, then the rasters back to back.

Origins are the EPSG:3857 metres of the level's pixel (0,0) centre. Coarser
levels are tile-aligned supersets of L0's ground rectangle, so each carries its
own origin.

## Renderer

`maps_render` draws one output line from one source row, with the viewport in
the level's own pixel space (`src_x0`, `src_y0`, `step_x`, `step_y`, Q16.16).
A row window is fetched into block RAM as 16-bit entries of two adjacent 8-bit
pixels and each output pixel costs one block RAM read plus a 256-entry palette
lookup. `tools/check_render.py` recomputes what the testbench ran from the
parameters it wrote out and compares every pixel.

Resampling is bilinear, with a nearest path for comparison. Three row buffers
are kept: two are read for the current line and the third is prefetched during
it. The testbench checks `fetch_count`, which exposes whether row reuse and the
overlapped prefetch are actually happening rather than silently falling back.

`step_x` and `step_y` are source pixels per output pixel, so **magnifying means
step below 1**. The level selector must keep them in `(0.5, 1]`: above 1 a source
row can advance by two per output line, consecutive line pairs share no row, and
no rotation is possible. That is a level-selection rule, not a renderer bug.

What the fetch counter says:

- `step_y = 0.750` (bilinear): 38 fetches for 48 lines. Fewer than one per line,
  because at magnification the row sometimes does not advance at all.
- `step_y = 1.000` (nearest): 50 fetches for 48 lines against 49 ideal.
- `step_y` 1.500, 1.750 and 1.990: 96, 120 and 144. Correct output, but two per
  line, so the rotation never engages. Those steps are outside the operating
  range; a level selector that kept them there would be misconfigured, and the
  renderer degrades to correct-but-slow rather than wrong.

In range, a line costs at most one row fetch of SPAN = 1284 entries, one entry
per cycle, overlapped with the 1280 emits, inside the 1650 clocks a 720p line
has. That is the real-time budget and it is met by construction; what is not yet
measured is whether the SDRAM delivers a row in 1284 cycles, which is
integration's question.

## Attribution

The pack is built from OpenTopoMap tiles. A shipped core or pack must carry:
"(c) OpenStreetMap contributors, SRTM | Map style (c) OpenTopoMap (CC-BY-SA)".
OpenTopoMap tiles are CC-BY-SA 4.0 and the underlying data is ODbL 1.0. The tile
cache is not part of this repository and the served tiles are not redistributed
here.

## Licence

GPL-3.0-only. `fpga/tinymaps/hdmi/` and `pll/` derive from nestang by
nand2mario (GPL-3.0), and the open-flow scripts derive from TinyTang's
`tools/desktop_open`. The pack builder `tools/maps_pack.py` is MIT.
