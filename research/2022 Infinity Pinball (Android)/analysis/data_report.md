# Infinity Pinball v1.12: table data, geometry and physics config

How this was produced: assets exported with AssetRipper (YAML), classes from Il2CppDumper (`il2cpp_dump.cs`), method logic from the Cpp2IL ARM64 analysis, and a few `static readonly` values read from `libil2cpp.so`. Tags: [asset] = serialized data, [code] = disassembly, [inferred] = interpretation. Diagrams are in `diagrams/`.

## 0. Key findings
1. **Table size:** one table is a 22 x 20 world-unit screen centred on (0,0) (x -11..11, y -10..10). Tables stack in y every 20 units: `SectionRandomizer._verticalPositionStep` = 20 [code], `CameraScroller.VerticalDistance` = 20 [asset], and `Ball.TABLE_HEIGHT` = 20 [code]. The top opening of one table is the bottom of the next.
2. **Wall sections are right halves only** (x ≈ 3.4..11). `CreateWallWithSpawnMap(left,right)` mirrors the left pick with scale.x = -1. The left and right picks are independent draws from 3, so there are **9 wall combinations per theme**.
3. **Wall collider geometry is the same in every theme**: sections 1 and 2 are hash-identical across Classic, Candy, Cyber, Spooky and Wildwest, and section 3 differs by under 0.1 unit. Only the art changes.
4. **Spawn maps are shared by all themes** (`WallSection_TableElements_1/2/3`). Each holds only 4–5 fixed anchors: LaneBlocker, Spring (slingshot), ExtraFlipper, Fence, OutlaneSpring. They are authored on the left; the right side is mirrored.
5. **Free elements use a 12x12 grid**: every background prefab carries an 18x12 box at (0,2) plus `TableGridPositions(12,12)`, which gives x = -8.25..8.25 (step 1.5) and y = -3.5..7.5 (step 1.0), 144 points. The bottom band (y < -4) is the flipper/sling/inlane zone, used only by anchors.
6. **Budget per table:** objects min 4 / max 8 (the logic pass found the min is effectively unused, so it's "up to 8"), at most 3 events, batches of 10 tables. Tables 9, 19, 29… are bonus tables. Chance rolls are `random.Next(100) < pct`.
7. **Difficulty:** all 5 TableDesignParameters assets hold identical values and a single customLevel (tables 0–3: no Warp, Rail, Spinner, BlockTop or DestroyableBumper, and no bonus). From table 4 on, everything is allowed.
8. **Physics:** gravity 9.81 x gravityScale 3.5 = 34.3 u/s² at a 50 Hz fixed step. The ball is r 0.6, mass 0.8, no drag, with continuous collision detection. Solids have no physics material (Unity default: friction 0.4, bounce 0). All "bounce" is scripted: zero the velocity, then apply an impulse along the normal. Flippers are HingeJoint2D motors.

## 1. Generator configuration (scene `game.unity`, SectionRandomizer)
Hard-coded constants:

| constant | value | meaning |
|---|---|---|
| LOCAL_LOW_FLIPPER_POSITION | (±2.95, -7.9) | where the flippers are placed |
| LOCAL_EXIT_BLOCKER_POSITION | (0, -8) | centre drain blocker |
| LOCAL_TOP_EXIT_BLOCKER_POSITION | (0, 8.85) | top lid (8.5x1, one-way) |
| LOCAL_CENTER_FENCE_POSITION | (0, -9) | centre electric fence |

`CreateTableElements` order:
1. Pick the left and right sections.
2. Background (1 of 3; it carries the placement grid).
3. Walls and their spawn maps.
4. Slingshots; their margins are removed from the grid.
5. Flippers.
6. Blockers.
7. Fences.
8. Outlane springs.
9. Extra flipper.
10. Rail, warp and teleport (if allowed), then rail validation.
11. Rewards and events, then 4..8 random objects by percent roll.

**Placement** (`ObjectPlacement.FindPosition`):
- Try up to 100 random free grid points. Each candidate is checked with an overlap circle or box (the object's margin) against the placed-object layers.
- On success, remove the grid points inside the margin. On failure, destroy the object.
- Per-prefab flags: `ForceCenteredOnTable` (slot machine, score multiplier, speed lane), `CenterOnXAxis` (lane, spinner), `DoNotPlaceInCenterX` (bumpers, holes, warps, drop targets), `MaxObjectAllowedPerTable`, and `GroupSpacing`.

**Rails:**
- An A* path on a grid 8 wide x 7 rows per table, 22 units bound, 80% of nodes walkable.
- Rendered as a SpriteShape spline with horizontal/vertical ramp triggers.
- Speed 10. A rail can span several tables.
- `RailPatternData` exists in code but is unused.

**Boss:** `Classic_Boss_WallSection` is shared by all themes. It is one closed polygon with a ceiling at y ≈ 9.3 and a drain gap at x = ±3.46. Its flippers sit at (±3.03, -6.55). The boss itself is a circle of r 1.94 with mass 1e5.

## 2. TableData sections (identical pattern in every theme)

| # | WallSection | Spring (slingshot) | LaneBlocker | SpawnMap |
|---|---|---|---|---|
| 1 | `<T>_WallSection_1` | `<T>_Bumper_Large` | Classic_Blocker_2 | WallSection_TableElements_1 |
| 2 | `<T>_WallSection_2` | `<T>_Bumper_Small` | Classic_Blocker_2 | WallSection_TableElements_2 |
| 3 | `<T>_WallSection_3` | `<T>_Bumper_Small` | Classic_Blocker_2 | WallSection_TableElements_3 |

## 3. TableDesignParameters (identical for all themes)

| Object | Warp | Hole | LockBall | Rail | Spinner | Bumper | MovingBumper | ScoreBumper | Event |
|---|---|---|---|---|---|---|---|---|---|
| Chance % | 3 | 15 | 2 | 55 | 2 | 85 | 65 | 35 | 24 |

| Table element | ElectricFenceOutlane | ElectricFenceCenter | SpringoutLane | ExtraFlipper |
|---|---|---|---|---|
| Chance % | 25 | 50 | 100 | 45 |

| Event reward | SpeedLane | SlotMachine | ScoreMultiplier | BlockSideLanes | BlockBottom | BlockTop | Multiball | BombBall |
|---|---|---|---|---|---|---|---|---|
| Chance % | 50 | 29 | 41 | 50 | 72 | 31 | 38 | 42 |

| Event trigger | DestroyableBumper | BashToy | Rollover | DropTarget |
|---|---|---|---|---|
| Chance % | 34 | 62 | 50 | 34 |

BonusTable chance: 9%.

customLevel:
- **Levels 0..3:**
  - AllowBonusTable: 0.
  - Events: everything except BlockTop.
  - Triggers: BashToy, RollOver, DropTarget.
  - Objects: Hole, LockBall, Lane, Bumper, MovingBumper, ScoreBumper, Event.
- **Level 4 and up:** everything allowed.

## 4. Wall sections (right half as authored; the left side is x → -x)

**Section 1: hourglass.** The pinch at x = 6.63, y ≈ 1 leaves a playfield about 13.3 wide.
- Outer polygon: (4.40,9.97) (8.83,5.38) (8.85,3.66) (6.63,1.47) (6.63,0.67) (8.88,-1.54) (8.88,-5.15) (4.42,-9.57) (4.42,-10.01) (10.97,-10.03) (10.93,9.92).
- Inlane guide: (6.53,-2.54) (6.51,-4.10) (3.40,-7.02) (3.90,-7.46) (6.85,-4.54) (6.87,-2.18).

**Section 2: wide, with straight sides** (playfield about 18.5 wide) and a top shoulder.
- Outer polygon: (4.36,10.00) (4.38,9.29) (4.75,8.85) (7.59,8.85) (9.27,7.91) (9.35,-6.13) (7.04,-8.51) (4.43,-10.01) (11.01,-10.01) (10.96,9.99).
- Extra diamond post: (9.27,-0.22) (8.64,-0.87) (8.64,-1.90) (9.25,-2.47) (9.82,-1.31).

**Section 3: wide top chamber**, then a deep inward spur to x = 5.85 at y ≈ 0, then a narrow bottom.
- Outer polygon: (4.35,9.93) (4.36,9.25) (8.39,9.23) (9.47,8.53) (10.02,7.77) (10.08,2.68) (8.50,1.21) (5.85,0.04) (5.90,-0.58) (9.26,-3.96) (9.23,-4.78) (7.95,-7.64) (4.46,-9.39) (4.44,-10.01) (10.98,-10.04) (10.93,10.02).

**All three:** the top and bottom openings are at x ≈ ±4.4 (an 8.8-wide gap), which is why any combination chains vertically. Each wall is a PolygonCollider2D on layer 8 "wall" with 11x20 sprites.

## 5. Spawn anchors (left side as authored)

| map | LaneBlocker | Spring (sling) | ExtraFlipper | Fence | OutlaneSpring |
|---|---|---|---|---|---|
| 1 | (-7.57,-1.81) | (-4.00,-3.50) | (-5.94,0.73) | (-5.26,-7.44) | (-7.69,-4.06) |
| 2 | (-8.53,-2.95) | (-5.00,-3.50) | none | (-5.61,-8.08) | (-8.56,-4.27) |
| 3 | (-7.34,-3.59) | (-4.51,-3.84) | (-5.32,-0.66) | (-5.09,-8.03) | none |

**Slingshot:** a polygon body (Large 1.59x3.40, Small 1.13x2.24) plus a separate EdgeCollider2D kick face on layer 11 "spring".

## 6. Physics configuration
- **Physics2D settings:** gravity (0,-9.81); velocity iterations 8, position iterations 3; velocity threshold 1. Fixed timestep 0.02 (50 Hz).
- **Physics materials:** the only material is `PHYS_LowBounce` (friction 0.1, bounce 0.01), used on rollovers and speed lanes.
- **Ball:** CircleCollider2D r 0.6 with a 1.5x1.5 sprite; mass 0.8, angular drag 0.05, gravityScale 3.5, continuous collision detection, no interpolation.
  - Spawn: zero the velocity, teleport to (0,-9.57), ignore the flippers, then an impulse of about 25 u/s up through the flipper gap. There's no plunger.
  - There's no velocity clamp. Speed tiers 11, 28 and 32 u/s drive the FX.
- **Flippers:**
  - Bodies: a kinematic root with a HingeJoint2D; the child is a dynamic body (mass 3) with a CapsuleCollider2D 2.86x0.78 and a one-way PlatformEffector2D.
  - Hinge: pivot at about (-3.42,-7.29), pivot to tip about 2.8. Limits ±22.5° (a 45° stroke). Motor speed 850°/s, max torque 10000. A full stroke takes about 53 ms; tip speed is about 41 u/s.
  - Gap between the flipper tips: 1.27, against a ball diameter of 1.2.
- **Scripted impulses:** all zero the velocity first, then add an impulse of Strength along the normal (±5%), so Δv = S / 0.8.

  | Element | Strength | Δv |
  |---|---|---|
  | Bumper / bash toy / breakable | 15 | 18.75 u/s |
  | Slingshot | 10 | 12.5 u/s |
  | Outlane kickback | 20 | 25 u/s |
  | Hold hole eject (after 1–2 s) | 20 | 25 u/s |
  | Speed lane (velocity not zeroed) | 40 | +50 u/s up |

- **Other elements:** moving bumpers travel ±2 in x at speed 2 (kinematic). Spinner top speed 700. Rail speed 10. Warp 0.5 s, teleporter 0.25 s. Electric fence: hold 0.5 s, then off for 5 s.

## 7. Element footprints (Classic)

| element | collider | placement margin | max / flags |
|---|---|---|---|
| Simple bumpers | circle r 0.85 / 0.75 | R 2.0 / 1.9 | unlimited, not centre-x |
| Moving bumper | circle r 0.80 | box 7.25x3.4 | unlimited |
| Score bumper | circle r 0.85 | R 2 | unlimited |
| Destroyable bumper | circle r 0.80 | R 1.4 | unlimited |
| Bash toy | circle r 0.50 | R 1.7 | unlimited |
| Drop target | circle r 0.50 | R 1 / box 2x3 | unlimited |
| Rollover | box 1x1 | R 0.88 | unlimited |
| Lane | capsule 0.5x1.78 | box 2.5x3.1 | 1, centre-x |
| Spinner | trigger r 0.6 | R 1.73 | 1, centre-x |
| Warp | trigger r 0.25 | box 1.2x4 | 1 |
| Teleport | trigger r 0.2 (+ r 1.5 attractor) | R 1.48 | 1 |
| Hold hole | trigger | R 1 | 2 |
| Slot machine | visual | box 7.94x3.96 | 1, forced centre |
| Score multiplier | visual | box 3.24x7.65 | 1, forced centre |
| Speed lane | trigger 0.61x2.39 | box 1.96x4.59 | 1, forced centre |
| Flipper | capsule 2.86x0.78 | R 1.9 | n/a |
| Sling Large / Small | poly + kick edge | R 2.5 / 2.0 | n/a |

**Spacing rule of thumb:** bumper centres end up at least about 2 units apart, which leaves a gap of about 0.4, a bit under one ball diameter.

## 8. Diagrams (`diagrams/`)
- `sections_<theme>_<n>.png`: one table built from section n on both sides.
- `sections_overview.png`: the 3 sections, plus 3 stacked tables with mixed left/right picks.
- `sections_boss.png`: the boss wall, its anchors and flippers.
- `element_footprints_*.png`: every element's collider plus its placement margin, with the ball for scale.

## 9. Caveats
- Method logic comes from Cpp2IL's ARM64 synopsis, not decompiled C#.
- The fixed timestep is the ProjectSettings value; no runtime override was found.
