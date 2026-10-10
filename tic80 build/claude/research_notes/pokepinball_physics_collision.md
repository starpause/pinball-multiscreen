# Pokémon Pinball (GBC): ball physics and collision engine notes

Source: the pret disassembly at
`research/1999 Pokemon Pinball (GBC)/Disassembly of Pokémon Pinball/`. All paths below are relative to that folder. I only read it and changed nothing.
Goal: copy the engine technique in TIC-80 Lua at 240x136 and 60 fps. Every table below has a formula you can use to regenerate it.

How sure each claim is:
- **[code]**: read directly from the asm.
- **[data-fit]**: I fitted a formula to the .bin/asm table with Python and checked the error.
- **[inferred]**: my own reading, likely but not proven.

---

## 0. Big picture (one frame)

The GB runs the whole sequence below once per frame, with no physics substeps (`home.asm:2091` Main → `.master_loop` → `DoScreenLogic` → `HandlePinballGame` → `GameScreenFunction_HandleBallPhysics`, then `rst AdvanceFrame`). The GB frame rate is 59.73 Hz, so the constants carry over to TIC-80's 60 fps unchanged.

`engine/pinball_game.asm:70-158` `GameScreenFunction_HandleBallPhysics`:

```
wFlipperCollision = 0 ; wCollisionForceAmplification = 0
ApplyGravityToBall          ; vy += 11/256                     (home.asm:2369)
LimitBallVelocity           ; clamp hi byte of vx, vy           (home.asm:2386)
wIsBallColliding = 0
HandleTilts                 ; nudge input, may move ball 1px   (home/tilt.asm:1)
if stage has flippers: HandleFlippers   ; sets wFlipperCollision + wCollisionNormalAngle
CheckStageCollision         ; 16-point ring test vs per-pixel masks, push-out, normal angle
   (if a flipper collided, the flipper's normal angle overrides the stage one)
CheckGameObjectCollisions / ResolveGameObjectCollisions   ; bumpers etc. may set angle/force
if wIsBallColliding:
    ApplyTiltForces                      ; adds the tilt impulse projected on the normal
    (bc,de) = RotateVector(v, angle)     ; into the normal frame
    ApplyCollisionForces                 ; bounce plus spin coupling
    if wFlipperCollision: de -= FlipperYForce ; bc += FlipperXForce (always 0)
    elif wNoCollisionApplied: skip writing velocity
    v = RotateVector(v', -angle)         ; back to world frame
MoveBallPosition            ; prev = pos ; pos += clamp(v, ±4.996)
CheckStageTransition        ; horizontal scroll plus vertical screen swap
DrawSpritesForStage         ; ball rotation += spin
```

Key point: velocity changes from a collision are applied before the move. The position is also pushed out of the wall inside `CheckStageCollision`, before the move.

---

## 1. Ball state representation

`wram.asm:271-296`:

| var | addr | format |
|---|---|---|
| `wBallXPos`, `wBallYPos` | d4b3, d4b5 | 16-bit **8.8 fixed point**, little-endian (lo byte = fraction, hi byte = pixel). Unsigned 0..255 px |
| `wPreviousBallXPos/YPos` | d4b7, d4b9 | 8.8 copy taken at the start of `MoveBallPosition` |
| `wBallXVelocity`, `wBallYVelocity` | d4bb, d4bd | signed 8.8, **px per frame**. +y = down |
| `wBallSpin` | d4c3 | signed byte, angular velocity in rotation units per frame |
| `wBallRotation` | d4c4 | unsigned byte, 0..255 = one full turn of the sprite |
| `wBallSize` | d4c8 | 0 normal, 1 mini, 2 super-mini (graphics only, see Ditto) |
| `wEnableBallGravityAndTilt` | d549 | 0 = no gravity or tilt (ball held, or before launch) |

So the format is **8 fractional bits**: 1 unit = 1/256 px (per frame).

