#!/usr/bin/env python3
"""Send TinyMaps the pack's level table, so the core can zoom between levels.

Command 0x0B takes a count and then, for each level, its SDRAM byte address,
width and height, with a CRC:

    u8 count, count * { u32 base, u16 w, u16 h }, u32 crc

The core keeps the table and uses it when a zoom runs off the end of its step
range: it steps to the next level and doubles or halves the source coordinates,
which works because the pack's levels are a factor of two apart in metres per
pixel.  Send this once after `load_pack.py`; without it the core still pans and
zooms, but only within the level it is showing.

    tools/set_levels.py

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

CMD_LEVELS = 0x0B
HDR, ENT = 56, 40


def levels_of(path):
    b = open(path, "rb").read()
    if b[:4] != b"TMPK":
        raise SystemExit(f"{path} is not a pack")
    nlev = struct.unpack_from("<H", b, 6)[0]
    out = []
    for i in range(nlev):
        off, w, h = struct.unpack_from("<III", b, HDR + ENT*i)
        out.append((off, w, h))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default="work/pack/phoenix-18km.tmpk")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false", default=True)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    levels = levels_of(args.pack)
    if not 1 <= len(levels) <= 4:
        raise SystemExit(f"{len(levels)} levels; the core holds four")
    body = bytes([len(levels)])
    for off, w, h in levels:
        body += struct.pack("<IHH", off, w, h)
    payload = body + struct.pack("<I", zlib.crc32(body) & 0xFFFF_FFFF)

    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        if args.tinytang:
            open_pipe(port, args.quiet)
        port.write(frame(payload, CMD_LEVELS))
        read_reply(port, 5.0)
    except RuntimeError as error:
        print(f"FAILED: {error}")
        return 1
    finally:
        port.close()
    for i, (off, w, h) in enumerate(levels):
        print(f"level {i}: {w}x{h} at {off:#08x}")
    print(f"level table sent ({len(levels)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
