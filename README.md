# TinyMaps

A map viewer core for TinyTang. Pan and zoom a pre-rendered OpenTopoMap-style
raster held in the dock SDRAM, at 1280x720.

Target: GW5AST-LV138PG484AC1/I0, revision C, open flow (yosys, nextpnr-himbaechel
and the apicula fork).

## State

Pre-hardware. The pack builder works and its output is verified; no gateware has
been written yet.

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

## Attribution

The pack is built from OpenTopoMap tiles. A shipped core or pack must carry:
"(c) OpenStreetMap contributors, SRTM | Map style (c) OpenTopoMap (CC-BY-SA)".
OpenTopoMap tiles are CC-BY-SA 4.0 and the underlying data is ODbL 1.0. The tile
cache is not part of this repository and the served tiles are not redistributed
here.

## Licence

TBD.