### Gravity
`home.asm:2369-2384`
```asm
ld de, $000b  ; gravity added to y velocity every frame
ld hl, wBallYVelocity ... add hl, de
```
`vy += 11/256 px/frame²`. That is 0.04297 px/frame², or about 154.7 px/s² at 60 fps. Gravity is on only when `wEnableBallGravityAndTilt != 0`. There is no table slope term; the "slope" is just this constant.

### Velocity clamp: on the hi byte only, per axis
`home.asm:2386-2409`
```asm
bit 7,a / jr nz,.neg / cp 8 / ret c / ld a,7 / ld [hl],a   ; hi>=8 -> hi=7 (lo kept)
.neg: cp -7 / ret nc / ld a,-7 / ld [hl],a                 ; hi<-7 -> hi=-7
```
Pseudocode: `if vx >= 8 then vx = 7 + frac(vx)`, `if vx < -7 then vx = -7 + frac(vx)`, and the same for vy. In practice each component stays in about [-7.0, +7.996] px/frame. The clamp is per axis, so diagonal motion can be about 1.41x faster (the code comments say so).

### Displacement clamp (separate from the velocity clamp)
`home.asm:2411-2455` `MoveBallPosition`/`AddVelocityToPosition`:
```asm
cp 5 / jr c,.readLoByte / ld bc,$04ff      ; hi >= 5  -> step = +4.996
cp -4 / jr nc,.readLoByte / ld bc,-$04ff   ; hi <= -5 -> step = -4.996
```
Each frame `pos += clamp(v, -1279/256, +1279/256)`. The stored velocity is **not** changed. This clamp keeps the ball from moving more than about 5 px per frame through the 4-px-radius collision ring, which is how they avoid tunnelling with only one step per frame.

### Launch / init (for scale)
- Red field start: `x=$a7.00 (167)`, `y=$98.00 (152)` (`ball_init/ball_init_red_field.asm:4-11`).
- Plunger launch sets `vx=0`, `vy=$FA80 = -5.5 px/frame`, spin=0, gravity on (`object_collision/red_stage_resolve_collision.asm:2220-2230`). The launch strength is fixed; there is no variable plunger.

### Ball size vs collision radius [inferred, strong evidence]
- The sprite is 16x16 (two 8x16 OBJs at x offsets 0 and 8, `data/sprite_frames.asm:283`).
- The collision test ring has radius 4 px (section 2).
- The collision masks are therefore drawn about 4 px "fatter" than the visible walls. The masks are a configuration space for a radius-4 probe. A 16-px ball fits in the plunger lane, yet that lane is only 11 px wide in the collision mask (I rendered `red_stage_bottom`: free pixels x=161..171 at y=100).
- Effective ball radius ≈ 4 (ring) + about 4 (wall inflation) ≈ 8.
- For your own tables: draw the collision bitmap with walls dilated by (ball_radius - 4) px, or keep it simple and use a ring radius equal to the ball radius.

---

## 2. Stage collision

### 2a. Data layout
1. **Collision attribute map** (`data/collision/maps/*.collision`, 1024 bytes each). The map is **32 tiles wide**, one byte per 8x8 tile. Only `$300` bytes (32x24 tiles = 256x192 px) are copied to `wStageCollisionMap` (c700) by `LoadCollisionAttributes` (`engine/pinball_game/stage_collision_attributes.asm:131-149`). The playfield actually uses about 24x22 tiles (192 px wide = 160 screen + 32 scroll).
   - The byte is a **mask index** (0..255) into the stage's mask sheet.
   - On stages with flippers (`wCurrentStage` bit 0 set = bottom halves and bonus stages), bytes `$d0-$ff` are special (`home.asm:2974` `TryLoadSpecialCollisionMask`):
     - `$d0-$df`: 16 animated Pokémon mask tiles in WRAM `wMonAnimatedCollisionMask` (c400).
     - `$e0-$ef`: left-flipper-area masks; `$f0-$ff`: right-flipper-area masks. Each has 3 banks of `$80` bytes (16 tiles), picked by the flipper state hi byte: <7, <14, else.
   - Some stages swap whole maps for structural changes such as one-way gates or ball-entrance variants. Red top has 8 variants selected by `wStageCollisionState`; the pointer table at `stage_collision_attributes.asm:22-63` has 6 bytes per entry: map ptr+bank, mask ptr+bank.
