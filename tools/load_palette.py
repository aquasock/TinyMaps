#!/usr/bin/env python3
"""Send a palette to TinyMaps over the Tang's USB console.

The core's loader parses command 0x08 out of the link's 0xAA frames:

    u16 start    first entry to write, 0-255
    u16 count    entries that follow
    count * 3    R, G, B for each entry, ascending index
    u32 crc      CRC-32 over the bytes above, complemented

It answers ACK 0x06, or NAK 0x15 then 'P' for a bad CRC.  Entries are written
as their third byte arrives, so a refused palette has already been applied; the
sender re-sends it and every entry is written again, which is harmless.

    tools/load_palette.py                          # the pack's own palette
    tools/load_palette.py --pack work/pack/x.tmpk
    tools/load_palette.py --rgb my.rgb             # 768 bytes, 256 RGB triples

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

CMD_PALETTE = 0x08


def palette_from_pack(path):
    """The 256-entry RGB table out of a pack, checked against its header CRC."""
    b = open(path, "rb").read()
    magic, _ver, _nlev, pal_off, pal_len, _total, _hc = struct.unpack_from("<4sHHIIII", b, 0)
    if magic != b"TMPK":
        raise SystemExit(f"{path} is not a pack")
    pal = b[pal_off:pal_off + pal_len]
    if len(pal) != 768:
        raise SystemExit(f"pack palette is {len(pal)} bytes, expected 768")
    return pal


def payload_for(rgb, start=0):
    count = len(rgb) // 3
    body = struct.pack("<HH", start, count) + rgb
    return body + struct.pack("<I", zlib.crc32(body) & 0xFFFF_FFFF)


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--pack", default="work/pack/phoenix-18km.tmpk")
    src.add_argument("--rgb", help="768 bytes of RGB triples instead of a pack")
    ap.add_argument("--start", type=int, default=0, help="first entry (default 0)")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false", default=True,
                    help="the port already reaches the core's UART")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    if args.rgb:
        rgb = open(args.rgb, "rb").read()
        what = args.rgb
    else:
        rgb = palette_from_pack(args.pack)
        what = args.pack

    payload = payload_for(rgb, args.start)
    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        if args.tinytang:
            open_pipe(port, args.quiet)
        port.write(frame(payload, CMD_PALETTE))
        read_reply(port, 5.0)
    except RuntimeError as error:
        print(f"FAILED: {error}")
        return 1
    finally:
        port.close()
    print(f"palette: {len(rgb)//3} entries from {what} at index {args.start}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
