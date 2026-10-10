# Pokemon Pinball (GBC) engine technique notes: flippers, objects, launch/drain, main loop, stage data

Source: pret disassembly at `research/1999 Pokemon Pinball (GBC)/Disassembly of Pokémon Pinball` (read-only).
Paths below are relative to that folder. All `.bin` analysis was done with `python -I` scripts in the scratchpad (flip*.py, ff*.py, circ.py, cd.py, png.py).

## 0. Conventions you need first

| Thing | Format | Ref |
|---|---|---|
| Ball position `wBallXPos`, `wBallYPos` | 8.8 fixed point (lo = fraction, hi = pixel), in *stage* pixel coords (the stage collision map is 32x24 tiles = 256x192 px) | wram.asm:271-275 |
| Ball velocity `wBallXVelocity/YVelocity` | 8.8 signed, px/frame, +y = down | wram.asm:283-288 |
| Angles | 1 byte, **256 units per circle, 0 = straight up, increases clockwise** (64 = right, 128 = down, 192 = left) | wram.asm:1829-1836, home.asm:2337 (Sine/Cosine) |
| Sine table | 65 entries, quarter wave, `round(255*sin(i*pi/128))` (0x00..0xFF) | data/sine_table.asm |
| Ball radius | 4 px (16 test points on a radius-4 ring) | home.asm:3065 `BallCollisionTestPointOffsets` |
| Stage | `wCurrentStage`; **bit 0 = bottom half of a table** (flippers only on odd stages). Red top=0, Red bottom=1, Blue top=4, Blue bottom=5, bonus stages 6..15 | pinball_game.asm:79-81 |

Global constants (home.asm):
- Gravity: `+$000B` to y velocity every frame = **0.043 px/frame^2** (home.asm:2369-2384, `ApplyGravityToBall`). Skipped when `wEnableBallGravityAndTilt == 0` (used to hold/freeze the ball).
- Velocity clamp: each axis' **high byte** is clamped to [-7, +7], so |v| < 8.0 px/frame per axis (lo byte keeps its value) (home.asm:2386-2409).
- Per-frame displacement clamp: when moving, if hi byte >= 5 the step is `$04FF` (4.996 px); if hi <= -5 the step is `-$04FF`. This anti-tunnelling clamp keeps the ball from skipping 8-px tiles (home.asm:2411-2455 `MoveBallPosition`/`AddVelocityToPosition`).

---

## 1. Flippers (engine/pinball_game/flippers.asm)

### 1.1 State variables (wram.asm:1747-1780)
```
wLeftFlipperState        dw  ; 8.8 fixed: hi byte = integer state 0..15
wLeftFlipperStateChange  dw  ; signed 8.8 delta applied this frame (+$0333, -$0333 or 0)
wRightFlipperState       dw
wRightFlipperStateChange dw
wPreviousLeftFlipperState  db ; integer state last frame
wPreviousRightFlipperState db
wFlipperCollisionNormalAngle db
wFlipperCollision        db  ; 1 = flipper hit this frame ($80 is reused by bumpers, see 2.4)
wFlipperXForce dw ; always 0 (never written non-zero; unused X path)
wFlipperYForce dw ; impulse along collision normal, 8.8 px/frame
wFlippersDisabled db
```

