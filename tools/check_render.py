#!/usr/bin/env python3
"""Independent reference for tb_maps_render.

Recomputes every case the testbench ran, from the parameters the testbench
wrote out, and compares against the pixels it captured.  Nearest sampling only;
the renderer's arithmetic is reproduced here from the same Q16.16 integers, not
from its implementation.

Exit 0 on an exact match, 1 otherwise.
"""
import sys
import numpy as np

OUT_W, OUT_H = None, None

def main():
    cases = [l.split() for l in open("build/sim/render_cases.txt") if l.strip()]
    raw = np.fromfile("build/sim/render_out.bin", dtype=np.uint8)
    pix = raw.reshape(-1, 3)

    # the level the testbench built
    lvl_w = int(cases[0][6]); lvl_h = int(cases[0][7]); out_w = int(cases[0][8])
    out_h = 48
    ys, xs = np.mgrid[0:lvl_h, 0:lvl_w]
    level = ((ys * 3 + xs * 5) & 0xFF).astype(np.uint8)
    pal = np.zeros((256, 3), np.uint8)
    v = np.arange(256, dtype=np.uint8)
    pal[:, 0] = v
    pal[:, 1] = v ^ 0x55
    pal[:, 2] = v ^ 0xAA

    total = len(cases) * out_w * out_h
    if len(pix) != total:
        print(f"FAIL: captured {len(pix)} pixels, expected {total}")
        return 1

    at = 0
    bad = 0
    for c in cases:
        idx, sx, sy, stx, sty = (int(c[i]) for i in range(5))
        oy = np.arange(out_h, dtype=np.int64)
        ox = np.arange(out_w, dtype=np.int64)
        rows = ((sy + oy * sty) >> 16)
        cols = ((sx + ox * stx) >> 16)
        rows = np.clip(rows, 0, lvl_h - 1)
        cols = np.clip(cols, 0, lvl_w - 1)
        expect = pal[level[np.ix_(rows, cols)]]

        got = pix[at:at + out_w * out_h].reshape(out_h, out_w, 3)
        at += out_w * out_h
        d = np.abs(got.astype(np.int16) - expect.astype(np.int16))
        n = int((d.max(axis=2) != 0).sum())
        if n:
            i, j = np.unravel_index(int((d.max(axis=2) != 0).argmax()), (out_h, out_w))
            print(f"  case {idx}: {n} of {out_w*out_h} pixels differ, "
                  f"first at ({j},{i}) got {tuple(got[i,j])} want {tuple(expect[i,j])}")
            bad += 1
        else:
            print(f"  case {idx}: {out_w*out_h} pixels match"
                  f"  (src {sx/65536:.3f},{sy/65536:.3f} step {stx/65536:.3f})")
    print("RENDER CHECK:", "PASS" if bad == 0 else f"FAIL ({bad} cases)")
    return 0 if bad == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
