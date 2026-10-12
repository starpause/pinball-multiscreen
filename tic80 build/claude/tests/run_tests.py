"""Build a test cart (game + autotest.lua), run TIC-80 headless, save screenshots.

Usage: python tests/run_tests.py [outdir]
Needs TIC-80 at C:\\Program Files\\tic80-v1.3-win.exe (override with TIC80 env var).
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import build_tic  # noqa: E402
from gen_sprites import write_indexed_png, PAL  # noqa: E402


def write_rgb_png(path, rows):
    import struct
    import zlib
    raw = b"".join(bytes([0]) + bytes(v for px in row for v in px) for row in rows)

    def ch(k, d):
        c = k + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    sig = bytes([137, 80, 78, 71, 13, 10, 26, 10])
    head = struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0)
    open(path, "wb").write(sig + ch(b"IHDR", head) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))


TIC = os.environ.get("TIC80", r"C:\Program Files\tic80-v1.3-win.exe")


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    work = tempfile.mkdtemp(prefix="frtest_")
    lua = os.path.join(work, "test.lua")
    with open(lua, "w", encoding="utf-8", newline="\n") as f:
        f.write(open(os.path.join(ROOT, "fairy_ring.lua"), encoding="utf-8").read())
        if os.environ.get("TEST_PRELUDE"):  # e.g. TEST_PRELUDE='TUNE.kick="reset"'
            f.write("\n" + os.environ["TEST_PRELUDE"] + "\n")
        if os.environ.get("FLIP_SWEEP"):
            f.write("\nFLIP_SWEEP = {" + os.environ["FLIP_SWEEP"] + "}\n")
        f.write(open(os.path.join(HERE, os.environ.get("AUTOTEST", "autotest.lua")), encoding="utf-8").read())
    build_tic.main(lua, os.path.join(ROOT, "fairy_ring_sprites.png"), os.path.join(work, "test.tic"),
                   build_tic.art_chunks(ROOT))
    r = subprocess.run([TIC, "--cli", "--skip", "--fs=" + work, "--cmd=load test.tic & run"],
                       capture_output=True, text=True, timeout=300)
    lines = r.stdout.splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("SHOT "):
            name = ln[5:].strip()
            rows = [[int(c, 16) for c in lines[i + 1 + y].strip()] for y in range(136)]
            big = []
            for row in rows:
                r2 = [c for c in row for _ in range(3)]
                big += [r2] * 3
            path = os.path.join(outdir, name + ".png")
            palf = os.path.join(ROOT, "art", "gameover_pal.bin")
            if name == "game_over" and os.path.exists(palf):
                pb = open(palf, "rb").read()
                rgb = []
                for y, row in enumerate(rows):
                    pr = [tuple(pb[y * 48 + i * 3:y * 48 + i * 3 + 3]) for i in range(16)]
                    r2 = [pr[c] for c in row for _ in range(3)]
                    rgb += [r2] * 3
                write_rgb_png(path, rgb)
            else:
                write_indexed_png(path, big, PAL, transparent=False)
            print("screenshot ->", path)
            i += 137
            continue
        print(ln)
        i += 1
    if r.stderr.strip():
        print("STDERR:", r.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out"))
