#!/usr/bin/env python3
"""Build a TinyMaps pack from OpenTopoMap tiles.

Cache lives outside the repository. Nothing here is redistributed; the tiles are
fetched once for a private offline pack and the pack must carry the OpenTopoMap
and OpenStreetMap attribution.

  maps_pack.py plan                 print the level table, no network
  maps_pack.py fetch                download the tiles into the cache
  maps_pack.py pack                 build the pack file from the cache
  maps_pack.py verify <pack>        decode a pack and compare against the cache
"""
import json, math, os, struct, sys, time, zlib
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS = None

LAT, LON = 33.4484, -112.0740     # downtown Phoenix
Z0, TILES = 15, 18                # finest level: 18x18 tiles at z15
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
    """finest first; each level covers the z15 ground rectangle exactly or as the
    minimal tile-aligned superset."""
    n = 2 ** Z0
    cx, cy = tile_xy(LAT, LON, Z0)
    x0 = int(round(cx - TILES / 2)); y0 = int(round(cy - TILES / 2))
    x1, y1 = x0 + TILES, y0 + TILES          # exclusive, in z15 tile units
    out = []
    for lvl, z in enumerate(range(Z0, Z0 - 4, -1)):
        s = 2 ** (Z0 - z)                    # z15 tiles per tile at zoom z
        tx0, tx1 = math.floor(x0/s), math.ceil(x1/s)
        ty0, ty1 = math.floor(y0/s), math.ceil(y1/s)
        # origin: this level's tile (tx0,ty0) in 3857, y measured downward
        ts = 2*MERC_HALF/(2**z)          # tile size in metres
        ox = -MERC_HALF + tx0 * ts
        oy =  MERC_HALF - ty0 * ts
        out.append(dict(level=lvl, zoom=z, tx0=tx0, ty0=ty0,
                        tiles_x=tx1-tx0, tiles_y=ty1-ty0,
                        width=(tx1-tx0)*256, height=(ty1-ty0)*256,
                        mpp=2*MERC_HALF/(2**z)/256, ox=ox, oy=oy))
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
    W, H = l['width'], l['height']
    im = Image.new("RGB", (W, H))
    for j in range(l['tiles_y']):
        for i in range(l['tiles_x']):
            im.paste(Image.open(path(l['zoom'], l['tx0']+i, l['ty0']+j)).convert("RGB"), (i*256, j*256))
    return im

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
