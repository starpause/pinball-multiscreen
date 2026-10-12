"""Game-over art concepts: full-screen 240x136, 16 colours each.

    python art/gen_gameover.py

Writes art/gameover_<name>.png (indexed, 16 colours, the in-game asset),
art/gameover_<name>_x3.png (preview) and art/gameover_options.png
(all concepts side by side). Every scene keeps the right ~100 px darker
for the stats text.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paint import Canvas, W, H, clamp, mix, hexc, lit, quantize, write_png  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- the fairy
def paint_fairy(cv, cx, cy, s, c, eyes="open", vines=None):
    """cx, cy = head centre; s = scale (1.0 ~ 13 px head radius).
    c: dict of colours (hair, hair_hi, skin, skin_sh, dress, dress_hi,
    wing, wing_hi, eye, crown, crown2, line)."""
    # wings (behind), translucent with veins and a bright rim
    def wing_col(nx, ny, d):
        if d > 0.86:
            return mix(c["wing"], c["line"], 0.45)            # dark rim
        return mix(c["wing_hi"], c["wing"], clamp(d * 1.15))
    for side in (-1, 1):
        cv.ellipse(cx + side * 22 * s, cy + 3 * s, 18 * s, 11 * s, wing_col, 0.7, rot=side * 0.75)
        cv.ellipse(cx + side * 17 * s, cy + 26 * s, 11 * s, 7.5 * s, wing_col, 0.7, rot=-side * 0.55)
        cv.ellipse(cx + side * 25 * s, cy - 4 * s, 3.2 * s, 3.2 * s, c["crown2"], 0.55)
        cv.ellipse(cx + side * 25 * s, cy - 4 * s, 1.6 * s, 1.6 * s, c["wing_hi"], 0.8)
        for k in range(4):
            a = -0.9 + k * 0.45
            ex = cx + side * (6 + 30 * math.cos(a)) * s
            ey = cy + (14 + 24 * math.sin(a)) * s
            cv.capsule(cx + side * 4 * s, cy + 16 * s, ex, ey, 0.45 * s, c["wing"], 0.35)
        cv.ellipse(cx + side * 27 * s, cy - 1 * s, 4 * s, 3 * s, c["wing_hi"], 0.55)
    # long hair behind the body
    for side in (-1, 1):
        cv.ellipse(cx + side * 12 * s, cy + 15 * s, 6 * s, 15 * s,
                   lambda nx, ny, d: lit(c["hair"], nx, ny, amb=0.6, spec=0.15), 1.0, rot=side * -0.12)
    # petal skirt (kneeling: wide, sitting in the grass)
    def dress_col(nx, ny, d):
        return lit(mix(c["dress_hi"], c["dress"], clamp(ny * 0.5 + 0.5)), nx, ny, amb=0.62, spec=0.2)
    cv.ellipse(cx, cy + 36 * s, 17 * s, 11 * s, dress_col)
    for k in range(7):
        px = cx + (-15 + k * 5) * s
        cv.ellipse(px, cy + 44 * s, 4.2 * s, 3.4 * s, dress_col)
    # torso
    cv.ellipse(cx, cy + 21 * s, 6.5 * s, 9 * s, dress_col)
    # arms + hands resting in the lap
    for side in (-1, 1):
        cv.capsule(cx + side * 6 * s, cy + 15 * s, cx + side * 7.5 * s, cy + 29 * s, 2.3 * s,
                   lambda t, d: mix(c["skin"], c["skin_sh"], clamp(d * 0.8)))
        cv.ellipse(cx + side * 5.5 * s, cy + 31 * s, 2.6 * s, 2.2 * s, c["skin"])
    cv.capsule(cx, cy + 10 * s, cx, cy + 14 * s, 2.5 * s, c["skin_sh"])
    # hair mass + face
    cv.ellipse(cx, cy - 1 * s, 16 * s, 16 * s,
               lambda nx, ny, d: lit(c["hair"], nx, ny, amb=0.62, spec=0.3, sharp=20))
    cv.ellipse(cx, cy + 3 * s, 12 * s, 11.5 * s,
               lambda nx, ny, d: mix(c["skin"], c["skin_sh"], clamp((d - 0.55) * 1.6 + ny * 0.25)))
    # bangs: a jagged fringe of hair locks
    for k in range(7):
        bx = cx + (-10.5 + k * 3.5) * s
        cv.ellipse(bx, cy - 5.5 * s + abs(k - 3) * 0.6 * s, 3.2 * s, 6.8 * s,
                   lambda nx, ny, d: lit(c["hair"], nx * 0.5, ny, amb=0.7, spec=0.25), 1.0,
                   rot=(k - 3) * 0.12)
    # anime hair shine (angel ring)
    for k in range(9):
        a = math.pi * (1.15 + k * 0.09)
        cv.ellipse(cx + math.cos(a) * 11 * s, cy - 2 * s + math.sin(a) * 9 * s, 1.6 * s, 0.8 * s,
                   c["hair_hi"], 0.85, rot=a + math.pi / 2)
    # eyes
    for side in (-1, 1):
        ex, ey = cx + side * 5.2 * s, cy + 4 * s
        if eyes == "open":
            cv.ellipse(ex, ey, 3.4 * s, 4.2 * s, c["line"])
            cv.ellipse(ex, ey + 0.3 * s, 2.7 * s, 3.5 * s,
                       lambda nx, ny, d: mix(c["eye"], c["wing_hi"], clamp(ny * 0.6 + 0.45)))
            cv.ellipse(ex, ey + 0.6 * s, 1.3 * s, 1.8 * s, c["line"], 0.75)
            cv.ellipse(ex - 1.1 * s, ey - 1.5 * s, 1.0 * s, 1.0 * s, (255, 255, 255))
            cv.ellipse(ex + 1.2 * s, ey + 1.8 * s, 0.5 * s, 0.5 * s, (255, 255, 255), 0.9)
            cv.capsule(ex - 3.6 * s, ey - 3.4 * s, ex + 3.4 * s, ey - 3.9 * s, 0.75 * s, c["line"])
        else:  # closed: soft downward arcs with a lash flick
            cv.bezier([(ex - 3.4 * s, ey), (ex - 1.5 * s, ey + 2.2 * s), (ex + 1.5 * s, ey + 2.2 * s),
                       (ex + 3.4 * s, ey)], 0.6 * s, c["line"], steps=16)
            cv.capsule(ex + side * 3.4 * s, ey, ex + side * 4.4 * s, ey - 1 * s, 0.45 * s, c["line"])
    # blush + mouth
    for side in (-1, 1):
        cv.ellipse(cx + side * 8 * s, cy + 8.5 * s, 2.2 * s, 1.2 * s, c["crown2"], 0.38)
    cv.bezier([(cx - 1.4 * s, cy + 10.2 * s), (cx - 0.4 * s, cy + 11 * s), (cx + 0.4 * s, cy + 11 * s),
               (cx + 1.4 * s, cy + 10.2 * s)], 0.4 * s, c["line"], steps=10, alpha=0.8)
    # flower crown
    for k in range(5):
        a = math.pi * (1.28 + k * 0.11)
        fx, fy = cx + math.cos(a) * 15 * s, cy - 1.5 * s + math.sin(a) * 14.5 * s
        col = c["crown"] if k % 2 == 0 else c["crown2"]
        for p in range(5):
            pa = p / 5 * 2 * math.pi + k
            cv.ellipse(fx + math.cos(pa) * 1.1 * s, fy + math.sin(pa) * 1.1 * s, 0.9 * s, 0.9 * s, col)
        cv.ellipse(fx, fy, 0.6 * s, 0.6 * s, (255, 236, 150))
    # a leaf or two between the flowers
    for k in range(4):
        a = math.pi * (1.335 + k * 0.11)
        cv.ellipse(cx + math.cos(a) * 15.5 * s, cy - 1.5 * s + math.sin(a) * 15 * s, 1.4 * s, 0.6 * s,
                   c["vine_hi"], 0.9, rot=a)
    # thorn vines wrapping her (Earthbind)
    if vines:
        for pts in vines:
            cv.bezier(pts, 1.5 * s, lambda t, d: mix(c["vine_hi"], c["vine"], clamp(d)), steps=50)
            rnd = random.Random(int(pts[0][0] * 7 + pts[0][1]))
            for i in range(1, 12):
                x, y = cv.point_at(pts, i / 12)
                x2, y2 = cv.point_at(pts, i / 12 + 0.01)
                tx, ty = x2 - x, y2 - y
                l = math.hypot(tx, ty) or 1
                nx, ny = -ty / l, tx / l
                side = 1 if i % 2 else -1
                cv.poly([(x - tx / l * 0.9 * s, y - ty / l * 0.9 * s), (x + tx / l * 0.9 * s, y + ty / l * 0.9 * s),
                         (x + nx * side * 3.2 * s, y + ny * side * 3.2 * s)], c["thorn"])
                if rnd.random() < 0.18:
                    rose(cv, x + nx * 2 * s, y + ny * 2 * s, 2.6 * s, c)


def rose(cv, x, y, r, c):
    cv.ellipse(x, y, r, r, lambda nx, ny, d: lit(c["rose"], nx, ny, amb=0.6, spec=0.2))
    for k in range(3):
        a = k * 2.1
        cv.ellipse(x + math.cos(a) * r * 0.35, y + math.sin(a) * r * 0.35, r * 0.45, r * 0.3,
                   c["rose_dk"], 0.7, rot=a)
    cv.ellipse(x - r * 0.3, y - r * 0.35, r * 0.3, r * 0.22, c["rose_hi"], 0.8)


def stars(cv, n, seed, y_max=80, x_max=W, col=(255, 250, 230)):
    rnd = random.Random(seed)
    for _ in range(n):
        x, y = rnd.random() * x_max, rnd.random() * y_max
        r = 0.35 + rnd.random() * 0.5
        cv.ellipse(x, y, r, r, col, 0.6 + rnd.random() * 0.4)
        if rnd.random() < 0.12:
            cv.capsule(x - 2.5, y, x + 2.5, y, 0.25, col, 0.6)
            cv.capsule(x, y - 2.5, x, y + 2.5, 0.25, col, 0.6)


def moon(cv, x, y, r, col, glow):
    for k in range(6, 0, -1):
        cv.ellipse(x, y, r * (1 + k * 0.32), r * (1 + k * 0.32), glow, 0.07)
    cv.ellipse(x, y, r, r, lambda nx, ny, d: mix(col, mix(col, glow, 0.5), clamp(d ** 3)))
    for (dx, dy, cr) in ((-0.3, -0.25, 0.22), (0.25, 0.2, 0.16), (0.05, -0.45, 0.1), (-0.15, 0.4, 0.12)):
        cv.ellipse(x + dx * r, y + dy * r, cr * r, cr * r, mix(col, glow, 0.55), 0.6)


def grass(cv, y0, seed, cols, n=220, h=(10, 26), x_range=(0, W)):
    rnd = random.Random(seed)
    for _ in range(n):
        x = x_range[0] + rnd.random() * (x_range[1] - x_range[0])
        hh = h[0] + rnd.random() * (h[1] - h[0])
        lean = (rnd.random() - 0.5) * 8
        col = cols[rnd.randrange(len(cols))]
        cv.bezier([(x, y0 + 4), (x, y0 - hh * 0.4), (x + lean * 0.5, y0 - hh * 0.8), (x + lean, y0 - hh)],
                  1.1, lambda t, d, col=col: mix(col, (255, 255, 255), t * 0.15), steps=10, taper=0.15)


def darken_right(cv, x0=138, amount=0.5):
    def f(x, y):
        if x < x0:
            return None
        return ((0, 0, 0), clamp((x - x0) / 30) * amount)
    cv.fill(f)


def sky(cv, stops):
    """vertical gradient: stops = [(y_frac, rgb), ...]"""
    def f(x, y):
        t = y / H
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                u = (t - stops[i][0]) / (stops[i + 1][0] - stops[i][0])
                return (mix(stops[i][1], stops[i + 1][1], u), 1.0)
        return (stops[-1][1], 1.0)
    cv.fill(f)


FAIRY = {
    "hair": hexc("f283c0"), "hair_hi": hexc("ffd9ef"), "skin": hexc("ffe7dc"), "skin_sh": hexc("e9b3b0"),
    "dress": hexc("62ad48"), "dress_hi": hexc("c8f080"), "wing": hexc("5fd6f0"), "wing_hi": hexc("e8fbff"),
    "eye": hexc("2a6fb0"), "crown": hexc("ffd76a"), "crown2": hexc("ff6fa0"), "line": hexc("3a1f3a"),
    "vine": hexc("1f4a2c"), "vine_hi": hexc("4f8a3c"), "thorn": hexc("162a1c"),
    "rose": hexc("d23c46"), "rose_dk": hexc("7a1830"), "rose_hi": hexc("ff9aa8"),
}


# ---------------------------------------------------------------- scenes
def scene_earthbind():
    """moonlit bamboo grove, the fairy kneeling bound in thorn vines"""
    cv = Canvas()
    sky(cv, [(0, hexc("0a1020")), (0.45, hexc("1d3a52")), (0.8, hexc("2c5a52")), (1, hexc("1a3326"))])
    stars(cv, 70, 3, y_max=70)
    moon(cv, 104, 30, 22, hexc("fff4d6"), hexc("8fd0e0"))
    rnd = random.Random(5)
    for k in range(12):  # bamboo stalks, far (dark) to near
        x = rnd.choice([rnd.random() * 70, 128 + rnd.random() * 18])
        far = k < 9
        col = hexc("1c3f3a") if far else hexc("3f7a48")
        hi = hexc("2c5a4c") if far else hexc("7fbf6a")
        w = 2.2 if far else 3.2
        cv.capsule(x, 0, x + rnd.uniform(-3, 3), H, w, lambda t, d, col=col, hi=hi: mix(hi, col, clamp(d)))
        for ny in range(10, H, 22):
            cv.capsule(x - w, ny, x + w, ny, 0.6, hi, 0.8)
        for _ in range(2):
            ly = rnd.random() * 90
            cv.ellipse(x + 7, ly, 8, 2, hi if not far else col, 0.9, rot=rnd.uniform(-0.5, 0.5))
    grass(cv, H - 20, 11, [hexc("2c5a3a"), hexc("3f7a48"), hexc("4f8a3c")], n=160, h=(8, 22), x_range=(0, 150))
    vines = [
        [(30, 84), (55, 70), (80, 92), (106, 78)],
        [(36, 104), (60, 92), (82, 110), (108, 98)],
        [(52, 60), (70, 76), (60, 96), (88, 120)],
    ]
    vines = [[(x * 1.2 - 12, y * 1.15 - 10) for (x, y) in v] for v in vines]
    paint_fairy(cv, 72, 52, 1.4, FAIRY, eyes="closed", vines=vines)
    grass(cv, H, 12, [hexc("1f4a2c"), hexc("2c5a3a"), hexc("62ad48")], n=140, h=(6, 18), x_range=(0, 150))
    darken_right(cv)
    return cv


def scene_dream():
    """dusk: she sleeps sitting on a giant glowing toadstool among fireflies"""
    cv = Canvas()
    sky(cv, [(0, hexc("1a1238")), (0.4, hexc("4a2a6a")), (0.75, hexc("b0507a")), (1, hexc("ff9a80"))])
    stars(cv, 50, 8, y_max=55)
    rnd = random.Random(9)
    for _ in range(18):  # bokeh
        x, y, r = rnd.random() * 200, 40 + rnd.random() * 80, 2 + rnd.random() * 5
        cv.ellipse(x, y, r, r, hexc("ffd7a0"), 0.18)
    # far hills
    cv.fill(lambda x, y: (hexc("2a1a40"), 1.0) if y > 104 + 8 * math.sin(x * 0.04) else None)
    # the toadstool
    cv.capsule(66, 98, 66, 132, 9, lambda t, d: mix(hexc("fff0e0"), hexc("c9a0b0"), clamp(d)), r2=12)
    cv.ellipse(66, 96, 44, 17, lambda nx, ny, d: lit(hexc("e23c5a"), nx, ny, amb=0.55, spec=0.35))
    for (dx, dy, r) in ((-24, -6, 4), (-6, -10, 5), (14, -7, 4.5), (28, -2, 3), (-34, 1, 3), (3, 1, 3.5)):
        cv.ellipse(66 + dx, 96 + dy, r, r * 0.75, hexc("fff4f0"))
    paint_fairy(cv, 66, 50, 1.1, FAIRY, eyes="closed")
    for _ in range(26):  # fireflies
        x, y = rnd.random() * 140, 20 + rnd.random() * 100
        cv.ellipse(x, y, 3, 3, hexc("ffe680"), 0.18)
        cv.ellipse(x, y, 0.9, 0.9, hexc("fffbd0"))
    grass(cv, H, 21, [hexc("3a2050"), hexc("5a3070"), hexc("7a3a6a")], n=120, h=(5, 14))
    darken_right(cv, amount=0.55)
    return cv


def scene_ring():
    """a misty clearing: she floats over a ring of glowing mushrooms"""
    cv = Canvas()
    sky(cv, [(0, hexc("06101a")), (0.35, hexc("0c2a3a")), (0.6, hexc("164a4a")), (1, hexc("0a1a1a"))])
    # aurora ribbons
    for k in range(3):
        y0 = 18 + k * 9
        cv.bezier([(-10, y0 + 10), (60, y0 - 12), (130, y0 + 16), (250, y0 - 6)], 5 - k,
                  lambda t, d: mix(hexc("7af0c0"), hexc("2a8a8a"), clamp(d)), steps=60, alpha=0.28)
    stars(cv, 60, 4, y_max=70)
    # trees silhouettes
    rnd = random.Random(14)
    for _ in range(9):
        x, h = rnd.random() * 240, 40 + rnd.random() * 40
        cv.poly([(x - 12, 112), (x, 112 - h), (x + 12, 112)], hexc("0b1f22"))
    cv.fill(lambda x, y: (hexc("13302a"), 1.0) if y > 108 else None)
    # the ring (an ellipse of glowing mushrooms), back half first
    ringc, rx, ry, cy0 = 70, 52, 12, 112
    caps = [hexc("8ff0ff"), hexc("ffd76a"), hexc("ff86c0")]
    pts = sorted([(math.sin(a) , a) for a in [i / 14 * 2 * math.pi for i in range(14)]])
    for sn, a in pts:
        x, y = ringc + math.cos(a) * rx, cy0 + math.sin(a) * ry
        sc = 0.8 + 0.25 * (math.sin(a) + 1) / 2
        col = caps[int(a * 7) % 3]
        cv.ellipse(x, y - 3 * sc, 9 * sc, 6 * sc, col, 0.15)
        cv.capsule(x, y, x, y - 5 * sc, 1.4 * sc, hexc("e8e0f0"))
        cv.ellipse(x, y - 6 * sc, 4.2 * sc, 2.6 * sc, lambda nx, ny, d, col=col: lit(col, nx, ny, amb=0.7))
        if sn < 0.2:  # back half: draw fairy after the first half
            pass
    # mist
    for k in range(4):
        cv.fill(lambda x, y, k=k: ((200, 230, 230), 0.07) if abs(y - (100 + k * 8 + 3 * math.sin(x * 0.05 + k))) < 3 else None)
    # glow under her + the fairy, floating, awake
    cv.ellipse(ringc, 112, 30, 7, hexc("8ff0ff"), 0.18)
    paint_fairy(cv, ringc, 44, 1.0, FAIRY, eyes="open")
    for _ in range(30):  # sparkles
        x, y = ringc + rnd.uniform(-46, 46), rnd.uniform(20, 108)
        r = rnd.uniform(0.4, 1.0)
        cv.ellipse(x, y, r, r, hexc("fffbd0"))
    darken_right(cv, amount=0.5)
    return cv


def main():
    names = sys.argv[1:] or ["earthbind", "dream", "ring"]
    scenes = {"earthbind": scene_earthbind, "dream": scene_dream, "ring": scene_ring}
    shots = []
    for n in names:
        print("painting", n, flush=True)
        rgb = scenes[n]().downsample()
        idx, pal = quantize(rgb, 16)
        write_png(os.path.join(HERE, "gameover_%s.png" % n), idx, pal)
        write_png(os.path.join(HERE, "gameover_%s_x3.png" % n), idx, pal, scale=3)
        shots.append((idx, pal))
    # side-by-side contact sheet (each 240x136, 2x, with gaps), as RGB
    rows = []
    for idx, pal in shots:
        for y in range(H):
            r = []
            for x in range(W):
                r += [pal[idx[y][x]]] * 2
            rows += [r, r]
        rows += [[(255, 255, 255)] * (W * 2)] * 6
    write_png(os.path.join(HERE, "gameover_options.png"), rows)
    print("wrote art/gameover_*.png")


if __name__ == "__main__":
    main()