### 1.2 Rotation: 16 discrete states, linear speed, same up and down
`UpdateFlipperStates` (flippers.asm:14-112):
```asm
    ld hl, wKeyConfigLeftFlipper
    call IsKeyPressed2
    ld hl, -$0333          ; released -> rotate down
    jr z, .checkLeftStateBounds
    ld a, [wFlippersDisabled] ...
    ld hl,  $0333          ; held     -> rotate up
.checkLeftStateBounds      ; if state==0 and going down, or state==$f and going up -> change = 0
    ...
    add hl, bc             ; state += change
    cp $10 / ld hl,$0f00   ; clamp to [0, $0F00]
```
Pseudocode:
```lua
local STEP = 0x333/256          -- 3.2 states per frame
change = held and STEP or -STEP
if (stateInt==0 and change<0) or (stateInt==15 and change>0) then change = 0 end
state = clamp(state + change, 0, 15)   -- stored 8.8; integer part = frame index
```
- **16 states (0 = rest/down, 15 = fully up)**. Full travel takes 15/3.2 = **~4.7 frames (5 frames)** both up and down. No acceleration, no separate up/down speeds.
- `stateChange` stays the full +/-3.2 even on the frame that clamps into 15 (only zeroed once already at the end stop). That matters for the impulse (1.5).
- Geometry measured from the collision tables (see 1.4): flipper angle ~= **+26.5 deg below horizontal at state 0 to ~-31 deg (above) at state 15**, ~**3.83 deg per state** (57 deg total sweep).
- Drawing uses only 3 sprites: states 0-6 = DOWN, 7-13 = HORIZONTAL, 14-15 = UP (flippers.asm:751-799 `LeftFlipperSpriteIds`; the table has 21 entries but only 0..15 are reachable). Sprite anchors: left (x=$38,y=$7B), right (x=$68,y=$7B) in stage px (flippers.asm:746-749).

### 1.3 Two-layer flipper collision (important!)
Flipper collision is a hybrid of two systems:

**A. Tile-mask layer (decides *whether* the ball touches and pushes it out).**
The bottom-stage collision map has special attribute bytes `$E0-$EF` (left flipper, 4x4 tiles) and `$F0-$FF` (right flipper). `TryLoadSpecialCollisionMask` (home.asm:2974-3058) swaps in one of **3 masks per flipper**, chosen from the integer state: `<7`, `7..13`, `>=14` (exactly matching the 3 sprites). Each mask set is 16 tiles x 8 bytes (1bpp) = `$80` bytes; 3 sets per side (data/collision/masks/bottom_left_masks.png etc.). In red_stage_bottom.collision the left flipper tiles sit at columns 6-9, rows 15-18 (px x 48..79, y 120..151); right at columns 10-13.
`CheckStageCollision` then does the generic ball-vs-mask test, sets `wIsBallColliding` and **pushes the ball out** (see 2.1). **If this layer reports no contact, no flipper impulse is applied** even if the flipper tables hit, because the main loop gates on `wIsBallColliding` (pinball_game.asm:99-102) and `CheckStageCollision` overwrites it.

**B. Precomputed per-angle attribute tables (decide normal and lever arm).**
`ReadFlipperCollisionAttributes` (flippers.asm:202-298):
```asm
    ldh a, [hBallXPos + 1]
    sub 43   ; box x 43..90
    ret c
    cp 48
    ret nc
    ...
    ldh a, [hBallYPos + 1]
    sub 123  ; box y 123..154
    ret c
    cp 32
    ret nc
    ldh a, [hPreviousFlipperState]
.collisionCheckLoop           ; addr = state*$600 + x*32 + y
    ...
    and a
    jr nz, .collision
    pop af                    ; not hit: step state toward current state
    cp [hl]                   ; (hFlipperState)
    ret z
    jr c, .checkNextHigherState
    dec a ...
```
- Data: `FlipperCollisionRadii` = radii_0 + radii_1 (16384 + 8192 = 24576 B) and `FlipperCollisionNormalAngles` = normal_angles_0 + _1 (24576 B) (main.asm:1099-1113).
- **Layout: `[state 0..15][x 0..47][y 0..31]`, column-major, `$600` bytes per state.** Index = `state*0x600 + x*32 + y`. Local box origin = stage px (43,123).
- **Swept test:** it checks every integer state from *previous* state toward *current* state (inclusive) and uses the first state that has a non-zero cell. This is how fast flipper motion (3 states per frame) doesn't pass through the ball.
- **Right flipper = mirrored left.** For x >= 80 the ball x is mirrored, `x' = 160.0 - x` (16-bit negate of x-160) (flippers.asm:167-176), the same table is read, and the resulting normal is mirrored with `angle = -angle` (`cpl; inc a`, flippers.asm:657-663).
- Left/right selection is just `ballX < 80` (flippers.asm:133-136).

