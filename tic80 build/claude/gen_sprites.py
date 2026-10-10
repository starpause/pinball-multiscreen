"""Generate fairy_ring_sprites.png: the Fairy Ring sprite sheet (128x256, indexed).

Hand-drawn sprites live below as ASCII art, one hex digit per pixel
('.' = 0 = transparent / colorkey). Textures and flipper rotations are
generated, so the sheet stays consistent with the physics shapes.

The PNG is indexed with the FAIRY NIGHT palette, so you can open it in
Aseprite / any editor, repaint, and rebuild the cart with build_tic.py.
"""
import math
import struct
import sys
import zlib

# ---------------- FAIRY NIGHT palette (16 colours) ----------------
PAL = [
    (0x0b, 0x0a, 0x14),  # 0 key / void
    (0x1c, 0x14, 0x30),  # 1 outline
    (0x2e, 0x23, 0x50),  # 2 floor
    (0x4a, 0x3a, 0x74),  # 3 floor light / lavender
    (0x1d, 0x3a, 0x2e),  # 4 deep moss
    (0x2f, 0x6e, 0x3c),  # 5 moss
    (0x62, 0xad, 0x48),  # 6 leaf
    (0xb8, 0xe6, 0x5c),  # 7 lime glow
    (0x5a, 0x34, 0x24),  # 8 bark dark
    (0x9a, 0x5e, 0x36),  # 9 bark
    (0xd2, 0x3c, 0x46),  # a mushroom red
    (0xff, 0x86, 0xc0),  # b fairy pink
    (0xff, 0xd7, 0x6a),  # c gold
    (0x86, 0xec, 0xff),  # d cyan glow
    (0xc9, 0xc0, 0xe6),  # e lilac
    (0xff, 0xfa, 0xf0),  # f white
]

W, H = 128, 256
sheet = [[0] * W for _ in range(H)]


def put(art, x0, y0):
    rows = [r for r in art.strip("\n").split("\n")]
    for y, row in enumerate(rows):
        for x, ch in enumerate(row.strip()):
            if ch != ".":
                sheet[y0 + y][x0 + x] = int(ch, 16)


