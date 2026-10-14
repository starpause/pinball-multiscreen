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

# 128/130: yellow pixie (moving bumper that bursts into dust), recoloured fairy
PIXIE_MAP = {"b": "c", "d": "7"}
put(remap(FAIRY_UP.replace(" ", "."), PIXIE_MAP), *tile_xy(128))
put(remap(FAIRY_DOWN.replace(" ", "."), PIXIE_MAP), *tile_xy(130))

# 132/134: beetle (catches the ball and tosses it up): closed / open jaws
BEETLE_BODY = [
    "......1441......",
    ".....144441.....",
    "..1..155551..1..",
    "...115575d511...",
    "....15575d551...",
    ".11155575d55111.",
    "....15575d551...",
    "...115575d511...",
    "..1.15555d551.1.",
    "....1555d5551...",
    ".....155d551....",
    "......11111.....",
    "................",
    "................",
]
put("\n".join(["......1..1......", ".......11......."] + BEETLE_BODY), *tile_xy(132))
put("\n".join(["....1......1....", ".....1....1....."] + BEETLE_BODY), *tile_xy(134))

# 31: small colony mushroom (stage 2), 110/111: spore rollover unlit / lit (stage 3)
put_tile("""
..1111..
.13e331.
1333e331
.111111.
..1ee1..
..1ee1..
...11...
........
""", 31)
SPORE = """
........
...11...
..1331..
.13e331.
..1331..
...11...
........
........
"""
put_tile(SPORE, 110)
put_tile(remap(SPORE, {"3": "d", "e": "f"}), 111)

# 136/138: wishing well (roulette: extra ball, saver, multiball...), idle / spinning
WELL = """
................
...1111111111...
..199999999991..
.19888888888891.
..111111111111..
...1........1...
...1........1...
..111111111111..
.1eeeeeeeeeeee1.
.1e3dddddddd3e1.
.1e3dddfdddd3e1.
.1eeeeeeeeeeee1.
.1e3e3e3e3e3ee1.
.1eeeeeeeeeeee1.
..111111111111..
................
"""
put(WELL, *tile_xy(136))
put(remap(WELL, {"d": "c", "f": "f", "3": "9"}), *tile_xy(138))

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


# ======================= level-10 fairy, poo piles, game-over art =======================
# 126/127: poo pile (ball-loss hazard on some drains) / splatted
put_tile("""
....1...
...181..
..18891.
..19981.
.1889881
.1998891
18888881
.111111.
""", 126)
put_tile("""
........
........
........
........
...1..1.
.1891981
18898891
.111111.
""", 127)


