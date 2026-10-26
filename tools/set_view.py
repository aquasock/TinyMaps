#!/usr/bin/env python3
"""Select a level and a view in TinyMaps, over the Tang's USB console.

The core's command 0x0A takes a whole viewport:

    u32 level_base   byte address of the level's first pixel
    u16 level_w       } one word, width low
    u16 level_h
    u32 step         Q16.16 source pixels per output pixel
    u32 src_x0       Q16.16 level pixel at output x = 0
    u32 src_y0
    u32 crc          over the twenty bytes above, complemented

and refuses it with NAK 'V' unless 0.5 < step <= 1 and the level fits in the
SDRAM.  That range is the renderer's, not this tool's politeness: above 1 a
source row can advance by two per output line and the row rotation cannot
engage, and at or below 0.5 the next finer level is the right one to show.

The step for a level is chosen so the picture is either 1:1 or, if the level is
narrower than the screen, magnified to fill it -- 768 columns across 1280 is
0.6.  So each level is shown at its own scale, which is what makes switching
between them look like zooming.

    tools/set_view.py --level 3                 # the 768x768 one, filling
    tools/set_view.py --level 0 --x 2000 --y 900
    tools/set_view.py --level 1 --step 0.75

SPDX-License-Identifier: MIT
"""
import argparse
import os
import struct
import sys
import zlib

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load_image import frame, open_pipe, read_reply  # noqa: E402

CMD_VIEW = 0x0A
OUT_W, OUT_H = 1280, 720
HDR, ENT = 56, 40
STEP_MIN, STEP_MAX = 0x8000 + 1, 0x10000        # (0.5, 1.0] in Q16.16


def levels_of(path):
    b = open(path, "rb").read()
    if b[:4] != b"TMPK":
        raise SystemExit(f"{path} is not a pack")
    nlev = struct.unpack_from("<H", b, 6)[0]
    out = []
    for i in range(nlev):
        off, w, h, mpp, z = struct.unpack_from("<IIIII", b, HDR + ENT*i)
        out.append(dict(index=i, base=off, w=w, h=h, mpp=mpp/65536.0, zoom=z))
    return out


def viewport_for(level, x=None, y=None, step=None):
    """The viewport that shows this level, centred on (x, y) level pixels."""
    w, h = level["w"], level["h"]
    q = step if step is not None else min(1.0, w / OUT_W)
    q_q16 = int(round(q * 65536))
    if not STEP_MIN <= q_q16 <= STEP_MAX:
        raise SystemExit(f"step {q:.4f} is outside (0.5, 1]; pick another level")

    cx = w / 2 if x is None else x
    cy = h / 2 if y is None else y
    x0 = int(round(cx * 65536 - (OUT_W / 2) * q_q16))
    y0 = int(round(cy * 65536 - (OUT_H / 2) * q_q16))
    # keep the window inside the level
    x0 = max(0, min(x0, int(round((w - OUT_W * q) * 65536))))
    y0 = max(0, min(y0, int(round((h - OUT_H * q) * 65536))))
    return s32(x0), s32(y0), q_q16


def s32(v):
    v &= 0xFFFF_FFFF
    return v - (1 << 32) if v >= (1 << 31) else v


def payload(level, x0, y0, q_q16):
    body = struct.pack("<IHHIII", level["base"], level["w"], level["h"],
                       q_q16, x0 & 0xFFFF_FFFF, y0 & 0xFFFF_FFFF)
    return body + struct.pack("<I", zlib.crc32(body) & 0xFFFF_FFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default="work/pack/phoenix-18km.tmpk")
    ap.add_argument("--level", type=int, default=3)
    ap.add_argument("--x", type=int, help="centre, in level pixels")
    ap.add_argument("--y", type=int)
    ap.add_argument("--step", type=float, help="Q16.16 override in (0.5, 1]")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false", default=True)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    levels = levels_of(args.pack)
    if not 0 <= args.level < len(levels):
        raise SystemExit(f"no level {args.level} in {args.pack}")
    lv = levels[args.level]
    x0, y0, q = viewport_for(lv, args.x, args.y, args.step)

    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        if args.tinytang:
            open_pipe(port, args.quiet)
        port.write(frame(payload(lv, x0, y0, q), CMD_VIEW))
        read_reply(port, 5.0)
    except RuntimeError as error:
        print(f"FAILED: {error}")
        return 1
    finally:
        port.close()
    print(f"level {lv['index']} z{lv['zoom']} {lv['w']}x{lv['h']} at {lv['base']:#08x}: "
          f"step {q/65536:.4f}, origin ({x0/65536:.1f}, {y0/65536:.1f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