def tile_xy(tid):
    return (tid % 16) * 8, (tid // 16) * 8


def put_tile(art, tid):
    put(art, *tile_xy(tid))


def remap(art, mapping):
    return "".join(mapping.get(c, c) for c in art)


# ======================= 8x8 sprites (row 0) =======================
# 0-3: dewdrop ball, a pink glint rolls around it (fixed highlight)
BALL = """
..1111..
.1fedd1.
1feddddd
1edddddd
1ddddde3
1dddde33
.1dde33.
..1111..
"""
# close the outline on the right side (art above keeps it compact)
BALL = """
..1111..
.1fedd1.
1feddde1
1eddddd1
1dddde31
1ddde331
.1de331.
..1111..
"""
for i, (gx, gy) in enumerate([(5, 2), (5, 5), (2, 5), (2, 2)]):
    x0, y0 = tile_xy(i)
    put(BALL, x0, y0)
    sheet[y0 + gy][x0 + gx] = 0xb

# 4-7: sparkle, 4 frames
SPARK = [
"""
........
........
........
...f....
........
........
........
........
""", """
........
........
...d....
..dfd...
...d....
........
........
........
""", """
........
...d....
...c....
.dcfcd..
...c....
...d....
........
........
""", """
...d....
........
...c....
d.cfc.d.
...c....
........
...d....
........
"""]
for i, a in enumerate(SPARK):
    put_tile(a, 4 + i)

# 8: firefly
put_tile("""
........
........
...77...
..7cc7..
..7cc7..
...77...
........
........
""", 8)
# 9: tiny glowing mushroom (fairy ring stones)
put_tile("""
........
..1111..
.1dfdd1.
1dddddd1
.11ee11.
...ee...
...ee...
........
""", 9)
# 10/11: lane rollover bud (closed) / flower (open, lit)
put_tile("""
........
...55...
..5665..
..5765..
..5665..
...55...
...44...
........
""", 10)
put_tile("""
..b..b..
.bfbbfb.
..bccb..
.bbcfbb.
..bccb..
.bfbbfb.
..b44b..
........
""", 11)
# 12/13: kickback arrow dim / lit
put_tile("""
...33...
..3223..
.322223.
3322223.
...22...
...22...
...22...
........
""", 12)
put_tile("""
...cc...
..cffc..
.cffffc.
ccffffcc
...ff...
...cf...
...cf...
........
""", 13)
# 14: flower decor, 15: clover decor
put_tile("""
........
..b.b...
.bcfcb..
..bcb...
...6....
..66.6..
...66...
........
""", 14)
put_tile("""
........
.66.66..
6776776.
.66666..
..6.6...
...5....
...5....
........
""", 15)

# ======================= texture tiles (row 1) =======================
# 16: RIM tile. Row d = colour for pixels d+1 px inside a wall (rows 0-3),
#     rows 4-5 = floor pixels 1-2 px from a wall (contact shadow).
put_tile("""
76677676
56565665
45454554
48848448
11111111
21212112
22222222
22222222
""", 16)
# 17: sling texture (petal stripes), 18: post (pebble), 19: gate
put_tile("""
bbfbbbbf
bbbbfbbb
abbbbbab
babbbbba
bbabbabb
bbbaabbb
abbbbbba
bbbfbbbb
""", 17)
put_tile("""
eeefeeee
eeeeeeef
eeeeee3e
3eeeeeee
eeeefeee
ee3eeeee
eeeeeee3
feeeeeee
""", 18)
put_tile("""
cccccccc
cccccccc
11111111
11111111
cccccccc
cccccccc
11111111
11111111
""", 19)

# 20-23: plunger spring, 4 compression frames (8 wide)
SPRINGS = [
"""
.cccccc.
.c9999c.
..eeee..
.e....e.
..eeee..
.e....e.
..eeee..
.e....e.
""", """
........
.cccccc.
.c9999c.
..eeee..
.e....e.
..eeee..
.eeeeee.
.e....e.
""", """
........
........
.cccccc.
.c9999c.
..eeee..
.eeeeee.
.eeeeee.
.e....e.
""", """
........
........
........
.cccccc.
.c9999c.
.eeeeee.
.eeeeee.
.e....e.
"""]
for i, a in enumerate(SPRINGS):
    put_tile(a, 20 + i)

# 24: grass tuft decor, 25: fern decor, 26: stones decor, 27: star
put_tile("""
........
........
.7...7..
.6.7.6..
.66.66..
..666...
.56665..
........
""", 24)
put_tile("""
....6...
...767..
..67.6..
.6.676..
...6.67.
..676...
.6..6...
....5...
""", 25)
put_tile("""
........
........
........
..3e....
.3ee3.e.
.13311e3
..11.13.
........
""", 26)
put_tile("""
........
...c....
...c....
.ccfcc..
...c....
...c....
........
........
""", 27)

# ======================= 16x16 sprites (rows 2-3: ids 32..47) =======================
BUMPER = """
................
.....111111.....
...11aaaaaa11...
..1afaaaaaaba1..
.1affaaaaffaba1.
.1aaaaaaaffaaa1.
1aaaaffaaaaaafa1
1baaaffaaaaaaaa1
1aaaaaaaaaafaa81
.11188888888111.
....1eeeeee1....
....1e1ee1e1....
....1beeeeb1....
....1eeeeee1....
....1eeeeee1....
.....111111.....
"""
put(BUMPER, *tile_xy(32))
put(remap(BUMPER, {"a": "b", "f": "c", "b": "f", "8": "a"}), *tile_xy(34))

TARGET = """
................
................
......1111......
....11333311....
...1333e33331...
..13e3333e3331..
..133333333e31..
..1333e3333331..
...1122222211...
......1ee1......
......1ee1......
.....1eeee1.....
.....155551.....
....15566551....
................
................
"""
put(TARGET, *tile_xy(36))
put(remap(TARGET, {"3": "d", "e": "f", "2": "3"}), *tile_xy(38))

FAIRY_UP = """
................
.dd.........dd..
.dfd.......dfd..
..dfd.bbb.dfd...
...dd bbbb dd...
.....bbfeb......
.....befe1......
......eee.......
.....ddddd......
....d.ddd.d.....
.....ddddd......
......e.e.......
......e.e.......
................
................
................
"""
FAIRY_DOWN = """
................
................
................
......bbb.......
.....bbbbb......
.dd..bbfeb..dd..
.dfd.befe1.dfd..
..dfdeeeeedfd...
...ddddddddd....
....d.ddd.d.....
.....ddddd......
......e.e.......
......e.e.......
................
................
................
"""
put(FAIRY_UP.replace(" ", "."), *tile_xy(40))
put(FAIRY_DOWN.replace(" ", "."), *tile_xy(42))

# 44/46: fairy ring portal (the capture hole), 2 glow frames
def portal(frame):
    out = [[0] * 16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - 7.5, y - 7.5)
            if d < 3.2:
                out[y][x] = 0x0 if d < 2.2 else 0x1
            elif d < 4.4:
                out[y][x] = 0x3 if (x + y + frame) % 2 else 0x1
    for i in range(8):
        a = (i + frame * 0.5) / 8 * 2 * math.pi
        mx, my = int(round(7.5 + math.cos(a) * 6.2)), int(round(7.5 + math.sin(a) * 6.2))
        for dx, dy, c in ((0, 0, 0xd if i % 2 == frame else 0xf), (-1, 0, 0xd), (1, 0, 0xd), (0, 1, 0xe)):
            if 0 <= mx + dx < 16 and 0 <= my + dy < 16:
                out[my + dy][mx + dx] = c
    return out


for f, tid in ((0, 44), (1, 46)):
    x0, y0 = tile_xy(tid)
    for y, row in enumerate(portal(f)):
        for x, c in enumerate(row):
            sheet[y0 + y][x0 + x] = c

# ======================= 16x16 textures (rows 4-5: ids 64..) =======================
def tex_floor(x, y):
    # dark violet forest floor: soft lighter patches, specks, tiny clovers
    h = (x * 7 + y * 13 + (x * y) % 5) % 16
    patch = (math.sin(x * 2 * math.pi / 16) + math.cos(y * 2 * math.pi / 16)) > 1.2
    if (x, y) in ((3, 4), (11, 12), (12, 3)):
        return 0x3
    if (x, y) in ((7, 9), (1, 13)):
        return 0x5
    if (x, y) in ((14, 8),):
        return 0x4
    if patch and h % 3 == 0:
        return 0x3
    return 0x2


def tex_bark(x, y):
    # vertical-ish grain with a knot; tiles seamlessly in 16x16
    wave = math.sin((y + x * 0.0) * 2 * math.pi / 16 + x * 0.9)
    k = math.hypot(x - 11, y - 5)
    if 1.0 < k < 2.0:
        return 0x9
    if k <= 1.0:
        return 0x1
    if x % 4 == 0:
        return 0x1 if wave > 0.3 else 0x8
    if x % 4 == 2 and wave > -0.2:
        return 0x9
    return 0x8


for tid, fn in ((64, tex_floor), (66, tex_bark)):
    x0, y0 = tile_xy(tid)
    for y in range(16):
        for x in range(16):
            sheet[y0 + y][x0 + x] = fn(x, y)

# 68: big toadstool decor (16x16), 70: mushroom cluster decor
put("""
................
................
.....111111.....
...11bbbbbb11...
..1bbfbbbbbfb1..
.1bbbbbbfbbbbb1.
.1bfbbbbbbbbfb1.
..111eeeeee111..
.....1eeee1.....
.....1eeee1.....
.....1eeee1.....
....155eee51....
...15566665551..
................
................
................
""", *tile_xy(68))
put("""
................
................
................
................
................
.........111....
........1ddd1...
..111..1dfddd1..
.1aaa1..11e11...
1afaaa1...e.....
.11e11....e.....
...e......e.....
...e...1111.....
..5e5.1cfcc1....
.55e5555e5555...
................
""", *tile_xy(70))

# ======================= table-generator toys (rows 6-7: ids 96..) =======================
# 96/98: firefly lantern (moving bumper), glow flicker frames
LANTERN = """
.......11.......
......1991......
.....111111.....
....1c7777c1....
...1c777777c1...
...17cfcc777c1..
...17cfc77777c..
...17cc777777c1.
...177777777c1..
...1c777777c1...
....1c7777c1....
.....111111.....
......1991......
.......11.......
................
................
"""
put(LANTERN, *tile_xy(96))
put(remap(LANTERN, {"7": "c", "c": "7"}), *tile_xy(98))

# 100/102/104: acorn bash toy: whole, cracked, nearly broken
ACORN = """
................
.....1111111....
....198989891...
...19898989891..
...11111111111..
....1bbbbbbb1...
....1bbfbbbb1...
....1bfbbbbb1...
....1bbbbbbb1...
....1bbbbbb81...
.....1bbbb81....
......1bb81.....
.......111......
................
................
................
"""
ACORN = ACORN.replace("b", "9")
put(ACORN, *tile_xy(100))
CRACK1 = ACORN.split("\n")
put("\n".join(r if i not in (7, 8) else r[:7] + "1" + r[8:] for i, r in enumerate(CRACK1)), *tile_xy(102))
put("\n".join(r if i not in (5, 6, 7, 8, 9) else r[:6] + "1" + r[7:9] + "1" + r[10:]
              for i, r in enumerate(CRACK1)), *tile_xy(104))

# 106/108: golden score toadstool (bumper variant), normal / hit
put(remap(BUMPER, {"a": "c", "8": "9", "b": "f", "f": "f"}), *tile_xy(106))
put(remap(BUMPER, {"a": "f", "8": "c", "b": "c", "f": "c"}), *tile_xy(108))

# 28: updraft wind arrow, 29: blocker post (small mushroom), 30: lit post
put_tile("""
...dd...
..dffd..
.dd..dd.
d..dd..d
..dffd..
.dd..dd.
d......d
........
""", 28)
put_tile("""
..1111..
.1eeee1.
1effffe1
1eeeeee1
.11ee11.
..1ee1..
..1ee1..
...11...
""", 29)
put_tile("""
..1111..
.1cccc1.
1cffffc1
1cccccc1
.11ff11.
..1ff1..
..1ff1..
...11...
""", 30)

# ======================= flippers (sprite bank, y >= 128) =======================
# 8 frames, 32x24 each, pivot at (6,12). Shape = the physics shape:
# tapered capsule, hub r=5, tip r=3, length 19, angle 26.5 deg down -> 31 up.
FL_LEN, FL_RH, FL_RT, PX, PY = 19, 5, 3, 6, 12


def flipper_frame(k):
    th = math.radians(26.5 - 3.83 * (2 * k + 0.5))
    ux, uy = math.cos(th), math.sin(th)
    nux, nuy = uy, -ux  # up-side normal

    def inside(px, py):
        dx, dy = px - PX, py - PY
        t = max(0.0, min(FL_LEN, dx * ux + dy * uy))
        r = FL_RH + (FL_RT - FL_RH) * t / FL_LEN
        cx, cy = ux * t, uy * t
        return math.hypot(dx - cx, dy - cy) <= r + 0.15

    out = [[0] * 32 for _ in range(24)]
    ins = [[inside(x + 0.5, y + 0.5) for x in range(32)] for y in range(24)]
    for y in range(24):
        for x in range(32):
            if not ins[y][x]:
                continue
            edge = any(not (0 <= x + dx < 32 and 0 <= y + dy < 24 and ins[y + dy][x + dx])
                       for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            dx, dy = x + 0.5 - PX, y + 0.5 - PY
            h = dx * nux + dy * nuy  # + = top side
            t = dx * ux + dy * uy
            if edge:
                c = 0x1
            elif h > 1.6:
                c = 0x7  # sunlit top edge
            elif abs(h) < 0.6 and t > 4:
                c = 0x7  # leaf vein
            elif h > -1.2:
                c = 0x6
            else:
                c = 0x5
            out[y][x] = c
    # hub: a gold acorn-cap pivot
    for y in range(24):
        for x in range(32):
            d = math.hypot(x + 0.5 - PX, y + 0.5 - PY)
            if d < 1.0:
                out[y][x] = 0x9
            elif d < 2.2:
                out[y][x] = 0xc
    return out


for k in range(8):
    x0, y0 = (k % 4) * 32, 128 + (k // 4) * 24
    for y, row in enumerate(flipper_frame(k)):
        for x, c in enumerate(row):
            sheet[y0 + y][x0 + x] = c


# ======================= write PNG =======================
def write_indexed_png(path, rows, pal, transparent=True):
    raw = b"".join(b"\0" + bytes(r) for r in rows)

    def chunk(kind, data):
        c = kind + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 3, 0, 0, 0))
    png += chunk(b"PLTE", b"".join(bytes(c) for c in pal))
    if transparent:
        png += chunk(b"tRNS", b"\0")  # index 0 shows as transparent in editors
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "fairy_ring_sprites.png"
    write_indexed_png(out, sheet, PAL)
    # optional 4x preview with a visible background, for eyeballing
    if len(sys.argv) > 2:
        prev = []
        for row in sheet:
            r = []
            for c in row:
                r += [c if c else 1] * 4
            prev += [r] * 4
        write_indexed_png(sys.argv[2], prev, PAL)
    print("wrote", out)
