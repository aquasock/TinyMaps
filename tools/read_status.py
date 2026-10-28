#!/usr/bin/env python3
"""Ask TinyMaps what the renderer is being told.

Command 0x0C is answered with twenty-one raw bytes, not a frame, because the
pipe a host uses is raw:

    0-3   level base (u32)        4-5   width (u16)      6-7  height (u16)
    8-11  step (u32, Q16.16)      12-15  origin x (i32)  16-19 origin y (i32)
    20    the renderer's line-engine state

    tools/read_status.py

Byte 20 is the renderer's state, 21 whether the picture is coming from the
pool, and 22 how many tile requests are waiting to go out.

State is 0 idle, 1 plan, 2 blocking fetch, 3 fetch, 4 emit, 5 done.  A picture
that freezes into one repeated row means the renderer is drawing the same source
line every time; these numbers say whether the step, the origin or the level
caused it.
"""
import argparse
import os
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load_image import frame, open_pipe  # noqa: E402

CMD_STATUS = 0x0C
STATES = {0: "idle", 1: "plan", 2: "blocking fetch", 3: "fetch", 4: "emit", 5: "done"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false", default=True)
    args = ap.parse_args()

    port = serial.Serial(args.port, args.baud, timeout=0.05)
    try:
        if args.tinytang:
            open_pipe(port, True)
        port.write(frame(b"\x00", CMD_STATUS))     # one dummy byte: a bare command is dropped
        got = b""
        end = time.monotonic() + 3.0
        while len(got) < 30 and time.monotonic() < end:
            got += port.read(64)
    finally:
        port.close()

    if len(got) < 30:
        print(f"FAILED: {len(got)} of 30 bytes back: {got.hex()}")
        return 1

    base, w, h, step, x0, y0, st = struct.unpack("<IHHIII", got[:20]) + (got[20],)
    print(f"level base {base & 0x1FF_FFFF:#08x}  {w}x{h}")
    print(f"step       {step} ({(step or 0)/65536:.4f} source px per output px)")
    print(f"origin     x {x0/65536:.2f}  y {y0/65536:.2f}   (raw {x0}, {y0})")
    print(f"renderer   {STATES.get(st, st)}")
    print(f"source     {'tile pool' if got[21] else 'the pack'}")
    print(f"requests   {got[22]} waiting")
    level = got[24] & 3
    tx, ty = got[25] & 0x7F, got[26] & 0x7F
    addr = got[27] | (got[28] << 8) | (got[29] << 16)
    print(f"fallback   {'yes: drawing the level below' if (got[23] & 2) else 'no: drawing the view level'}")
    print(f"last hit   L{level} tile {tx},{ty} at pool {addr:#08x} "
          f"(slot {(addr - 0x01C00000) // 16384 if addr >= 0x01C00000 else -1})")
    print(f"           the table's slot for that tile is "
          f"{(tx + 13 * ty + level) % 256}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