2. **Collision masks** (`data/collision/masks/*.png` → `.1bpp`): **8 bytes per tile**, one byte per row. Bit 7 is the leftmost pixel; 1 bit = solid. A 128x128 sheet = 256 tiles = 2 KB.
3. Tile attribute values are also kept for game logic: `wCurCollisionAttribute` and `wCurCollisionTileOffset` record which tile was hit, used to detect lanes and triggers (`home.asm:2925-2972`).

### 2b. Collision point test: 16 points, per pixel
`home.asm:2653-2770` `CheckStageCollision`:
```asm
ld a,[wBallXPos+1] / sub 4 / and 7 -> wSubTileBallXPos ; (x-4)&~7 -> tile col
ld a,[wBallYPos+1] / sub 4 / and 7 -> wSubTileBallYPos
; reads the 2x2 tile attributes UL,UR,LL,LR at (tx,ty),(tx+1,ty),(tx,ty+1),(tx+1,ty+1)
ld b, 16  ; length of wCollisionPointTests
```
The `CollisionTests` tables (`home.asm:3090-3244`) are a bit-level precompute, one per x sub-pixel. They test exactly these 16 offsets from the **integer** ball centre (`BallCollisionTestPointOffsets`, `home.asm:3065-3081`). Index 0 = right, then clockwise on screen (index 4 = straight down):

```
 i : 0     1     2     3     4     5      6      7      8      9       10      11      12     13     14     15
dx,dy: (4,0) (4,1) (3,3) (1,4) (0,4) (-1,4) (-3,3) (-4,1) (-4,0) (-4,-1) (-3,-3) (-1,-4) (0,-4) (1,-4) (3,-3) (4,-1)
```
(I checked `CollisionTest_X0` entry 0 = row 0, mask $10 (x=3), slot $0B. That is point 11 = (-1,-4) relative to the centre, taken from base (cx-4, cy-4).) These points form a jagged octagon of radius 4. Point i sits at angle `atan2(dy,dx)`, which is not uniformly 22.5°: the angles are 0, 14.04, 45, 75.96, 90, …

Lua equivalent:
```lua
hits[i] = solid(px+dx[i], py+dy[i])   -- px,py = floor(ball.x), floor(ball.y); i = 0..15
```

### 2c. Choosing the contact arc
`home.asm:2795-2865`:
- The 16 results are copied twice in a row (`wCollisionPointTests` d7c9 and then d7d9) so runs can wrap past index 15.
- If point 0 is set, the scan first skips the run that touches it (`.findNextCollisionPoint2`), so a run that wraps around index 15→0 is counted once.
- It finds the **longest run of consecutive solid points**: `start` = first index, `end` = last index (mod 16), `len` = count. It sets `wIsBallColliding = len`. A run of 0 means no collision.
- The code then uses `idx = start<<4 | end` (0..255).

### 2d. Normal angle and push-out: `CollisionForceAngles`, `CollisionYDeltas`, `CollisionXDeltas`
`home.asm:2876-2911`; data in `data/collision/collision_deltas.asm` (256 × db angle, 256 × dw Ydelta, 256 × dw Xdelta, all indexed by `idx`).
```asm
ld hl, CollisionForceAngles / add hl,de / ld a,[hl] / ld [wCollisionNormalAngle],a
sla e / rl d / ld hl, CollisionYDeltas ... wBallYPos += [hl]  (8.8)
ld hl, CollisionXDeltas ... wBallXPos += [hl]
```

**Angle encoding:** 0..255 = full circle. The angle θ names the outward normal vector `n = (sin θ, -cos θ)`, so θ=0 means the normal points up (floor under the ball), $40 means right (wall on the left), $80 means down (ceiling), $C0 means left.

