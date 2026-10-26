#!/usr/bin/env python3
"""Load a raw image into TinyMaps' SDRAM over the Tang's USB console.

The core's loader (`maps_link_rx`) takes the BL616 link's 0xAA frames, parses
the `0x07` payload stream out of them, and writes it to an SDRAM byte address.
The payload is TinyNES's load format with an SDRAM address in place of a program
entry point:

    header, 5 words little-endian
      0  magic 'TML1' (0x314c4d54)   1  SDRAM byte address (8-byte aligned)
      2  length                      3  image CRC-32
      4  header CRC-32 over the first 16 bytes
    then ceil(length / 8192) blocks, each of up to 8192 bytes and its CRC-32

CRCs are zlib's CRC-32, which is what the loader's complemented running
register works out to.  Each header and block is answered ACK 0x06 or NAK 0x15
plus a letter -- 'H' header CRC, 'C' block CRC, 'I' image CRC -- and a NAKed
block is sent again.  The sender is stop-and-wait: nothing more goes out until
the loader has answered.

Every payload byte travels inside a frame, because the loader's parser is what
decides a byte is data:

    0xAA len_hi len_lo 0x07 payload      len = 1 + payload, big-endian, < 2048

Two-wire mode (`--tinytang`, the default) uses the console the board exposes:
the board is asked whether its shell is at a prompt, and its `fpgapipe` command
then passes the console straight through to the core's UART until this tool
closes the port.  Nothing is sent unless the board says it is at a prompt --
raw bytes and keystrokes are the same thing on that wire.

    tools/maps_test_image.py
    tools/load_image.py work/test/test-image.bin

SPDX-License-Identifier: MIT
"""
import argparse
import re
import struct
import sys
import time
import zlib

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")

MAGIC = 0x314C_4D54          # 'TML1' in memory order
CMD_DATA = 0x07
ACK, NAK = 0x06, 0x15
BLOCK = 8192
PAYLOAD_MAX = 2046           # len counts the command byte and must stay under 2048
REASONS = {
    b"H": "header CRC",
    b"C": "block CRC",
    b"I": "image CRC",
    b"T": "timeout",
}

PROBE = b"\x1b[?77n"
PROBE_REPLY = re.compile(rb"\x1b\[\?77;(\d+)n")


def crc(data):
    return zlib.crc32(data) & 0xFFFF_FFFF


def frame(payload, cmd=CMD_DATA):
    """One 0xAA frame around a chunk of payload."""
    n = len(payload) + 1
    assert 0 < n < 2048, n
    return bytes([0xAA, (n >> 8) & 0xFF, n & 0xFF, cmd]) + payload


def framed(data):
    """A byte string split across as many frames as it needs."""
    return b"".join(frame(data[i:i + PAYLOAD_MAX])
                    for i in range(0, len(data), PAYLOAD_MAX))


def read_reply(port, timeout):
    """ACK, or raise with the NAK reason."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        b = port.read(1)
        if not b:
            continue
        if b[0] == ACK:
            return
        if b[0] == NAK:
            reason = port.read(1)
            raise RuntimeError(f"NAK: {REASONS.get(reason, reason)}")
        # anything else is console text that arrived before the pipe opened
    raise RuntimeError("no answer from the loader")


def open_pipe(port, quiet=False):
    """Ask the board for the shell prompt, then hand the console to the core."""
    time.sleep(0.2)
    port.reset_input_buffer()
    port.write(PROBE)
    seen = b""
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline:
        seen += port.read(256)
        m = PROBE_REPLY.search(seen)
        if m:
            if m.group(1) != b"1":
                raise RuntimeError(f"the console is in state {m.group(1).decode()}, "
                                   f"not at a shell prompt")
            break
    else:
        raise RuntimeError("the console did not answer the status probe")
    port.write(b"fpgapipe\r")
    deadline = time.monotonic() + 2.0
    seen = b""
    while time.monotonic() < deadline:
        seen += port.read(256)
        if b"fpgapipe: open" in seen:
            port.reset_input_buffer()
            if not quiet:
                print("console handed to the core (fpgapipe)")
            return
    raise RuntimeError(f"fpgapipe did not open: {seen[-200:]!r}")


def load(port, image, addr, retries, quiet=False):
    header = struct.pack("<4I", MAGIC, addr, len(image), crc(image))
    header += struct.pack("<I", crc(header))

    t0 = time.monotonic()
    port.write(framed(header))
    read_reply(port, 5.0)
    if not quiet:
        print(f"header: {len(image)} bytes to {addr:#010x}, accepted")

    sent = 0
    for off in range(0, len(image), BLOCK):
        block = image[off:off + BLOCK]
        payload = block + struct.pack("<I", crc(block))
        for attempt in range(retries + 1):
            port.write(framed(payload))
            try:
                read_reply(port, 5.0)
                break
            except RuntimeError as error:
                if attempt == retries or not str(error).startswith("NAK"):
                    raise
                if not quiet:
                    print(f"block at {addr + off:#x}: {error}, sending again")
                time.sleep(0.02)
        sent += len(block)
        if not quiet:
            print(f"  {sent}/{len(image)} bytes", end="\r", flush=True)

    if not quiet:
        dt = time.monotonic() - t0
        print(f"\n{sent} bytes written in {dt:.1f} s ({sent / dt / 1000:.0f} kB/s)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", help="raw eight-bit raster or any byte image")
    ap.add_argument("--addr", default="0", help="SDRAM byte address (default 0)")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200,
                    help="ignored by the USB CDC, kept for other ports")
    ap.add_argument("--tinytang", dest="tinytang", action="store_true", default=True,
                    help="ask the console for a prompt and open fpgapipe (default)")
    ap.add_argument("--no-pipe", dest="tinytang", action="store_false",
                    help="the port already reaches the core's UART")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    addr = int(args.addr, 0)
    if addr % 8:
        sys.exit("the loader needs an eight-byte aligned address")

    with open(args.image, "rb") as f:
        image = f.read()
    if not image:
        sys.exit(f"{args.image} is empty")

    port = serial.Serial(args.port, args.baud, timeout=0.02)
    try:
        if args.tinytang:
            open_pipe(port, args.quiet)
        load(port, image, addr, args.retries, args.quiet)
    except RuntimeError as error:
        print(f"FAILED: {error}")
        return 1
    finally:
        port.close()          # dropping the port is what closes fpgapipe
    print("loaded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
