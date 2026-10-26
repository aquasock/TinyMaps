#!/usr/bin/env python3
"""Ask TinyMaps what the renderer is being told.

Command 0x0C is answered with twenty-one raw bytes, not a frame, because the
pipe a host uses is raw:

    0-3   level base (u32)        4-5   width (u16)      6-7  height (u16)
    8-11  step (u32, Q16.16)      12-15  origin x (i32)  16-19 origin y (i32)
    20    the renderer's line-engine state

    tools/read_status.py

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
        while len(got) < 21 and time.monotonic() < end:
            got += port.read(64)
    finally:
        port.close()

    if len(got) < 21:
        print(f"FAILED: {len(got)} of 21 bytes back: {got.hex()}")
        return 1

    base, w, h, step, x0, y0, st = struct.unpack("<IHHIII", got[:20]) + (got[20],)
    print(f"level base {base:#08x}  {w}x{h}")
    print(f"step       {step} ({(step or 0)/65536:.4f} source px per output px)")
    print(f"origin     x {x0/65536:.2f}  y {y0/65536:.2f}   (raw {x0}, {y0})")
    print(f"renderer   {STATES.get(st, st)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
