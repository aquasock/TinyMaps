#!/usr/bin/env python3
"""Answer the core's tile requests from a tile pack, over the BL616 link.

  serve_tiles.py <pack> [--port /dev/ttyUSB0] [--baud 2000000]
                        [--blocks 1024] [--count N] [--no-prepare] [--quiet]

This is the host half of streaming.  The core asks for a tile with command 0x1C,
`AA 00 06 1C L TXL TXH TYL TYH`, and the answer is the tile's bytes as a run of
command 0x1D blocks -- nine header bytes, the block, a CRC-32, answered ACK or NAK
'D'.  Neither direction acknowledges a request; the core asks again on its own
retry timer if an answer never comes.

Before serving, unless `--no-prepare` is given, it loads the pack's shared palette
with command 0x08 and switches the picture source to the pool with command 0x1E.
An eight-bit pack has one palette for the whole pack, and that palette is the
table the fabric's pixel path reads, so this is what makes a streamed tile look
like itself rather than grey.

Only eight-bit packs are served: a four-bit pack carries a palette per tile, and
the pixel path reads eight-bit indices, so serving one would paint the picture
with the wrong colours and no error.  The tool refuses instead.  The tile size
comes out of the pack's header, so a 128-pixel pack (16 KiB a tile, four times as
many slots in the same pool) is served the same way as a 256-pixel one.

SPDX-License-Identifier: MIT
"""
import argparse
import os
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import serial
except ImportError:                                        # pragma: no cover
    sys.exit("pyserial is required: pip install pyserial")

import load_image as li
import maps_pack

CMD_TILE_REQ = 0x1C
CMD_TILE_BLOCK = 0x1D
CMD_PALETTE = 0x08
CMD_SOURCE = 0x1E
ACK, NAK = 0x06, 0x15

HDR_BYTES = 9                   # level, tx, ty, offset, count
BLOCK_MAX = 2032                # payload the receiver's frame limit allows


def crc32(data):
    return zlib.crc32(data) & 0xFFFF_FFFF


def request(frame):
    """(level, tx, ty) from a 0x1C frame, or None if it is not one."""
    if len(frame) != 9 or frame[0] != 0xAA or frame[3] != CMD_TILE_REQ:
        return None
    level = frame[4]
    tx = frame[5] | (frame[6] << 8)
    ty = frame[7] | (frame[8] << 8)
    return level, tx, ty


def block(level, tx, ty, offset, payload):
    """One 0x1D frame: header, bytes, CRC-32, all little-endian."""
    head = struct_head(level, tx, ty, offset, len(payload))
    body = head + payload
    return li.frame(body + crc32(body).to_bytes(4, "little"), CMD_TILE_BLOCK)


def struct_head(level, tx, ty, offset, count):
    return (bytes([level]) + tx.to_bytes(2, "little") + ty.to_bytes(2, "little")
            + offset.to_bytes(2, "little") + count.to_bytes(2, "little"))


def tile_bytes(pk, level, tx, ty):
    """The tile's own bytes out of the pack, or None if there is no such tile."""
    if level >= len(pk["levels"]):
        return None
    lv = pk["levels"][level]
    if tx >= lv["tx"] or ty >= lv["ty"]:
        return None
    first = lv["first"] + ty * lv["tx"] + tx
    start = first * pk["rec"]
    return pk["data"][start:start + pk["rec"]]


def read_frames(port, deadline):
    """Frames arriving from the core: hunt 0xAA, take the length, the command and
    the payload.  Anything else on the line (console text from before the pipe
    opened) is skipped."""
    state, need, buf = "hunt", 0, bytearray()
    while time.monotonic() < deadline:
        chunk = port.read(256)
        if not chunk:
            return
        for b in chunk:
            if state == "hunt":
                if b == 0xAA:
                    buf = bytearray([b]); state = "lenh"
            elif state == "lenh":
                buf.append(b)
                if b >= 8:                    # a length high byte this large is
                    state = "hunt"            # not a frame; keep hunting
                else:
                    state = "lenl"
            elif state == "lenl":
                buf.append(b)
                need = ((buf[1] << 8) | buf[2]) + 3
                state = "body"
            else:
                buf.append(b)
                if len(buf) >= need:
                    yield bytes(buf[:need])
                    state, buf = "hunt", bytearray()