### 1.4 What is in the tables (inspected with python)
- **radius byte = round(euclidean distance from the pivot) in px**, 0 = no collision. The pivot is at local (11,17), i.e. **stage (54,140)**. Checked over all 9804 non-zero cells: `radius - round(dist)` is always 0. Range 1..26.
- The non-zero region is the area where the ball *centre* may be when touching the flipper, i.e. flipper shape grown by the ball radius. It is a filled shape about 600-630 cells per state: a disc of radius ~11 around the pivot (hub, ~7 px plus 4 px ball) plus a tapered body to about r = 24-26 (tip). It is **solid below the top surface** (about 14 px thick at r = 16), so a ball that sank in is still pushed up.
- **Normal byte (0 = up, clockwise)**: on the hub's back half it points radially away from the pivot (e.g. (0,17)->192, (11,6)->0). Across the whole body (top *and* underside) it is roughly the top-surface normal, changing slightly with r. Most common body normal per state: s0 ~10-13, s7 ~8, s10 = 0, s15 = 244 (-12 units = -17 deg). At the tip it fans out radially (values up to 0x60-0x80 at the far tip end).
- Ready-made procedural regeneration (good enough for gameplay):
```lua
-- local coords: pivot P=(11,17); state s in 0..15
-- flipper axis angle theta(s) = rad(26.5 - 3.83*s)   (+ = tip below pivot, screen y-down)
-- body = tapered capsule: hub radius rh=7 at P, tip radius rt=3 at P + L*(cos,sin), L~=20
-- region = { p : distToTaperedCapsule(p) <= 4 (ball radius) } UNION { p under the top surface, within 14px below it, 0<=proj<=L }
-- radius[p] = round(|p-P|)
-- normal[p] = if proj(p) <= 0 (behind pivot): radial angle from P
--             elseif proj(p) >= L (beyond tip): radial angle from tip centre
--             else perpendicular to axis pointing "up" (-y side)
-- angle encoding: a = (atan2(dx, -dy) / (2*pi) * 256) % 256
```
Precompute into a Lua table `flip[s][x][y] = {r, n}` at boot (16*48*32 = 24.6k cells, cheap) or just evaluate analytically per frame for the 1-3 swept states.

### 1.5 Impulse from the moving flipper
`HandleFlipperCollision` (flippers.asm:622-673):
```asm
    ldh a, [hFlipperCollisionRadius]
    sla a ...
    ld hl, FlipperRadiusMagnitudes   ; 8.8 lever-arm factor per radius
    ...
    ldh a, [hFlipperStateChange] ...
    sla e / rl d / sla e / rl d      ; stateChange * 4
    call CalculateFlipperYForce      ; (mag * change*4) >> 8 (8.8 * 8.8 -> middle 16 bits)
    ld [wFlipperYForce], ...
    ...
    ld a, 1
    ld [wCollisionForceAmplification], a
    ld a, [wFlipperYForce + 1]
    bit 7, a
    ret z
    xor a  ; negative (flipper moving down) -> force = 0
```
`FlipperRadiusMagnitudes` (flippers.asm:801-833), indexed by radius px:
```
r:  0   1   2   3   4   5   6   7   8   9   10  11  12  13  14  15  16  17+
  $00 $0C $1C $30 $38 $48 $5C $6C $70 $80 $94 $A4 $B4 $C4 $D4 $E4 $F8 $FC (cap)
```
That is about **mag(r) ~= 15.5*r / 256, capped at 252/256 for r >= 17** (a linear lever arm).

Plain English: `F = mag(r) * (stateChange*4)`, in px/frame along the collision normal, and only when the flipper is rising:
```lua
local function flipperImpulse(r, change)  -- change in states/frame (+3.2 rising)
  if change <= 0 then return 0 end         -- falling or held: no kick
  local mag = math.min(r*15.5, 252)/256
  return mag * change * 4                  -- e.g. r=16: 0.97*12.8 = 12.4 px/f (saturates)
end
```
Values: r = 5 gives 3.6, r = 10 gives 7.4, r = 16 gives 12.4 px/frame. The result then hits the 7.99 velocity clamp and the 4.996 px/frame step clamp, so **tip hits are always max speed and only hits near the pivot are weaker**. (Real tangential speed at r = 16 is only ~3.4 px/f, so the game gives about 3.6x more.)

