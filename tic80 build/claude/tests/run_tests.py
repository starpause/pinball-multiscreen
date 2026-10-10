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

TIC = os.environ.get("TIC80", r"C:\Program Files\tic80-v1.3-win.exe")


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    work = tempfile.mkdtemp(prefix="frtest_")
    lua = os.path.join(work, "test.lua")
    with open(lua, "w", encoding="utf-8", newline="\n") as f:
        f.write(open(os.path.join(ROOT, "fairy_ring.lua"), encoding="utf-8").read())
        if os.environ.get("FLIP_SWEEP"):
            f.write("\nFLIP_SWEEP = {" + os.environ["FLIP_SWEEP"] + "}\n")
        f.write(open(os.path.join(HERE, "autotest.lua"), encoding="utf-8").read())
    build_tic.main(lua, os.path.join(ROOT, "fairy_ring_sprites.png"), os.path.join(work, "test.tic"))
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
