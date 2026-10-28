#!/usr/bin/env python3
"""Write a tile pack whose tiles name themselves, for diagnosing the picture.

  maps_pattern_pack.py [<out>] [--tile 128] [--levels 4]

Every tile is flat colour keyed to its own coordinates, with a white border on its
top and left edges and a small binary code in its top-left corner giving the
tile's `tx` and `ty`.  That makes the screen itself a measurement: a tile drawn in
the wrong place, a row stride that shears, a window base that is off, or a tile
whose bytes landed somewhere else all show up as something you can read, instead
of as plausible-looking map texture that nobody can interpret.

The container is the same one `maps_pack.py tiles` writes, so `serve_tiles.py`
serves it and `maps_pack.py verify-tiles` checks it without knowing the
difference.  The level grids match the real pack's, so the same viewport applies.

Reading a capture: the palette is a ramp, so an index is recoverable from its
colour, and the corner code names the tile.  `check_capture.py` compares against
the real pack; this pack is for looking at and for decoding by hand or by script.

SPDX-License-Identifier: MIT
"""
import argparse
import os
import struct
import sys
import zlib

import numpy as np

SIZE = 128              # pixels across a tile
THDR, TENT = 68, 40
PAL_ENTRIES = 256


def palette():
    """256 distinct entries; the index is recoverable from the colour because the
    three channels step by different odd amounts."""
    pal = bytearray()
    for i in range(PAL_ENTRIES):
        pal += bytes(((i * 37) & 0xFF, (i * 73) & 0xFF, (i * 109) & 0xFF))
    return bytes(pal)


def code(level, tx, ty):
    return (tx + 7 * ty + 31 * level) & 0xFF


def tile(level, tx, ty, size):
    """Flat colour, white top and left border, and the coordinates in binary in
    the corner: tx in the first four cells, ty in the next four."""
    im = np.full((size, size), code(level, tx, ty), np.uint8)
    im[0, :] = 255                      # top border
    im[:, 0] = 255                      # left border
    cell = max(4, size // 16)
    for bit in range(4):
        c = 2 + bit * (cell + 1)
        if not (tx >> bit) & 1:
            im[c:c + cell, 2:2 + cell] = 0
        else:
            im[c:c + cell, 2:2 + cell] = 255
        if not (ty >> bit) & 1:
            im[2:2 + cell, c:c + cell] = 0
        else:
            im[2:2 + cell, c:c + cell] = 255
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default="work/pack/pattern-8bpp-128.tmtl")
    ap.add_argument("--tile", type=int, default=SIZE)
    ap.add_argument("--levels", type=int, default=4)
    args = ap.parse_args()
    t = args.tile
    if t & (t - 1) or t < 64 or t > 512:
        sys.exit("--tile must be a power of two from 64 to 512")

    # the real pack's level geometry, so the same viewport and the same tiles
    live = [(4608, 4608), (2304, 2432), (1152, 1216), (832, 864)]
    zooms = [15, 14, 13, 12]
    mpps = [4777, 9555, 19109, 38219]
    origins = [(-12486753, 3966165)] * 4

    grids = [((w + t - 1) // t, (h + t - 1) // t) for w, h in live[:args.levels]]
    first, n = [], 0
    for gx, gy in grids:
        first.append(n)
        n += gx * gy

    rec = t * t
    pal = palette()
    doff = THDR + TENT * args.levels + len(pal)
    body = bytearray()
    for level, (gx, gy) in enumerate(grids):
        for ty in range(gy):
            for tx in range(gx):
                body += tile(level, tx, ty, t).tobytes()

    hdr = bytearray(THDR)
    struct.pack_into("<4sHHIBBHIIII", hdr, 0, b"TMTL", 2, args.levels,
                     t, 8, 0, 0, rec, rec, doff, doff + len(body))
    hdr[36:68] = f"pattern {t}px 8bpp".encode().ljust(32, b"\0")[:32]
    tbl = bytearray()
    for i, ((gx, gy), f) in enumerate(zip(grids, first)):
        tbl += struct.pack("<IIIIiiII", gx, gy, zooms[i],
                           int(round(mpps[i])), origins[i][0], origins[i][1],
                           f, 0) + b"\0" * 8
    assert len(tbl) == TENT * args.levels
    hdr[32:36] = b"\0\0\0\0"
    crc = zlib.crc32(bytes(hdr) + bytes(tbl) + pal + bytes(body))
    struct.pack_into("<I", hdr, 32, crc)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(hdr); f.write(tbl); f.write(pal); f.write(body)
    print(f"wrote {args.out}: {doff + len(body)} bytes, {n} tiles, "
          f"{t}px, one colour per tile, coordinates coded in the corner")
    for i, ((gx, gy), f) in enumerate(zip(grids, first)):
        print(f"  L{i} z{zooms[i]}: {gx}x{gy} = {gx*gy} tiles from {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
