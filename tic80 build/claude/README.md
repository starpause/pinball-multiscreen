# Fairy Ring Pinball (TIC-80)

An endless tower of one-screen pinball tables for [TIC-80](https://tic80.com). Climb out of the top of each table to reach the next level.

- **Engine:** see [ENGINE_NOTES.md](ENGINE_NOTES.md).
- **How levels are generated:** see [TABLE_GEN.md](TABLE_GEN.md).

## Play

Open `fairy_ring.tic` in TIC-80 (the free version works).

| Control | Gamepad | Keyboard (TIC-80 defaults) |
|---|---|---|
| Left flipper | any D-pad direction | arrow keys |
| Right flipper | A or B | Z or X |
| Nudge | X or Y | A or S |

## Play with logging (human analytics)

Every game over writes a `RUNLOG` line with the seed, the level reached, the score, and the time, balls lost and drops on each level. To collect those lines, run the game through `play.py` from a terminal in **this folder**:

```bash
python play.py
```

TIC-80 opens and starts the game as usual. Your runs are appended to `logs/runlog.txt`, across as many sessions as you like. To see a summary (per level: how often it was reached, average time, balls lost and drops):

```bash
python tests/human_stats.py
```

Logs from several people can be combined: append their `runlog.txt` files together, then pass the combined file to `human_stats.py`.

**Where TIC-80 is installed:** `play.py` and the test scripts expect TIC-80 at `C:\Program Files\tic80-v1.3-win.exe`. If yours is somewhere else, set the `TIC80` environment variable to its path first.

Windows (PowerShell):

```powershell
$env:TIC80 = "D:\tools\tic80.exe"
```

macOS / Linux / Git Bash:

```bash
export TIC80=/path/to/tic80
```

**Without Python:** run TIC-80 yourself from this folder with the cart as an argument and its output redirected, and the `RUNLOG` lines end up in the file:

```bash
tic80 --skip fairy_ring.tic > runlog.txt
```

Passing the cart as an argument (rather than `--fs=`) keeps TIC-80 on its normal settings folder, so your gamepad and key mapping is kept between runs.

## Build

The free TIC-80 can't load `.lua` files, so the code and sprite sheet are packed into the `.tic`:

```bash
python build.py
```

This regenerates `fairy_ring_sprites.png` from `gen_sprites.py`, then packs everything into `fairy_ring.tic`. If you've hand-edited the PNG, use `python build.py --keep-png` so it isn't regenerated over your changes.

## Tweaking the sprites

Every sprite is exported as its own PNG in `art/sprites/` (for example `bumper_red_normal_hit.png`, `fairy_flutter_2frames.png`, `flippers_8_angles_32x24.png`), along with the full sheet (`_sheet.png`) and a 4x preview (`_sheet_x4.png`). The files are indexed with the game's 16-colour palette, and colour 0 is transparent.

**Export** (already done; repeat only to start fresh, since it overwrites `art/sprites/`, so copy your edits somewhere else first):

```bash
python art/export_sprites.py
```

**Edit** any of the PNGs. Aseprite in indexed mode is ideal. Keep the image size and stick to the 16 palette colours.

**Import** by building as usual:

```bash
python build.py
```

The build spots every sprite file that differs from the export and pastes it into the cart's sheet ("applied your edited sprites: ..."). Untouched files are ignored, so code changes to the generated art still come through.

## Game-over art

The game-over screen is a full-screen 240x136 image. TIC-80 shows 16 colours at a time, but the game switches the palette on every scanline, so each row gets 10 colours of its own plus 6 fixed ones (the stats text colours). That keeps full-colour art close to the original. To replace the art, make a 240x136 PNG (any colours), then:

```bash
python art/import_gameover.py path/to/your-art.png
python build.py
```

`art/gameover_preview_x3.png` shows the result. The importer writes `art/gameover_screen.bin` and `art/gameover_pal.bin`, and `build.py` packs them into the cart. Keep the right ~80 px (from x = 160) fairly plain: the stats panel goes there.

`art/gen_gameover.py` holds the earlier painted concepts (`python art/gen_gameover.py`).

## Tests and bot analytics

```bash
python tests/run_tests.py out
```

This runs TIC-80 headless with scripted input: physics checks, every mechanic, a 260-run trap/loop hunt and screenshots. The screenshots go to the `out` folder.

```bash
python tests/run_analytics.py --seeds 20 --tables 30
```

A simple bot plays thousands of generated tables and reports difficulty by level, wall piece, toy and goal. The bot doesn't aim, so treat its numbers as relative; human logs are the better guide.