**Regenerating formula [data-fit: 256/256 angles exact; deltas within 1.23/256 px, i.e. rounding]:**
```
a0 = angle_deg(P[start]),  a1 = angle_deg(P[end])  ;  if a1 < a0 then a1 += 360   (start==end -> a1=a0)
mid  = (a0 + a1)/2           -- direction of the contact centre (screen degrees, 0=+x, 90=+y/down)
half = (a1 - a0)/2           -- half-width of the contact arc
theta = (round(mid*256/360) - 64) mod 256          -- CollisionForceAngles[idx]
depth = 1 + 4*(1 - cos(half))                      -- px; 1.0 for 1 point ... 5.0 for a flat wall through the ring ... ~8.9 max
delta = depth * (-cos(mid), -sin(mid))             -- (CollisionXDeltas, CollisionYDeltas)[idx] * 1/256
```
In words: the normal points from the middle of the touching arc back through the ball centre. The ball is pushed out along that normal by `1 + r(1-cos α)`, which is the penetration depth of a flat wall cutting a radius-4 circle at half-angle α, plus 1 px of margin. The push-out happens every frame the ball touches, whatever its velocity.

`circle_collision_angles.bin` and the other `*_collision_angles.bin` files are **not** used for the stage. They serve round or irregular objects in bonus stages (section 2g).

### 2e. Response: rotate, bounce, rotate back
**Rotation** (`home.asm:2457-2518` `RotateVector`), with c=cos θ, s=sin θ:
```
x' =  x*c + y*s
y' =  y*c - x*s           -- y' > 0 means moving INTO the wall (normal is -y' in this frame)
```
Back-rotation uses `NegateAngleAndRotateVector` (θ → -θ).

The multiply is `MultiplyVectorComponentByAngleFactor` (`home.asm:2280`): `v*e/256` with e = |sin| in 0..255 and a sign flag. Because sin max is 255/256, each rotate pair shrinks the vector by about 0.4–0.8%. This is a small built-in energy loss; copy it if you want the exact feel.

**Sine table** (`data/sine_table.asm`, 65 entries for the quarter wave). The `Sine` routine (`home.asm:2343`) folds the angle: `and $7f`; if ≥$40, use `$80-a`; bit 7 of the angle gives the sign. `Cosine(a) = Sine(a+$40)`.
[data-fit, exact]: `SineTable[i] = min(255, round(256*sin(i*pi/128)))`, i=0..64.

**ApplyCollisionForces** (`home.asm:2520-2617`):
```asm
bit 7,d / jr nz,.exit          ; y' < 0 (already leaving): wNoCollisionApplied=$ff, no-op
cp 3 ... rumble + sfx if hi(y') >= 3
srl d/rr e x2 -> hl = y'/4 ; srl -> de = y'/8
.amplify: add hl,de (wCollisionForceAmplification times)
negate -> y'' = -(y'/4 + amp*y'/8)
ld a,[wBallSpin] / sra a -> x'' = x' + spin/2   (spin/2 in 1/256 px units)
new spin = hi byte of (x''*4)   ; sla c/rl b twice, ld a,b
```
Pseudocode, in units of px/frame:
```
if y' <= 0 (sign bit set): no change (wNoCollisionApplied = $ff); flipper/kicker force still applies
e = 0.25 + 0.125*amp          -- amp: 0 = walls, 1 = flippers, 2 = Diglett
y'' = -y' * e                 -- coefficient of restitution 0.25 (walls), 0.375 (flippers), 0.5 (amp=2)
x'' = x' + spin/512           -- spin is a signed byte; tiny effect
spin = floor(x''*4)           -- signed byte; tangential speed sets the spin
```
- There is **no tangential friction**. Tangential speed is kept, apart from the rotate shrink and the spin term.
- Walls are very "dead" (e=0.25), so the ball sticks to and rolls along walls nicely. The liveliness comes from kickers (below).
- `wCollisionForceAmplification` is set to 1 by flippers (`flippers.asm:663-665`) and to 2 by Diglett (`red_stage_resolve_collision.asm:466`).

