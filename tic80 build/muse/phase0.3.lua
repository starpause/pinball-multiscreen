-- Fairy Ring Pinball : Phase 0 cart scaffold
-- TIC-80, Lua, 240x136, 60fps
-- Scope: marble ball only, Mushroom Grove table only.
-- Loop: plunger launch, flippers, drain, score, game over.
--
-- Physics: ball is a circle, table is line segments and circles.
-- Fixed timestep: 4 substeps per frame. No rigid-body engine,
-- just tuned arcade collision (devlog rule: simple and done).

-- ============================== config ==============================
local W, H = 240, 136
local SUBSTEPS = 4
local GRAV = 0.22        -- px per frame^2 at 60fps, marble = full gravity
local MAXSPEED = 9.0     -- px per frame, anti-tunneling clamp
local FRICTION = 0.9995  -- per-substep rolling resistance: calms the chaos
                         -- ~11%/sec, keeps the marble weighty but controllable

-- ball profile: marble (heavy glass, thuddy)
local balldef = { r = 3, grav = 1.0, rest = 0.55, drag = 0.0 }

-- ============================== state ==============================
local frame = 0
local state = "plunge"   -- plunge | play | drain | gameover
local score = 0
local ballsLeft = 3
local charge = 0
local plungerHeld = false
local drainTimer = 0
local stuckTimer = 0

local ball = { x = 220, y = 125, vx = 0, vy = 0, r = balldef.r }

-- ============================== table geometry ==============================
-- wall segment: {x1,y1,x2,y2,rest}
local walls = {
  {12,24, 12,104, 0.45},     -- left wall
  {12,24, 40,10, 0.45},      -- top-left arch
  {40,10, 200,10, 0.45},     -- top
  {228,16, 216,8, 0.45},     -- horseshoe R1: catches the lane ball, turns it left
  {216,8, 200,10, 0.45},     -- horseshoe R2: guides it left along the top
  {200,10, 194,22, 0.45},    -- horseshoe R3: deposits it into the playfield
  {228,16, 228,128, 0.45},   -- right wall / lane right side
  {12,104, 92,118, 0.45},    -- left inlane guide (ends AT the pivot: no V-trap)
  {212,104, 148,118, 0.45},  -- right inlane guide (ends AT the pivot)
  {212,20, 212,128, 0.45},    -- plunger lane divider (tall: lane is fully separated)
  {212,128, 228,128, 0.45},  -- lane floor (ball rests here)
}

-- one-way gate at the lane exit: lets the launched ball out (moving left),
-- blocks playfield balls from falling back into the lane (moving right).
-- nx,ny points to the solid side (the playfield side).
local oneways = {
  {200,8, 200,40, -1, 0},
}

-- slingshot kicker faces: {x1,y1,x2,y2, nx,ny (kick dir), kick, score}
local slings = {
  {50,88, 66,102, 0.8,0.6, 2.0, 50},
  {190,88, 174,102, -0.8,0.6, 2.0, 50},
}

-- mushroom bumpers: {x,y,r, kick, lit}
local bumpers = {
  {x=95,  y=42, r=7, kick=3.4},
  {x=145, y=42, r=7, kick=3.4},
  {x=120, y=64, r=7, kick=3.4},
}

-- toadstool standup targets (future quest targets, score for now)
local targets = {
  {x=58,  y=52, r=4, lit=false},
  {x=182, y=52, r=4, lit=false},
  {x=120, y=28, r=4, lit=false},
}

-- flippers: pivot, len, rest/active angles (radians, y-down), swing speed
-- gap between tips at rest ~14px (about 2 ball widths): fair, not a drain pipe
local flippers = {
  {px=92,  py=118, len=24, rest=0.5,         active=-0.5,        speed=0.367, a=0.5,         w=0},
  {px=148, py=118, len=24, rest=math.pi-0.5,  active=math.pi+0.5, speed=0.367, a=math.pi-0.5, w=0},
}

-- ============================== input ==============================
-- left flipper: Left arrow or Z | right flipper: Right arrow
-- plunger: Up arrow or X (hold to charge, release to fire)
-- (M for right flipper per design doc needs key() scancodes; Phase 0 uses arrows.)
local function leftHeld()  return btn(2) or btn(4) end
local function rightHeld() return btn(3) end
local function plungeHeld() return btn(0) or btn(5) end