How it is applied (pinball_game.asm:103-147). In the frame rotated so the normal points up (`RotateVector` by the normal angle; rotated +y = into the surface):
1. `ApplyCollisionForces` (home.asm:2520-2617): only if the ball moves *into* the surface (rotated vy >= 0): `vy = -(vy/4 + amp*vy/8)`. Flipper has amp = 1, so **restitution 3/8**. Plain walls have amp = 0 (1/4) and some objects amp = 2 (1/2). Tangential `vx += spin/2` (spin in 1/256 units, tiny) and `spin = hi(vx*4)`. No tangential friction.
2. `vy -= wFlipperYForce` (pinball_game.asm:115-125). Note this runs even when step 1 was skipped because the ball was moving away (the `wNoCollisionApplied` early-out is bypassed for flipper/bumper hits).
3. Rotate back by `-normal`, store velocity.

### 1.6 Hold / cradle
There is no special cradle code. It emerges from:
- At state 15 with the button held, `stateChange = 0`, so the impulse is 0 and the ball just gets the 3/8 bounce and slides on a surface whose normal is ~244 (tilted up-left on the left flipper). Gravity rolls it down toward the pivot/inlane corner, where it settles: a "catch". At state 0 the normal is ~10-16 (slope down toward the centre), so the ball rolls off the tip into the drain gap.
- Releasing gives a negative change: force 0 (the down-swing never kicks the ball). Re-pressing kicks from wherever the ball is, with lever arm r. That gives "post pass"/"tap pass" for free.
- Sound: one `PlaySoundEffect $0C` per new press (flippers.asm:114-131).

Implementation tip for TIC-80: since only 3 mask variants exist for the tile layer, you can skip layer A. Do the contact test straight from the analytic flipper (distance <= 4 + thickness). Push out along the normal by the penetration depth, then apply 1.5. Keep the "swept states prev..cur" loop.

---

## 2. Object collisions (engine/pinball_game/object_collision/*, data/collision/*)

### 2.1 Underlying generic collision: tile masks + 16-point ring (home.asm:2653-2972)
All physical surfaces (walls, slingshots, bumpers, drop-target bodies) are part of the **stage collision map**: 32 x 24 tiles of attribute bytes, copied to WRAM `wStageCollisionMap` (`$300` bytes, stage_collision_attributes.asm:131-149) so game logic can **rewrite tiles at runtime** (e.g. Diglett opens/closes by writing `wStageCollisionMap+$e3`, red_stage_resolve_collision.asm:236-240). Each attribute indexes an 8x8 1bpp mask tile (8 bytes).

Algorithm (`CheckStageCollision`):
1. Take the 2x2 tiles under (ballX-4, ballY-4). Test **16 points on a radius-4 ring** around the ball centre (offsets in `BallCollisionTestPointOffsets`, home.asm:3065-3082: (4,0),(4,1),(3,3),(1,4),(0,4),(-1,4),(-3,3),(-4,1),(-4,0),... clockwise starting at "right"). `CollisionTests` (home.asm:3090+) are precomputed (y-offset, bitmask, index) triples per sub-tile x.
2. Find the **longest run of consecutive set points** (with wrap). Store `(start<<4)|end` and run length n.
3. `wCollisionNormalAngle = CollisionForceAngles[start*16+end]`; position += `CollisionXDeltas/YDeltas[...]` (data/collision/collision_deltas.asm, 256 entries each).
4. `wCurCollisionAttribute` = attribute of the tile holding the first colliding point. This is the hook objects use (2.2).

**Regenerated (verified against the 256-entry tables):**
```lua
-- P[i] = ring offsets above, i=0..15
-- normal = direction opposite to sum(P[start..end]) ; mean err 2.3/256, max 7.8/256
-- push-out distance (px, along normal) = 1 + 4*(1 - cos((n-1)*pi/16)), n = run length
--   n=1:1.0  n=5:2.17  n=9:5.0  n=13:7.83  (exact match; push dir err < 0.25/256)
```