def serve(port, pk, blocks, count, quiet, once=False):
    served = 0
    done = set()
    while count == 0 or served < count:
        got = False
        for frame in read_frames(port, time.monotonic() + 30.0):
            got = True
            req = request(frame)
            if req is None:
                if not quiet:
                    # A frame shorter than a command byte used to index off the
                    # end of it and take the whole serve session down with an
                    # IndexError, which reads exactly like the core giving up.
                    if len(frame) >= 4:
                        print(f"  ignoring command {frame[3]:02x} ({len(frame)} bytes)")
                    else:
                        print(f"  ignoring a short frame ({len(frame)} bytes)")
                continue
            level, tx, ty = req
            if once and (level, tx, ty) in done:
                continue
            done.add((level, tx, ty))
            data = tile_bytes(pk, level, tx, ty)
            if data is None:
                # Past the edge of the level.  The renderer's fetch window is
                # wider than a level can be, so the last chunks of a line ask for
                # a tile that cannot exist; the honest answer is a blank tile --
                # there is no map out there -- and it keeps the line completing.
                if not quiet:
                    print(f"  L{level} {tx},{ty} is outside the level, answering blank")
                data = bytes(pk["rec"])
            t0 = time.monotonic()
            for off in range(0, len(data), blocks):
                piece = data[off:off + blocks]
                for attempt in range(4):
                    port.write(block(level, tx, ty, off, piece))
                    try:
                        li.read_reply(port, 5.0)
                        break
                    except RuntimeError as e:
                        if attempt == 3:
                            raise
                        print(f"  block at {off} refused ({e}), sending again")
                port.reset_input_buffer()
            served += 1
            if not quiet:
                print(f"  L{level} {tx},{ty}: {len(data)} bytes in "
                      f"{(len(data) + blocks - 1) // blocks} blocks, "
                      f"{time.monotonic() - t0:.2f} s")
        if not got and time.monotonic() % 5 < 0.01:
            pass
    return served


def prepare(port, pk, quiet):
    """The palette the pool's tiles are drawn through, then the pool itself."""
    if not quiet:
        print(f"loading the pack's {len(pk['pal'])}-byte palette")
    payload = (0).to_bytes(2, "little") + (256).to_bytes(2, "little") + pk["pal"]
    port.write(li.frame(payload + crc32(payload).to_bytes(4, "little"), CMD_PALETTE))
    li.read_reply(port, 5.0)
    if not quiet:
        print("switching the picture source to the tile pool")
    port.write(li.frame(b"\x01", CMD_SOURCE))
    li.read_reply(port, 5.0)


