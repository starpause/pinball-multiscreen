-- title:   Fairy Ring Pinball
-- author:  jordan + claude
-- desc:    two-screen pinball; engine modeled on Pokemon Pinball (GBC)
-- script:  lua

-- How it works (see ENGINE_NOTES.md for the long version):
--  * The table is a per-pixel COLLISION MAP (cmap), one attribute byte per
--    pixel. It is painted at boot with TIC-80 primitives, read back with
--    pix(), so what you draw is exactly what the ball collides with.
--  * The ball is tested at 16 points on a radius-4 ring. The longest run of
--    touching points gives the surface normal and a push-out distance.
--  * Bounce: rotate velocity into the normal's frame, keep the tangent,
--    keep 1/4 (walls), 3/8 (flippers) or 1/2 (rubber) of the normal speed,
--    then add any kicker force. One physics step per frame, movement clamped
--    to 5 px/frame per axis so the ring cannot skip over a wall.
--  * Flippers are 16 discrete states. Collision checks every state between
--    last frame's and this frame's (a swept test), and the kick scales with
--    distance from the pivot.
--  * Two screens. Each screen's static art is baked once into map RAM
--    (exactly two 240x136 screens fit) and memcpy'd back every frame.

-- ============================ constants ============================
local GRAV    = 11/256   -- px/frame^2 (Pokemon Pinball: +$000B per frame)
local VMAX    = 7.99     -- per-axis velocity clamp
local STEPMAX = 4.996    -- per-axis movement clamp ($04FF)
local BR      = 4        -- ball radius = ring probe radius
local WW, WH  = 176, 256 -- world (playfield + plunger lane)
local VIEWS   = {0, 120} -- world y at the top of each screen
local SNAP    = 0x8000   -- map RAM: two 16320-byte screen snapshots
local SCRBYTES = 16320

-- FAIRY NIGHT palette indices (the palette ships in the sprite sheet)
local C_KEY, C_OUT, C_FLOOR, C_FLOORL = 0, 1, 2, 3
local C_MOSSD, C_MOSS, C_LEAF, C_LIME = 4, 5, 6, 7
local C_BARKD, C_BARK, C_RED, C_PINK = 8, 9, 10, 11
local C_GOLD, C_CYAN, C_LILAC, C_WHITE = 12, 13, 14, 15

-- collision attributes (one per pixel in the cmap; also the paint colour)
local EMPTY, WALL, SLING, BUMPER, TARGET, GATE, POST = 0, 1, 2, 3, 4, 5, 6

-- restitution "amp" per attribute: keep (1/4 + amp/8) of the normal speed
local AMP = {[WALL]=0, [SLING]=0, [BUMPER]=0, [TARGET]=2, [GATE]=0, [POST]=2}

-- ============================ input ============================
-- Left flipper: Left / Z    Right flipper: Right / X
-- Plunger: hold Down or A, release to launch.   Nudge: Up
local vpad = nil -- test harness can replace this with a table of booleans
local function pad(i)
  if vpad then return vpad[i] or false end
  return btn(i)
end
local function leftHeld()  return pad(2) or pad(4) end
local function rightHeld() return pad(3) or pad(5) end
local function plungeHeld() return pad(1) or pad(6) end

-- ============================ collision map ============================
local cmap = {}
local OY = 0 -- world->screen y offset while painting

local function prect(x, y, w, h, a) rect(x, y - OY, w, h, a) end
local function pcirc(x, y, r, a) circ(x, y - OY, r, a) end
local function ptri(x1, y1, x2, y2, x3, y3, a)
  tri(x1, y1 - OY, x2, y2 - OY, x3, y3 - OY, a)
end
local function ppoly(pts, a) -- convex polygon as a triangle fan
  local n = #pts // 2
  for i = 2, n - 1 do
    ptri(pts[1], pts[2], pts[i*2-1], pts[i*2], pts[i*2+1], pts[i*2+2], a)
  end
end
local function pcap(x1, y1, x2, y2, r, a) -- thick segment with round ends
  local dx, dy = x2 - x1, y2 - y1
  local l = math.sqrt(dx*dx + dy*dy)
  local nx, ny = -dy / l * r, dx / l * r
  ptri(x1+nx, y1+ny, x2+nx, y2+ny, x2-nx, y2-ny, a)
  ptri(x1+nx, y1+ny, x2-nx, y2-ny, x1-nx, y1-ny, a)
  pcirc(x1, y1, r, a) pcirc(x2, y2, r, a)
end