**Kickers, bumpers, Voltorb, flippers: extra normal impulse** (`engine/pinball_game.asm:113-135`). When `wFlipperCollision != 0`, after the bounce:
```
y'' -= wFlipperYForce        ; i.e. extra speed along the outward normal
x'' += wFlipperXForce        ; always 0 in practice (HandleFlippers zeroes it)
```
- **Bumpers and Voltorbs** set `wFlipperYForce = $0200` (2.0 px/frame) and `wFlipperCollision = $80`. Bumpers also bias the normal angle by `-8` or `+8` (±11.25°) per bumper (`red_stage_resolve_collision.asm:1680-1711`, `:584-600`).
- **Flippers** (`flippers.asm:622-673`): `FlipperYForce = FlipperRadiusMagnitudes[r] * (flipperStateChange*4)`, computed as 8.8×8.8 → 16.16 and keeping the middle 16 bits (`CalculateFlipperYForce`, `flippers.asm:423`).
  - `r` = distance from the pivot (table `flippers.asm:801`: 0,$0C,$1C,$30,… up to $F8, then $FC). That is roughly 0.06 px of force per unit of radius, near-linear.
  - The state change is ±$0333 per frame (state range 0..$0F00, so a full swing takes about 4.7 frames).
  - Example: at the tip with the flipper rising, the force is ≈ 0.98 × 12.8 ≈ 12.6 px/frame. The next frame's ±7 clamp limits it.
  - If the computed force would push the ball into the flipper, it is zeroed.
  - The flipper normal is mirrored (`cpl/inc`) for the right flipper (x ≥ 80).
  - Flipper geometry comes from precomputed per-state tables (`data/collision/flippers/radii_*`, `normal_angles_*`): 16 states × 48(x) × 32(y) bytes, $600 per state. Each byte holds the radius index (0 = no hit) and the normal angle per pixel. The window starts at x 43, y 123, and the right flipper samples it mirrored.
  - The code walks the states from the previous one to the current one (`ReadFlipperCollisionAttributes`, `flippers.asm:202-298`), so a fast swing can't tunnel through the ball.

### 2f. Tilt forces during collision
See section 5. `ApplyTiltForces` runs only when `wIsBallColliding`, and before the rotation.

### 2g. ball_physics_*.bin and the object angle tables: what they really are
All three `ball_physics_*.bin` files are **position-indexed force fields**. Each cell holds 4 bytes, `(dvx s16 LE, dvy s16 LE)` in 1/256 px/frame, and the cell's values are **added to the velocity every frame** while the ball (integer pixel position relative to the field origin) is inside the grid. If |Δv| ≥ about 1 px/frame they also start rumble. None of them are reflection tables.

| file | used by | grid | content | regenerating formula [data-fit] |
|---|---|---|---|---|
| `ball_physics_e4000.bin` (4096 B) | Mewtwo bonus orbiting shields, `object_collision/mewtwo_bonus_object_collision.asm:45-110` | 32×32, index `(dy*32+dx)*4`, dx,dy = ball − object ∈ [0,32) | **repulsion, inverse square**, centre (16,16) | `Δv = 7680 * d/|d|^3` (in 1/256 units), d=(dx-16,dy-16); 0 at centre. That is 1920/256 = 7.5 px/frame at r=2, 0.12 at r=16. 0 cells off-radial |
| `ball_physics_f0000.bin` (9216 B) | Slot-cave pull, red and blue fields (`red_stage_resolve_collision.asm:1863`, `blue_stage_resolve_collision.asm:2745-2880`). Window: ball y−$86 (bottom stage) or y−$fe (wraps for top), x−$38, each <$30 | 48×48, index `(dy*48+dx)*4` (computed as dy*192 + dx*4) | **attraction toward (24,24)**, ring-shaped magnitude peaking at r≈8 | `|Δv| = 1791 * u^4/(1+u^8)`, u = r/7.95, direction = −d/|d| (toward centre). Max error 1.4/256 over all 2304 cells. Peak 895/256 = 3.5 px/frame at r=8; about 0 near the centre (so the ball settles); about 1/r^4 far away |
| `ball_physics_ec000.bin` (16384 B; only the first 9216 B are used, the rest are zeros) | Blue field arrow force field (`ApplyForceFieldForce_Up/Right/Down/Left`, `blue_stage_resolve_collision.asm:3100-3400`). The same 48×48 table is reused for all 4 directions by swapping/negating components and mirroring the index | 48×48 | **hand-authored "fountain"**: a thin up-jet column (rows 1-14), a wide region (rows 15-31) whose sides push inward and up, then a straight up-column (rows 32-45, x 16..31). Values up to about −506 vy (−2 px/frame) and ±424 vx | Not a clean formula. Rebuild procedurally: e.g. `vy = -k*(1 - |x-24|/w)` inside the funnel, plus `vx = ±c` on the side lobes pointing toward x=24 |

