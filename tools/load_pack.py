#!/usr/bin/env python3
"""Load a whole map pack into TinyMaps over the Tang's USB console.

Sends the pack's palette with command 0x08 and then each level's raster with
command 0x07 at the level's own byte offset, so the SDRAM ends up laid out as
the pack says and `tools/set_view.py` can select a level by number.

    tools/load_pack.py                      # work/pack/phoenix-18km.tmpk
    tools/load_pack.py --levels 3           # just the coarsest

28 MiB at the link's 190 kB/s is about two and a half minutes; that is the
loader's rate, not the card's.

SPDX-License-Identifier: MIT
"""
import argparse
import os
import struct
import sys

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load_image import frame, open_pipe, read_reply, load  # noqa: E402
from load_palette import CMD_PALETTE, palette_from_pack, payload_for  # noqa: E402

HDR, ENT = 56, 40


def levels_of(path):
    """(index, offset, width, height, bytes) for each level, from the header.

    Refuses a pack whose levels do not share one origin.  The navigation in the
    fabric crosses levels by doubling or halving the source coordinates, which
    is only true of a shared origin; a pack cut on each zoom's own tile grid
    makes the picture jump at every crossing, and the board has no way to know
    or correct it -- the level table carries no origin.  So the check lives
    here, before anything is sent.
    """
    b = open(path, "rb").read()
    magic, _ver, nlev, _po, _pl, total, _hc = struct.unpack_from("<4sHHIIII", b, 0)
    if magic != b"TMPK":
        raise SystemExit(f"{path} is not a pack")
    out, origins = [], set()
    for i in range(nlev):
        off, w, h, _mpp, _z, ox, oy = struct.unpack_from("<IIIIIii", b, HDR + ENT*i)
        origins.add((ox, oy))
        out.append((i, off, w, h, b[off:off + w*h]))
    if len(origins) != 1:
        raise SystemExit(
            f"{path} is not aligned: its levels have {len(origins)} different origins "
            f"{sorted(origins)}.  Each level must start at one shared ground point "
            "or a level crossing will jump the centre; rebuild it with tools/maps_pack.py.")
    return out, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default="work/pack/phoenix-18km.tmpk")
    ap.add_argument("--levels", default="all",
                    help="'all' or a comma-separated list, e.g. 2,3")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false", default=True)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    levels, total = levels_of(args.pack)
    want = ([l[0] for l in levels] if args.levels == "all"
            else [int(x) for x in args.levels.split(",")])

    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        if args.tinytang:
            open_pipe(port, args.quiet)
        port.write(frame(payload_for(palette_from_pack(args.pack)), CMD_PALETTE))
        read_reply(port, 5.0)
        if not args.quiet:
            print("palette: 256 entries")
        for idx, off, w, h, raster in levels:
            if idx not in want:
                continue
            load(port, raster, off, 3, args.quiet)
            if not args.quiet:
                print(f"level {idx}: {w}x{h} at {off:#08x}")
    except RuntimeError as error:
        print(f"FAILED: {error}")
        return 1
    finally:
        port.close()
    print(f"loaded levels {want} of {args.pack} ({total / 1048576:.2f} MiB pack)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