-- ---------------- table layout (world coords, 176 x 256) ----------------
-- Object lists double as physics data and draw data.
local bumpers = {
  {x=62, y=60, r=6, spr=0, flash=0, cool=0},
  {x=98, y=56, r=6, spr=2, flash=0, cool=0},
  {x=80, y=82, r=6, spr=4, flash=0, cool=0},
}
local targets = { -- toadstool standups (bottom screen)
  {x=56, y=150, r=5, lit=false},
  {x=80, y=144, r=5, lit=false},
  {x=104, y=150, r=5, lit=false},
}
local slings = {
  {ax=34, ay=170, bx=34, by=196, cx=48, cy=206, rot=-11.25, cool=0, flash=0},
  {ax=126, ay=170, bx=126, by=196, cx=112, cy=206, rot=11.25, cool=0, flash=0},
}
local lanes = { -- top rollovers, AABB sensors
  {x=72, y=30, lit=false, inside=false},
  {x=88, y=30, lit=false, inside=false},
  {x=104, y=30, lit=false, inside=false},
}
local hole = {x=128, y=100, r=4, inside=false, count=0} -- the fairy ring
local kickbacks = {
  {x=10.5, y=234, lit=true, inside=false},
  {x=149.5, y=234, lit=false, inside=false},
}

local function paint_table()
  prect(0, 0, WW, WH, WALL)                 -- everything solid ...
  pcirc(88, 84, 82, EMPTY)                  -- ... carve the dome
  prect(6, 84, 148, WH - 84, EMPTY)         -- ... the playfield
  prect(160, 60, 10, WH - 60, EMPTY)        -- ... the plunger lane
  prect(160, 251, 10, 5, WALL)              -- lane floor (ball rests here)
  prect(154, 76, 6, WH - 76, WALL)          -- lane divider
  pcirc(156.5, 76, 3, WALL)                 -- rounded divider top
  prect(154, 36, 2, 40, GATE)               -- one-way gate out of the lane

  -- top rollover lane posts (rubber)
  for _, x in ipairs({64, 80, 96, 112}) do pcap(x, 22, x, 34, 2, POST) end
  -- mushroom bumpers
  for _, b in ipairs(bumpers) do pcirc(b.x, b.y, b.r, BUMPER) end

  -- bottom: inlane/outlane rails, aprons that feed the flippers
  pcap(17.5, 160, 17.5, 256, 2, WALL)
  pcap(142.5, 160, 142.5, 256, 2, WALL)
  -- the apron's top edge is flush with the resting flipper's top surface
  -- (26.5 deg, tangent to the hub), so the ball rolls straight onto it
  ppoly({20,205.4, 52,221.4, 52,256, 20,256}, WALL)
  ppoly({140,205.4, 140,256, 108,256, 108,221.4}, WALL)
  -- slingshots: solid triangle, kicking face on the playfield side
  for _, s in ipairs(slings) do
    ptri(s.ax, s.ay, s.bx, s.by, s.cx, s.cy, WALL)
    pcap(s.ax, s.ay, s.cx, s.cy, 1.5, SLING)
  end
  -- toadstool targets
  for _, t in ipairs(targets) do pcirc(t.x, t.y, t.r, TARGET) end
end

local function build_cmap()
  for i = 0, WW * WH - 1 do cmap[i] = WALL end
  for slice = 0, 1 do
    OY = slice * 136
    cls(0)
    paint_table()
    local rows = math.min(136, WH - OY)
    for y = 0, rows - 1 do
      local base = (y + OY) * WW
      for x = 0, WW - 1 do cmap[base + x] = pix(x, y) end
    end
  end
  OY = 0
end

-- ============================ ball + ring probe ============================
local ball = {x=164.5, y=246.5, vx=0, vy=0, grav=false,
              px=164.5, py=246.5, spin=0, rot=0}

