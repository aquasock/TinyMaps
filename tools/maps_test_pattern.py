#!/usr/bin/env python3
"""Write a static diagnostic pattern for the renderer, and the palette it needs.

Two files, both deterministic:

- the index raster, 1280x1280, laid out so that any addressing error shows up as
  a wrong *place* rather than a slightly wrong colour;
- the palette, 256 entries, so that a given index always means the same colour
  and a capture can be compared against what was sent without guessing.

The top of the image is the part that matters here: the first thirty-two rows
are one-pixel horizontal stripes alternating black and white, so a frame whose
top rows come from the wrong place looks obviously striped wrong, and the
neighbouring rows differ by a full white-to-black step, which is the most
sensitive test of a row address there is.  Below that: a one-pixel chequerboard,
colour bars, a grey ramp, one-pixel vertical lines, and a ruler grid.

    tools/maps_test_pattern.py                       # work/test/pattern.*
    tools/maps_test_pattern.py -o work/test/tp

SPDX-License-Identifier: MIT
"""
import argparse
import os
import struct
import sys

W, H = 1280, 1280
BLACK, WHITE = 0, 255


def palette():
    """256 entries where every index is a different colour, and 0/255 are black/white."""
    pal = bytearray()
    for i in range(256):
        if i == BLACK:
            pal += bytes([0, 0, 0])
        elif i == WHITE:
            pal += bytes([255, 255, 255])
        else:
            pal += bytes([i, (i * 5) & 0xFF, 255 - i])
    return bytes(pal)


def image():
    img = bytearray([BLACK]) * (W * H)

    def put(x, y, v):
        img[y * W + x] = v

    def fill(x0, y0, x1, y1, v):
        for y in range(y0, y1):
            row = y * W
            img[row + x0:row + x1] = bytes([v]) * (x1 - x0)

    # rows 0-31: one-pixel horizontal stripes, the row-address test
    for y in range(0, 32):
        fill(0, y, W, y + 1, WHITE if (y & 1) else BLACK)

    # rows 32-63: one-pixel chequerboard
    for y in range(32, 64):
        for x in range(W):
            put(x, y, WHITE if ((x + y) & 1) else BLACK)

    # rows 64-191: eight colour bars, 160 pixels each
    for b in range(8):
        fill(b * 160, 64, (b + 1) * 160, 192, 1 + b)

    # rows 192-319: grey ramp, five pixels a step
    for x in range(W):
        fill(x, 192, x + 1, 320, (x // 5) & 0xFF)

    # rows 320-447: one-pixel vertical lines, the column-address test
    for y in range(320, 448):
        for x in range(W):
            put(x, y, WHITE if (x & 1) else BLACK)

    # rows 448-1279: a 32-pixel ruler grid, so a position can be named by eye
    for y in range(448, H):
        for x in range(W):
            v = 64 + ((x // 32 + y // 32) % 8) * 24
            if (x % 32 == 0) or (y % 32 == 0):
                v = WHITE
            put(x, y, v)

    # a one-pixel white border so the level's edges are unambiguous
    for x in range(W):
        put(x, 0, WHITE); put(x, H - 1, WHITE)
    for y in range(H):
        put(0, y, WHITE); put(W - 1, y, WHITE)
    return bytes(img)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="work/test/pattern")
    args = ap.parse_args()
    parent = os.path.dirname(args.output)
    if parent:
        os.makedirs(parent, exist_ok=True)

    open(args.output + ".pal", "wb").write(palette())
    open(args.output + ".idx", "wb").write(image())
    print(f"{args.output}.idx  {W}x{H} indices, {W*H} bytes")
    print(f"{args.output}.pal  256 RGB entries, 768 bytes")
    print("  rows 0-31 stripes, 32-63 chequerboard, 64-191 colour bars,")
    print("  192-319 grey ramp, 320-447 vertical lines, 448+ ruler grid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