Bonus-stage **object angle tables** (1 byte per pixel; byte `$FF` = outside the object, otherwise `angle/2`, so the code does `sla a` to get 0..254):
- `circle_collision_angles.bin`: 32×32, round object (Gastly, Seel bonus). Used as `CheckSingleGastlyCollision` in `object_collision/gengar_bonus_object_collision.asm:45-85`:
  ```asm
  ld a, [wBallXPos+1] / sub b / cp $20 / jr nc,.no   ; dx in [0,32)
  ... hl = CircularCollisionAngles + dy*32 + dx
  bit 7,a / jr nz,.no / sla a / ld [wCollisionNormalAngle],a / wIsBallColliding=1
  ```
  [data-fit] Inside if `(x-15.5)²+(y-15.5)² <= 278` (r ≈ 16.7, 4/1024 cells differ). Value `= floor(atan2(dx, -dy)*128/pi / 2)` with d = (x-16, y-16); 98% within ±1 unit (angle/2 units).
  This disc already includes the ball's radius: object r ≈ 8 plus ball r ≈ 8.
- `gengar_collision_angles.bin` (3072 B = 32 cols × 96 rows), `haunter_…` (1280 = 32×40), `meowth_…` (1920 = 32×60), `meowth_jewel_…` (576 = 32×18): the same encoding (32 bytes per row, `$FF` = empty, angle/2) for non-circular sprites. Generate them by taking a dilated sprite silhouette and storing the gradient direction of its distance field, using the same angle convention.

Object collisions never push the ball out (they have no delta table). They only set the normal angle, so the bounce happens and the ball moves away.

---

## 3. Ball rotation and spin animation

- **Spin source:** only collisions. `spin = hi byte(4*x'')`, i.e. 4 × the tangential speed in px/frame, as a signed byte (`home.asm:2604-2613`). Between collisions spin stays constant: no decay, no update from velocity in free flight.
- Spin and rotation are reset to 0 on ball init, launch, and when the ball is captured by a hole or sucked away.
- **Rotation:** `wBallRotation += wBallSpin` every frame inside `DrawPinball` (`engine/pinball_game/draw_sprites/draw_pinball.asm:5-8`).
- **Frame selection:** `frame = (rotation >> 4) & 7`, giving 8 frames, `SPRITE_BALL_SPIN_0..7` (`draw_pinball.asm:20-27`). The ball goes through all 8 frames in 256 rotation units, i.e. one frame every 32 units.
  - Example: rolling at 2 px/frame tangential gives spin 8, a new frame every 2 frames, and a full cycle in 32 frames = 64 px of travel. A 16-px ball's circumference is about 50 px, so this is close to real rolling.