-- ============================== collision ==============================
local function collide_segment(b, x1,y1,x2,y2, rest, ox,oy)
  local dx, dy = x2-x1, y2-y1
  local l2 = dx*dx + dy*dy
  local t = 0
  if l2 > 0 then
    t = ((b.x-x1)*dx + (b.y-y1)*dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local cx, cy = x1+dx*t, y1+dy*t
  local nx, ny = b.x-cx, b.y-cy
  local d = math.sqrt(nx*nx + ny*ny)
  if d < b.r and d > 0.0001 then
    nx, ny = nx/d, ny/d
    if ox then
      -- one-way: only collide when approaching from the solid side
      local side = (b.x-cx)*ox + (b.y-cy)*oy
      local vnw = b.vx*ox + b.vy*oy
      if not (side > 0 and vnw < 0) then return false end
      nx, ny = ox, oy
    end
    b.x = b.x + nx*(b.r-d)
    b.y = b.y + ny*(b.r-d)
    local vn = b.vx*nx + b.vy*ny
    if vn < 0 then
      local e = rest or 0.45
      b.vx = b.vx - (1+e)*vn*nx
      b.vy = b.vy - (1+e)*vn*ny
      return true, nx, ny
    end
  end
  return false
end

local function collide_bumper(b, bp)
  local nx, ny = b.x-bp.x, b.y-bp.y
  local d = math.sqrt(nx*nx + ny*ny)
  local rr = b.r + bp.r
  if d < rr and d > 0.0001 then
    nx, ny = nx/d, ny/d
    b.x = bp.x + nx*rr
    b.y = bp.y + ny*rr
    local spd = math.sqrt(b.vx*b.vx + b.vy*b.vy)
    local vn = b.vx*nx + b.vy*ny
    if vn < 0 then
      b.vx = b.vx - 2*vn*nx
      b.vy = b.vy - 2*vn*ny
    end
    -- enforce minimum kick along the normal
    local vn2 = b.vx*nx + b.vy*ny
    if vn2 < bp.kick then
      b.vx = b.vx + (bp.kick-vn2)*nx
      b.vy = b.vy + (bp.kick-vn2)*ny
    end
    score = score + 100 + math.min(200, math.floor(spd*8))
    return true
  end
  return false
end

local function collide_target(b, tg)
  local nx, ny = b.x-tg.x, b.y-tg.y
  local d = math.sqrt(nx*nx + ny*ny)
  local rr = b.r + tg.r
  if d < rr and d > 0.0001 then
    nx, ny = nx/d, ny/d
    b.x = tg.x + nx*rr
    b.y = tg.y + ny*rr
    local vn = b.vx*nx + b.vy*ny
    if vn < 0 then
      local e = 0.35
      b.vx = b.vx - (1+e)*vn*nx
      b.vy = b.vy - (1+e)*vn*ny
    end
    if not tg.lit then
      tg.lit = true
      score = score + 250
    end
    return true
  end
  return false
end

-- Per-substep flipper rotation (anti-tunneling):
-- the tip moves at most (speed/SUBSTEPS)*len px per substep, so the
-- discrete collision check can never skip over the ball, even at the tip.
-- f.w stays the true per-frame angular velocity for the contact kick.
local function flipper_step(f, pressed)
  local target = pressed and f.active or f.rest
  local step = f.speed / SUBSTEPS
  local old = f.a
  local d = target - old
  if math.abs(d) <= step then f.a = target
  else f.a = old + (d > 0 and step or -step) end
  f.w = (f.a - old) * SUBSTEPS
end

local function flipper_collide(b, f)
  local dx, dy = math.cos(f.a), math.sin(f.a)
  local x2, y2 = f.px+dx*f.len, f.py+dy*f.len
  local sx, sy = x2-f.px, y2-f.py
  local l2 = sx*sx + sy*sy
  local t = ((b.x-f.px)*sx + (b.y-f.py)*sy) / l2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local cx, cy = f.px+sx*t, f.py+sy*t
  local nx, ny = b.x-cx, b.y-cy
  local d = math.sqrt(nx*nx + ny*ny)
  if d < b.r and d > 0.0001 then
    nx, ny = nx/d, ny/d
    b.x = b.x + nx*(b.r-d)
    b.y = b.y + ny*(b.r-d)
    -- contact point velocity from flipper rotation: v = w * dist * tangent
    local dist = t * f.len
    local tx, ty = -dy, dx
    local cvx, cvy = f.w*dist*tx, f.w*dist*ty
    local rvx, rvy = b.vx-cvx, b.vy-cvy
    local vn = rvx*nx + rvy*ny
    if vn < 0 then
      local e = 0.35
      b.vx = b.vx - (1+e)*vn*nx
      b.vy = b.vy - (1+e)*vn*ny
      return true
    end
  end
  return false
end

-- ============================== physics step ==============================
local function physics(leftP, rightP)
  for _ = 1, SUBSTEPS do
    flipper_step(flippers[1], leftP)
    flipper_step(flippers[2], rightP)
    ball.vy = ball.vy + GRAV*balldef.grav/SUBSTEPS
    ball.x = ball.x + ball.vx/SUBSTEPS
    ball.y = ball.y + ball.vy/SUBSTEPS
    for _, s in ipairs(walls) do
      collide_segment(ball, s[1],s[2],s[3],s[4], s[5])
    end
    for _, s in ipairs(oneways) do
      collide_segment(ball, s[1],s[2],s[3],s[4], 0.4, s[5],s[6])
    end
    for _, sl in ipairs(slings) do
      local hit, nx, ny = collide_segment(ball, sl[1],sl[2],sl[3],sl[4], 0.3)
      if hit then
        ball.vx = ball.vx + sl[5]*sl[7]
        ball.vy = ball.vy + sl[6]*sl[7]
        score = score + sl[8]
      end
    end
    for _, bp in ipairs(bumpers) do collide_bumper(ball, bp) end
    for _, tg in ipairs(targets) do collide_target(ball, tg) end
    for _, f in ipairs(flippers) do flipper_collide(ball, f) end
    -- rolling resistance (keeps the marble from accelerating forever)
    ball.vx = ball.vx * FRICTION
    ball.vy = ball.vy * FRICTION
  end
  -- anti-tunneling speed clamp
  local spd = math.sqrt(ball.vx*ball.vx + ball.vy*ball.vy)
  if spd > MAXSPEED then
    ball.vx = ball.vx/spd*MAXSPEED
    ball.vy = ball.vy/spd*MAXSPEED
  end
end

-- ============================== game flow ==============================
local function reset_ball()
  ball.x, ball.y, ball.vx, ball.vy = 220, 125, 0, 0
  charge = 0
  plungerHeld = false
  stuckTimer = 0
end

local function full_reset()
  score = 0
  ballsLeft = 3
  for _, tg in ipairs(targets) do tg.lit = false end
  reset_ball()
  state = "plunge"
end

local function update()
  if state == "plunge" then
    local held = plungeHeld()
    if held then
      charge = math.min(1, charge + 1/45)
    else
      if plungerHeld and charge > 0.05 then
        ball.vy = -(3 + 6*charge)  -- fire! full charge orbits the lane
      end
      charge = 0
    end
    plungerHeld = held
    if ball.x < 195 then state = "play" end
  elseif state == "play" then
    if ball.y > 138 then
      state = "drain"
      drainTimer = 40
    end
    -- safety net: unstuck a dead ball (sideways kick so it can't re-wedge)
    local spd = math.sqrt(ball.vx*ball.vx + ball.vy*ball.vy)
    if spd < 0.05 then stuckTimer = stuckTimer + 1
    else stuckTimer = 0 end
    if stuckTimer > 240 then
      ball.vx = (math.random() - 0.5) * 4
      ball.vy = -2
      stuckTimer = 0
    end
  elseif state == "drain" then
    drainTimer = drainTimer - 1
    if drainTimer <= 0 then
      ballsLeft = ballsLeft - 1
      if ballsLeft > 0 then
        reset_ball()
        state = "plunge"
      else
        state = "gameover"
      end
    end
  elseif state == "gameover" then
    if btnp(5) or btnp(4) then full_reset() end
  end
end

-- ============================== draw ==============================
-- ============================== sprites ==============================
-- Sprite sheet: fairy_sprites.png, imported ONCE via `import tiles fairy_sprites.png`
-- (16 sprites per row). After importing, `save pinball` to keep them in the cart.
local SPR_MUSH = {0, 2, 4}        -- mushroom bumpers, 16x16 (base ids)
local SPR_TOAD = 6                -- toadstool target unlit, 16x16
local SPR_TOAD_LIT = 8            -- toadstool target lit, 16x16
local SPR_BALL = 10               -- marble, 8x8
local SPR_SLING = 12              -- slingshot leaf, 16x16
local SPR_FLIP = {64,68,72,128,132,136}  -- flipper flipbook, 32x32, pivot at (6,16)

-- flipbook frame from flipper angle (0=rest .. 5=fully swung)
local function flip_frame(f)
  local t = (f.rest - f.a) / (f.rest - f.active)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return SPR_FLIP[math.floor(t*5 + 0.5) + 1]
end

local function draw_table()
  -- walls stay vector (crisp lines)
  for _, s in ipairs(walls) do
    line(s[1],s[2],s[3],s[4], 6)
  end
  -- one-way gate (dashed look)
  line(200,8, 200,40, 5)
  -- plunger lane floor marker
  line(212,128, 228,128, 3)
  -- slingshot leaves (right one mirrored)
  spr(SPR_SLING, 50,87, 0, 1, 0, 0, 2, 2)
  spr(SPR_SLING, 174,87, 0, 1, 1, 0, 2, 2)
  -- mushroom bumpers
  for i, bp in ipairs(bumpers) do
    spr(SPR_MUSH[i], bp.x-8, bp.y-8, 0, 1, 0, 0, 2, 2)
  end
  -- toadstool targets (lit or unlit)
  for _, tg in ipairs(targets) do
    spr(tg.lit and SPR_TOAD_LIT or SPR_TOAD, tg.x-8, tg.y-8, 0, 1, 0, 0, 2, 2)
  end
  -- flippers (flipbook; right one mirrored, pivot at (26,16) when flipped)
  local f = flippers[1]
  spr(flip_frame(f), f.px-6, f.py-16, 0, 1, 0, 0, 4, 4)
  f = flippers[2]
  spr(flip_frame(f), f.px-26, f.py-16, 0, 1, 1, 0, 4, 4)
end

local function draw_hud()
  print("SCORE "..score, 14, 14, 3)
  for i = 1, ballsLeft do
    circ(172 + i*8, 16, 2, 3)
  end
  if state == "plunge" then
    -- charge meter in the lane
    rect(231, 120-40*charge, 3, 40*charge, 11)
    if math.floor(frame/16)%2 == 0 then
      print("HOLD X, RELEASE TO LAUNCH", 62, 70, 3)
    end
  elseif state == "gameover" then
    print("GAME OVER", 100, 60, 10)
    if math.floor(frame/16)%2 == 0 then
      print("PRESS X TO PLAY AGAIN", 74, 74, 3)
    end
  end
end

local function draw_ball()
  spr(SPR_BALL, ball.x-4, ball.y-4)
end

-- ============================== main ==============================
function TIC()
  frame = frame + 1
  local lp, rp = leftHeld(), rightHeld()
  update()
  physics(lp, rp)
  cls(0)
  draw_table()
  draw_ball()
  draw_hud()
end

full_reset()

-- Test hook: lets a headless harness inspect and poke game state.
-- Harmless in the real cart (one extra global, never drawn).
FRP = {
  ball = ball,
  flippers = flippers,
  walls = walls,
  oneways = oneways,
  slings = slings,
  bumpers = bumpers,
  targets = targets,
  get = function() return state, score, ballsLeft, charge end,
  reset = full_reset,
  set_ball = function(x, y, vx, vy)
    ball.x, ball.y = x, y
    ball.vx, ball.vy = vx or 0, vy or 0
  end,
}