def chibi_fairy(W, H, sad=False):
    """Procedural chibi fairy (big eyes, butterfly wings, flower crown).
    Colours: hair b, wings d (+e/f), dress 7 (+6), skin f/e, crown c/a.
    Hair, wings and dress get recoloured per 10 levels in the game."""
    g = [[0] * W for _ in range(H)]
    s = W / 32.0  # designed at 32 px wide

    def ell(cx, cy, rx, ry, c, only_empty=False):
        for y in range(H):
            for x in range(W):
                if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1:
                    if not only_empty or g[y][x] == 0:
                        g[y][x] = c

    def rect(x0, y0, x1, y1, c):
        for y in range(max(0, int(y0)), min(H, int(y1))):
            for x in range(max(0, int(x0)), min(W, int(x1))):
                g[y][x] = c

    cx = W / 2
    # wings (behind): big upper lobes, small lower lobes, with spots
    for side in (-1, 1):
        ell(cx + side * 9.5 * s, 9 * s, 7 * s, 6.5 * s, 0xd)
        ell(cx + side * 8 * s, 19 * s, 5 * s, 4.5 * s, 0xd)
        ell(cx + side * 11 * s, 7.5 * s, 3 * s, 2.5 * s, 0xe)
        ell(cx + side * 9 * s, 19.5 * s, 2 * s, 1.8 * s, 0xe)
        ell(cx + side * 12.5 * s, 6 * s, 1.2 * s, 1.2 * s, 0xf)
    # dress: a petal bell, darker hem
    for y in range(int(17 * s), int(26 * s)):
        half = (2.5 * s + (y - 17 * s) * 0.6)
        for x in range(W):
            if abs(x + 0.5 - cx) <= half:
                g[y][x] = 0x6 if y >= int(25 * s) - 1 else 0x7
    # legs + shoes
    for lx in (cx - 2.5 * s, cx + 1.5 * s):
        rect(lx, 26 * s, lx + max(1, 1.2 * s), 30 * s, 0xf)
        rect(lx - 0.5 * s, 30 * s, lx + max(2, 2 * s), 31 * s, 0xb)
    # arms
    for side in (-1, 1):
        rect(cx + side * 4.5 * s - (1 if side < 0 else 0), 17.5 * s, cx + side * 4.5 * s + (0 if side < 0 else 1), 21.5 * s, 0xf)
    # head (skin) + hair cap + side locks
    hr = 6.2 * s
    hy = 10.5 * s
    ell(cx, hy - 0.8 * s, hr + 1.6 * s, hr + 1.2 * s, 0xb)          # hair mass
    ell(cx - 6.5 * s, hy + 3.5 * s, 1.8 * s, 4 * s, 0xb)             # locks
    ell(cx + 6.5 * s, hy + 3.5 * s, 1.8 * s, 4 * s, 0xb)
    ell(cx, hy + 1.2 * s, hr, hr * 0.92, 0xf)                         # face
    # bangs: scalloped fringe over the top of the face
    for x in range(W):
        fx = x + 0.5 - cx
        if abs(fx) < hr:
            edge = hy - 2.8 * s + 1.0 * s * abs(((fx / s) % 3) - 1.5) / 1.5
            for y in range(int(hy - hr), int(edge)):
                if 0 <= y < H and g[y][x] == 0xf:
                    g[y][x] = 0xb
    # shading under the hair
    for x in range(W):
        for y in range(H - 1):
            if g[y][x] == 0xb and g[y + 1][x] == 0xf:
                g[y + 1][x] = 0xe
    # eyes
    ey = int(hy + 0.6 * s)
    for side in (-1, 1):
        ew, eh = max(2, round(2.4 * s)), max(3, round(3.6 * s))
        ex = int(cx + side * 2.8 * s) - (ew if side < 0 else 0)
        if sad:
            for x in range(ex, ex + ew + 1):
                if 0 <= x < W:
                    g[ey + eh // 2][x] = 1
            continue
        rect(ex, ey, ex + ew, ey + eh, 1)          # dark outline / pupil
        rect(ex, ey + 1, ex + ew, ey + eh - 1, 0xd)  # big cyan iris
        g[ey + 1][ex] = 0xf                         # sparkle
        if eh >= 4:
            g[ey + eh - 2][ex + ew - 1] = 0xf
    # blush + mouth
    if s >= 0.7:
        for side in (-1, 1):
            bx = int(cx + side * 4.2 * s) - (1 if side < 0 else 0)
            if 0 <= bx < W:
                g[ey + int(2.8 * s)][bx] = 0xb
        my = ey + int(3.6 * s)
        g[my][int(cx) - 1] = 1 if not sad else 0xe
        if sad:
            g[my + 1][int(cx)] = 1
    # flower crown
    for k, fx in enumerate((-4, -1.5, 1.5, 4)):
        x, y = int(cx + fx * s), int(hy - hr - 0.4 * s)
        if 0 <= y < H and 0 <= x < W:
            g[y][x] = 0xc if k % 2 == 0 else 0xa
            if s >= 0.9 and y + 1 < H:
                g[y + 1][x] = 0xf
    # outline pass
    out = [row[:] for row in g]
    for y in range(H):
        for x in range(W):
            if g[y][x] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H and g[ny][nx] not in (0, 1):
                        out[y][x] = 1
                        break
    return out


def blit(img, x0, y0):
    for y, row in enumerate(img):
        for x, c in enumerate(row):
            if c:
                sheet[y0 + y][x0 + x] = c


def beetle_girl_32():
    half = [
        '......11........',
        '.....1ca1.......',
        '......11........',
        '.......11.......',
        '........1.......',
        '......1111111111',
        '....112222332222',
        '..11222222222222',
        '.1aa122222222222',
        '1caa122112222111',
        '11aa121221121111',
        '.111111221111111',
        '111...1fffffffff',
        '1be1.111111fffff',
        '1bde1ffb1f11ffff',
        '.1be11111aa1fffb',
        '..111..1b1a1ffff',
        '...11be111111111',
        '..1bbeee1aaa1111',
        '.1bbeeee111aa1cc',
        '.1bfeee11881aaaa',
        '..1beee118818aaa',
        '...1111118188aaa',
        '......11111fffff',
        '........11111111',
        '..........1111..',
        '..........1121..',
        '.........11aa1..',
        '.........1aca1..',
        '.........1aaaa1.',
        '.........111111.',
        '................',
    ]
    rows = [h + h[::-1] for h in half]
    return [[int(c, 16) if c != '.' else 0 for c in r] for r in rows]


def beetle_girl_24():
    half = [
        '....11......',
        '....1ca1....',
        '.....11.....',
        '......1.....',
        '....11111111',
        '..1122232222',
        '.1aa12222222',
        '1caa12211211',
        '.11111122111',
        '1be1.1ffffff',
        '1bde1ff11fff',
        '.1be11aa1ffb',
        '..111..11fff',
        '.1be11aaa11c',
        '1bfe1188aaaa',
        '.1be118188aa',
        '..111111ffff',
        '......111111',
        '........111.',
        '.......11aa1',
        '.......1aca1',
        '.......11111',
        '............',
        '............',
    ]
    rows = [h + h[::-1] for h in half]
    return [[int(c, 16) if c != '.' else 0 for c in r] for r in rows]


# sprite bank (ids 256+): 32x32 beetle girl boss at (0,176) = id 352,
# 24x24 medium at (32,176) = id 356, 64x64 game-over scene at (64,176) = id 360
BIG_FAIRY = beetle_girl_32()
blit(BIG_FAIRY, 0, 176)
blit(beetle_girl_24(), 32, 176)


def game_over_scene():
    W = H = 64
    g = [[0] * W for _ in range(H)]
    # stars
    for (x, y) in ((4, 5), (40, 3), (55, 9), (30, 12), (60, 22), (8, 26), (48, 18)):
        g[y][x] = 0xf
    # moon with craters
    for y in range(H):
        for x in range(W):
            d = math.hypot(x + 0.5 - 17, y + 0.5 - 15)
            if d < 10:
                g[y][x] = 0xc if d > 8.6 else 0xf
    for (x, y, r) in ((14, 12, 1.6), (20, 18, 1.2), (19, 10, 0.9)):
        for yy in range(H):
            for xx in range(W):
                if math.hypot(xx + 0.5 - x, yy + 0.5 - y) < r:
                    g[yy][xx] = 0xe
    # tall grass behind
    for x in range(W):
        h = 6 + int(3 * math.sin(x * 0.9) + 2 * math.sin(x * 0.37))
        for y in range(H - h - 4, H):
            if 0 <= y < H:
                g[y][x] = 0x4 if (x + y) % 3 else 0x5
    # the fairy, sad, kneeling into the grass
    fairy = chibi_fairy(40, 40, sad=True)
    for y in range(40):
        for x in range(40):
            c = fairy[y][x]
            if c and 18 + y < H - 3:
                g[18 + y][20 + x] = c
    # thorn vines wrapping across her: sine bands with spikes and roses
    for k, (y0, amp, ph) in enumerate(((44, 2.5, 0.0), (51, 2, 1.7), (56, 1.5, 3.1))):
        for x in range(4, 60):
            y = int(y0 + amp * math.sin(x * 0.28 + ph))
            for dy in (0, 1):
                if 0 <= y + dy < H:
                    g[y + dy][x] = 0x5 if dy == 0 else 0x4
            if x % 5 == k % 5 and 0 <= y - 1 < H:
                g[y - 1][x] = 1          # thorn
            if x % 13 == (k * 4) % 13 and 0 <= y - 1 < H:
                g[y - 1][x], g[y][x] = 0xa, 0xb  # little rose
    # ground
    for x in range(W):
        for y in range(H - 3, H):
            g[y][x] = 0x6 if y == H - 3 else 0x5
    return g


blit(game_over_scene(), 64, 176)


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
