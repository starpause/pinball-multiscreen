# Fairy Ring engine notes: Pokémon Pinball → TIC-80

How Pokémon Pinball (GBC, 1999) does its physics, read from the pret disassembly
in `research/1999 Pokemon Pinball (GBC)/Disassembly of Pokémon Pinball`, and how
`fairy_ring.lua` does the same thing in TIC-80 Lua.

The full research reports, with asm quotes and `file:line` citations, are in
[research_notes/](research_notes/). This file is the short, practical version.

> **Update:** the cart is now an endless tower of generated one-screen tables;
> see [TABLE_GEN.md](TABLE_GEN.md). The physics described here (ring probe,
> bounce, swept flippers, baking) is unchanged. The two-screen layout,
> plunger and fixed objects described in sections 6–7 belong to the first
> draft (in git history).

## Files

| File | What it is |
|---|---|
| `fairy_ring.tic` | The cart. Load it in TIC-80 (free version is fine). |
| `fairy_ring.lua` | All game code (plain text, edit anywhere). |
| `fairy_ring_sprites.png` | Sprite sheet, 128x256, **indexed with the 16-colour FAIRY NIGHT palette**. The palette goes into the cart. |
| `gen_sprites.py` | Generates the sheet (ASCII-art sprites + generated textures/flippers). |
| `build.py` | `python build.py` = regenerate sheet + pack cart. `python build.py --keep-png` = pack from a hand-edited PNG. |
| `build_tic.py` | Packs `.lua` + `.png` into a `.tic` (the free TIC-80 can't load `.lua`). |
| `tests/run_tests.py` | Runs TIC-80 headless with scripted input, prints physics checks, saves screenshots. |

Controls: **Left / Z** = left flipper, **Right / X** = right flipper, **Down / A** = hold to charge the plunger and release to launch, **Up** = nudge.

## 1. Units and the frame loop

| | Pokémon Pinball | Fairy Ring |
|---|---|---|
| Numbers | 8.8 fixed point, px and px/frame | Lua floats, same units |
| Gravity | `vy += 11/256` per frame (`home.asm:2374`) | `GRAV = 11/256` |
| Velocity clamp | whole-pixel byte limited to ±7 per axis (`home.asm:2386`) | `VMAX = 7.99` |
| Movement clamp | step ≤ $04FF = 4.996 px per axis; stored velocity unchanged (`home.asm:2428`) | `STEPMAX = 4.996` |
| Substeps | **none**, one step per frame | none |

Frame order (`engine/pinball_game.asm:69-176`), copied in `physics()`:

1. Gravity, then velocity clamp.
2. Flippers: read input, update state, swept collision.
3. Stage collision: the ring test, then push the ball out.
4. Objects: bumpers, slingshots and targets react to the attribute that was touched; sensors fire.
5. Bounce in the normal's frame, then add any kick force.
6. Move the ball with the clamped step.
7. Switch screens, or drain.

The movement clamp is how they avoid tunnelling without substeps. The ball can't move more than 5 px a frame, and the probe ring has radius 4, so **any wall at least 5–6 px thick can't be skipped**. Keep walls that thick when you design tables. The thin rails in the Fairy Ring table are 5 px.

## 2. Collision map: per-pixel, not vectors

**Pokémon:** each stage is a 32x24 tile map. Each tile byte picks an 8x8 1-bit mask, so collision is per pixel. The tile byte is also an *attribute* that game objects check: "the ball touched a bumper tile" (`stage_collision_attributes.asm`). The map is copied to RAM so the game can rewrite tiles at runtime to open and close gates.

**Fairy Ring:** a per-pixel attribute map `cmap[y*176+x]` covering the whole 176x256 world.
- Attributes: `EMPTY, WALL, SLING, BUMPER, TARGET, GATE, POST`.
- **How it's made:** `paint_table()` draws the layout with TIC-80 primitives, using the attribute number as the colour. `build_cmap()` then reads it back with `pix()`. So the shapes you paint *are* the collision; there are no separate vectors to keep in sync.
- To change the table, edit `paint_table()` and the object lists above it.
- **Gates:** `GATE` pixels are solid only when the ball moves right (`attr_at()`). That makes the one-way exit from the plunger lane.

## 3. The 16-point ring and the normal

**Pokémon** (`home.asm:2653-2972`, `3065`):
1. Test 16 fixed points on a radius-4 ring around the ball, clockwise from the right: (4,0) (4,1) (3,3) (1,4) (0,4) …
2. Find the **longest run** of consecutive solid points, wrapping around. Its first and last indices `s`, `e` index three 256-entry tables: normal angle, X push-out and Y push-out (`data/collision/collision_deltas.asm`).

Those tables have a closed form, which reproduces all 256 angles exactly:

```
mid  = (angle(s) + angle(e)) / 2       half = (angle(e) - angle(s)) / 2
normal   = -(cos mid, sin mid)          -- points away from the contact
push-out = 1 + 4*(1 - cos half)         -- px along the normal, every frame in contact
```

**Fairy Ring:**
- At boot, `RUN[s*16+e]` is computed from that formula, which regenerates the same tables.
- `ring_test()` returns the hit, the normal, the push distance and the attribute of the first touching point.
- If all 16 points are solid, the ball is "buried" and goes back to last frame's position. The headless stress test never triggered this in 64k frames.

**One difference:** Pokémon's ball sprite is 16 px but the probe radius is only 4, because their wall masks are drawn about 4 px *fatter* than the visible walls. Our ball is 8x8 with radius 4, so visible walls and collision walls are the same pixels.

## 4. The bounce

`ApplyCollisionForces` (`home.asm:2520`), the same in `physics()` step 5:

```
rotate velocity into the normal frame: vn (into the surface), vt (along it)
if moving into the surface:  vn = -vn * (1/4 + amp/8)
    amp 0 = walls (1/4), amp 1 = flippers (3/8), amp 2 = rubber/targets (1/2)
vt is kept as-is (no friction)
vn += kick                     -- flipper or bumper force
rotate back
```

Spin is `4 x vt`, set on contact and never decayed. It drives the ball's 4 rolling frames.

## 5. Flippers

**Pokémon** (`engine/pinball_game/flippers.asm`):
- **States:** 16 states (0 = down, 15 = up) stored in 8.8. The state changes ±$0333 = **3.2 states per frame** up and down, so a full stroke takes about 5 frames. The angle runs from 26.5° below horizontal to about 31° above.
- **Collision tables:** `[state][x 0..47][y 0..31]`, 48x32 per state, giving a *radius from the pivot* and a *normal angle* for every pixel where the ball's centre would touch. The right flipper reuses the table with x mirrored.
- **Swept test:** check every state from last frame's to this frame's and use the first hit. That's why a 3-states-per-frame swing never passes through the ball.
- **Kick:** `F = min(15.5*r, 252)/256 * stateChange * 4`, applied along the normal, only while rising. Tip hits saturate at the speed clamp; hits near the pivot are weaker.
- **Cradle:** there's no special code. A held flipper doesn't change state, so it gives no kick, and the slope rolls the ball back into the corner.

**Fairy Ring:**
- `flipper_state_hit()` evaluates the same shape analytically. The shape is a tapered capsule: hub radius 5, tip radius 3, length 19, the same numbers `gen_sprites.py` uses to draw the 8 flipper frames.
- The normal is the top-surface normal along the body and radial at the hub and tip.
- The solid region extends about 14 px under the top surface, as in theirs, so a ball that sinks in still gets pushed up.
- `flipper_collide()` is the swept loop with Pokémon's kick formula.
- The apron's top edge is flush with the resting flipper's surface. Without that, the ball got stuck at the hub: the tests caught it sitting in a 1-px notch.

## 6. Objects

Every "active" object in Pokémon is a **fixed impulse along the contact normal**. Bumpers reuse the flipper force path (`red_stage_resolve_collision.asm:556-712`).

| Object | Pokémon | Fairy Ring |
|---|---|---|
| Pop bumper | 2.0 px/f kick along the normal, edge-triggered | toadstool bumpers, 2.0 kick, 6-frame cooldown, 100 pts |
| Slingshot | 2.0 kick, normal rotated ±8/256 turn (11.25°) | same; the kicking face flashes |
| Rubber / targets | amp 2 = keep 1/2 | toadstool standups and lane posts |
| Rollover / hole | AABB-only sensors, edge-triggered | top lane buds, fairy-ring portal, kickbacks |
| Capture hole | zero velocity, snap, gravity off, timer, eject vy=+2 | the fairy ring holds 70 frames, then ejects down-left |
| Kickback | vy = −4.0 | same, lit at game start and by targets/ring |
| Plunger | fixed vy = −5.5 | charge plunger: −3.6 … −5.5 (full charge = theirs) |
| Ball saver | 20 s, paused in the plunger lane | 15 s, same pause rule |

Edge triggering: a sensor fires on entry and re-arms only after the ball leaves. The fairy-ring capture originally armed on a wider radius than it fired on, so it never fired. The test caught it.

## 7. Two screens

**Pokémon** (`vertical_screen_transition.asm:63-111`):
- Each table is two stages with a 136-px offset between them, which happens to equal the TIC-80 screen height.
- The swap is a hard cut.
- There's hysteresis: down at y≥168, up at y<8.
- Drain is "y≥168 on a stage with nothing below".

**Fairy Ring:**
- **One continuous world** (176x256) and two fixed camera stops, at y=0 and y=120. The views overlap by 16 px, so the ball is never hidden at the seam.
- The view switches up when y<124 and down when y≥132.
- **Baked backgrounds:** TIC-80's map RAM (`0x8000`, 32,640 bytes) holds exactly two 240x136 screens. At boot each screen is rendered pixel by pixel from the sprite sheet and saved there. Every frame is then one `memcpy` plus the moving sprites. Boot takes about 50 ms.

## 8. Art pipeline: everything is pixels

All static art is sampled from the sprite sheet at bake time:
- **Walls:** the bark texture (tiles 66–67/82–83).
- **Wall edges:** a moss rim from tile 16, rows 0–3, chosen by distance to the open playfield (a two-pass distance field).
- **Floor:** the forest-floor texture (tiles 64/65/80/81), with a contact shadow from tile 16 rows 4–5.
- **Slings, posts, gate:** their own 8x8 texture tiles.

**Repaint any of those tiles and the whole table restyles itself on the next boot.**

Sprite map (tile ids):

| ids | sprite |
|---|---|
| 0–3 | dewdrop ball, rolling frames |
| 4–7 | sparkle |
| 8 | firefly |
| 9 | tiny mushroom |
| 10 / 11 | lane bud, unlit / lit |
| 12 / 13 | kickback arrow, unlit / lit |
| 14, 15, 24–27 | decor |
| 16–19 | rim / sling / post / gate textures |
| 20–23 | plunger spring frames |
| 32 / 34 | bumper, normal / hit |
| 36 / 38 | target, unlit / lit |
| 40 / 42 | fairy, wing frames |
| 44 / 46 | fairy-ring portal |
| 64 / 66 | floor / bark textures (16x16) |
| 68, 70 | big decor |
| 256+ | 8 flipper frames, 32x24, pivot at (6,12); the right flipper is the same sprite flipped |

To edit the art: either change the ASCII art in `gen_sprites.py`, or open the PNG in an indexed-mode editor (Aseprite) and rebuild with `python build.py --keep-png`. You can also edit inside TIC-80's sprite editor and save the cart; then `fairy_ring.tic` holds the newest art.

## 9. Not done yet

- **Sound:** the `sfx()` calls are in place, but the cart has no SFX data yet, so it's silent.
- **Ramps and layers:** one cmap means everything sits on one level. Ramps need a second cmap and a "layer" bit on the ball. Pokémon swaps collision-map variants (`wStageCollisionState`) for its opening and closing structures.
- **Tuning:** the numbers are Pokémon's, but this table has a smaller ball on a roomier field. Play it, then tune `GRAV`, the bumper and sling kicks, and the flipper lever constant.
