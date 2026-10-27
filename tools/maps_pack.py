#!/usr/bin/env python3
"""Build a TinyMaps pack from OpenTopoMap tiles.

Cache lives outside the repository. Nothing here is redistributed; the tiles are
fetched once for a private offline pack and the pack must carry the OpenTopoMap
and OpenStreetMap attribution.

  maps_pack.py plan                 print the level table, no network
  maps_pack.py fetch                download the tiles into the cache
  maps_pack.py pack                 build the pack file from the cache
  maps_pack.py verify <pack>        decode a pack and compare against the cache
  maps_pack.py tiles [<out>] [--bits=8]
                                    build a tile pack for streaming; eight bits
                                    is what the fabric reads, four is smaller
                                    and needs the pixel path to learn nibbles
  maps_pack.py verify-tiles <pack>  check every tile record's shape and indices
"""
import json, math, os, struct, sys, time, zlib
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS = None

LAT, LON = 33.4484, -112.0740     # downtown Phoenix
Z0, TILES = 15, 18                # finest level: 18x18 tiles at z15
ALIGN_MIN_PX = 640                # the screen at step 0.5 shows 640 source pixels
UA = "TinyMaps/0.1 (offline map pack for personal hardware; one-off fetch)"
CACHE = os.path.expanduser("~/.cache/tinymaps/tiles")
OUT = "work/pack/phoenix-18km.tmpk"
MERC_HALF = 20037508.342789244
R = 6378137.0

def ground_mpp(z, lat=LAT):
    return 156543.03392 * math.cos(math.radians(lat)) / (2 ** z)

def tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.log(math.tan(math.radians(lat)) + 1/math.cos(math.radians(lat)))/math.pi) / 2.0 * n
    return x, y

def levels():
    """finest first; every level is cut to one shared origin.

    The navigation crosses levels by doubling or halving the source
    coordinates, which is only true when all levels put their pixel (0,0) on
    the same ground point.  A tile-aligned mosaic does not: each zoom's tiles
    start on that zoom's own grid, so the four corners land up to a couple of
    hundred pixels apart and the picture jumps at every crossing.  So the
    finest level's tile corner is the shared origin, and every level is cropped
    to begin there.  The offsets are exact whole pixels of the coarse grid,
    because each level's pixels are a power-of-two subdivision of the same
    ground; nothing is resampled.

    Each level keeps its own extent, so the coarser ones still cover more
    ground, except where cropping leaves less than ALIGN_MIN_PX across: then a
    ring of tiles is added on the right and bottom.  Below that width a level
    cannot fill the screen at step 0.5, which is where a crossing lands.
    """
    n = 2 ** Z0
    cx, cy = tile_xy(LAT, LON, Z0)
    x0 = int(round(cx - TILES / 2)); y0 = int(round(cy - TILES / 2))
    x1, y1 = x0 + TILES, y0 + TILES          # exclusive, in z15 tile units

    # the shared origin: the finest level's tile corner, in 3857, y downward
    ts0 = 2*MERC_HALF/(2**Z0)
    shared_x = -MERC_HALF + math.floor(x0) * ts0
    shared_y =  MERC_HALF - math.floor(y0) * ts0

    out = []
    for lvl, z in enumerate(range(Z0, Z0 - 4, -1)):
        s = 2 ** (Z0 - z)                    # z15 tiles per tile at zoom z
        tx0, tx1 = math.floor(x0/s), math.ceil(x1/s)
        ty0, ty1 = math.floor(y0/s), math.ceil(y1/s)
        ts = 2*MERC_HALF/(2**z)              # tile size in metres
        mpp = ts / 256
        # where the shared origin falls inside this level's own mosaic
        mosaic_x = -MERC_HALF + tx0 * ts
        mosaic_y =  MERC_HALF - ty0 * ts
        crop_x = int(round((shared_x - mosaic_x) / mpp))
        crop_y = int(round((mosaic_y - shared_y) / mpp))
        assert crop_x >= 0 and crop_y >= 0, (z, crop_x, crop_y)
        while (tx1 - tx0) * 256 - crop_x < ALIGN_MIN_PX: tx1 += 1
        while (ty1 - ty0) * 256 - crop_y < ALIGN_MIN_PX: ty1 += 1
        out.append(dict(level=lvl, zoom=z, tx0=tx0, ty0=ty0,
                        tiles_x=tx1-tx0, tiles_y=ty1-ty0,
                        crop_x=crop_x, crop_y=crop_y,
                        width=(tx1-tx0)*256 - crop_x,
                        height=(ty1-ty0)*256 - crop_y,
                        mpp=mpp, ox=shared_x, oy=shared_y))
    return out

