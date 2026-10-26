#!/usr/bin/env python3
"""Independent reference for tb_maps_render.

Recomputes every case the testbench ran, from the parameters it wrote out, and
compares against the pixels it captured.  The arithmetic is reproduced from the
same Q16.16 integers the hardware takes, including the renderer's rounding lerp,
so a match means the datapath agrees, not that two implementations agree on a
formula nobody checked.

Exit 0 on an exact match, 1 otherwise.
"""
import sys
import numpy as np

def blend(a, b, w):
    """elementwise lerp matching maps_render's blend(): 8-bit ends, 16-bit weight"""
    a = a.astype(np.int64); b = b.astype(np.int64); w = w.astype(np.int64)
    return ((a * (0xFFFF - w) + b * w + 0x8000) >> 16).astype(np.uint8)

def main():
    cases = [l.split() for l in open("build/sim/render_cases.txt") if l.strip()]
    pix = np.fromfile("build/sim/render_out.bin", dtype=np.uint8).reshape(-1, 3)

    lvl_w = int(cases[0][7]); lvl_h = int(cases[0][8]); out_w = int(cases[0][9])
    out_h = 48
    ys, xs = np.mgrid[0:lvl_h, 0:lvl_w]
    level = ((ys * 3 + xs * 5) & 0xFF).astype(np.uint8)
    pal = np.zeros((256, 3), np.uint8)
    v = np.arange(256, dtype=np.uint8)
    pal[:, 0] = v; pal[:, 1] = v ^ 0x55; pal[:, 2] = v ^ 0xAA

    total = len(cases) * out_w * out_h
    if len(pix) != total:
        print(f"FAIL: captured {len(pix)} pixels, expected {total}")
        return 1

    at = 0; bad = 0
    for c in cases:
        idx, sx, sy, stx, sty, bil = (int(c[i]) for i in range(6))
        oy = np.arange(out_h, dtype=np.int64)
        ox = np.arange(out_w, dtype=np.int64)
        syq = sy + oy * sty                      # Q16.16 per line
        sxq = sx + ox * stx                      # Q16.16 per column
        rows = (syq >> 16)
        cols = (sxq >> 16)
        r1 = np.minimum(rows + 1, lvl_h - 1)
        c1 = np.minimum(cols + 1, lvl_w - 1)
        rows = np.clip(rows, 0, lvl_h - 1); cols = np.clip(cols, 0, lvl_w - 1)
        c1 = np.clip(c1, 0, lvl_w - 1)

        if bil:
            fx = (sxq & 0xFFFF)
            wy = (syq & 0xFFFF)
            a0 = level[np.ix_(rows, cols)]; a1 = level[np.ix_(rows, c1)]
            b0 = level[np.ix_(r1,   cols)]; b1 = level[np.ix_(r1,   c1)]
            fxm = np.broadcast_to(fx.reshape(1, -1), (out_h, out_w))
            wym = np.broadcast_to(wy.reshape(-1, 1), (out_h, out_w))
            h0 = blend(a0, a1, fxm); h1 = blend(b0, b1, fxm)
            idxs = blend(h0, h1, wym)
        else:
            idxs = level[np.ix_(rows, cols)]

        expect = pal[idxs]
        got = pix[at:at + out_w * out_h].reshape(out_h, out_w, 3)
        at += out_w * out_h
        d = np.abs(got.astype(np.int16) - expect.astype(np.int16))
        n = int((d.max(axis=2) != 0).sum())
        kind = "bilinear" if bil else "nearest "
        if n:
            i, j = np.unravel_index(int((d.max(axis=2) != 0).argmax()), (out_h, out_w))
            print(f"  case {idx} {kind} step {stx/65536:.3f}: {n} of {out_w*out_h} differ, "
                  f"first at ({j},{i}) got {tuple(got[i,j])} want {tuple(expect[i,j])}")
            bad += 1
        else:
            print(f"  case {idx} {kind} step {stx/65536:.3f}: {out_w*out_h} pixels match")
    print("RENDER CHECK:", "PASS" if bad == 0 else f"FAIL ({bad} cases)")
    return 0 if bad == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
