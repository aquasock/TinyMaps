#!/usr/bin/env python3
"""Write a known test image for the loader.

The image is a 768x768 raster of eight-bit palette indices: a 12 by 12 grid of
flat 64x64 cells whose values step down from 255 at the top left to 0 at the
bottom right, inside a four-pixel border of 255.  At the viewport the core ships
with -- 0.6 source pixels per output pixel, level 768 wide -- the grid fills the
1280-pixel line, every cell is about 107 pixels across, and the picture is a
staircase that gets darker to the right and downwards.

That is enough to see whether the loader put the bytes where the renderer reads
them, and which way round: a mirrored, transposed or half-loaded image does not
look like this.

    tools/maps_test_image.py                 # work/test/test-image.bin
    tools/maps_test_image.py -o /tmp/x.bin

SPDX-License-Identifier: MIT
"""
import argparse
import os
import sys

SIZE = 768
CELLS = 12
CELL = SIZE // CELLS          # 64
BORDER = 4
WHITE = 255


def build():
    img = bytearray([WHITE]) * (SIZE * SIZE)
    for row in range(CELLS):
        for col in range(CELLS):
            # 255 at the top left, 0 at the bottom right, one step per cell
            value = 255 - (row * CELLS + col) * 255 // (CELLS * CELLS - 1)
            y0 = row * CELL
            x0 = col * CELL
            for y in range(y0, y0 + CELL):
                base = y * SIZE
                img[base + x0:base + x0 + CELL] = bytes([value]) * CELL
    # the border goes on last so it stays white over the corner cells
    for y in range(SIZE):
        base = y * SIZE
        if y < BORDER or y >= SIZE - BORDER:
            img[base:base + SIZE] = bytes([WHITE]) * SIZE
        else:
            img[base:base + BORDER] = bytes([WHITE]) * BORDER
            img[base + SIZE - BORDER:base + SIZE] = bytes([WHITE]) * BORDER
    return bytes(img)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="work/test/test-image.bin")
    args = ap.parse_args()

    img = build()
    parent = os.path.dirname(args.output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(img)
    print(f"{args.output}: {SIZE}x{SIZE} eight-bit indices, {len(img)} bytes")
    print(f"  {CELLS}x{CELLS} cells of {CELL}x{CELL} px, values 255 down to 0 "
          f"from the top left, {BORDER}-pixel white border")
    return 0


if __name__ == "__main__":
    sys.exit(main())
