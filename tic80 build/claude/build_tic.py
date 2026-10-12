"""Pack a Lua source file + a sprite sheet PNG into a TIC-80 .tic cart.

The free TIC-80 build only loads .tic/.png carts, so this lets us keep the
code in a plain .lua file (diffable, editable anywhere) and still run it.

Usage:
    python build_tic.py game.lua sprites.png out.tic

Sprite sheet: 128 px wide, 128 or 256 px tall.
  rows   0-127 -> BG tiles      (ids   0-255)
  rows 128-255 -> sprite tiles  (ids 256-511)
If the PNG is indexed with <= 16 colours, its palette becomes the cart
palette and indices are used as-is (draw in Aseprite etc. in indexed mode).
Otherwise pixels are matched to the nearest SWEETIE-16 colour (TIC-80's
default palette). Pure stdlib: no Pillow needed.
"""
import os
import struct
import sys
import zlib

SWEETIE16 = [
    (0x1a, 0x1c, 0x2c), (0x5d, 0x27, 0x5d), (0xb1, 0x3e, 0x53), (0xef, 0x7d, 0x57),
    (0xff, 0xcd, 0x75), (0xa7, 0xf0, 0x70), (0x38, 0xb7, 0x64), (0x25, 0x71, 0x79),
    (0x29, 0x36, 0x6f), (0x3b, 0x5d, 0xc9), (0x41, 0xa6, 0xf6), (0x73, 0xef, 0xf7),
    (0xf4, 0xf4, 0xf4), (0x94, 0xb0, 0xc2), (0x56, 0x6c, 0x86), (0x33, 0x3c, 0x57),
]

CHUNK_TILES, CHUNK_SPRITES, CHUNK_CODE, CHUNK_PALETTE, CHUNK_DEFAULT = 1, 2, 5, 12, 17
CHUNK_MAP, CHUNK_PATTERNS = 4, 15


def read_png(path):
    """Return (w, h, rows) where rows[y][x] = (r, g, b, a). 8-bit, non-interlaced."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, plte, trns = 8, b"", None, None
    while pos < len(data):
        n, = struct.unpack(">I", data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
    assert interlace == 0, "interlaced PNG not supported"
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    if ctype == 3:
        assert depth in (1, 2, 4, 8)
    else:
        assert depth == 8, "only 8-bit PNGs supported"
    bpp = max(1, channels * depth // 8)
    stride = (w * channels * depth + 7) // 8
    raw = zlib.decompress(idat)
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b, c = prev[x], prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        prev = line
        px = []
        for x in range(w):
            if ctype == 3:
                bit = x * depth
                v = (line[bit // 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
                r, g, b_ = plte[v]
                al = trns[v] if trns and v < len(trns) else 255
                px.append((r, g, b_, al))
            elif ctype == 2: px.append(tuple(line[x * 3:x * 3 + 3]) + (255,))
            elif ctype == 6: px.append(tuple(line[x * 4:x * 4 + 4]))
            elif ctype == 0: px.append((line[x],) * 3 + (255,))
            elif ctype == 4: px.append((line[x * 2],) * 3 + (line[x * 2 + 1],))
        rows.append(px)
    return w, h, rows, plte


def nearest(rgb, pal):
    return min(range(len(pal)), key=lambda k: sum((rgb[j] - pal[k][j]) ** 2 for j in range(3)))


def sheet_to_tiles(rows, y0, pal):
    """128x128 region starting at row y0 -> 256 tiles * 32 bytes (4bpp, low nibble = left)."""
    cache, out = {}, bytearray()
    for t in range(256):
        tx, ty = (t % 16) * 8, (t // 16) * 8 + y0
        for y in range(8):
            for x in range(0, 8, 2):
                px = []
                for dx in (0, 1):
                    p = rows[ty + y][tx + x + dx] if ty + y < len(rows) else (0, 0, 0, 0)
                    # fully transparent pixels become colour 0 (the usual colorkey)
                    key = p[:3] if p[3] >= 128 else None
                    if key not in cache:
                        cache[key] = 0 if key is None else nearest(key, pal)
                    px.append(cache[key])
                out.append(px[0] | (px[1] << 4))
    return bytes(out)


def chunk(kind, data, bank=0):
    assert len(data) <= 0xFFFF, "chunk too large (%d bytes)" % len(data)
    return bytes([kind | (bank << 5)]) + struct.pack("<H", len(data)) + b"\0" + data


def art_chunks(root):
    """Full-screen game-over art made by art/import_gameover.py, if present:
    the image goes in the 2nd half of map RAM (0x8000 + 16320; the first
    half is the game's table snapshot), the per-scanline palettes go in
    music-pattern RAM (0x11164; the game has no music yet)."""
    scr = os.path.join(root, "art", "gameover_screen.bin")
    pal = os.path.join(root, "art", "gameover_pal.bin")
    if not (os.path.exists(scr) and os.path.exists(pal)):
        return []
    return [(CHUNK_MAP, bytes(16320) + open(scr, "rb").read()),
            (CHUNK_PATTERNS, open(pal, "rb").read())]


def main(lua_path, png_path, out_path, extra=()):
    code = open(lua_path, "rb").read()
    w, h, rows, plte = read_png(png_path)
    assert w == 128 and h in (128, 256), "sheet must be 128x128 or 128x256 (got %dx%d)" % (w, h)
    pal = list(plte[:16]) if plte and len(plte) <= 16 else SWEETIE16
    pal += [(0, 0, 0)] * (16 - len(pal))
    cart = chunk(CHUNK_DEFAULT, b"")
    cart += chunk(CHUNK_PALETTE, b"".join(bytes(c) for c in pal))
    cart += chunk(CHUNK_TILES, sheet_to_tiles(rows, 0, pal))
    if h == 256:
        cart += chunk(CHUNK_SPRITES, sheet_to_tiles(rows, 128, pal))
    # code over 64 KB is split across code banks, up to 8 banks = 512 KB.
    # TIC-80 lays banks out in REVERSE order (bank 7 first), so the first
    # 64 KB goes in bank 7, the next in bank 6, ... (verified headless)
    assert len(code) <= 8 * 0x10000, "code too large for 8 banks"
    for i in range(0, (len(code) + 0xFFFF) // 0x10000):
        part = code[i * 0x10000:(i + 1) * 0x10000]
        bank = 7 - i if len(code) > 0x10000 else 0
        if len(part) == 0x10000:  # a full bank: size field can't hold 65536
            cart += bytes([CHUNK_CODE | (bank << 5)]) + bytes(3) + part
        else:
            cart += chunk(CHUNK_CODE, part, bank)
    for kind, data in extra:
        cart += chunk(kind, data)
    open(out_path, "wb").write(cart)
    print("wrote %s: %d bytes code, %dx%d sheet" % (out_path, len(code), w, h))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