def path(z, x, y):
    return os.path.join(CACHE, f"{z}_{x}_{y}.png")

def fetch(ls):
    os.makedirs(CACHE, exist_ok=True)
    todo = [(l['zoom'], tx, ty) for l in ls
            for ty in range(l['ty0'], l['ty0']+l['tiles_y'])
            for tx in range(l['tx0'], l['tx0']+l['tiles_x'])]
    print(f"{len(todo)} tiles to consider, cache {CACHE}")
    got = skipped = 0
    t0 = time.time()
    for i, (z, x, y) in enumerate(todo):
        p = path(z, x, y)
        if os.path.exists(p) and os.path.getsize(p) > 0:
            skipped += 1; continue
        import urllib.request
        for attempt in range(4):
            try:
                req = urllib.request.Request(f"https://tile.opentopomap.org/{z}/{x}/{y}.png",
                                             headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                if data[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError("not a png")
                open(p, "wb").write(data); got += 1; break
            except Exception as e:
                if attempt == 3:
                    print(f"  FAILED {z}/{x}/{y}: {e}"); raise
                time.sleep(2 * (attempt + 1))
        if (i+1) % 25 == 0:
            print(f"  {i+1}/{len(todo)}  new {got} cached {skipped}  {time.time()-t0:.0f}s")
        time.sleep(0.35)
    print(f"done: {got} fetched, {skipped} already cached, {time.time()-t0:.0f}s")

def mosaic(l):
    """the level's tiles as one image, cut to start at the shared origin"""
    im = Image.new("RGB", (l['tiles_x']*256, l['tiles_y']*256))
    for j in range(l['tiles_y']):
        for i in range(l['tiles_x']):
            im.paste(Image.open(path(l['zoom'], l['tx0']+i, l['ty0']+j)).convert("RGB"), (i*256, j*256))
    x, y = l['crop_x'], l['crop_y']
    return im.crop((x, y, x + l['width'], y + l['height']))

def build_palette(ims, per_level=250_000, seed=7):
    """one shared 256-entry palette, cut from a uniform random pixel sample taken
    across every level. A resized subsample biases the histogram and costs about
    5x the error, so sample the real pixels."""
    rng = np.random.default_rng(seed)
    samp = []
    for im in ims:
        a = np.asarray(im, np.uint8).reshape(-1, 3)
        samp.append(a[rng.integers(0, len(a), per_level)])
    s = np.concatenate(samp)
    side = int(math.isqrt(len(s)))
    canvas = Image.fromarray(s[:side*side].reshape(side, side, 3))
    return canvas.quantize(colors=256, method=Image.MEDIANCUT).getpalette()[:768]

HDR = 56          # magic/version/count + offsets + name
ENT = 40          # one level descriptor

def pack(ls):
    ims = [mosaic(l) for l in ls]
    pal = build_palette(ims)
    palimg = Image.new("P", (1, 1)); palimg.putpalette(pal)
    name = b"Phoenix metro 18.4km z15 8bpp"
    pal_off = HDR + ENT * len(ls)
    data_off = pal_off + 768
    body = bytearray(); entries = []
    for l, im in zip(ls, ims):
        q = im.quantize(palette=palimg, dither=Image.FLOYDSTEINBERG)
        a = np.asarray(q, np.uint8)
        entries.append(dict(l, offset=data_off + len(body), crc=zlib.crc32(a.tobytes())))
        body += a.tobytes()
    total = data_off + len(body)
    hdr = bytearray(HDR)
    struct.pack_into("<4sHHIIII", hdr, 0, b"TMPK", 1, len(ls), pal_off, 768, total, 0)
    hdr[24:56] = name[:31].ljust(32, b"\0")
    tbl = bytearray()
    for e in entries:
        tbl += struct.pack("<IIIIIiiIII", e['offset'], e['width'], e['height'],
                           int(round(e['mpp']*65536)), e['zoom'], int(round(e['ox'])), int(round(e['oy'])),
                           e['tiles_x'], e['tiles_y'], e['crc'])
    assert len(tbl) == ENT * len(ls), (len(tbl), ENT*len(ls))
    hdr[20:24] = b"\0\0\0\0"                 # crc field excluded from its own crc
    hc = zlib.crc32(bytes(hdr) + bytes(tbl) + bytes(pal))
    struct.pack_into("<I", hdr, 20, hc)
    pre = bytes(hdr) + bytes(tbl) + bytes(pal)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(pre); f.write(bytes(body))
    print(f"wrote {OUT}: {total} bytes ({total/1048576:.2f} MiB)  header crc {hc:08x}  data at {data_off}")
    for e in entries:
        print(f"  L{e['level']} z{e['zoom']} {e['width']}x{e['height']} "
              f"{e['width']*e['height']/1048576:7.2f} MiB  merc-mpp {e['mpp']:.3f}  off {e['offset']}  crc {e['crc']:08x}")
    return entries

# ---------------------------------------------------------- tile packs (TMTL) --
# A tile pack is what streaming needs: one record per 256-pixel tile, four bits
# per pixel with a sixteen-entry palette of the tile's own, laid out so a tile's
# bytes are contiguous and a tile row is exactly one 256-byte SDRAM line.
#
#   0   u32  magic 'TMTL'
#   4   u16  version = 1
#   6   u16  level count
#   8   u32  tile pixels (256)
#   12  u8   bits per pixel (4 or 8)
#   13  u8   palette entries (16, or 0 for a 256-entry table: one byte cannot
#            say 256)
#   14  u16  zero
#   16  u32  tile payload bytes (32768 at 4bpp, 65536 at 8bpp)
#   20  u32  record bytes
#   24  u32  tile data offset
#   28  u32  total bytes
#
# At four bits a pixel a record carries its own 16-colour palette (48 bytes) and
# then the nibbles.  At eight bits a pixel the pack carries one 256-entry palette
# between the level table and the records -- the table the fabric's pixel path
# already reads -- and a record is nothing but the tile's own bytes.
#   32  u32  header CRC-32 over the header with this field zeroed, the level
#            table and every tile record
#   36  u8   name[32]
#   68  level table, 40 bytes each:
#         u32 tiles x, u32 tiles y, u32 zoom, u32 m/px Q16.16,
#         i32 origin 3857 x, i32 origin 3857 y, u32 first tile, u32 zero
#   then the tile records in level order, row-major within a level.
#
# Every level shares the origin rule of the 8bpp pack: the finest level's tile
# corner, so a level crossing stays a doubling of the coordinates.

THDR, TENT = 68, 40
TSIZE = 256


def tile_shape(bits):
    """(palette bytes in a record, payload bytes, record bytes) for a pack.

    Four bits per pixel carries its own sixteen-colour palette in every record,
    because sixteen colours chosen per tile is what makes a tile look like
    itself.  Eight bits per pixel has one 256-entry palette for the whole pack,
    which is the table the fabric's pixel path already reads, so a record is
    nothing but the tile's own bytes.
    """
    if bits == 4:
        return 48, TSIZE * TSIZE // 2, 48 + TSIZE * TSIZE // 2
    if bits == 8:
        return 0, TSIZE * TSIZE, TSIZE * TSIZE
    raise ValueError(f"{bits} bits per pixel is not a pack this tool writes")


def padded_mosaic(l):
    """the level's raster padded up to whole tiles, with the grid it needs.

    A level's width and height are not multiples of the tile size -- L3 is
    832x864 -- so the last column and row of tiles would be part of a tile and
    part nothing.  Padding to whole tiles keeps every record 256x256 and puts the
    filler outside the level, where the renderer's clamp never looks.
    """
    im = mosaic(l)
    gx = (l['width'] + TSIZE - 1) // TSIZE
    gy = (l['height'] + TSIZE - 1) // TSIZE
    out = Image.new("RGB", (gx * TSIZE, gy * TSIZE), (0, 0, 0))
    out.paste(im, (0, 0))
    return out, gx, gy


def tile_records(ls, bits):
    """(records, shared palette or None) for every tile, level order, row-major
    within a level"""
    _pal, _pay, rec = tile_shape(bits)
    out = []
    shared = None
    palimg = None
    if bits == 8:
        # one palette for the pack, cut from a sample of every level, so a tile
        # is drawn through the table the fabric already has loaded
        shared = build_palette([padded_mosaic(l)[0] for l in ls])
        palimg = Image.new("P", (1, 1)); palimg.putpalette(shared)
    for l in ls:
        im, gx, gy = padded_mosaic(l)
        for ty in range(gy):
            for tx in range(gx):
                box = (tx * TSIZE, ty * TSIZE, (tx + 1) * TSIZE, (ty + 1) * TSIZE)
                t = im.crop(box)
                if bits == 8:
                    q = t.quantize(palette=palimg, dither=Image.NONE)
                    out.append((b"", np.asarray(q, np.uint8).tobytes()))
                else:
                    q = t.quantize(colors=16, method=Image.MEDIANCUT,
                                   dither=Image.NONE)
                    pal = bytes(q.getpalette()[:48]).ljust(48, b"\0")
                    idx = np.asarray(q, np.uint8)
                    assert idx.max() < 16, (idx.max(), tx, ty)
                    # two pixels a byte, high nibble first, row by row
                    packed = (idx[:, 0::2] << 4) | idx[:, 1::2]
                    out.append((pal, packed.astype(np.uint8).tobytes()))
    assert all(len(p) + len(x) == rec for p, x in out)
    return out, shared


def pack_tiles(ls, out_path, bits=4):
    _pbytes, _pay, TREC = tile_shape(bits)
    recs, shared = tile_records(ls, bits)
    first = []
    grids = []
    n = 0
    for l in ls:
        _im, gx, gy = padded_mosaic(l)
        grids.append((gx, gy))
        first.append(n)
        n += gx * gy
    assert len(recs) == n, (len(recs), n)

    body = bytearray()
    for pal, px in recs:
        body += pal + px
    share = bytes(shared) if shared else b""
    data_off = THDR + TENT * len(ls) + len(share)

    hdr = bytearray(THDR)
    struct.pack_into("<4sHHIBBHIIII", hdr, 0, b"TMTL", 2 if bits == 8 else 1, len(ls),
                     TSIZE, bits, (256 if bits == 8 else 16) % 256, 0,
                     _pay, TREC, data_off, data_off + len(body))
    hdr[36:68] = f"Phoenix metro tiles {bits}bpp".encode().ljust(32, b"\0")[:32]

    tbl = bytearray()
    for l, f, (gx, gy) in zip(ls, first, grids):
        tbl += struct.pack("<IIIIiiII", gx, gy, l['zoom'],
                           int(round(l['mpp'] * 65536)),
                           int(round(l['ox'])), int(round(l['oy'])), f, 0) + b"\0" * 8
    assert len(tbl) == TENT * len(ls)

    hdr[32:36] = b"\0\0\0\0"
    crc = zlib.crc32(bytes(hdr) + bytes(tbl) + share + bytes(body))
    struct.pack_into("<I", hdr, 32, crc)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(hdr); f.write(tbl); f.write(share); f.write(body)
    print(f"wrote {out_path}: {data_off + len(body)} bytes "
          f"({(data_off + len(body)) / 1048576:.2f} MiB), {n} tiles, "
          f"{bits} bpp, header crc {crc:08x}")
    for l, f, (gx, gy) in zip(ls, first, grids):
        c = gx * gy
        print(f"  L{l['level']} z{l['zoom']}: {gx}x{gy} = {c} tiles "
              f"from {f}, {c * TREC / 1048576:.2f} MiB")
    return 0


def read_tiles(p):
    b = open(p, "rb").read()
    magic, ver, nlev, tsz, bits, pal, _z, pay, rec, doff, total = \
        struct.unpack_from("<4sHHIBBHIIII", b, 0)
    assert magic == b"TMTL", magic
    pbytes, pay, rec = tile_shape(bits)
    # the palette count is one byte, so a 256-entry table is written as zero
    pal_entries = pal if pal else 256
    assert tsz == TSIZE and pal_entries == (256 if bits == 8 else 16), \
        (tsz, bits, pal_entries)
    assert rec == struct.unpack_from("<I", b, 20)[0] and total == len(b), (rec, total, len(b))
    table_end = THDR + TENT * nlev
    # the shared palette, if this pack has one, sits between the level table and
    # the records
    share = b[table_end:doff]
    assert len(share) in (0, 768), len(share)
    hdr = bytearray(b[:THDR]); hdr[32:36] = b"\0\0\0\0"
    want = struct.unpack_from("<I", b, 32)[0]
    assert zlib.crc32(bytes(hdr) + b[THDR:doff] + b[doff:total]) == want, "header crc"
    lvs = []
    for i in range(nlev):
        tx, ty, z, mpp, ox, oy, first, _r = struct.unpack_from("<IIIIiiII", b, THDR + TENT * i)
        lvs.append(dict(level=i, tx=tx, ty=ty, zoom=z, mpp=mpp / 65536, ox=ox, oy=oy, first=first))
    return dict(levels=lvs, data=b[doff:total], name=b[36:68].rstrip(b"\0").decode(),
                bits=bits, rec=rec, pbytes=pbytes, pal=share)


def verify_tiles(p):
    pk = read_tiles(p)
    ls = levels()
    ok = True
    TREC = pk['rec']
    print(f"{p}: '{pk['name']}', {len(pk['levels'])} levels, "
          f"{len(pk['data']) // TREC} tiles, {pk['bits']} bpp")
    origins = {(lv['ox'], lv['oy']) for lv in pk['levels']}
    if len(origins) == 1:
        print(f"  origin 3857 {origins.pop()} shared by all levels")
    else:
        print(f"  origins differ: {sorted(origins)}")
        ok = False
    for lv, l in zip(pk['levels'], ls):
        n = lv['tx'] * lv['ty']
        im = np.asarray(padded_mosaic(l)[0], np.int16)
        bad = worst = 0
        for k in range(n):
            off = (lv['first'] + k) * TREC
            if pk['bits'] == 8:
                pal = np.frombuffer(pk['pal'], np.uint8).reshape(256, 3)
                idx = np.frombuffer(pk['data'][off:off + TREC], np.uint8)
                assert idx.size == TSIZE * TSIZE, (idx.size, k)
            else:
                pal = np.frombuffer(pk['data'][off:off + pk['pbytes']],
                                    np.uint8).reshape(16, 3)
                px = np.frombuffer(pk['data'][off + pk['pbytes']:off + TREC], np.uint8)
                assert px.size == TSIZE * TSIZE // 2, (px.size, k)
                hi, lo = px >> 4, px & 0x0F
                idx = np.empty(TSIZE * TSIZE, np.uint8)
                idx[0::2], idx[1::2] = hi, lo
                if idx.max() >= 16:
                    bad += 1
                    continue
            # decode and compare against the tile this record claims to be: a
            # transposed or shifted tile is well formed and wrong, and only this
            # catches it
            got = pal[idx.reshape(TSIZE, TSIZE)].astype(np.int16)
            tx, ty = k % lv['tx'], k // lv['tx']
            src = im[ty * TSIZE:(ty + 1) * TSIZE, tx * TSIZE:(tx + 1) * TSIZE]
            mean = float(np.abs(got - src).mean())
            worst = max(worst, mean)
            if mean > 12.0:            # 16 colours on aerial imagery
                bad += 1
        print(f"  L{lv['level']} z{lv['zoom']}: {lv['tx']}x{lv['ty']} = {n} tiles, "
              f"worst tile {worst:4.1f}/255 vs its source, "
              f"{'all decode to their place' if bad == 0 else str(bad) + ' wrong'}")
        ok &= bad == 0
    print("VERDICT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    if len(sys.argv) < 2: print(__doc__); return 1
    cmd = sys.argv[1]; ls = levels()
    if cmd == "plan":
        tot = 0
        for l in ls:
            n = l['width']*l['height']; tot += n
            print(f"L{l['level']} z{l['zoom']} {l['mpp']:6.3f} m/px  {l['tiles_x']}x{l['tiles_y']} tiles  "
                  f"{l['width']}x{l['height']}  {n/1048576:7.2f} MiB")
        print(f"total raster {tot} B = {tot/1048576:.2f} MiB of 32.00 MiB "
              f"({tot/(2*8192*512*4)*100:.1f}%), {sum(l['tiles_x']*l['tiles_y'] for l in ls)} tiles")
        return 0
    if cmd == "fetch": fetch(ls); return 0
    if cmd == "pack":  pack(ls);  return 0
    if cmd == "verify": return verify(sys.argv[2])
    if cmd == "tiles":
        # the fabric's streaming path reads eight bits a pixel and one shared
        # palette, because that is the table its pixel path already has; four
        # bits a pixel with a palette per tile is the smaller pack and waits for
        # the pixel path to learn about nibbles.
        bits = 4
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        for a in sys.argv[2:]:
            if a.startswith("--bits="):
                bits = int(a.split("=", 1)[1])
        if bits not in (4, 8):
            print(f"--bits must be 4 or 8, not {bits}")
            return 2
        out = args[0] if args else f"work/pack/phoenix-18km-{bits}bpp.tmtl"
        return pack_tiles(ls, out, bits)
    if cmd == "verify-tiles": return verify_tiles(sys.argv[2])
    if cmd == "extract":
        # the raw eight-bit raster of one level, for tools/load_image.py
        if len(sys.argv) < 4:
            print("usage: maps_pack.py extract <pack> <level 0-3> [-o out.bin]"); return 1
        pk = read_pack(sys.argv[2])
        want = int(sys.argv[3])
        for lv in pk["levels"]:
            if lv["level"] == want:
                out = "work/test/level%d.bin" % want
                if len(sys.argv) > 5 and sys.argv[4] == "-o":
                    out = sys.argv[5]
                import os
                os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
                open(out, "wb").write(lv["idx"].tobytes())
                print(f"{out}: L{want} z{lv['zoom']} {lv['w']}x{lv['h']}, "
                      f"{lv['w']*lv['h']} bytes")
                return 0
        print(f"no level {want} in {sys.argv[2]}"); return 1
    if cmd == "preview": pack_path = sys.argv[2] if len(sys.argv) > 2 else OUT; preview(pack_path); return 0
    print("unknown command"); return 1


# ---------------------------------------------------------------- verify ----
def read_pack(p):
    b = open(p, "rb").read()
    magic, ver, nlev, pal_off, pal_len, total, hc = struct.unpack_from("<4sHHIIII", b, 0)
    assert magic == b"TMPK", magic
    hdr = bytearray(b[:HDR]); hdr[20:24] = b"\0\0\0\0"
    assert zlib.crc32(bytes(hdr) + b[HDR:pal_len and HDR+ENT*nlev] + b[pal_off:pal_off+pal_len]) == hc, "header crc"
    assert total == len(b), (total, len(b))
    pal = b[pal_off:pal_off+pal_len]
    out = []
    for i in range(nlev):
        off, w, h, mpp_q16, z, ox, oy, tx, ty, crc = struct.unpack_from("<IIIIIiiIII", b, HDR+ENT*i)
        raw = b[off:off+w*h]
        assert zlib.crc32(raw) == crc, f"level {i} crc"
        idx = np.frombuffer(raw, np.uint8).reshape(h, w)
        rgb = np.frombuffer(pal, np.uint8).reshape(256, 3)[idx]
        out.append(dict(level=i, zoom=z, w=w, h=h, mpp=mpp_q16/65536, ox=ox, oy=oy, rgb=rgb, idx=idx))
    return dict(version=ver, nlev=nlev, total=total, name=b[24:56].rstrip(b"\0").decode(), levels=out,
                palette=np.frombuffer(pal, np.uint8).reshape(256, 3))

def verify(p):
    pk = read_pack(p)
    print(f"{p}: v{pk['version']} '{pk['name']}' {pk['total']} B, {pk['nlev']} levels")
    ls = levels()
    ok = True
    # the one invariant the navigation depends on: all levels share an origin
    origins = {(lv['ox'], lv['oy']) for lv in pk['levels']}
    if len(origins) == 1:
        ox, oy = origins.pop()
        print(f"  origin 3857 ({ox:.0f}, {oy:.0f}) shared by all {pk['nlev']} levels")
    else:
        print(f"  origins differ across levels: {sorted(origins)}")
        print("     ^^ FAILS alignment: a level crossing will jump the centre")
        ok = False
    for lv, l in zip(pk['levels'], ls):
        src = np.asarray(mosaic(l), np.int16)
        got = lv['rgb'].astype(np.int16)
        assert src.shape == got.shape, (src.shape, got.shape)
        from PIL import ImageFilter
        def blur(a):
            return np.asarray(Image.fromarray(a.astype(np.uint8)).filter(ImageFilter.BoxBlur(2)), np.float32)
        d = np.abs(src-got); mean = d.mean()
        loc = np.abs(blur(src)-blur(got)).mean()
        uniq = len(np.unique(lv['idx']))
        print(f"  L{lv['level']} z{lv['zoom']} {lv['w']}x{lv['h']}: "
              f"per-pixel {mean:5.2f}/255  local(4px) {loc:5.2f}  max {d.max():3d}  "
              f"colours used {uniq:3d}  crc ok  mpp {lv['mpp']:.3f}")
        bad = loc > 2.0 or uniq < 128
        ok &= not bad
        if bad: print("     ^^ FAILS tolerance")
    print("VERDICT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

# --------------------------------------------------------------- preview ----
def preview(p, outdir="work/pack"):
    pk = read_pack(p)
    pal = Image.fromarray(pk['palette'].reshape(256, 1, 3)).resize((256, 16), Image.NEAREST)
    pal.save(f"{outdir}/palette.png")
    ox, oy = mp_last_center()
    for lv in pk['levels']:
        im = Image.fromarray(lv['rgb'])
        # output window at this level's own 1:1 scale
        w, h = min(1280, lv['w']), min(720, lv['h'])
        cx = int((ox - lv['ox']) / lv['mpp']); cy = int((lv['oy'] - oy) / lv['mpp'])
        cx = max(w//2, min(lv['w']-w//2, cx)); cy = max(h//2, min(lv['h']-h//2, cy))
        box = (cx-w//2, cy-h//2, cx+w//2, cy+h//2)
        c = im.crop(box)
        if c.size != (1280, 720): c = c.resize((1280, 720), Image.LANCZOS)
        c.save(f"{outdir}/from_pack_L{lv['level']}_z{lv['zoom']}.png")
        print(f"  L{lv['level']} z{lv['zoom']} crop {box} -> from_pack_L{lv['level']}_z{lv['zoom']}.png")

def mp_last_center():
    from pyproj import CRS, Transformer
    return Transformer.from_crs(CRS.from_epsg(4326), CRS.from_epsg(3857), always_xy=True).transform(LON, LAT)

if __name__ == "__main__":
    sys.exit(main())
