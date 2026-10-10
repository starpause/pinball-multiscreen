# How Infinity Pinball builds its "infinite" tables

From decompiling v1.12 (Unity 2021.3 IL2CPP): class dump, ARM64 method analysis, and every serialized asset.
Details are in [logic_report.md](logic_report.md) (algorithm, with method citations) and [data_report.md](data_report.md) (numbers, geometry, physics). The pictures are in [diagrams/](diagrams/); start with `sections_overview.png`. The ripped art and audio are in `../ripped_v1.12/` (main pixel atlas: `textures/SS_Sprites.png`). That folder and `il2cpp_dump.cs` are local-only and not committed to git.

## Short answer

**It's infinite, but it isn't freeform procedural.** Every table is an **authored shell** with a **random scatter** of toys in a protected zone, run under a fixed rule budget. Rails are the only geometry generated from nothing.

```
table N  (22 x 20 units, stacked every 20 units, endless)
├─ shell (authored, mix-and-match)
│   ├─ left wall  = 1 of 3 hand-made half-walls, mirrored
│   ├─ right wall = 1 of 3 (independent pick → 9 combos/theme)
│   ├─ background = 1 of 3
│   └─ every half-wall has the same 8.8-wide top/bottom openings,
│      so any combo chains with any other table
├─ fixed bottom kit (always the same spots)
│   flippers (±2.95,-7.9) · slingshots · inlanes · drain blocker
│   + per-wall anchor slots: lane blocker, outlane kicker, fence, extra flipper
├─ random toys (12x12 grid in an 18x12 box, above the flipper zone)
│   shuffled creator list, each rolls its own %, up to 8 objects
│   each placed at a random free grid point whose clearance circle is empty
├─ goals: 1–3 "events" = trigger (targets / rollovers / bash toy)
│          → reward (multiball, slot machine, speed lane, blockers, x-multiplier)
└─ links: rail (A* path, spans 2–4 tables), warp (1–3 tables up), teleporter pair
```

Every theme uses the same 3 wall collider shapes, the same spawn maps and the same percentages. Themes only reskin it.

## Why its tables are fun when vibe-coded ones aren't

The fun comes from constraints the designers fixed by hand. Randomness only fills the gaps.

1. **The bottom third is never random.** Flippers, slingshots, inlanes and outlanes are always in their authored, proven spots. The random toys can't touch the flipper zone (y < -4). A vibe-coded table usually randomizes the part that matters most.
2. **Walls are a small authored set built to chain.** There are 3 half-walls, each a strong silhouette: an hourglass, a wide box, a top chamber with a spur. Mixing left and right gives 9 asymmetric tables, and the shared opening widths mean any table connects to any other.
3. **Clearance, not coordinates.** Each toy has a margin radius (bumpers about 2 units, about 3.3 ball diameters). It's placed only where that circle is empty, and the grid points inside it are then removed. That guarantees ball-sized gaps between toys. Up to 100 tries per object; a failed toy is simply left out.
4. **Small budgets.** At most 8 toys and 3 goals per table, and at most one "centre feature" (slot machine, multiplier or speed lane). Tables never turn into clutter.
5. **Every table has the same main goal: exit through the top.** Events add optional side goals (hit the targets to get multiball). Falling just drops you into the previous table, softened (velocity × 0.5 / 0.1) with a temporary exit blocker.
6. **Gentle start, rhythm, fixed physics.** Tables 0–3 have a reduced toy list (no warps, rails or spinners) and both outlane kickers. Every 10th table is a hand-made bonus table. Kickers reset the ball's velocity, then apply a fixed impulse, so bumpers always feel the same whatever the incoming speed.

## Lessons for our tables (TIC-80 / Fairy Ring)

- Build a **library of hand-made half-wall shapes** with standard connection widths, mirror them, and mix left and right.
- Keep **one fixed bottom kit** (flippers, slings, inlanes) and authored **anchor slots** per wall shape for optional parts (kickback, lane blocker, extra flipper).
- Scatter toys on a **coarse grid inside a box above the flipper zone**, with **per-toy clearance margins**, a **max count per table**, **one centre feature**, and gated toy lists for the first few tables.
- Generate **goals as trigger→reward pairs**, not just toys.
- Scaled to our cart: 22 units ≈ 148 px playfield means about 6.7 px/unit, so our 8-px ball (r 4 ≈ 0.6 units) is **almost exactly Infinity's ball-to-table ratio**. Their margins in our units: bumpers ~13 px, grid pitch ~10 x 7 px.