-- 16 probe points, clockwise from "right" (Pokemon Pinball's exact offsets)
local RING = {
  {4,0},{4,1},{3,3},{1,4},{0,4},{-1,4},{-3,3},{-4,1},
  {-4,0},{-4,-1},{-3,-3},{-1,-4},{0,-4},{1,-4},{3,-3},{4,-1},
}
local RANG = {}
for i, p in ipairs(RING) do
  local a = math.atan(p[2], p[1])
  if a < 0 then a = a + 2*math.pi end
  RANG[i-1] = a
end

-- normal + push-out for every (first, last) touching point = the
-- collision_deltas tables, regenerated from their formula
local RUN = {}
for s = 0, 15 do
  for e = 0, 15 do
    local a0, a1 = RANG[s], RANG[e]
    if a1 < a0 then a1 = a1 + 2*math.pi end
    local mid, half = (a0 + a1) / 2, (a1 - a0) / 2
    RUN[s*16+e] = {-math.cos(mid), -math.sin(mid), 1 + 4*(1 - math.cos(half))}
  end
end

local function attr_at(x, y)
  local ix, iy = x // 1, y // 1
  if ix < 0 or ix >= WW or iy < 0 then return WALL end
  if iy >= WH then return EMPTY end -- open below: the drain
  local a = cmap[iy * WW + ix]
  if a == GATE and ball.vx <= 0 then return EMPTY end -- one-way
  return a
end

local hits = {}
-- returns hit, nx, ny, push, attr (attr of the first touching point)
local function ring_test(bx, by)
  local any, all = false, true
  for i = 0, 15 do
    local p = RING[i+1]
    local a = attr_at(bx + p[1], by + p[2])
    hits[i] = a
    if a ~= EMPTY then any = true else all = false end
  end
  if not any then return false end
  if all then return true, 0, 0, 0, hits[0], true end
  local best, bs = 0, 0
  for i = 0, 15 do
    if hits[i] ~= EMPTY and hits[(i-1)%16] == EMPTY then
      local n = 0
      while n < 16 and hits[(i+n)%16] ~= EMPTY do n = n + 1 end
      if n > best then best, bs = n, i end
    end
  end
  local r = RUN[bs*16 + (bs+best-1)%16]
  return true, r[1], r[2], r[3], hits[bs]
end

-- ============================ flippers ============================
-- 16 states; state changes 3.2/frame (0x333) so a full stroke is ~5 frames.
-- Angle: 26.5 deg below horizontal (state 0) to ~31 deg above (state 15).
local FL_PIVOT_Y = 228
local FL_LEN, FL_RH, FL_RT = 19, 5, 3  -- length, hub radius, tip radius (= sprite)
local flippers = {
  {px=54, dir=1,  s=0, ds=0, prev=0, held=false},
  {px=106, dir=-1, s=0, ds=0, prev=0, held=false},
}
local FCOS, FSIN = {}, {}
for s = 0, 15 do
  local th = math.rad(26.5 - 3.83 * s)
  FCOS[s], FSIN[s] = math.cos(th), math.sin(th)
end

local function flipper_update(f, held)
  f.prev = f.s // 1
  local ch = held and 0x333/256 or -0x333/256
  if (f.prev == 0 and ch < 0) or (f.prev == 15 and ch > 0) then ch = 0 end
  f.s = math.max(0, math.min(15, f.s + ch))
  f.ds = ch
  if held and not f.held then sfx(0, 40, 6, 0, 8) end
  f.held = held
end

-- Test the ball against one flipper state, in left-flipper space
-- (dx = distance right of pivot, mirrored for the right flipper).
-- Returns nx, ny (left space), push, radius-from-pivot  or nil.
local function flipper_state_hit(dx, dy, s)
  local ux, uy = FCOS[s], FSIN[s]
  local nux, nuy = uy, -ux                 -- "up" side normal
  local t = dx*ux + dy*uy
  local d = math.sqrt(dx*dx + dy*dy)
  if t < 0 then                            -- behind the pivot: round hub
    if d < FL_RH + BR and d > 0.01 then
      return dx/d, dy/d, FL_RH + BR - d, d
    end
  elseif t > FL_LEN then                   -- beyond the tip: round tip
    local tx, ty = dx - ux*FL_LEN, dy - uy*FL_LEN
    local dt = math.sqrt(tx*tx + ty*ty)
    if dt < FL_RT + BR and dt > 0.01 then
      return tx/dt, ty/dt, FL_RT + BR - dt, d
    end
  else                                     -- body: push out of the top
    local lim = FL_RH + (FL_RT - FL_RH) * t / FL_LEN + BR
    local h = dx*nux + dy*nuy
    if h < lim and h > -(lim + 6) then
      return nux, nuy, lim - h, d
    end
  end
end

-- swept test from last frame's state to this frame's; first hit wins
local function flipper_collide(f)
  local dx = (ball.x - f.px) * f.dir
  local dy = ball.y - FL_PIVOT_Y
  if dx < -12 or dx > 30 or dy < -24 or dy > 18 then return false end
  local s, e = f.prev, f.s // 1
  local step = e >= s and 1 or -1
  for st = s, e, step do
    local nx, ny, push, r = flipper_state_hit(dx, dy, st)
    if nx then
      local force = 0
      if f.ds > 0 then force = math.min(15.5 * r, 252) / 256 * f.ds * 4 end
      return true, nx * f.dir, ny, push, force
    end
  end
  return false
end

-- ============================ game state ============================
local state = "title" -- title | plunge | play | hold | drain | over
local view = 2
local score, balls, mult = 0, 3, 1
local charge, plungeWas = 0, false
local saver = 0
local holdT, holdKind = 0, nil
local drainT = 0
local msg, msgT = "", 0
local shake, nudgeCool = 0, 0
local frame = 0
local lastNx, lastNy, touching = 0, 0, false

-- sparkle particles (sprite tiles 4-7) and the fairy mascot
local parts = {}
local function sparkle(x, y, n)
  for _ = 1, n or 4 do
    parts[#parts + 1] = {x = x, y = y, vx = (math.random() - 0.5) * 2,
      vy = (math.random() - 0.5) * 2 - 0.5, t = 16 + math.random(0, 8)}
  end
end
local fairy = {x = 120, y = 90, tx = 120, ty = 90}

local function say(m, t) msg, msgT = m, t or 120 end
local function add(p) score = score + p * mult end

local function serve()
  ball.x, ball.y, ball.vx, ball.vy = 164.5, 246.5, 0, 0
  ball.grav, ball.spin = false, 0
  charge, plungeWas = 0, false
  state, view = "plunge", 2
end

local function new_game()
  score, balls, mult = 0, 3, 1
  for _, t in ipairs(targets) do t.lit = false end
  for _, l in ipairs(lanes) do l.lit = false end
  kickbacks[1].lit, kickbacks[2].lit = true, false
  hole.count = 0
  saver = 0
  serve()
end

local function capture(x, y, frames, kind)
  ball.x, ball.y, ball.vx, ball.vy = x, y, 0, 0
  ball.grav = false
  holdT, holdKind, state = frames, kind, "hold"
end

-- ============================ objects ============================
local function nearest(list)
  local best, bd = nil, 1e9
  for _, o in ipairs(list) do
    local d = (o.x - ball.x)^2 + (o.y - ball.y)^2
    if d < bd then best, bd = o, d end
  end
  return best
end

local function rotate(nx, ny, deg)
  local a = math.rad(deg)
  local c, s = math.cos(a), math.sin(a)
  return nx*c - ny*s, nx*s + ny*c
end

-- Sensors: no physics, edge-triggered (fire once on entry)
local function sensors()
  for i, l in ipairs(lanes) do
    local inside = math.abs(ball.x - l.x) < 5 and math.abs(ball.y - l.y) < 4
    if inside and not l.inside then
      add(250)
      if not l.lit then l.lit = true sparkle(l.x, l.y - 6, 4) end
      if lanes[1].lit and lanes[2].lit and lanes[3].lit then
        for _, m in ipairs(lanes) do m.lit = false end
        mult = math.min(5, mult + 1)
        add(2500)
        say("MULTIPLIER x" .. mult)
      end
    end
    l.inside = inside
  end
  local d = math.sqrt((ball.x - hole.x)^2 + (ball.y - hole.y)^2)
  if d < hole.r and not hole.inside then
    hole.inside = true -- re-armed once the ejected ball is clear
    hole.count = hole.count + 1
    add(5000 * hole.count)
    say(hole.count % 3 == 0 and "FAIRY RING!!" or "FAIRY RING " .. hole.count)
    if hole.count % 3 == 0 then add(50000) kickbacks[1].lit, kickbacks[2].lit = true, true end
    sparkle(hole.x, hole.y, 10)
    capture(hole.x, hole.y, 70, "hole")
  end
  if d > hole.r + 4 then hole.inside = false end
  for _, k in ipairs(kickbacks) do
    local inside = math.abs(ball.x - k.x) < 5 and math.abs(ball.y - k.y) < 5
    if inside and not k.inside and k.lit and ball.vy > 0 then
      k.lit = false
      add(1000)
      say("KICKBACK!")
      capture(k.x, k.y, 20, "kick")
    end
    k.inside = inside
  end
end

-- Physical objects: react to the attribute the ring touched.
-- Returns the kick force and restitution amp for the bounce.
local function object_hit(attr, nx, ny)
  if attr == BUMPER then
    local b = nearest(bumpers)
    if b.cool <= 0 then
      b.cool, b.flash = 6, 8
      add(100)
      sparkle(ball.x - nx * BR, ball.y - ny * BR, 3)
      sfx(1, 36, 6, 2, 12)
      return 2.0, 0, nx, ny -- fixed kick along the normal
    end
  elseif attr == SLING then
    local s = ball.x < 80 and slings[1] or slings[2]
    if s.cool <= 0 then
      s.cool, s.flash = 8, 6
      add(10)
      sfx(1, 30, 6, 2, 10)
      local rx, ry = rotate(nx, ny, s.rot) -- tilt the kick 11.25 deg up
      return 2.0, 0, rx, ry
    end
  elseif attr == TARGET then
    local t = nearest(targets)
    if not t.lit then
      t.lit = true
      add(500)
      sparkle(t.x, t.y - 4, 5)
      sfx(1, 52, 8, 1, 10)
      if targets[1].lit and targets[2].lit and targets[3].lit then
        for _, u in ipairs(targets) do u.lit = false end
        kickbacks[1].lit, kickbacks[2].lit = true, true
        add(5000)
        say("KICKBACKS LIT")
      end
    end
  end
  return 0, AMP[attr] or 0, nx, ny
end

-- ============================ physics frame ============================
-- Order follows Pokemon Pinball's HandleBallPhysics.
local function physics()
  local lh, rh = leftHeld(), rightHeld()
  flipper_update(flippers[1], lh)
  flipper_update(flippers[2], rh)
  if state == "hold" then return end

  -- 1. gravity, velocity clamp
  if ball.grav then ball.vy = ball.vy + GRAV end
  ball.vx = math.max(-VMAX, math.min(VMAX, ball.vx))
  ball.vy = math.max(-VMAX, math.min(VMAX, ball.vy))

  -- 2. stage collision (ring), push out
  local hit, nx, ny, push, attr, buried = ring_test(ball.x, ball.y)
  if buried then -- fully inside a wall: step back to last good spot
    ball.x, ball.y = ball.px, ball.py
    ball.vx, ball.vy = -ball.vx * 0.5, -ball.vy * 0.5
    hit = false
  elseif hit then
    ball.x, ball.y = ball.x + nx*push, ball.y + ny*push
  end

  -- 3. flippers override the stage normal
  local kick, amp = 0, 0
  for _, f in ipairs(flippers) do
    local fh, fnx, fny, fpush, force = flipper_collide(f)
    if fh then
      hit, nx, ny, attr = true, fnx, fny, WALL
      ball.x, ball.y = ball.x + fnx*fpush, ball.y + fny*fpush
      kick, amp = force, 1
      break
    end
  end

  -- 4. objects
  if hit and attr ~= WALL then kick, amp, nx, ny = object_hit(attr, nx, ny) end
  touching, lastNx, lastNy = hit, nx, ny

  -- 5. bounce in the normal's frame
  if hit then
    local tx, ty = -ny, nx
    local vn = ball.vx*nx + ball.vy*ny
    local vt = ball.vx*tx + ball.vy*ty
    if vn < 0 then vn = -vn * (0.25 + 0.125*amp) end
    vn = vn + kick
    ball.vx, ball.vy = vt*tx + vn*nx, vt*ty + vn*ny
    ball.spin = math.max(-127, math.min(127, (vt * 4) // 1))
  end

  -- 6. move (clamped step: the ring can never skip a 5px+ wall)
  ball.px, ball.py = ball.x, ball.y
  ball.x = ball.x + math.max(-STEPMAX, math.min(STEPMAX, ball.vx))
  ball.y = ball.y + math.max(-STEPMAX, math.min(STEPMAX, ball.vy))
  ball.rot = (ball.rot + ball.spin) % 256

  sensors()
end

-- ============================ game flow ============================
local function update()
  frame = frame + 1
  if msgT > 0 then msgT = msgT - 1 end
  if shake > 0 then shake = shake - 1 end
  if nudgeCool > 0 then nudgeCool = nudgeCool - 1 end
  for _, b in ipairs(bumpers) do b.cool, b.flash = b.cool - 1, b.flash - 1 end
  for _, s in ipairs(slings) do s.cool, s.flash = s.cool - 1, s.flash - 1 end

  if state == "title" or state == "over" then
    if (btnp(4) or btnp(5)) and not vpad then new_game() end
    return
  end

  if state == "plunge" then
    local held = plungeHeld()
    if held then charge = math.min(1, charge + 1/40) end
    if plungeWas and not held then
      ball.vy = -(3.6 + 1.9 * charge) -- full charge = -5.5, Pokemon's launch
      ball.grav = true
      state = "play"
      sfx(1, 24, 10, 2, 12)
    end
    plungeWas = held
  elseif state == "hold" then
    holdT = holdT - 1
    if holdT <= 0 then
      ball.grav, state = true, "play"
      if holdKind == "hole" then ball.vx, ball.vy = -1.2, 1.8
      else ball.vx, ball.vy = 0, -4.0 end -- kickback
    end
  elseif state == "play" then
    -- nudge: only does anything while touching (projected on the normal)
    if pad(0) and nudgeCool == 0 then
      nudgeCool, shake = 30, 6
      if touching then
        local f = 0*lastNx + -2*lastNy
        if f > 0 then ball.vx, ball.vy = ball.vx + f*lastNx, ball.vy + f*lastNy end
      end
    end
    if saver > 0 and ball.x < 154 then saver = saver - 1 end
    -- weak launch fell back into the lane
    if ball.x > 160 and ball.y > 240 and math.abs(ball.vy) < 0.3 then serve() end
    if ball.y > WH + 6 then
      if saver > 0 then
        say("BALL SAVED")
        saver = -1
        serve()
      else
        state, drainT = "drain", 60
        sfx(1, 12, 30, 2, 12)
      end
    end
  elseif state == "drain" then
    drainT = drainT - 1
    if drainT <= 0 then
      balls = balls - 1
      mult = 1
      if balls > 0 then serve() saver = 0 else state = "over" end
    end
  end
end

-- the ball saver starts when a freshly served ball first reaches the table
local function arm_saver()
  if state == "play" and saver == 0 and ball.x < 154 then saver = 15 * 60 end
end

-- ============================ baking the screens ============================
-- Static art is rendered ONCE per screen from the sprite sheet:
--   walls  = bark texture (tile 66, 16x16) with a moss rim (tile 16 rows 0-3)
--   floor  = forest floor texture (tile 64) with a contact shadow (rows 4-5)
--   slings / posts / gate = their own 8x8 texture tiles
-- Repaint those tiles in the sprite editor and the whole table restyles.
local T_RIM, T_SLING, T_POST, T_GATE, T_FLOOR, T_BARK = 16, 17, 18, 19, 64, 66

local function sget(id, x, y) -- read a pixel from the sprite sheet
  return peek4(0x8000 + id * 64 + y * 8 + x)
end
local function tex16(id, x, y) -- sample a 16x16 texture made of 4 tiles
  local tx, ty = x % 16, y % 16
  return sget(id + (tx // 8) + (ty // 8) * 16, tx % 8, ty % 8)
end

local function solid_vis(a) return a == WALL or a == SLING or a == POST or a == GATE end

-- Chebyshev distance (capped) from every pixel to the nearest pixel where
-- is_src() is true. Two passes, O(pixels).
local function dist_field(is_src, cap)
  local d = {}
  for i = 0, WW * WH - 1 do d[i] = is_src(cmap[i]) and 0 or cap end
  for y = 0, WH - 1 do
    for x = 0, WW - 1 do
      local i = y * WW + x
      local v = d[i]
      if v > 0 then
        if x > 0 then v = math.min(v, d[i-1] + 1) end
        if y > 0 then
          v = math.min(v, d[i-WW] + 1)
          if x > 0 then v = math.min(v, d[i-WW-1] + 1) end
          if x < WW-1 then v = math.min(v, d[i-WW+1] + 1) end
        end
        d[i] = v
      end
    end
  end
  for y = WH - 1, 0, -1 do
    for x = WW - 1, 0, -1 do
      local i = y * WW + x
      local v = d[i]
      if v > 0 then
        if x < WW-1 then v = math.min(v, d[i+1] + 1) end
        if y < WH-1 then
          v = math.min(v, d[i+WW] + 1)
          if x < WW-1 then v = math.min(v, d[i+WW+1] + 1) end
          if x > 0 then v = math.min(v, d[i+WW-1] + 1) end
        end
        d[i] = v
      end
    end
  end
  return d
end

local slingRim = {{}, {}} -- kicking-face pixels, lit up when a sling fires

local function bake_pixel(x, wy, dOpen, dWall)
  local i = wy * WW + x
  local a = cmap[i]
  if not solid_vis(a) then
    local dw = dWall[i]
    if dw <= 2 then return sget(T_RIM, (x + wy) % 8, 3 + dw) end
    return tex16(T_FLOOR, x, wy)
  end
  local de = dOpen[i]
  if a == SLING then
    if de == 1 then
      local list = slingRim[x < 80 and 1 or 2]
      list[#list + 1] = i
      return C_GOLD
    end
    return sget(T_SLING, x % 8, wy % 8)
  elseif a == POST then
    return de == 1 and C_WHITE or sget(T_POST, x % 8, wy % 8)
  elseif a == GATE then
    return sget(T_GATE, x % 8, wy % 8)
  end
  if de <= 4 then return sget(T_RIM, (x + wy) % 8, de - 1) end
  return tex16(T_BARK, x, wy)
end

-- decorations baked into the background: {sprite, x, y, w, h}
local DECOR = {
  {14, 8, 88}, {15, 146, 120}, {24, 8, 130}, {25, 146, 92},
  {68, 4, 40, 2, 2}, {70, 132, 6, 2, 2}, {26, 22, 116},
  {24, 60, 236}, {14, 66, 244}, {26, 92, 240}, {25, 100, 236}, {15, 76, 248},
  {8, 140, 62}, {27, 30, 20}, {27, 136, 30},
}

local function bake_decor(top)
  for _, d in ipairs(DECOR) do
    local w, h = d[4] or 1, d[5] or 1
    spr(d[1], d[2], d[3] - top, 0, 1, 0, 0, w, h)
  end
  -- plunger lane chevrons, in the rim colours
  for y = 196, 236, 10 do
    pix(164, y - top, C_LIME) pix(165, y - top, C_LIME)
    pix(163, y + 1 - top, C_LEAF) pix(166, y + 1 - top, C_LEAF)
  end
  -- "FAIRY RING" lettering on the top screen floor
  print("FAIRY", 21, 100 - top, C_FLOORL, false, 1, true)
  print("RING", 23, 107 - top, C_FLOORL, false, 1, true)
end

local MINI_X, MINI_Y = 186, 60

local function bake_hud()
  -- bark frame with an inset night-sky panel
  for y = 0, 135 do
    for x = WW, 239 do pix(x, y, tex16(T_BARK, x, y)) end
  end
  rect(WW + 4, 3, 240 - WW - 7, 130, C_KEY)
  rectb(WW + 3, 2, 240 - WW - 5, 132, C_MOSS)
  print("FAIRY", 186, 7, C_OUT, false, 1, false)
  print("FAIRY", 185, 6, C_PINK, false, 1, false)
  print("RING", 192, 15, C_OUT, false, 1, false)
  print("RING", 191, 14, C_GOLD, false, 1, false)
  print("SCORE", 184, 26, C_LILAC, false, 1, true)
  print("BALL", 184, 44, C_LILAC, false, 1, true)
  -- minimap of the whole world at 1/4 scale
  for my = 0, WH // 4 - 1 do
    for mx = 0, WW // 4 - 1 do
      local solid = 0
      for sy = 0, 3, 2 do
        for sx = 0, 3, 2 do
          if solid_vis(cmap[(my*4+sy) * WW + mx*4+sx]) then solid = solid + 1 end
        end
      end
      pix(MINI_X + mx, MINI_Y + my, solid >= 3 and C_BARKD or C_FLOOR)
    end
  end
end

local function bake_screens()
  local dOpen = dist_field(function(a) return not solid_vis(a) end, 6)
  local dWall = dist_field(solid_vis, 6)
  for v = 1, 2 do
    local top = VIEWS[v]
    cls(0)
    slingRim = {{}, {}}
    for y = 0, 135 do
      local wy = top + y
      for x = 0, WW - 1 do pix(x, y, bake_pixel(x, wy, dOpen, dWall)) end
    end
    bake_decor(top)
    bake_hud()
    memcpy(SNAP + (v - 1) * SCRBYTES, 0, SCRBYTES)
  end
end

-- ============================ drawing ============================
local function draw_flipper(f, top)
  local k = (f.s // 1) // 2 -- 8 frames for 16 states
  local id = 256 + (k // 4) * 48 + (k % 4) * 4
  if f.dir == 1 then
    spr(id, f.px - 6, FL_PIVOT_Y - 12 - top, 0, 1, 0, 0, 4, 3)
  else
    spr(id, f.px - 25, FL_PIVOT_Y - 12 - top, 0, 1, 1, 0, 4, 3)
  end
end

local function draw_world()
  local top = VIEWS[view]
  local sx = (shake > 0) and (frame % 2 * 2 - 1) or 0
  memcpy(0, SNAP + (view - 1) * SCRBYTES, SCRBYTES)

  -- portal (the fairy ring hole)
  spr(44 + ((frame // 12) % 2) * 2, hole.x - 8 + sx, hole.y - 8 - top, 0, 1, 0, 0, 2, 2)
  for _, b in ipairs(bumpers) do
    local lit = b.flash > 0
    spr(lit and 34 or 32, b.x - 8 + sx, b.y - 8 - top - (lit and 1 or 0), 0, 1, 0, 0, 2, 2)
  end
  for _, t in ipairs(targets) do
    spr(t.lit and 38 or 36, t.x - 8 + sx, t.y - 8 - top, 0, 1, 0, 0, 2, 2)
  end
  for si, s in ipairs(slings) do
    if s.flash > 0 then
      for _, i in ipairs(slingRim[si]) do
        local wy = i // WW
        if wy >= top and wy < top + 136 then pix(i % WW + sx, wy - top, C_WHITE) end
      end
    end
  end
  for _, l in ipairs(lanes) do
    local lit = l.lit and (frame // 16) % 4 ~= 0
    spr(lit and 11 or 10, l.x - 4 + sx, l.y - 10 - top, 0)
  end
  for _, k in ipairs(kickbacks) do
    local lit = k.lit and (frame // 10) % 2 == 0
    spr(lit and 13 or 12, k.x - 4 + sx, k.y - 12 - top, 0)
  end
  -- plunger spring
  spr(20 + math.min(3, (charge * 4) // 1), 161, 250 - top, 0)

  for _, f in ipairs(flippers) do draw_flipper(f, top) end

  -- ball: 4 rolling frames driven by the spin
  local bx, by = ball.x // 1 + sx, ball.y // 1 - top
  if not (state == "hold" and holdKind == "hole" and holdT % 6 < 3) then
    spr((ball.rot // 64) % 4, bx - 4, by - 4, 0)
  end

  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x, p.y, p.t = p.x + p.vx, p.y + p.vy, p.t - 1
    if p.t <= 0 then table.remove(parts, i)
    else spr(4 + (3 - math.min(3, p.t // 6)), p.x - 4 + sx, p.y - 4 - top, 0) end
  end

  local fy = fairy.y + math.sin(frame / 20) * 2
  spr(40 + ((frame // 6) % 2) * 2, fairy.x - 8 + sx, fy - 8 - top, 0, 1,
      fairy.tx < fairy.x and 1 or 0, 0, 2, 2)
end

local function draw_hud()
  print(string.format("%9d", score), 182, 33, C_WHITE, true, 1, false)
  for i = 1, 3 do spr(i <= balls and 0 or 9, 182 + i * 9, 50, 0) end
  if mult > 1 then print("x" .. mult, 224, 44, C_GOLD, false, 1, true) end
  if saver > 0 and (saver > 180 or frame % 16 < 8) then
    print("SAVE", 216, 26, C_CYAN, false, 1, true)
  end
  -- minimap: current screen and the ball
  rectb(MINI_X - 1, MINI_Y + VIEWS[view] // 4 - 1, WW // 4 + 2, 136 // 4 + 2, C_LIME)
  pix(MINI_X + ball.x // 4, MINI_Y + ball.y // 4, C_PINK)
  if msgT > 0 and (msgT > 30 or frame % 8 < 4) then
    print(msg, 182, 127, C_GOLD, false, 1, true)
  elseif state == "plunge" and frame % 40 < 30 then
    print("DOWN:LAUNCH", 182, 127, C_LILAC, false, 1, true)
  end
  if state == "title" or state == "over" then
    rect(24, 50, 128, 36, C_KEY) rectb(24, 50, 128, 36, C_PINK)
    rectb(26, 52, 124, 32, C_MOSS)
    local t = state == "over" and "GAME OVER" or "FAIRY RING"
    print(t, 88 - #t * 3, 58, C_GOLD)
    if frame % 40 < 28 then print("PRESS Z OR X", 52, 72, C_LILAC, false, 1, false) end
  end
end

local function update_fairy()
  -- hover near the ring; follow the ball loosely while it is on the top screen
  if ball.y < 130 and state == "play" then
    fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
  else
    fairy.tx = hole.x - 16 + math.cos(frame / 70) * 10
    fairy.ty = hole.y - 18 + math.sin(frame / 50) * 6
  end
  fairy.x = fairy.x + (fairy.tx - fairy.x) * 0.04
  fairy.y = fairy.y + (fairy.ty - fairy.y) * 0.04
end

local function update_view()
  if view == 2 and ball.y < VIEWS[2] + 4 then view = 1
  elseif view == 1 and ball.y >= 132 then view = 2 end
end

-- ============================ main ============================
function BOOT()
  build_cmap()
  bake_screens()
  serve()
  state = "title"
end

function TIC()
  update()
  if state ~= "title" and state ~= "over" then physics() end
  arm_saver()
  update_view()
  update_fairy()
  draw_world()
  draw_hud()
end

-- test hook for the headless harness (harmless in the real cart)
FR = {
  ball = ball, flippers = flippers, bumpers = bumpers, targets = targets,
  lanes = lanes, hole = hole, kickbacks = kickbacks,
  cmap = cmap, WW = WW, WH = WH,
  set_pad = function(p) vpad = p end,
  get = function() return state, score, balls, view, saver, mult end,
  new_game = new_game, physics = physics, update = update, tic = TIC,
  ring_test = ring_test,
  force_state = function(s) state = s end,
  set_view = function(v) view = v end,
  tic_draw = function() update_view() update_fairy() draw_world() draw_hud() end,
}