- The sign of the spin follows the rotated frame's x', so a ball rolling right along a floor (θ=0, x' = vx) gets positive spin.
- Sprite placement: OAM (y,x) = (y + 1 − 16 − SCY + 8, x + 1 − SCX), with 2 OBJs at x offsets 0 and 8. On screen the 16x16 ball's top-left is at (x−7−SCX, y−23−SCY) after the GB OAM offsets (−8,−16). So the **collision Y coordinate is about 16 px below the BG coordinate** (screen centre y ≈ y−16) [inferred from the arithmetic; the effect is that the collision map has 2 tile rows above the visible top].
- On original DMG only (not GBC/SGB), a second "ghost" ball is drawn at last frame's position and rotation. This is a motion-blur trick (`draw_pinball.asm:30-60`).

---

## 4. Screen layout and vertical transitions

- **Stages are separate sections.** Each field is two stage IDs, `STAGE_*_TOP` and `STAGE_*_BOTTOM`. Each has its own BG, its own 32x24-tile collision map and its own objects. Bonus stages are single screens.
- **There is no vertical scrolling inside a section.** `hSCY = -wUpperTiltPixelsOffset` only, which is the tilt shake (`vertical_screen_transition.asm:166-172`). The visible playfield is 160 × 134 (bottom message window at `hWY=$86`), or 160 × 144 on bottom stages when no text is shown.
- **Horizontal scroll** (`ScrollScreenToShowPinball`, `vertical_screen_transition.asm:146-173`). The stage is 192 px wide and the screen 160. `wSCX` moves 2 px per frame: toward +$20 (32) when ball x ≥ $9A (154), else toward 0. It stops when the next value would be $22 or negative. Then `hSCX = wSCX - wLeftAndRightTiltPixelsOffset`. Not needed for a 240-wide TIC-80 screen.
- **Vertical swap trigger** (`CheckStageTransition`, `vertical_screen_transition.asm:63-98`), checked every frame after the move:
  ```asm
  ld a,[wBallYPos+1] / add $10 / cp $18 / jr c,.moving_up   ; y+16 < 24  -> y < 8 (y in [-16,8) by wrap)
  cp $b8 / ret c                                            ; y+16 >= 184 -> y >= 168
  ... down: FieldVerticalTransition(BallMovingDownStageTransitions[stage]) ; y -= $88
  ... up:   FieldVerticalTransition(BallMovingUpStageTransitions[stage])   ; y += $88
  ; table value $FF -> ball lost (bottom of the bottom stage = drain)
  ```
  - Section offset = **136 px ($88)**. Down: y 168 → 32 on the lower stage. Up: y 7 → 143 on the upper stage. That leaves a 24-px dead band on each side (up threshold 8 vs arrival 32; down threshold 168 vs arrival 143), so the swap can't flicker back and forth.
  - The two sections overlap: top-stage y ∈ [136,192) is the same place as bottom-stage y ∈ [0,56).
  - Velocity is preserved across the swap.
  - Tables: `BallMovingUpStageTransitions` (`:100`) and `BallMovingDownStageTransitions` (`:118`). Red: TOP↓BOTTOM and BOTTOM↑TOP. Blue: the same. Bottom↓ = `$FF` = lose ball. Top↑ = `$FF` (unreachable).
- **What the swap does** (`FieldVerticalTransition`, `vertical_screen_transition.asm:1-41`):
  1. Hide the ball sprite and stop rumble.
  2. Set `wCurrentStage` to the new stage.
  3. Black out the palettes for one frame, then disable the LCD.
  4. Reload the collision attributes (`LoadStageCollisionAttributes`) and the stage graphics and objects (`LoadStageData`), then re-enable the LCD and restore the palettes.

  It is a hard cut with one blank frame, not a scroll. Game state persists in WRAM.
- `engine/pinball_game/map_move.asm` is the **"Map Move" game mode** (which Pokémon region/billboard map is active). It is not camera movement.

For TIC-80 (136 px tall, matching the 136-px section offset): use one tall collision bitmap per field and swap the camera by 136 px, or reproduce the separate sections with the same hysteresis (leave at <8 or ≥168, arrive at +136/−136).

---

## 5. Tilt / nudge

`home/tilt.asm`. Three directions: left, right, up. Each has a key, a counter, a "reset" latch and a "pushing" flag.

**Per frame while the key is held** (`HandleLeftTilt`, `:7-50`):
- If the counter < 3 (left/right) or < 4 (up):
  - counter++
  - play sfx $3f on the first frame
  - if ball visible and gravity on: move the ball **1 px** (left tilt: x−1; right tilt: x+1; up tilt: y+1)
  - shift the screen offset by 1 px (shake)
  - pushing = 1
- When the counter reaches the max: set `reset=1`. The nudge can't happen again until the key is released.

**Release or cooldown:** pushing = 0; counter-- and the screen offset returns 1 px per frame.

In short, one nudge = up to 3 px of ball displacement (4 for up) over 3–4 frames, plus a screen shake.

**Velocity impulse, only while the ball touches something** (`ApplyTiltForces`, `home/tilt.asm:175-230`):
```asm
c = up<<2 | right<<1 | left ; TiltForces[c] -> table (none / left / right / cancel / up / up+left / up+right / up)
hl += wCollisionNormalAngle*4 ; vx += s16[hl] ; vy += s16[hl+2]
```
Data `data/tilt/{left_only,right_only,up_only,up_left,up_right}`: 256 entries × 4 bytes (dvx, dvy s16), indexed by the normal angle θ.

[data-fit, exact to rounding] `table[θ] = (F·n) n`, with n = (sin θ, −cos θ), i.e. **the tilt force projected onto the contact normal**:
- left_only: F = (+256, 0) → +1 px/frame to the right (the table moves left, so the ball is kicked right off left-facing walls).
- right_only: F = (−256, 0).
- up_only: F = (0, −512) → 2 px/frame upward.
- up_left / up_right: sum of the two.

The projection uses n twice, so the sign of n cancels. The impulse is along the normal axis, and the bounce step then reflects any into-wall part. When up+left+right are all held, index 7 = up only.

---

## 6. Lua sketch (float version, same constants)

```lua
G=11/256; VMAX_HI=8; STEP=1279/256; E_WALL=0.25
P={{4,0},{4,1},{3,3},{1,4},{0,4},{-1,4},{-3,3},{-4,1},{-4,0},{-4,-1},{-3,-3},{-1,-4},{0,-4},{1,-4},{3,-3},{4,-1}}
-- precompute ANG[idx], DX[idx], DY[idx] with the formula in 2d (idx = s*16+e)
function physics(b)
  b.vy=b.vy+G
  b.vx=clamp_hi(b.vx); b.vy=clamp_hi(b.vy)        -- [-7, 8)
  local px,py=b.x//1,b.y//1
  local hit={} for i=0,15 do hit[i]=solid(px+P[i+1][1],py+P[i+1][2]) end
  local s,e,len=longest_run_wrap(hit)                 -- see 2c
  if len>0 then
    local k=s*16+e; b.x=b.x+DX[k]; b.y=b.y+DY[k]
    local th=ANG[k]*2*math.pi/256; local c,sn=math.cos(th),math.sin(th)
    local x1= b.vx*c+b.vy*sn; local y1= b.vy*c-b.vx*sn
    if y1>0 then
      y1=-y1*(0.25+0.125*amp)
      x1=x1+b.spin/512; b.spin=clamp8((x1*4)//1)
    end
    y1=y1-kick                                         -- bumper 2.0, flipper r*dstate*4
    b.vx= x1*c-y1*sn; b.vy= y1*c+x1*sn                 -- rotate by -th
  end
  b.x=b.x+clamp(b.vx,-STEP,STEP); b.y=b.y+clamp(b.vy,-STEP,STEP)
  b.rot=(b.rot+b.spin)%256; b.frame=(b.rot>>4)&7
end
```
(In the original, if y1 ≤ 0 and there is no kicker, the velocity is left untouched.)

Scaling note: with TIC-80 at the same 60 fps and a similar pixel scale, all constants carry over as-is. If your ball is not 16 px, scale the ring radius (4), the push-out formula (r=4) and the wall inflation together.
