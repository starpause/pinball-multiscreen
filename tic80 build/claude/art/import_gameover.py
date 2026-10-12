"""Import full-screen game-over art (240x136, any colours) for the cart.

    python art/import_gameover.py path/to/game-over.png

TIC-80 shows 16 colours at a time, but its BDR() callback can change the
palette on every scanline. So each row of the image gets its own palette:
9 colours picked for that row + 7 fixed slots (black, muted lavender, lime,
red, gold, lilac, white: the game palette's own values) that the stats text uses, so
text looks the same on every row.

Writes:
  art/gameover_screen.bin   16320 bytes, 4 bpp screen (low nibble = left pixel)
  art/gameover_pal.bin      136 rows x 48 bytes (16 RGB colours per row)
  art/gameover_preview_x3.png  what it will look like
build.py packs the .bin files into the cart (map + music-pattern chunks).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import build_tic  # noqa: E402
from paint import median_cut, write_png  # noqa: E402

W, H = 240, 136
# fixed slots = FAIRY NIGHT palette entries used by the game-over text
FIXED = {0: (0x0b, 0x0a, 0x14), 3: (0x4a, 0x3a, 0x74), 7: (0xb8, 0xe6, 0x5c),
         10: (0xd2, 0x3c, 0x46), 12: (0xff, 0xd7, 0x6a), 14: (0xc9, 0xc0, 0xe6),
         15: (0xff, 0xfa, 0xf0)}
FREE = [i for i in range(16) if i not in FIXED]


def dist(a, b):
    return (a[0] - b[0]) ** 2 * 0.3 + (a[1] - b[1]) ** 2 * 0.59 + (a[2] - b[2]) ** 2 * 0.11


def main(src):
    w, h, rows, _ = build_tic.read_png(src)
    assert (w, h) == (W, H), "game-over art must be 240x136 (got %dx%d)" % (w, h)
    screen, pals, preview = bytearray(), bytearray(), []
    for y in range(H):
        px = [p[:3] for p in rows[y]]
        pal = [FIXED.get(i, (0, 0, 0)) for i in range(16)]
        for i, c in zip(FREE, median_cut(list(px), len(FREE))):
            pal[i] = c
        cache = {}
        idx = []
        for p in px:
            if p not in cache:
                cache[p] = min(range(16), key=lambda i: dist(pal[i], p))
            idx.append(cache[p])
        for x in range(0, W, 2):
            screen.append(idx[x] | (idx[x + 1] << 4))
        pals += b"".join(bytes(c) for c in pal)
        preview.append([pal[i] for i in idx for _ in range(3)])
    open(os.path.join(HERE, "gameover_screen.bin"), "wb").write(screen)
    open(os.path.join(HERE, "gameover_pal.bin"), "wb").write(pals)
    write_png(os.path.join(HERE, "gameover_preview_x3.png"), [r for r in preview for _ in range(3)])
    print("wrote gameover_screen.bin (%d B), gameover_pal.bin (%d B), preview" % (len(screen), len(pals)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else
         os.path.join(HERE, "..", "..", "..", "table-ideas", "0xFae Pinball", "sprites", "game-over.png"))