def selftest(pack=None, blocks=1024):
    """The framing, a tile lookup and the block header, without a board."""
    pk = dict(levels=[dict(tx=2, ty=3, first=4)], rec=64, data=bytes(range(256)),
              pal=bytes(range(64)), bits=8)
    # the tile at column 1 of row 2 is the sixth record of the pack: a row is two
    # tiles, so two rows is four, plus one
    assert tile_bytes(pk, 0, 1, 2) == pk["data"][5 * 64:6 * 64], "lookup"
    assert tile_bytes(pk, 0, 2, 0) is None, "a column past the grid"
    assert tile_bytes(pk, 1, 0, 0) is None, "a level that is not there"
    f = block(2, 0x1234, 0x0010, 1024, b"\x01\x02\x03")
    # the frame's length counts the command, so it is the nine header bytes, the
    # three payload bytes, the four CRC bytes and the command itself
    assert f[:4] == bytes([0xAA, 0x00, 9 + 3 + 4 + 1, CMD_TILE_BLOCK]), f[:4]
    assert f[4:13] == bytes([2, 0x34, 0x12, 0x10, 0x00, 0x00, 0x04, 0x03, 0x00]), f[4:13]
    assert int.from_bytes(f[13:16], "little") == 0x030201, "the block's bytes"
    want = crc32(f[4:16])
    assert int.from_bytes(f[16:20], "little") == want, "the block's crc"
    req = request(bytes([0xAA, 0x00, 0x06, CMD_TILE_REQ, 1, 0x05, 0x02, 0x10, 0x00]))
    assert req == (1, 0x0205, 0x0010), req
    assert request(bytes([0xAA, 0x00, 0x06, CMD_TILE_BLOCK, 1, 0, 0, 0, 0])) is None
    if pack:
        # A real pack, through the rules the fabric enforces: every block whole
        # words inside the tile, the bytes reassembling to the tile exactly, and
        # each frame's CRC over its own header and payload.
        pk = maps_pack.read_tiles(pack)
        assert pk["bits"] == 8, pk["bits"]
        for level, tx, ty in [(len(pk["levels"]) - 1, 0, 0),
                              (0, pk["levels"][0]["tx"] - 1, pk["levels"][0]["ty"] - 1)]:
            data = tile_bytes(pk, level, tx, ty)
            assert data is not None, (level, tx, ty)
            assert len(data) == pk["rec"], len(data)
            got = bytearray()
            for off in range(0, len(data), blocks):
                piece = data[off:off + blocks]
                assert off % 8 == 0 and len(piece) % 8 == 0, (off, len(piece))
                assert off + len(piece) <= pk["rec"], (off, len(piece))
                f = block(level, tx, ty, off, piece)
                head = f[4:13]
                assert head[0] == level and int.from_bytes(head[1:3], "little") == tx
                assert int.from_bytes(head[3:5], "little") == ty
                assert int.from_bytes(head[5:7], "little") == off
                assert int.from_bytes(head[7:9], "little") == len(piece)
                body = f[4:13 + len(piece)]
                assert int.from_bytes(f[13 + len(piece):17 + len(piece)], "little") \
                    == crc32(body), "block crc"
                got += f[13:13 + len(piece)]
            assert bytes(got) == data, f"L{level} {tx},{ty} did not reassemble"
            print(f"selftest: L{level} {tx},{ty} reassembles from "
                  f"{(len(data) + blocks - 1) // blocks} blocks, every CRC over its own header")
    print("selftest: framing, tile lookup and block CRC all agree")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("pack", nargs="?")
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--blocks", type=int, default=1024,
                    help="bytes per 0x1D block (a multiple of 8, at most %d)" % BLOCK_MAX)
    ap.add_argument("--count", type=int, default=0, help="stop after this many tiles")
    ap.add_argument("--once", action="store_true",
                    help="answer each tile once per run: the core re-asks while an "
                         "answer is in flight, and a tile already in the pool needs "
                         "no second copy")
    ap.add_argument("--no-prepare", action="store_true",
                    help="do not load the palette or switch the picture source")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest(args.pack, args.blocks)
    if not args.pack:
        ap.error("a pack is required unless --selftest")

    pk = maps_pack.read_tiles(args.pack)
    if pk["bits"] != 8:
        sys.exit(f"{args.pack} is {pk['bits']} bits a pixel; the fabric reads eight "
                 f"and one shared palette, so this pack cannot be served yet")
    if args.blocks % 8 or args.blocks <= 0 or args.blocks > BLOCK_MAX:
        sys.exit(f"--blocks must be a multiple of 8 and at most {BLOCK_MAX}")
    print(f"{args.pack}: {len(pk['levels'])} levels, {len(pk['data']) // pk['rec']} "
          f"tiles, {pk['bits']} bpp, blocks of {args.blocks}")

    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        li.open_pipe(port, quiet=args.quiet)
        if not args.no_prepare:
            prepare(port, pk, args.quiet)
        print("serving: waiting for tile requests (ctrl-c to stop)")
        n = serve(port, pk, args.blocks, args.count, args.quiet, args.once)
        print(f"served {n} tiles")
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        port.close()          # dropping the port is what closes fpgapipe
    return 0


if __name__ == "__main__":
    sys.exit(main())