### 2.2 Object hitbox definition: attribute list + AABB (object_collision.asm)
`HandleGameObjectCollision` (object_collision.asm:20-56), `CheckGameObjectCollision` (:58-104), `IsCollisionInList` (:106-138).

Per object group there are two data blocks (data/collision/game_objects/red_stage_game_object_collision.asm):
```
RedStageBumpersCollisionAttributes:   ; optional: which collision-map tile attributes count
    db $00                            ; 0 = flat list (1 = indexed by wStageCollisionState)
    db $32,$3F,$37,$3C,$34,$31,$3E,$36,$3B,$3D
    db $FF
RedStageBumpersCollisionData:
    db $06, $0B                       ; AABB half-extents |dx| < 6, |dy| < 11
    db $06, $30, $66                  ; object id, centre x, centre y (stage px)
    db $07, $6F, $66
    db $FF
```
Logic:
```lua
-- called once per group per frame; only ONE object can trigger per frame
if triggered == NONE and not out[bit7] then
  ok = carryIn_skipList or (ballColliding and contains(attrList, curCollisionAttribute))
  if ok then for i,o in ipairs(objs) do
      if abs(o.x - bx) < hx and abs(o.y - by) < hy then triggered = o.id; idx=i; break end
  end end
  out = 0
  if triggered and triggered ~= previousTriggered then out = {idx, id} end  -- edge-triggered
end
previousTriggered = triggered  (saved after all groups, :1-7)
```
- **Physical objects** (bumpers, slingshots, Voltorbs, Digletts, Staryu, wild mon) use attribute list + AABB: the ball must be *touching mask pixels with one of those attributes* and be inside the AABB of a specific instance (which tells you which one).
- **Rollovers/triggers/holes** (spinner, CAVE lights, lane triggers, launch alley, Bellsprout mouth, slots) pass `scf` and are **AABB only**. They have no wall; the ball passes through.
- `PinballCollidesWithPoints` (:140-169): point list, hit when `(p - ball)` is in [-24,-1] on both axes (`cp $e8`), i.e. ball in [p+1, p+24]: a 24x24 box whose top-left is the point. Used for evolution trinkets.
- Moving/animated objects in bonus stages use per-object **32x32 circle-normal tables**. `circle_collision_angles.bin` (1024 B = 32x32): value with bit7 set = no hit, else `normal = value*2`. The disc is centred at (16,16), radius ~16.5 (sprite radius + ball). Normal = outward radial (fit error ~1.5/256). Regenerate: `if d<=16.5 then n = atan2angle(x-16, y-16) // 2 else $80`. gengar/haunter/meowth `_collision_angles.bin` are the same idea per animation frame (gengar_bonus_object_collision.asm:213-249 sets `wCollisionNormalAngle` and `wIsBallColliding=1` directly).
- Scoring: `ld bc, FiveHundredPoints / callba AddBigBCD6FromQueueWithBallMultiplier` (score.asm:62+). That is a queued 6-byte BCD add, times `wBallType` (min 1).

