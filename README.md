# pinball-multiscreen

Research and development for **Fairy Ring Pinball**, a multi-screen pixel-art pinball game for [TIC-80](https://tic80.com) (Lua, 240x136, 60 fps).

The design direction is **flippers on every screen**, as in Revenge of the 'Gator, Kirby's Pinball Land and Infinity Pinball. Each screen is its own small play area with goals. Levels are built with Infinity Pinball-style generation (authored wall pieces, a fixed flipper kit, constrained random placement, trigger→reward goals), informed by hand-made screens from KPL and RotG.

## Layout

| Path | What |
|---|---|
| `tic80 build/claude/` | The current cart: `fairy_ring.lua`, `fairy_ring_sprites.png` → `fairy_ring.tic`. See its `ENGINE_NOTES.md`. |
| `tic80 build/muse/` | An earlier prototype (superseded). |
| `research/` | Reference games: manuals, screenshots, guides, devlogs and analysis. |
| `research/1999 Pokemon Pinball (GBC)/` | The pret disassembly. Our engine notes on it are in `tic80 build/claude/research_notes/`. |
| `research/2022 Infinity Pinball (Android)/analysis/` | How Infinity Pinball generates its endless tables (README, logic and data reports, diagrams). |
| `table-ideas/` | Table concepts and moodboards. |

## Build the cart

The free TIC-80 build can't load `.lua` files directly, so the build script packs the code and sprite sheet into a `.tic`:

```bash
cd "tic80 build/claude"
python build.py
```

Then load `fairy_ring.tic` in TIC-80. Controls follow Revenge of the 'Gator: any **D-pad** direction is the left flipper, **A/B** (Z/X keys) is the right flipper, and **X/Y** (A/S keys) nudges. Headless tests: `python tests/run_tests.py <outdir>` (needs TIC-80 at `C:\Program Files\tic80-v1.3-win.exe`, or set `TIC80`).

## Credits & Attribution
- Fairy boss assets adapted from [Papoycore's Fairy](https://papoycore.itch.io/fairy) by papoycore.

## Not in this repo

ROMs, APKs, save files and archives are excluded (see `.gitignore`), as are the assets and class dump we extracted from the Infinity Pinball APK. The research material is here for study and reference; the games belong to their respective owners.
