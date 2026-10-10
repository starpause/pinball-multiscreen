"""Rebuild everything: sprite sheet -> fairy_ring.tic.

    python build.py            regenerate fairy_ring_sprites.png from gen_sprites.py, then pack the cart
    python build.py --keep-png pack the cart from the existing PNG (use this once you hand-edit the sheet)
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_tic  # noqa: E402

if "--keep-png" not in sys.argv:
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "gen_sprites.py"),
                    os.path.join(HERE, "fairy_ring_sprites.png")], check=True)
build_tic.main(os.path.join(HERE, "fairy_ring.lua"),
               os.path.join(HERE, "fairy_ring_sprites.png"),
               os.path.join(HERE, "fairy_ring.tic"))