### 2.3 Resolve step = per-object callbacks
`ResolveRedFieldBottomGameObjectCollisions` (red_stage_resolve_collision.asm:24-47) is a flat list of `Resolve*`/`Update*` calls. Each reads its `wWhichX` output byte, clears it, and does the effect + anims + timers. Then `CheckSpecialModeColision` notifies the current mode (catch'em, evolution).

### 2.4 Bounce strengths (concrete)
| Object | Detection | Response | Score | Ref |
|---|---|---|---|---|
| Wall | mask | `vy = -vy/4` (amp 0) | - | home.asm:2557-2585 |
| **Voltorb (round pop bumper, top)** | attrs $E0-$F5, AABB 14x14 | **fixed kick 2.0 px/frame along mask normal**: `wFlipperYForce=$0200`, `wFlipperCollision=$80`, plus the 1/4 bounce; rumble; anim 16 f | 500 | red_stage_resolve_collision.asm:556-599 |
| **"Bumpers" = slingshots above flippers** (ids 6,7 at (48,102),(111,102)) | attrs list, AABB 6x11 | **kick 2.0 px/frame** along normal **rotated -8 (left) / +8 (right) units (11.25 deg)** `BumperCollisionAngleDeltas_RedField: db -8, 8`; light 16 f | (none here) | :1631-1712 |
| Diglett side kickers / Poliwag, Psyduck | attrs + AABB | no fixed kick; **amp=2, restitution 1/2** | 500 | :460-470; blue :1805-1816 |
| Flipper | tables | restitution 3/8 + lever impulse (1.5) | - | flippers.asm |
| Spinner | AABB 8x4 only | no physics. `spinnerVel = ballVy` at contact. Each frame `vel -> 0` by 7/256; `state += vel`, wraps every **$18 (24.0)** units = 1 turn, +10 pts + Pikachu charge per turn | 10/turn | :601-702 |
| Rollover lights (CAVE), lane triggers | AABB only | none (flags/lights) | varies | :744+, :1251+ |

The kick trick: bumpers reuse the flipper path. Setting `wFlipperCollision != 0` makes the main loop subtract `wFlipperYForce` in the rotated frame (pinball_game.asm:111-125). So **every "active" object is just a fixed impulse along the contact normal, optionally rotated**.

### 2.5 Capture holes / kickers (ball lock and eject)
Common pattern (Bellsprout :1523-1611, Ditto slot :1715-1795, Slot cave :1937-2036, Pikachu kickback :2314-2496):
```lua
on trigger:
  vel = 0; spin = 0
  ball.x, ball.y = HOLE_X, HOLE_Y           -- snap (Bellsprout $7C,$78; slot $50,$16; Ditto $11,$23)
  enableGravity = false                     -- freeze
  counter = N                               -- e.g. slot $13 = 19, Ditto $10 = 16 ticks (+ anim)
each frame: counter -= 1; at chosen counts: shrink ball gfx, hide ball, run logic (slot/mode), show ball
on 0: enableGravity = true; vy = +2.0 (slot/Ditto/Bellsprout: `wBallYVelocity+1 = 2`), slot also vx = +0.5 ($80)
```
- **Pikachu outlane kickback**: AABB 3x5 at (14,124)/(146,124). Only fires on the side chosen by the last flipper pressed (`SetPikachuSaverSide`) and when charge is full. Freezes the ball for the ~90-frame animation, then `vy = $FC00 = -4.0 px/frame`, +5000.
- **Slot "force field"** (attractor into the open cave), `_ApplySlotForceField_RedField` (:1797-1935): adds a vector from `ball_physics_f0000.bin` to the velocity each frame. **Layout: 48x48 cells x 4 bytes (dx,dy little-endian 8.8), index `y*192 + x*4`**, box = ball (x-$38, y-$FE) on the bottom screen. Analysis: purely radial **toward (24,24)**. Magnitude fits **F(r) ~= 0.42*r^4 / (1 + (r/8)^8)** /256 px/f^2 (peak ~3.4 px/f^2 at r~8, about 0 at the centre, falls off ~r^-4; log-fit error 0.0009). Rumble if |F| >= 2.
- `ball_physics_e4000.bin` (32x32x4) = radial *repulsor* field around Mewtwo's orbiting balls, same mechanism (mewtwo_bonus_object_collision.asm:69-117). `ball_physics_ec000.bin` = other blue-stage fields.

---

## 3. Launch, drain, ball saver

### 3.1 Ball init (engine/pinball_game/ball_init/*)
`InitBallForStage` (ball_init.asm:1-37): zero velocity, flipper states, spin. Set visible and gravity on, `wSCX=$20` (camera starts scrolled right). Per table: `InitBallRedField` (ball_init_red_field.asm:1-20) puts the ball at **($A7.00, $98.00) = (167,152)** in the plunger lane, **gravity off**. If `wLostBall`, per-ball progress is reset (spinner, CAVE lights, multipliers...).

### 3.2 Plunger: there isn't one (fixed launch)
`ResolveRedStagePinballLaunchCollision` (red_stage_resolve_collision.asm:2207-2254), launch-alley AABB 8x8 at ($A8,$98):
```asm
    ld a, $80
    ld [wBallYVelocity], a
    ld a, $fa
    ld [wBallYVelocity + 1], a   ; vy = $FA80 = -5.5 px/frame, vx = 0
    ld a, $1
    ld [wEnableBallGravityAndTilt], a
...
    ld a, $ff
    ld [wPreviousTriggeredGameObject], a  ; re-arm so it triggers every frame while resting
```
Waits until `wKeyConfigBallStart` is pressed (`wPinballLaunched=1`). On the first ball the initial map roulette spins first. **Constant -5.5 px/frame shot, no charge.** While in the lane the camera scrolls (`ScrollScreenToShowPinball`, vertical_screen_transition.asm:150-175: SCX +/-2 per frame toward 0..$22 depending on ballX >= $9A).

### 3.3 Screen transitions and drain (vertical_screen_transition.asm:63-111)
```asm
CheckStageTransition:
    ld a, [wBallYPos + 1]
    add $10
    cp $18
    jr c, .moving_up        ; y < 8   -> go to upper stage (y += $88)
    cp $b8
    ret c                   ; y < 168 -> nothing
    ... BallMovingDownStageTransitions[stage]; $FF -> .youLose
    ; else switch to lower stage, y -= $88 (136)
```
The table is split into stacked "stages" (screens) that overlap 192-136 = 56 px. **Drain = ball y >= 168 on a stage that has no stage below** (bottom screens and bonus stages). Then `wMoveToNextScreenState=1` and `HandleBallLoss`.

### 3.4 Ball saver
- Timers `wBallSaverTimerSeconds` / `wBallSaverTimerFrames` (60 frames per second). Started by `Start20/30/60/90SecondSaverTimer` (ball_saver/*.asm: frames=59, seconds=N, `wNumTimesBallSavedTextWillDisplay = 2`). A **20 s saver starts at game start and after every lost ball** (`InitRedField`, `HandleBallLossRedField`). 30/60/90 are slot rewards.
- Tick (`UpdateBallSaverState`, red_stage_resolve_collision.asm:54-106): **paused while ballX >= 154 (plunger lane)**. Icon flashing by remaining seconds: >=11 solid, 6-10 `&$10`, 2-5 `&$04`, <2 off.
- On drain (`HandleBallLossRedField`, ball_loss_red_field.asm:1-24): if the timer is non-zero, show "BALL SAVED", decrement the save count, and when it hits 0 force the timer to 1s/1f (so expire). `wLostBall` stays 0, so the screen state goes EndBall -> StartBall and the ball is **re-served at the plunger** without resetting progress. Otherwise: lose ball, start the new 20 s saver, use an extra ball or the next life (`wNumBallLives = 3`) or game over.

---

## 4. Per-frame main loop (engine/pinball_game.asm:69-176, `GameScreenFunction_HandleBallPhysics`)
Screen state machine (pinball_game.asm:1-9): `LoadGFX -> StartBall -> HandleBallPhysics (loop) -> HandleBallLoss -> EndBall -> (StartBall | bonus | high scores)`.

```
1  wFlipperCollision = 0; wCollisionForceAmplification = 0
2  ApplyGravityToBall           vy += 11/256
3  LimitBallVelocity            clamp hi bytes to +-7
4  wIsBallColliding = 0
5  HandleTilts                  input: tilt buttons nudge ball 1px + screen shake (home/tilt.asm)
6  if bottom stage: HandleFlippers   input -> flipper state -> swept table lookup -> impulse
7  CheckStageCollision          16-pt mask test: normal, push-out, curCollisionAttribute
     (if flipper hit, its normal overrides the mask normal: pinball_game.asm:82-90)
8  CheckGameObjectCollisions    per-stage list of group checks -> wWhichX bytes
9  ResolveGameObjectCollisions  per-stage list of callbacks: score, anims, kicks (set YForce),
                                captures, force fields, timers, ball saver tick
10 menu key -> pause menu
11 if wIsBallColliding:
      ApplyTiltForces           (tilt only acts while touching something; table by normal angle)
      v = Rotate(v, normal)
      ApplyCollisionForces      restitution 1/4 (+amp*1/8), spin
      if wFlipperCollision: vy_rot -= wFlipperYForce
      v = Rotate(v, -normal)
12 MoveBallPosition             pos += clamp(v, +-4.996)
13 CheckStageTransition         camera scroll, stage swap, drain -> HandleBallLoss
14 DrawSpritesForStage, bottom text, HUD (score, balls, party icon, saver icon)
15 DecrementTimer (mode timer)
16 if wMoveToNextScreenState: next screen state
```
Notes: collision uses the position from *last* frame's move (detect then resolve, then move), so collision response is applied one step later. Velocity is clamped before collision, so a flipper kick can reach ~12 px/f for one frame of movement (capped to 4.996 px by MoveBallPosition) and is clamped to 7.99 on the next frame.

---

## 5. Stage data architecture (data-driven tables)
Every per-stage operation is a **jump table indexed by `wCurrentStage`** (16 slots, top/bottom pairs, bonus stages duplicated):
| Hook | Table | File |
|---|---|---|
| Init game-wide vars for the table (score, lives, saver) | `CallTable_8348` -> `InitRedField`... | stage_init/init_stages.asm:1-40, init_red_field.asm |
| Ball spawn | `InitBall_CallTable` | ball_init/ball_init.asm:24-40 |
| Collision map + masks | `StageCollisionAttributesPointers` -> `{flag, (mapPtr,bank), (masksPtr,bank)}`, flag=1 means a list of variants indexed by `wStageCollisionState` (Red top has 8 variants for opened/closed structures) | stage_collision_attributes.asm:1-130 |
| Gfx + object gfx refresh | `LoadStageData` -> `_LoadStageData` table -> `_LoadStageDataRedFieldBottom` (list of Load* calls) | vertical_screen_transition.asm:35-61; load_stage_data/*.asm |
| Object detection | `GameObjectCollisions_CallTable` -> list of `Check*Collision` (each = data pointers into game_objects/*.asm) | object_collision/object_collision.asm:9-26, red_stage_object_collision.asm |
| Object behaviour | `CallTable_2822` -> list of `Resolve*` | object_collision.asm:171-190 |
| Ball loss | `CallTable_dc4d` | ball_loss/ball_loss.asm |
| Stage links | `BallMovingUp/DownStageTransitions` ($FF = none/drain) | vertical_screen_transition.asm:113-147 |
| Sprites | `DrawSpritesForStage` table | draw_sprites/* |

Bottom-screen object checks are further split by ball y (`cp $56`: upper vs lower half, red_stage_object_collision.asm:10-24) for speed.

Suggested Lua shape:
```lua
Stage = {
  map = {...32x24 attr bytes...}, masks = {...attr -> 8 row bytes or function(x,y)...},
  variants = {...},                  -- collision states (gates open/closed)
  links = {up=nil, down="bottom"},
  spawn = {x=167, y=152, gravity=false},
  groups = {                         -- detection data
    {attrs={0x32,...}, hx=6, hy=11, objs={{id=6,x=48,y=102},{id=7,x=111,y=102}}, out="bumper"},
    {attrs=nil, hx=8, hy=4, objs={{id=9,x=144,y=108}}, out="spinner"},
  },
  resolve = { bumper=function(g,o) kick(2.0, o.id==6 and -8 or 8); score(...) end, ... },
  update  = { function() spinner_update() end, ballsaver_update, ... },
}
```

---

## Quick constant sheet
- gravity 11/256 px/f^2; vel clamp |hi| <= 7; step clamp 4.996 px/f; ball r = 4
- flipper: 16 states, +/-3.2 states/f (~5 f full stroke), ~3.83 deg/state, 26.5 deg down to 31 deg up; pivot stage (54,140), mirrored about x = 80 (right pivot 106); box x 43..90, y 123..154 (48x32)
- flipper impulse = min(15.5r, 252)/256 * 12.8 px/f when rising; restitution 3/8
- wall restitution 1/4; amp-2 objects 1/2; bumpers/slings +2.0 px/f along normal (slings rotated +/-11.25 deg)
- launch vy = -5.5 px/f fixed; kickback vy = -4.0; hole eject vy = +2.0 (slot also vx = +0.5)
- drain y >= 168 on bottom screen; screens overlap with 136 px shift
- saver 20 s default (pauses in plunger lane), up to 2 saves per window
