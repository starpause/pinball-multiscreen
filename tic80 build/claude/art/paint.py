"""Tiny RGB 'painter' + 16-colour quantiser for full-screen TIC-80 art.

Scenes are painted at 2x (480x272) with soft, anti-aliased, shaded
shapes, downsampled to 240x136, then reduced to an optimal 16-colour
palette with ordered (Bayer) dithering, the way SNES-era title screens
read as "painted" at low resolution.

`quantize()` also imports any outside art: give it a PNG of any size.
Pure stdlib (no Pillow / numpy).
"""
import math
import struct
import zlib

W, H = 240, 136
S = 2                     # supersampling factor
W2, H2 = W * S, H * S


def clamp(v, a=0.0, b=1.0):
    return a if v < a else b if v > b else v


def mix(c1, c2, t):
    return (c1[0] + (c2[0] - c1[0]) * t, c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t)


def hexc(h):
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


class Canvas:
    def __init__(self):
        self.px = [[[0.0, 0.0, 0.0] for _ in range(W2)] for _ in range(H2)]

    # ---- primitives (all coordinates in final-pixel units; scaled by S) ----
    def blend(self, x, y, c, a):
        if a <= 0 or x < 0 or y < 0 or x >= W2 or y >= H2:
            return
        p = self.px[y][x]
        a = 1.0 if a > 1 else a
        p[0] += (c[0] - p[0]) * a
        p[1] += (c[1] - p[1]) * a
        p[2] += (c[2] - p[2]) * a

    def fill(self, fn):
        """fn(x, y) -> (rgb, alpha) or None, x/y in final pixels."""
        for y in range(H2):
            for x in range(W2):
                r = fn((x + 0.5) / S, (y + 0.5) / S)
                if r:
                    self.blend(x, y, r[0], r[1])

    def ellipse(self, cx, cy, rx, ry, col, alpha=1.0, rot=0.0):
        """col: rgb or fn(nx, ny, d) -> rgb, where (nx, ny) is the unit-disc position."""
        R = max(rx, ry) + 1
        ca, sa = math.cos(rot), math.sin(rot)
        for y in range(int((cy - R) * S), int((cy + R) * S) + 1):
            for x in range(int((cx - R) * S), int((cx + R) * S) + 1):
                fx, fy = (x + 0.5) / S - cx, (y + 0.5) / S - cy
                ux, uy = fx * ca + fy * sa, -fx * sa + fy * ca
                nx, ny = ux / rx, uy / ry
                d = math.sqrt(nx * nx + ny * ny)
                a = clamp((1 - d) * min(rx, ry) * S + 0.5) * alpha
                if a > 0:
                    self.blend(x, y, col(nx, ny, d) if callable(col) else col, a)

    def capsule(self, x1, y1, x2, y2, r1, col, alpha=1.0, r2=None):
        r2 = r1 if r2 is None else r2
        R = max(r1, r2) + 1
        dx, dy = x2 - x1, y2 - y1
        l2 = dx * dx + dy * dy or 1e-9
        for y in range(int((min(y1, y2) - R) * S), int((max(y1, y2) + R) * S) + 1):
            for x in range(int((min(x1, x2) - R) * S), int((max(x1, x2) + R) * S) + 1):
                px, py = (x + 0.5) / S, (y + 0.5) / S
                t = clamp(((px - x1) * dx + (py - y1) * dy) / l2)
                r = r1 + (r2 - r1) * t
                qx, qy = x1 + dx * t - px, y1 + dy * t - py
                d = math.sqrt(qx * qx + qy * qy)
                a = clamp((r - d) * S + 0.5) * alpha
                if a > 0:
                    self.blend(x, y, col(t, d / r if r else 0) if callable(col) else col, a)

    def poly(self, pts, col, alpha=1.0):
        ys = [p[1] for p in pts]
        n = len(pts)
        for y in range(int(min(ys) * S), int(max(ys) * S) + 1):
            yc = (y + 0.5) / S
            xs = []
            for i in range(n):
                ax, ay = pts[i]
                bx, by = pts[(i + 1) % n]
                if (ay <= yc < by) or (by <= yc < ay):
                    xs.append(ax + (yc - ay) * (bx - ax) / (by - ay))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                for x in range(int(xs[k] * S), int(xs[k + 1] * S) + 1):
                    self.blend(x, y, col((x + 0.5) / S, yc) if callable(col) else col, alpha)

    def bezier(self, pts, r, col, steps=40, alpha=1.0, taper=1.0):
        prev = None
        for i in range(steps + 1):
            t = i / steps
            x = (1 - t) ** 3 * pts[0][0] + 3 * (1 - t) ** 2 * t * pts[1][0] + 3 * (1 - t) * t * t * pts[2][0] + t ** 3 * pts[3][0]
            y = (1 - t) ** 3 * pts[0][1] + 3 * (1 - t) ** 2 * t * pts[1][1] + 3 * (1 - t) * t * t * pts[2][1] + t ** 3 * pts[3][1]
            rr = r * (1 - (1 - taper) * t)
            if prev:
                self.capsule(prev[0], prev[1], x, y, prev[2], col, alpha, rr)
            prev = (x, y, rr)

    def point_at(self, pts, t):
        x = (1 - t) ** 3 * pts[0][0] + 3 * (1 - t) ** 2 * t * pts[1][0] + 3 * (1 - t) * t * t * pts[2][0] + t ** 3 * pts[3][0]
        y = (1 - t) ** 3 * pts[0][1] + 3 * (1 - t) ** 2 * t * pts[1][1] + 3 * (1 - t) * t * t * pts[2][1] + t ** 3 * pts[3][1]
        return x, y

    def downsample(self):
        out = []
        for y in range(H):
            row = []
            for x in range(W):
                acc = [0.0, 0.0, 0.0]
                for sy in range(S):
                    for sx in range(S):
                        p = self.px[y * S + sy][x * S + sx]
                        acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]
                row.append(tuple(min(255, max(0, v / (S * S))) for v in acc))
            out.append(row)
        return out


