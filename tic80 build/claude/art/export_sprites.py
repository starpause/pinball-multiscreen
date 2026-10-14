"""Export every sprite from the sheet as its own PNG, for tweaking.

    python art/export_sprites.py

Writes art/sprites/<name>.png (indexed, FAIRY NIGHT palette, colour 0 =
transparent) for every sprite, plus the full sheet (_sheet.png), a 4x
labelled-free preview (_sheet_x4.png) and manifest.json.

Edit any of those PNGs (Aseprite in indexed mode is ideal; stay inside the
16 palette colours and keep the size) and run `python build.py`: build.py
pastes every sprite whose file no longer matches the exported fingerprint
back over the generated sheet. Untouched files are ignored, so later code
changes to the art still come through. Re-run this script to re-export
(it overwrites art/sprites/, so keep edits elsewhere first).
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import build_tic  # noqa: E402
from gen_sprites import PAL, write_indexed_png  # noqa: E402

OUT = os.path.join(HERE, "sprites")

# (file name, x, y, w, h) in sheet pixels; tile id = (y // 8) * 16 + x // 8
SPRITES = [
    ("ball_rolling_4frames", 0, 0, 32, 8),
    ("sparkle_4frames", 32, 0, 32, 8),
    ("firefly_decor", 64, 0, 8, 8),
    ("tiny_mushroom", 72, 0, 8, 8),
    ("lane_bud_unlit_lit", 80, 0, 16, 8),
    ("kickback_arrow_unlit_lit", 96, 0, 16, 8),
    ("decor_flower", 112, 0, 8, 8),
    ("decor_clover", 120, 0, 8, 8),
    ("texture_wall_rim_rows", 0, 8, 8, 8),
    ("texture_sling", 8, 8, 8, 8),
    ("texture_post", 16, 8, 8, 8),
    ("texture_gate", 24, 8, 8, 8),
    ("decor_grass", 64, 8, 8, 8),
    ("decor_fern", 72, 8, 8, 8),
    ("decor_stones", 80, 8, 8, 8),
    ("decor_star", 88, 8, 8, 8),
    ("updraft_arrow", 96, 8, 8, 8),
    ("blocker_post_unlit_lit", 104, 8, 16, 8),
    ("mushroom_small", 120, 8, 8, 8),
    ("bumper_red_normal_hit", 0, 16, 32, 16),
    ("mushroom_big_colony", 32, 16, 16, 16),
    ("fairy_flutter_2frames", 64, 16, 32, 16),
    ("fairy_ring_portal_2frames", 96, 16, 32, 16),
    ("texture_floor_16", 0, 32, 16, 16),
    ("texture_bark_16", 16, 32, 16, 16),
    ("decor_big_toadstool", 32, 32, 16, 16),
    ("decor_mushroom_cluster", 48, 32, 16, 16),
    ("acorn_3_damage_frames", 32, 48, 48, 16),
    ("bumper_gold_normal_hit", 80, 48, 32, 16),
    ("spore_unlit_lit", 112, 48, 16, 8),
    ("poo_pile_normal_splat", 112, 56, 16, 8),
    ("pixie_2frames", 0, 64, 32, 16),
    ("wishing_well_idle_spin", 64, 64, 32, 16),
    ("flippers_8_angles_32x24", 0, 128, 128, 48),
    ("queen_red_lg_32", 0, 176, 32, 32),
    ("queen_red_md_24", 32, 176, 24, 24),
]


def sheet_indices(path):
    w, h, rows, plte = build_tic.read_png(path)
    pal = list(plte[:16]) if plte and len(plte) <= 16 else PAL
    cache = {}
    out = []
    for row in rows:
        r = []
        for p in row:
            k = p[:3] if p[3] >= 128 else None
            if k not in cache:
                cache[k] = 0 if k is None else build_tic.nearest(k, pal)
            r.append(cache[k])
        out.append(r)
    return out


def file_hash(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def main():
    os.makedirs(OUT, exist_ok=True)
    sheet = sheet_indices(os.path.join(ROOT, "fairy_ring_sprites.png"))
    manifest = {}
    for name, x, y, w, h in SPRITES:
        crop = [row[x:x + w] for row in sheet[y:y + h]]
        path = os.path.join(OUT, name + ".png")
        write_indexed_png(path, crop, PAL)
        manifest[name] = {"x": x, "y": y, "w": w, "h": h, "sha1": file_hash(path),
                          "tile_id": (y // 8) * 16 + x // 8}
    write_indexed_png(os.path.join(OUT, "_sheet.png"), sheet, PAL)
    big = []
    for row in sheet:
        r = [c if c else 1 for c in row for _ in range(4)]
        big += [r] * 4
    write_indexed_png(os.path.join(OUT, "_sheet_x4.png"), big, PAL, transparent=False)
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
    print("exported %d sprites to %s" % (len(SPRITES), OUT))


def apply_edits(sheet_path):
    """Called by build.py: paste user-edited sprite PNGs over the sheet."""
    mpath = os.path.join(OUT, "manifest.json")
    if not os.path.exists(mpath):
        return []
    manifest = json.load(open(mpath))
    edited = [n for n, m in manifest.items()
              if os.path.exists(os.path.join(OUT, n + ".png")) and file_hash(os.path.join(OUT, n + ".png")) != m["sha1"]]
    if not edited:
        return []
    sheet = sheet_indices(sheet_path)
    for n in edited:
        m = manifest[n]
        spr = sheet_indices(os.path.join(OUT, n + ".png"))
        if len(spr) != m["h"] or len(spr[0]) != m["w"]:
            print("  skipped %s: size changed (must stay %dx%d)" % (n, m["w"], m["h"]))
            continue
        for yy in range(m["h"]):
            for xx in range(m["w"]):
                sheet[m["y"] + yy][m["x"] + xx] = spr[yy][xx]
    write_indexed_png(sheet_path, sheet, PAL)
    return edited


if __name__ == "__main__":
    main()
