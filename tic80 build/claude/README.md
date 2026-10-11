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

**Without Python:** run TIC-80 yourself from this folder with its output redirected, and the `RUNLOG` lines end up in the file:

```bash
tic80 --skip --fs=. "--cmd=load fairy_ring.tic & run" > runlog.txt
```

The game-over screen also shows lifetime stats (runs, best level, deadliest level). TIC-80 saves those in the cart's persistent memory, separately for each place the cart is launched from. So they may start fresh when you launch through `play.py`; the log file is unaffected.

## Build

The free TIC-80 can't load `.lua` files, so the code and sprite sheet are packed into the `.tic`:

```bash
python build.py
```

This regenerates `fairy_ring_sprites.png` from `gen_sprites.py`, then packs everything into `fairy_ring.tic`. If you've hand-edited the PNG, use `python build.py --keep-png` so it isn't regenerated over your changes.

## Tests and bot analytics

```bash
python tests/run_tests.py out
```

This runs TIC-80 headless with scripted input: physics checks, every mechanic, a 260-run trap/loop hunt and screenshots. The screenshots go to the `out` folder.

```bash
python tests/run_analytics.py --seeds 20 --tables 30
```

A simple bot plays thousands of generated tables and reports difficulty by level, wall piece, toy and goal. The bot doesn't aim, so treat its numbers as relative; human logs are the better guide.