def lit(base, nx, ny, light=(-0.55, -0.65), amb=0.55, spec=0.35, sharp=12):
    """sphere-ish shading for a unit-disc position"""
    nz = math.sqrt(max(0.0, 1 - nx * nx - ny * ny))
    lx, ly = light
    lz = math.sqrt(max(0.0, 1 - lx * lx - ly * ly))
    dif = max(0.0, nx * lx + ny * ly + nz * lz)
    s = max(0.0, dif) ** sharp * spec
    return tuple(min(255, c * (amb + (1 - amb) * dif) + 255 * s) for c in base)


# ---------------- quantise: median cut + Bayer dithering ----------------
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def median_cut(pixels, n=16):
    boxes = [pixels]
    while len(boxes) < n:
        boxes.sort(key=lambda b: -len(b) * max(max(p[i] for p in b) - min(p[i] for p in b) for i in range(3)) if b else 0)
        b = boxes.pop(0)
        if len(b) < 2:
            boxes.append(b)
            break
        ch = max(range(3), key=lambda i: max(p[i] for p in b) - min(p[i] for p in b))
        b.sort(key=lambda p: p[ch])
        boxes += [b[:len(b) // 2], b[len(b) // 2:]]
    pal = []
    for b in boxes:
        if b:
            pal.append(tuple(int(sum(p[i] for p in b) / len(b)) for i in range(3)))
    while len(pal) < n:
        pal.append((0, 0, 0))
    return pal


def quantize(rgb_rows, n=16, dither=22.0, palette=None, keep_black=True):
    """rgb rows (240x136) -> (indices rows, palette). Index 0 is the darkest colour."""
    flat = [p for row in rgb_rows for p in row]
    pal = palette or median_cut(flat[::3] if len(flat) > 20000 else flat, n)
    pal.sort(key=lambda c: c[0] * 0.3 + c[1] * 0.59 + c[2] * 0.11)  # 0 = darkest
    cache = {}

    def nearest(c):
        k = (int(c[0]) >> 2, int(c[1]) >> 2, int(c[2]) >> 2)
        if k not in cache:
            cache[k] = min(range(len(pal)), key=lambda i: (pal[i][0] - c[0]) ** 2 * 0.3
                           + (pal[i][1] - c[1]) ** 2 * 0.59 + (pal[i][2] - c[2]) ** 2 * 0.11)
        return cache[k]
    out = []
    for y, row in enumerate(rgb_rows):
        orow = []
        for x, c in enumerate(row):
            t = (BAYER[y % 4][x % 4] / 16.0 - 0.47) * dither
            orow.append(nearest((c[0] + t, c[1] + t, c[2] + t)))
        out.append(orow)
    return out, pal


def write_png(path, rows, pal=None, scale=1):
    h, w = len(rows), len(rows[0])
    if pal is None:  # rgb rows
        raw = b"".join(b"\0" + bytes(int(v) for px in row for _ in range(scale) for v in px) * 1
                       for row in rows for _ in range(scale))
        ctype, plte = 2, None
    else:
        raw = b"".join(b"\0" + bytes(i for i in row for _ in range(scale)) for row in rows for _ in range(scale))
        ctype, plte = 3, b"".join(bytes(c) for c in pal)

    def chunk(k, d):
        c = k + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, ctype, 0, 0, 0))
    if plte:
        png += chunk(b"PLTE", plte)
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)
