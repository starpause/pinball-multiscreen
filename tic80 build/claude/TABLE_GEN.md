# Fairy Ring table generator

An endless tower of one-screen tables, each with its own flippers (Revenge of the 'Gator / Kirby's Pinball Land / Infinity Pinball). Shoot through the **top opening** to climb to the next table. Fall out of the **bottom** and you drop to the table below. Below your checkpoint floor, you lose the ball instead.

The generator follows the recipe we decompiled from Infinity Pinball (see `research/2022 Infinity Pinball (Android)/analysis/`): **authored shells + a fixed bottom kit + constrained random scatter + trigger→reward goals**. All code is in `fairy_ring.lua`, sections "table pieces" → "table generation".

## Scale

One table is 150x136 px, which is Infinity's 22x20-unit table at about 6.8 px per unit. Our 8-px ball matches Infinity's ball-to-table ratio, so its spacing numbers carry straight over.

## 1. Shell: half-wall pieces (`PIECES`)

Each piece is the right-hand wall contour in `(dx, y)`, where dx is the distance from the centre line. It runs from the **top opening** `(30, 0)` to the **kit joint** `(69, 90)`. Each side of a table picks a piece independently, and the left side is mirrored, so 5 pieces give 25 shells. Because every piece shares the same openings, any table connects to any other.

| Piece | Shape | Slot |
|---|---|---|
| HOLLOW | wide chamber, rounded shoulder | upper flipper (45%) |
| HOURGLASS | pinched waist | none |
| ROOT | root spur juts in | upper flipper on the spur (45%) |
| ALCOVE | side pocket | fairy ring hole inside (80%) |
| FUNNEL | slanted shoulders steer shots to the exit | none |

Tables 0–3 only use HOLLOW, HOURGLASS and FUNNEL.

**To add a piece:** append a contour to `PIECES`. Keep it starting at `30,0` and ending at `69,90`, and keep walls at least 5 px thick (the movement clamp needs that).

## 2. Fixed bottom kit (`KIT`)

Every table has the same, proven flipper area:
- the outer wall and outlane
- the inlane guide
- the slingshot (gold kick face)
- flippers pivoting at `CX ± 25, y 118`

The kit has three anchor slots for optional parts:
- an outlane **kickback** (lit at 40%; always lit on table 0 and the bonus table)
- outlane **side posts**
- a **centre post** between the flippers

The scatter grid never reaches below y 76.

## 3. Goals: trigger → reward (Infinity's events)

Tables 0–3 get 1 goal; later tables get 1–3. Triggers and rewards are each picked by weight (the weights are Infinity's percentages), and no trigger or reward repeats within a table:

- **Triggers:**
  - BUDS: 3 rollovers spaced 13 px
  - TOADS: 3 standup targets
  - ACORN: a bash toy that breaks after 3 hits
- **Rewards:**
  - KICKBACK: lights both kickbacks
  - SIDE POSTS: close the outlanes for 30 s
  - CENTER POST: blocks the drain for 30 s
  - UPDRAFT: a wind column that blows the ball up for 15 s. It's a centre feature, so at most one per table, and the generator keeps the column clear.
  - MULT +1
  - JACKPOT

Goals re-arm after paying out. Completing every goal on a table once gives **TABLE CLEAR** (+10,000), and the tower in the HUD marks the table green.

## 4. Free toys: grid scatter with clearance (Infinity's ObjectPlacement)

**The pocket rule:** any gap between two solids must be either **closed** or **wider than the ball** (8 px + 3 px slack). If it isn't, the ball can wedge in it and never come out. This applies to:
- toy-to-wall gaps (`cmap_clear(r + GAP)`);
- gaps between two toys that don't kick the ball away (targets, acorns). Bumpers may sit closer, because they knock the ball out of any pocket;
- the kit itself: the slingshot sits high enough that the inlane under it stays 14+ px wide;
- upper flippers, which get a sloped **bracket** behind their pivot so the ball rolls back onto the flipper.

The bot test counts **traps**: the ball stays inside a 16-px box for 4 s while no flipper is held. A first playtest showed a slingshot/inlane pocket, and the bot found 35 traps. After these rules it finds 0. The game has the same detector as a safety net: it pops a trapped ball out ("UNSTUCK"), as Infinity respawns a stuck ball.

- **Grid:** 12x12 candidate points (x 20..130 step 10, y 13..79 step 6). Every toy has a collision radius `r` and a clearance margin `m`, taken from Infinity's margins (`TOY`).
- **Placement:** up to 100 random grid points per toy. A point is accepted only if:
  - no wall pixel lies within `r + ball + 3`;
  - no other toy is closer than the larger of the two margins;
  - and, for moving lanterns, their whole sideways path is clear.

  Grid points inside the margin are then removed. A toy that doesn't fit is simply left out.
- **Creators:** shuffled each pass, each rolling its own chance: bumper 85%, lantern 65% (x2), gold bumper 35%, fairy ring hole 15%, warp ring 8% (not on gentle tables).
- **Cap:** at most 3 toys on gentle tables, 4–7 later.

## 5. Rhythm

- **Bonus "fairy court":** every 10th table (9, 19, …). It's hand-made: a ring of bumpers around a jackpot warp ring, with kickbacks lit and the centre post up. Reaching it raises your **checkpoint floor**.
- **Falling down:** drops you into the table below with softened speed (Infinity: vx × 0.5, vy × 0.1), and that table's centre post comes up for 5 s as a mercy.
- **Determinism:** each table is seeded from `(masterSeed, index)`, so revisiting a table gives the same layout, and its goal progress persists.

## Measuring fun: the playability bot (`tests/autotest.lua`)

`python tests/run_tests.py <outdir>` runs a simple bot that flips whenever the ball falls into a flipper's reach. It plays each of tables 0–19 six times and reports how many launches **climbed**, **drained** or **stayed** for 60 s. Set `FLIP_SWEEP=0.4,0.6,...` to compare flipper power.

**Kicker rule:** bumpers and slingshots use Pokémon's **additive** rule: a 1/4 bounce, then a +2.0 px/frame push along the normal, with slingshots tilted 11.25° upward. Infinity's **reset** rule (zero the velocity, then a fixed kick) is kept as `TUNE.kick = "reset"`. Compare them with `TEST_PRELUDE='TUNE.kick="reset"' python tests/run_tests.py out`.

| Bot, 120 launches | reset (Infinity) | add (Pokémon) |
|---|---|---|
| climbed | 49 | 87 |
| drained | 15 | 27 |
| still bouncing after 60 s | 56 | 6 |
| traps | 0 | 0 |

With the additive rule the ball keeps its momentum through the table, so long stalemates almost vanish and every table gets climbed regularly.

Earlier results with the reset rule (flip power 0.6, pocket rule on): 49 climbs, 15 drains, 56 stays and **0 traps** out of 120. Every table except table 2 was climbed at least once. Next tuning ideas:
- cap total toys **including** goal objects;
- **re-roll** tables the bot can never climb or that trap the ball, a validation step Infinity doesn't have.
