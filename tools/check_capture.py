#!/usr/bin/env python3
"""Compare a capture of the Tang's picture against what the pack says it should be.

  check_capture.py <pack> <capture.png> [--level N] [--x X] [--y Y] [--step S]

The viewport is the one the core was told (`set_view.py --level N`), so the
reference is built from the pack exactly the way the renderer is supposed to walk
it: output pixel (x, y) reads the level at (src_x0 + x*step, src_y0 + y*step), and
at step 1.0 that is one level pixel per output pixel.

It reports the overall disagreement, then where it is: a per-row and per-column
error profile says whether the picture is shifted, banded or spotty, and a vertical
shift search says whether the rows are right at all.  That is the difference
between "the picture is wrong" and "the rows are off by three", which is what the
last several hardware runs needed and did not have.

SPDX-License-Identifier: MIT
"""
import argparse
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, __file__.rsplit("/", 2)[0] + "/tools")
import maps_pack


def reference(pk, level, src_x0, src_y0, step, w, h):
    lv = pk["levels"][level]
    data = pk["data"]
    rec = pk["rec"]
    pal = np.frombuffer(pk["pal"], np.uint8).reshape(256, 3).astype(np.int16)
    ts = pk["tsize"]
    first = lv["first"]
    grid_x = lv["tx"]

    out = np.zeros((h, w, 3), np.int16)
    cols = src_x0 + (np.arange(w) * step).astype(np.int64)
    rows = src_y0 + (np.arange(h) * step).astype(np.int64)
    for y in range(h):
        r = rows[y]
        ty = r // ts
        row_in = r % ts
        for x in range(w):
            c = cols[x]
            tx = c // ts
            k = first + ty * grid_x + tx
            if ty >= lv["ty"] or tx >= grid_x:
                continue
            off = k * rec + row_in * ts + (c % ts)
            out[y, x] = pal[data[off]]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pack")
    ap.add_argument("capture")
    ap.add_argument("--level", type=int, default=0)
    ap.add_argument("--x", type=float, default=1664.0)
    ap.add_argument("--y", type=float, default=1944.0)
    ap.add_argument("--step", type=float, default=1.0)
    args = ap.parse_args()

    pk = maps_pack.read_tiles(args.pack)
    cap = np.asarray(Image.open(args.capture).convert("RGB"), np.int16)
    h, w = cap.shape[:2]
    ref = reference(pk, args.level, round(args.x), round(args.y), args.step, w, h)

    # The capture card lifts the levels -- the handoff says so plainly -- so an
    # absolute difference measures the card, not the picture.  Standardise each
    # image instead and compare structure.
    def std(x):
        x = x.astype(np.float32)
        m = x.mean(axis=(0, 1), keepdims=True)
        sd = x.std(axis=(0, 1), keepdims=True) + 1e-6
        return (x - m) / sd

    ref_n, cap_n = std(ref), std(cap)
    best = None
    for dy in range(-8, 9):
        shifted = np.roll(ref_n, dy, axis=0)
        d = np.abs(shifted - cap_n).mean()
        if best is None or d < best[1]:
            best = (dy, d)
    print(f"picture {w}x{h}, reference from {args.pack} level {args.level} "
          f"at ({args.x:.0f},{args.y:.0f}) step {args.step}")
    print(f"vertical shift that fits best: {best[0]:+d} pixels "
          f"(mean abs {best[1]:.1f}/255)")

    ref_s = np.roll(ref_n, best[0], axis=0)
    err = np.abs(ref_s - cap_n).mean(axis=2)
    # per-row and per-column disagreement, to say whether it is banded
    rows = err.mean(axis=1)
    cols = err.mean(axis=0)
    print(f"standardised mean abs error {err.mean():.3f} "
          f"(0 is perfect, 1 is unrelated), median {np.median(err):.3f}")
    print(f"worst rows:   {np.argsort(rows)[-8:][::-1].tolist()} "
          f"(error {rows.max():.2f})")
    print(f"worst columns:{np.argsort(cols)[-8:][::-1].tolist()} "
          f"(error {cols.max():.2f})")
    print(f"rows whose error is under 0.5: {(rows < 0.5).sum()} of {h}")
    print(f"columns whose error is under 0.5: {(cols < 0.5).sum()} of {w}")
    # is the error concentrated at tile boundaries (128 pixels apart)?
    edges = [c for c in range(w) if c % 128 in (0, 1, 126, 127)]
    inside = [c for c in range(w) if c % 128 not in (0, 1, 126, 127)]
    print(f"mean error at tile edges {cols[edges].mean():.1f}, "
          f"inside tiles {cols[inside].mean():.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
