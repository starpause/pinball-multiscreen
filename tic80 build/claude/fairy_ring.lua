-- title:   Fairy Ring Pinball
-- author:  jordan + claude
-- desc:    an endless tower of one-screen pinball tables
-- script:  lua

-- Design (see ENGINE_NOTES.md and TABLE_GEN.md):
--  * Every table is ONE screen with its own flippers (Revenge of the
--    'Gator / Kirby's Pinball Land / Infinity Pinball). Shoot out of the
--    top opening to climb to the next table; fall out of the bottom and
--    you drop to the table below.
--  * Tables are generated the way Infinity Pinball does it: authored
--    half-wall PIECES (mirrored, mixed left/right) + a fixed bottom KIT
--    (flippers, slings, inlanes, outlanes) + toys scattered on a grid with
--    clearance margins + 1-3 trigger->reward GOALS. Gentle tables 0-3,
--    a bonus "fairy court" every 10th table that becomes your checkpoint.
--  * Physics is the Pokemon Pinball engine: per-pixel collision map,
--    16-point ring probe, rotate-into-normal bounce, swept 16-state
--    flippers. Kickers use Infinity's rule: reset velocity, fixed kick.

-- ============================ constants ============================
local GRAV    = 0.06     -- px/frame^2 (Infinity: 34.3 u/s^2 at 6.8 px/u)
local VMAX    = 7.99     -- per-axis velocity clamp
local STEPMAX = 4.996    -- per-axis movement clamp: the ring can't skip 5px walls
local BR      = 4        -- ball radius = ring probe radius
local WW, WH  = 150, 136 -- one table = one screen (22 x 20 Infinity units)
local CX      = 75       -- table centre line
local SNAP    = 0x8000   -- map RAM: baked background of the current table
local SCRBYTES = 16320

-- tuned feel (px/frame)
local KICK_BUMPER = 2.2  -- Infinity bumper 18.75 u/s
local KICK_SLING  = 1.6
local KICK_POST   = 1.2
-- scales Pokemon's flipper lever impulse; global so tests can sweep it
TUNE = {flip = 0.6}
local LAUNCH_VY   = -2.9

-- FAIRY NIGHT palette indices (the palette ships in the sprite sheet)
local C_KEY, C_OUT, C_FLOOR, C_FLOORL = 0, 1, 2, 3
local C_MOSSD, C_MOSS, C_LEAF, C_LIME = 4, 5, 6, 7
local C_BARKD, C_BARK, C_RED, C_PINK = 8, 9, 10, 11
local C_GOLD, C_CYAN, C_LILAC, C_WHITE = 12, 13, 14, 15

-- collision map attributes (static geometry only; toys are analytic)
local EMPTY, WALL, SLING = 0, 1, 2

-- ============================ input ============================
-- Revenge of the 'Gator controls: any D-PAD direction = left flipper,
-- A or B (Z / X keys) = right flipper. Nudge: X or Y button (A / S keys).
local vpad = nil -- the test harness replaces this with a table of booleans
local function pad(i)
  if vpad then return vpad[i] or false end
  return btn(i)
end
local function leftHeld()  return pad(0) or pad(1) or pad(2) or pad(3) end
local function rightHeld() return pad(4) or pad(5) end
local function nudgeHeld() return pad(6) or pad(7) end

-- ============================ rng ============================
-- xorshift32: deterministic per (seed, table index), so a table is the
-- same every time you come back to it
local function RNG(seed)
  local s = seed & 0xffffffff
  if s == 0 then s = 0x9e3779b9 end
  local r = {}
  function r.next()
    s = s ~ ((s << 13) & 0xffffffff)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & 0xffffffff)
    return s
  end
  function r.int(n) return r.next() % n end           -- 0 .. n-1
  function r.chance(p) return r.next() % 100 < p end  -- p percent
  function r.pick(t) return t[r.int(#t) + 1] end
  function r.shuffle(t)
    for i = #t, 2, -1 do local j = r.int(i) + 1 t[i], t[j] = t[j], t[i] end
    return t
  end
  return r
end

-- ============================ collision map ============================
local cmap = {}
local function cset(x, y, a)
  if x >= 0 and x < WW and y >= 0 and y < WH then cmap[y * WW + x] = a end
end

-- scanline fill of any (concave ok) polygon, flat {x1,y1,x2,y2,...}
local function fill_poly(p, a)
  local n = #p // 2
  local y0, y1 = 1e9, -1e9
  for i = 1, n do y0 = math.min(y0, p[i*2]) y1 = math.max(y1, p[i*2]) end
  for y = math.max(0, y0 // 1), math.min(WH - 1, y1 // 1) do
    local yc, xs = y + 0.5, {}
    for i = 1, n do
      local ax, ay = p[i*2-1], p[i*2]
      local j = i % n + 1
      local bx, by = p[j*2-1], p[j*2]
      if (ay <= yc and by > yc) or (by <= yc and ay > yc) then
        xs[#xs + 1] = ax + (yc - ay) * (bx - ax) / (by - ay)
      end
    end
    table.sort(xs)
    for k = 1, #xs - 1, 2 do
      for x = math.ceil(xs[k] - 0.5), math.floor(xs[k+1] - 0.5) do cset(x, y, a) end
    end
  end
end

local function fill_capsule(x1, y1, x2, y2, r, a)
  local dx, dy = x2 - x1, y2 - y1
  local l2 = dx*dx + dy*dy
  for y = (math.min(y1, y2) - r) // 1, (math.max(y1, y2) + r) // 1 do
    for x = (math.min(x1, x2) - r) // 1, (math.max(x1, x2) + r) // 1 do
      local px, py = x + 0.5, y + 0.5
      local t = l2 > 0 and math.max(0, math.min(1, ((px-x1)*dx + (py-y1)*dy) / l2)) or 0
      local qx, qy = x1 + dx*t - px, y1 + dy*t - py
      if qx*qx + qy*qy <= r*r then cset(x, y, a) end
    end
  end
end

-- mirror helpers: pieces are authored as the RIGHT half in (dx, y)
-- where dx = distance right of the centre line
local function side_x(dx, side) return side > 0 and CX + dx or CX - dx end
local function side_poly(dxy, side)
  local p = {}
  for i = 1, #dxy, 2 do p[#p+1] = side_x(dxy[i], side) p[#p+1] = dxy[i+1] end
  return p
end

-- ============================ table pieces ============================
-- Half-wall PIECES: the wall contour of the right half from the top
-- opening (dx 30, y 0) down to the kit joint (dx 69, y 90). Any piece
-- connects to any other table because the openings never change.
-- slots: optional anchors the generator may fill.
local PIECES = {
  { name = "HOLLOW",  -- wide chamber with a rounded top shoulder
    wall = {30,0, 36,6, 58,8, 68,16, 70,26, 70,84, 69,90},
    flipper = {dx = 62, y = 54} },
  { name = "HOURGLASS", -- pinched waist: the ball rattles through the middle
    wall = {30,0, 40,10, 64,24, 65,34, 51,47, 51,55, 66,68, 69,90} },
  { name = "ROOT",  -- a root spur juts in, an upper flipper rides on it
    wall = {30,0, 33,8, 62,10, 70,20, 70,42, 52,51, 47,56, 52,60, 70,64, 69,90},
    flipper = {dx = 56, y = 46} },
  { name = "ALCOVE", -- a side pocket with a fairy ring hole inside
    wall = {30,0, 36,8, 60,12, 60,34, 73,38, 73,58, 60,62, 60,84, 69,90},
    hole = {dx = 66, y = 48} },
  { name = "FUNNEL", -- slanted shoulders steer high shots to the exit
    wall = {30,0, 46,14, 70,30, 70,88, 69,90} },
}

-- The fixed bottom KIT (right half; mirrored for the left):
-- outer wall + outlane, inlane guide, slingshot, flipper pivot, and the
-- anchor slots for kickback / side post / centre post.
local KIT = {
  wall  = {69,89, 69,106, 41,130, 41,140, 80,140, 80,89},
  guide = {57,88, 57,100, 32,114},          -- capsule chain, r = 2
  sling = {43,74, 43,92, 33,97},            -- triangle; face = pt1 -> pt3
                                            -- (inlane under it stays 14+ px wide)
  pivot = {dx = 25, y = 118},
  kick  = {dx = 36, y = 126},               -- outlane kickback sensor
  post  = {dx = 64, y = 86},                -- outlane side post (blocker)
}
local CENTER_POST = {x = CX, y = 131}

-- ============================ toy catalogue ============================
-- r = collision radius, m = placement clearance margin (Infinity's
-- ObjectPlacement radius, scaled 6.8 px/unit), notc = keep off the centre
local TOY = {
  bumper  = {r = 6, m = 14, notc = true, kicker = true},
  gold    = {r = 6, m = 14, notc = true, kicker = true}, -- score bumper
  lantern = {r = 5, m = 16, travel = 14, kicker = true}, -- moving bumper
  hole    = {r = 4, m = 12, notc = true},   -- fairy ring: hold + eject
  warp    = {r = 4, m = 12, notc = true},   -- pink ring: warp up a table
  acorn   = {r = 5, m = 13},                -- bash toy (3 hits)
  toad    = {r = 4, m = 8},                 -- standup target (groups of 3)
  bud     = {r = 0, m = 7},                 -- rollover sensor (groups of 3)
}

-- goal definitions: trigger -> reward (Infinity's event model)
local TRIGGERS = {  -- weight = Infinity trigger chance %
  {kind = "BUDS", w = 50}, {kind = "ACORN", w = 62}, {kind = "TOADS", w = 34},
}
local REWARDS = {   -- weight = Infinity event chance %
  {kind = "KICKBACK", w = 50}, {kind = "POSTS", w = 50},
  {kind = "CENTER", w = 72}, {kind = "UPDRAFT", w = 50},
  {kind = "MULTI", w = 41}, {kind = "JACKPOT", w = 29},
}
local REWARD_LABEL = {KICKBACK = "KICKBACK", POSTS = "SIDE POSTS",
  CENTER = "CENTER POST", UPDRAFT = "UPDRAFT", MULTI = "MULT +1", JACKPOT = "JACKPOT"}

-- ============================ table generation ============================
local masterSeed = 1
local function is_bonus(idx) return idx > 0 and (idx + 1) % 10 == 0 end

-- does a circle of radius rr at (x,y) touch any solid pixel?
local function cmap_clear(x, y, rr)
  for py = (y - rr) // 1, (y + rr) // 1 do
    for px = (x - rr) // 1, (x + rr) // 1 do
      local dx, dy = px + 0.5 - x, py + 0.5 - y
      if dx*dx + dy*dy <= rr*rr then
        if px < 0 or px >= WW or py < 0 or py >= WH then return false end
        if cmap[py * WW + px] ~= EMPTY then return false end
      end
    end
  end
  return true
end

local function paint_table(t)
  for i = 0, WW * WH - 1 do cmap[i] = EMPTY end
  -- upper-flipper brackets: a sloped mount from the wall down to the pivot,
  -- so a ball behind the flipper rolls back onto it instead of wedging
  for _, b in ipairs(t.brackets or {}) do
    fill_capsule(side_x(b.dx + 16, b.side), b.y - 7, side_x(b.dx + 3, b.side), b.y + 1, 4, WALL)
  end
  for _, side in ipairs({-1, 1}) do
    local pc = side < 0 and t.left or t.right
    local w = {30, -2}
    for i = 1, #pc.wall do w[#w + 1] = pc.wall[i] end
    for _, v in ipairs({80, 90, 80, -2}) do w[#w + 1] = v end
    fill_poly(side_poly(w, side), WALL)
    fill_poly(side_poly(KIT.wall, side), WALL)
    local g = KIT.guide
    for i = 1, #g - 2, 2 do
      fill_capsule(side_x(g[i], side), g[i+1], side_x(g[i+2], side), g[i+3], 2, WALL)
    end
    local s = KIT.sling
    fill_poly(side_poly(s, side), WALL)
    fill_capsule(side_x(s[1], side), s[2], side_x(s[5], side), s[6], 1.5, SLING)
  end
end

-- Infinity's ObjectPlacement: random free grid points, clearance margin
-- against walls and already-placed toys, up to 100 tries.
local function new_grid()
  local g = {}
  for gy = 0, 11 do
    for gx = 0, 11 do g[#g + 1] = {x = 20 + gx * 10, y = 13 + gy * 6} end
  end
  return g
end

-- POCKET RULE: any gap between two solids must be either closed or wider
-- than the ball (8 px) plus slack, otherwise the ball can wedge in it.
local GAP = 2 * BR + 3
local function spot_ok(t, x, y, def, extra)
  if def.notc and math.abs(x - CX) < 10 then return false end
  if not cmap_clear(x, y, def.r + GAP) then return false end
  if def.travel then
    for dx = -def.travel, def.travel, 4 do
      if not cmap_clear(x + dx, y, def.r + BR + 2) then return false end
    end
  end
  for _, o in ipairs(t.objs) do
    local od = TOY[o.kind]
    local need = math.max(def.m, od.m) + (extra or 0)
    if def.r > 0 and od.r > 0 and not (def.kicker and od.kicker) then
      need = math.max(need, def.r + od.r + GAP)
    end
    if (o.x - x)^2 + (o.y - y)^2 < need * need then return false end
  end
  return true
end

local function claim(t, x, y, m)
  for i = #t.grid, 1, -1 do
    local p = t.grid[i]
    if (p.x - x)^2 + (p.y - y)^2 < m * m then table.remove(t.grid, i) end
  end
end

local function add_obj(t, kind, x, y, extra)
  local o = {kind = kind, x = x, y = y, x0 = x, r = TOY[kind].r,
             lit = false, hits = 0, cool = 0, flash = 0, alive = true, phase = 0}
  for k, v in pairs(extra or {}) do o[k] = v end
  t.objs[#t.objs + 1] = o
  claim(t, x, y, TOY[kind].m)
  return o
end

-- place one toy (or a row of `count` toys spaced `gap` apart)
local function place(t, rng, kind, count, gap, centred)
  -- (a row is checked member by member before any member is added)
  count, gap = count or 1, gap or 0
  local def = TOY[kind]
  for _ = 1, 100 do
    if #t.grid == 0 then return nil end
    local p = t.grid[rng.int(#t.grid) + 1]
    local x, y = centred and CX or p.x, p.y
    local x0 = x - (count - 1) * gap / 2
    local ok = true
    for k = 0, count - 1 do
      local mx = x0 + k * gap
      local saveNotc = def.notc
      if count > 1 then def.notc = false end
      ok = ok and spot_ok(t, mx, y, def, 0)
      def.notc = saveNotc
      if not ok then break end
    end
    if ok then
      local group = {}
      for k = 0, count - 1 do group[#group + 1] = add_obj(t, kind, x0 + k * gap, y) end
      return group
    end
  end
  return nil
end

local function weighted(rng, list, allow)
  local total = 0
  for _, e in ipairs(list) do if allow(e) then total = total + e.w end end
  if total == 0 then return nil end
  local r = rng.int(total)
  for _, e in ipairs(list) do
    if allow(e) then
      if r < e.w then return e end
      r = r - e.w
    end
  end
end

local function generate(idx)
  local rng = RNG(masterSeed * 7919 + idx * 104729 + 1)
  local t = {idx = idx, objs = {}, flippers = {}, events = {}, grid = new_grid(),
             kick = {false, false}, posts = 0, center = 0, updraft = 0,
             bonus = is_bonus(idx), visited = false, cleared = false}
  local gentle = idx < 4

  -- 1. shell: one piece per side, picked independently (mirrored left)
  if t.bonus then
    t.left, t.right = PIECES[1], PIECES[1]
  else
    local pool = gentle and {PIECES[1], PIECES[2], PIECES[5]} or PIECES
    t.left, t.right = rng.pick(pool), rng.pick(pool)
  end
  paint_table(t)

  -- 2. fixed kit: main flippers always
  t.flippers[1] = {px = CX - KIT.pivot.dx, py = KIT.pivot.y, dir = 1, s = 0, ds = 0, prev = 0}
  t.flippers[2] = {px = CX + KIT.pivot.dx, py = KIT.pivot.y, dir = -1, s = 0, ds = 0, prev = 0}
  t.kick[1] = idx == 0 or t.bonus or rng.chance(40)
  t.kick[2] = idx == 0 or t.bonus or rng.chance(40)
  -- keep the kit zone out of the scatter grid
  for i = #t.grid, 1, -1 do if t.grid[i].y > 76 then table.remove(t.grid, i) end end

  -- 3. piece slots: upper flipper (45%), alcove hole
  for si, side in ipairs({-1, 1}) do
    local pc = side < 0 and t.left or t.right
    if pc.flipper and not gentle and rng.chance(45) then
      local f = pc.flipper
      t.flippers[#t.flippers + 1] = {px = side_x(f.dx, side), py = f.y, dir = -side,
        s = 0, ds = 0, prev = 0, extra = true}
      t.brackets = t.brackets or {}
      t.brackets[#t.brackets + 1] = {side = side, dx = f.dx, y = f.y}
      claim(t, side_x(f.dx, side), f.y, 22)
    end
    if pc.hole and rng.chance(80) then
      add_obj(t, "hole", side_x(pc.hole.dx, side), pc.hole.y)
    end
  end

  if t.brackets then paint_table(t) end -- brackets are walls too

  if t.bonus then
    -- the fairy court: a ring of bumpers around a jackpot ring
    add_obj(t, "warp", CX, 44, {court = true})
    for k = 0, 4 do
      local a = k / 5 * 2 * math.pi - math.pi / 2
      add_obj(t, k % 2 == 0 and "gold" or "bumper", CX + math.cos(a) * 30, 44 + math.sin(a) * 22)
    end
    t.center = 99999 -- centre post up for the whole visit
    return t
  end

  -- 4. goals: 1 on gentle tables, else 1-3 (Infinity: Next(3)+1)
  local nGoals = gentle and 1 or 1 + rng.int(3)
  local usedReward, usedTrigger, centreTaken = {}, {}, false
  for _ = 1, nGoals do
    local rw = weighted(rng, REWARDS, function(e)
      if usedReward[e.kind] then return false end
      if e.kind == "UPDRAFT" and (gentle or centreTaken) then return false end
      return true
    end)
    local tr = weighted(rng, TRIGGERS, function(e)
      return not usedTrigger[e.kind] and not (gentle and e.kind == "ACORN" and idx == 0)
    end)
    if rw and tr then
      local members
      if tr.kind == "BUDS" then members = place(t, rng, "bud", 3, 13)
      elseif tr.kind == "TOADS" then members = place(t, rng, "toad", 3, 19)
      else members = place(t, rng, "acorn") end
      if members then
        usedReward[rw.kind], usedTrigger[tr.kind] = true, true
        if rw.kind == "UPDRAFT" then
          centreTaken = true
          claim(t, CX, 40, 18) -- keep the wind column clear
        end
        t.events[#t.events + 1] = {trigger = tr.kind, reward = rw.kind,
          members = members, times = 0}
      end
    end
  end

  -- 5. free toys: shuffled creators, each rolls its chance, up to a cap
  local cap = gentle and 3 or 4 + rng.int(4)
  local creators = {{"bumper", 85}, {"lantern", 65}, {"lantern", 65},
                    {"gold", 35}, {"hole", 15}}
  if not gentle then creators[#creators + 1] = {"warp", 8} end
  local placed = 0
  for _ = 1, 20 do
    if placed >= cap then break end
    rng.shuffle(creators)
    for _, c in ipairs(creators) do
      if placed >= cap then break end
      if rng.chance(c[2]) then
        if place(t, rng, c[1]) then placed = placed + 1 end
      end
    end
  end
  return t
end

-- ============================ ball + ring probe ============================
local ball = {x = CX, y = 128, vx = 0, vy = 0, px = CX, py = 128,
              spin = 0, rot = 0, noflip = true}

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
-- normal + push-out for every (first, last) touching point: the
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
  if ix < 0 or ix >= WW then return WALL end
  if iy < 0 or iy >= WH then return EMPTY end -- open top and bottom
  return cmap[iy * WW + ix]
end

local hits = {}
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
-- 16 states, 3.2 states/frame (0x333), 26.5 deg down -> ~31 deg up
local FL_LEN, FL_RH, FL_RT = 19, 5, 3 -- = the sprite shape
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
end

local function flipper_state_hit(dx, dy, s)
  local ux, uy = FCOS[s], FSIN[s]
  local nux, nuy = uy, -ux
  local t = dx*ux + dy*uy
  local d = math.sqrt(dx*dx + dy*dy)
  if t < 0 then
    if d < FL_RH + BR and d > 0.01 then return dx/d, dy/d, FL_RH + BR - d, d end
  elseif t > FL_LEN then
    local tx, ty = dx - ux*FL_LEN, dy - uy*FL_LEN
    local dt = math.sqrt(tx*tx + ty*ty)
    if dt < FL_RT + BR and dt > 0.01 then return tx/dt, ty/dt, FL_RT + BR - dt, d end
  else
    local lim = FL_RH + (FL_RT - FL_RH) * t / FL_LEN + BR
    local h = dx*nux + dy*nuy
    if h < lim and h > -(lim + 6) then return nux, nuy, lim - h, d end
  end
end

-- swept test from last frame's state to this frame's; first hit wins
local function flipper_collide(f)
  local dx = (ball.x - f.px) * f.dir
  local dy = ball.y - f.py
  if dx < -12 or dx > 30 or dy < -24 or dy > 18 then return false end
  local s, e = f.prev, f.s // 1
  local step = e >= s and 1 or -1
  for st = s, e, step do
    local nx, ny, push, r = flipper_state_hit(dx, dy, st)
    if nx then
      local force = 0
      if f.ds > 0 then force = math.min(15.5 * r, 252) / 256 * f.ds * 4 * TUNE.flip end
      return true, nx * f.dir, ny, push, force
    end
  end
  return false
end

-- ============================ game state ============================
local state = "title" -- title | ready | play | hold | lost | over
local tables = {}      -- generated tables by index (state persists)
local cur              -- current table
local floorIdx = 0     -- checkpoint: falling below this loses the ball
local best = 0
local score, balls, mult = 0, 3, 1
local saver = 0
local holdT, holdObj = 0, nil
local lostT = 0
local msg, msgT = "", 0
local shake, nudgeCool = 0, 0
local frame = 0
local touching, lastNx, lastNy = false, 0, 0
local lflip, rflip = false, false

local function say(m, t) msg, msgT = m, t or 120 end
local function add(p) score = score + p * mult end

local parts = {}
local function sparkle(x, y, n)
  for _ = 1, n or 4 do
    if #parts >= 60 then return end
    parts[#parts + 1] = {x = x, y = y, vx = (math.random() - 0.5) * 2,
      vy = (math.random() - 0.5) * 2 - 0.5, t = 16 + math.random(0, 8)}
  end
end
local fairy = {x = 120, y = 60, tx = 120, ty = 60}

local bake -- forward

local function get_table(idx)
  if not tables[idx] then tables[idx] = generate(idx) end
  return tables[idx]
end

local function enter_table(idx)
  cur = get_table(idx)
  paint_table(cur)
  cur.visited = true
  for i = #parts, 1, -1 do parts[i] = nil end
  best = math.max(best, idx)
  if cur.bonus then floorIdx = math.max(floorIdx, idx) end
  for _, f in ipairs(cur.flippers) do f.s, f.prev, f.ds = 0, 0, 0 end
  bake()
end

local function serve()
  ball.x, ball.y, ball.vx, ball.vy = CX, 129, 0, 0
  ball.noflip, ball.spin = true, 0
  state = "ready"
end

local function new_game(seed)
  masterSeed = seed or (time() // 1) % 100000 + 1
  tables, floorIdx, best = {}, 0, 0
  score, balls, mult, saver = 0, 3, 1, 0
  enter_table(0)
  serve()
end

-- ============================ goals ============================
local function trigger_done(ev)
  if ev.trigger == "ACORN" then return not ev.members[1].alive end
  for _, o in ipairs(ev.members) do if not o.lit then return false end end
  return true
end

local function grant(ev)
  ev.times = ev.times + 1
  local rw = ev.reward
  if rw == "KICKBACK" then cur.kick[1], cur.kick[2] = true, true
  elseif rw == "POSTS" then cur.posts = 30 * 60
  elseif rw == "CENTER" then cur.center = 30 * 60
  elseif rw == "UPDRAFT" then cur.updraft = 15 * 60
  elseif rw == "MULTI" then mult = math.min(9, mult + 1)
  elseif rw == "JACKPOT" then add(5000 * (cur.idx + 1)) end
  add(2500)
  say(REWARD_LABEL[rw] .. "!")
  sparkle(ball.x, ball.y, 8)
  -- re-arm the trigger so the goal can be earned again
  if ev.trigger == "ACORN" then
    local a = ev.members[1]
    a.alive, a.hits, a.respawn = false, 0, 10 * 60
  else
    for _, o in ipairs(ev.members) do o.lit = false end
  end
  local all = true
  for _, e in ipairs(cur.events) do if e.times == 0 then all = false end end
  if all and not cur.cleared then
    cur.cleared = true
    add(10000)
    say("TABLE CLEAR!", 150)
  end
end

local function check_goals()
  for _, ev in ipairs(cur.events) do
    if trigger_done(ev) then grant(ev) end
  end
end

-- ============================ objects ============================
local function capture(o, frames)
  ball.x, ball.y, ball.vx, ball.vy = o.x, o.y, 0, 0
  holdT, holdObj, state = frames, o, "hold"
end

local function post_list()
  local l = {}
  if cur.center > 0 then l[#l + 1] = {x = CENTER_POST.x, y = CENTER_POST.y, r = 4} end
  if cur.posts > 0 then
    for _, side in ipairs({-1, 1}) do
      l[#l + 1] = {x = side_x(KIT.post.dx, side), y = KIT.post.y, r = 4}
    end
  end
  return l
end

-- analytic circle toys: returns the hit object and its normal
local function toy_collide()
  for _, o in ipairs(cur.objs) do
    local def = TOY[o.kind]
    if o.alive and def.r > 0 and o.kind ~= "hole" and o.kind ~= "warp" and o.kind ~= "bud" then
      local dx, dy = ball.x - o.x, ball.y - o.y
      local d = math.sqrt(dx*dx + dy*dy)
      local rr = o.r + BR
      if d < rr and d > 0.01 then
        local nx, ny = dx / d, dy / d
        ball.x, ball.y = o.x + nx * (rr + 0.5), o.y + ny * (rr + 0.5)
        return o, nx, ny
      end
    end
  end
  for _, p in ipairs(post_list()) do
    local dx, dy = ball.x - p.x, ball.y - p.y
    local d = math.sqrt(dx*dx + dy*dy)
    if d < p.r + BR and d > 0.01 then
      local nx, ny = dx / d, dy / d
      ball.x, ball.y = p.x + nx * (p.r + BR + 0.5), p.y + ny * (p.r + BR + 0.5)
      return {kind = "post"}, nx, ny
    end
  end
end

local function rotate(nx, ny, deg)
  local a = math.rad(deg)
  local c, s = math.cos(a), math.sin(a)
  return nx*c - ny*s, nx*s + ny*c
end

-- sensors: rollovers, rings, kickbacks, updraft
local function sensors()
  for _, o in ipairs(cur.objs) do
    if o.kind == "bud" then
      local inside = math.abs(ball.x - o.x) < 5 and math.abs(ball.y - o.y) < 5
      if inside and not o.inside then
        add(100)
        if not o.lit then o.lit = true sparkle(o.x, o.y, 3) end
      end
      o.inside = inside
    elseif (o.kind == "hole" or o.kind == "warp") then
      local d = math.sqrt((ball.x - o.x)^2 + (ball.y - o.y)^2)
      if d < o.r and not o.inside then
        o.inside = true
        add(o.court and 25000 or 2500)
        say(o.kind == "warp" and (o.court and "FAIRY COURT!" or "WARP UP!") or "FAIRY RING")
        sparkle(o.x, o.y, 10)
        capture(o, o.kind == "warp" and 50 or 60)
        return
      end
      if d > o.r + 5 then o.inside = false end
    end
  end
  for i, side in ipairs({-1, 1}) do
    local kx, ky = side_x(KIT.kick.dx, side), KIT.kick.y
    if cur.kick[i] and math.abs(ball.x - kx) < 5 and math.abs(ball.y - ky) < 6 and ball.vy > 0 then
      cur.kick[i] = false
      add(500)
      say("KICKBACK!")
      ball.x, ball.y = kx, ky
      ball.vx, ball.vy = 2.6 * side, -2.4  -- back up the outlane
      shake = 4
    end
  end
  if cur.updraft > 0 and math.abs(ball.x - CX) < 8 and ball.y > 8 and ball.y < 84 then
    ball.vy = math.max(-4.6, ball.vy - 0.35)
  end
end

-- ============================ physics frame ============================
local function physics()
  lflip, rflip = leftHeld(), rightHeld()
  for _, f in ipairs(cur.flippers) do flipper_update(f, f.dir == 1 and lflip or rflip) end
  for _, o in ipairs(cur.objs) do
    o.cool, o.flash = o.cool - 1, o.flash - 1
    if o.kind == "lantern" then
      o.phase = o.phase + 1
      o.x = o.x0 + math.sin(o.phase / 60) * TOY.lantern.travel
    end
    if o.respawn then
      o.respawn = o.respawn - 1
      if o.respawn <= 0 then o.respawn, o.alive = nil, true end
    end
  end
  if state ~= "play" then return end

  -- 1. gravity, clamp
  ball.vy = ball.vy + GRAV
  ball.vx = math.max(-VMAX, math.min(VMAX, ball.vx))
  ball.vy = math.max(-VMAX, math.min(VMAX, ball.vy))
  if ball.noflip and ball.vy > 0 then ball.noflip = false end

  -- 2. walls (ring probe)
  local hit, nx, ny, push, attr, buried = ring_test(ball.x, ball.y)
  local kind = attr
  if buried then
    ball.x, ball.y = ball.px, ball.py
    ball.vx, ball.vy = -ball.vx * 0.5, -ball.vy * 0.5
    hit = false
  elseif hit then
    ball.x, ball.y = ball.x + nx*push, ball.y + ny*push
  end

  -- 3. toys, then flippers (flippers win)
  local o, onx, ony = toy_collide()
  if o then hit, nx, ny, kind = true, onx, ony, o end
  local kick, amp, reset = 0, 0, false
  if not ball.noflip then
    for _, f in ipairs(cur.flippers) do
      local fh, fnx, fny, fpush, force = flipper_collide(f)
      if fh then
        hit, nx, ny, kind = true, fnx, fny, "flipper"
        ball.x, ball.y = ball.x + fnx*fpush, ball.y + fny*fpush
        kick, amp = force, 1
        break
      end
    end
  end

  -- 4. what did we hit?
  if hit then
    if kind == SLING then
      local side = ball.x < CX and -1 or 1
      if (cur.slingCool or 0) <= 0 then
        cur.slingCool = 8
        nx, ny = rotate(nx, ny, side < 0 and -11.25 or 11.25)
        kick, reset = KICK_SLING, true
        add(10)
      end
    elseif type(kind) == "table" then
      local k = kind.kind
      if k == "bumper" or k == "gold" or k == "lantern" then
        if kind.cool <= 0 then
          kind.cool, kind.flash = 6, 8
          kick, reset = KICK_BUMPER, true
          add(k == "gold" and 500 or 100)
          sparkle(ball.x - nx * BR, ball.y - ny * BR, 2)
        end
      elseif k == "toad" then
        amp = 2
        if not kind.lit then kind.lit = true add(250) sparkle(kind.x, kind.y, 4) end
      elseif k == "acorn" then
        amp, kick = 2, 0.8
        if kind.cool <= 0 then
          kind.cool, kind.flash = 12, 6
          kind.hits = kind.hits + 1
          add(150)
          if kind.hits >= 3 then kind.alive = false add(1000) sparkle(kind.x, kind.y, 8) end
        end
      elseif k == "post" then
        amp, kick = 2, KICK_POST
      end
    end
  end
  touching, lastNx, lastNy = hit, nx, ny

  -- 5. response: Infinity-style reset kick, or Pokemon rotate-bounce
  if hit then
    if reset then
      ball.vx, ball.vy = nx * kick, ny * kick
    else
      local tx, ty = -ny, nx
      local vn = ball.vx*nx + ball.vy*ny
      local vt = ball.vx*tx + ball.vy*ty
      if vn < 0 then vn = -vn * (0.25 + 0.125*amp) end
      vn = vn + kick
      ball.vx, ball.vy = vt*tx + vn*nx, vt*ty + vn*ny
      ball.spin = math.max(-127, math.min(127, (vt * 4) // 1))
    end
  end
  if cur.slingCool then cur.slingCool = cur.slingCool - 1 end

  -- 6. move
  ball.px, ball.py = ball.x, ball.y
  ball.x = ball.x + math.max(-STEPMAX, math.min(STEPMAX, ball.vx))
  ball.y = ball.y + math.max(-STEPMAX, math.min(STEPMAX, ball.vy))
  ball.rot = (ball.rot + ball.spin) % 256

  sensors()
  check_goals()
end

-- ============================ table transitions ============================
local function transitions()
  if state ~= "play" then return end
  if ball.y < -6 then -- out of the top: climb
    local nxt = cur.idx + 1
    local fresh = not (tables[nxt] and tables[nxt].visited)
    if fresh then add(1000 * nxt) end
    enter_table(nxt)
    ball.y = ball.y + WH
    ball.noflip = true
    say(cur.bonus and "FAIRY COURT" or ("TABLE " .. nxt))
  elseif ball.y > WH + 6 then -- out of the bottom
    if cur.idx <= floorIdx then
      if saver > 0 then
        say("BALL SAVED")
        saver = 0
        serve()
      else
        state, lostT = "lost", 60
      end
    else
      enter_table(cur.idx - 1)
      ball.y = ball.y - WH
      ball.vx, ball.vy = ball.vx * 0.5, ball.vy * 0.1 -- Infinity's softened drop
      cur.center = math.max(cur.center, 5 * 60)       -- mercy post
      say("DOWN TO " .. cur.idx)
    end
  end
end

-- ============================ game flow ============================
local function update()
  frame = frame + 1
  for i = #parts, 1, -1 do -- particles age here, not in draw
    local p = parts[i]
    p.x, p.y, p.t = p.x + p.vx, p.y + p.vy, p.t - 1
    if p.t <= 0 then table.remove(parts, i) end
  end
  if msgT > 0 then msgT = msgT - 1 end
  if shake > 0 then shake = shake - 1 end
  if nudgeCool > 0 then nudgeCool = nudgeCool - 1 end

  if state == "title" or state == "over" then
    if not vpad then
      for i = 0, 5 do if btnp(i) then new_game() break end end
    end
    return
  end
  if cur.posts > 0 then cur.posts = cur.posts - 1 end
  if cur.center > 0 and not cur.bonus then cur.center = cur.center - 1 end
  if cur.updraft > 0 then cur.updraft = cur.updraft - 1 end
  if saver > 0 and state == "play" then saver = saver - 1 end

  if state == "ready" then
    if leftHeld() or rightHeld() then
      state = "play"
      ball.vy = LAUNCH_VY
      ball.vx = (frame % 7 - 3) * 0.1
      if saver == 0 then saver = 10 * 60 end
    end
  elseif state == "hold" then
    holdT = holdT - 1
    if holdT <= 0 then
      state = "play"
      local o = holdObj
      if o.kind == "warp" then
        local nxt = cur.idx + 1
        enter_table(nxt)
        ball.x, ball.y = CX, WH - 4
        ball.vx, ball.vy = 0, LAUNCH_VY
        ball.noflip = true
        say(cur.bonus and "FAIRY COURT" or ("TABLE " .. nxt))
      else
        local side = o.x < CX and 1 or -1
        ball.vx, ball.vy = 0.9 * side, 1.4 -- eject down toward the flippers
      end
    end
  elseif state == "play" then
    if nudgeHeld() and nudgeCool == 0 then
      nudgeCool, shake = 30, 6
      if touching then
        local f = -2 * lastNy
        if f > 0 then ball.vx, ball.vy = ball.vx + f*lastNx, ball.vy + f*lastNy end
      end
    end
    -- trap safety net (Infinity respawns a stuck ball after 5 s): if the
    -- ball stays inside a 16 px box for 4 s with no flipper held (so a
    -- cradle is fine), pop it out toward the centre
    local tb = ball.trap
    if not tb or lflip or rflip or math.abs(ball.x - tb.x) > 8 or math.abs(ball.y - tb.y) > 8 then
      ball.trap = {x = ball.x, y = ball.y, t = 0}
    else
      tb.t = tb.t + 1
      if tb.t > 240 then
        ball.trap = nil
        ball.vx, ball.vy = (CX - ball.x) * 0.04, -2.2
        ball.traps = (ball.traps or 0) + 1
        say("UNSTUCK")
      end
    end
  elseif state == "lost" then
    lostT = lostT - 1
    if lostT <= 0 then
      balls = balls - 1
      mult = 1
      if balls > 0 then
        if cur.idx ~= floorIdx then enter_table(floorIdx) end
        serve()
      else state = "over" end
    end
  end
end

-- ============================ baking ============================
-- The static art of a table is rendered ONCE (on entering it) from the
-- sprite sheet's texture tiles and saved into map RAM; every frame then
-- starts with a single memcpy.
local T_RIM, T_SLING, T_FLOOR, T_BARK = 16, 17, 64, 66

local function sget(id, x, y) return peek4(0x8000 + id * 64 + y * 8 + x) end
local function tex16(id, x, y)
  local tx, ty = x % 16, y % 16
  return sget(id + (tx // 8) + (ty // 8) * 16, tx % 8, ty % 8)
end

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

local slingRim = {{}, {}}
local DECOR = {14, 15, 24, 25, 26, 27}

local HUD_X = WW

local function bake_hud()
  for y = 0, 135 do
    for x = HUD_X, 239 do pix(x, y, tex16(T_BARK, x, y)) end
  end
  rect(HUD_X + 3, 3, 240 - HUD_X - 6, 130, C_KEY)
  rectb(HUD_X + 2, 2, 240 - HUD_X - 4, 132, C_MOSS)
  print("FAIRY", HUD_X + 7, 7, C_OUT) print("FAIRY", HUD_X + 6, 6, C_PINK)
  print("RING", HUD_X + 41, 7, C_OUT) print("RING", HUD_X + 40, 6, C_GOLD)
  print("SCORE", HUD_X + 6, 17, C_LILAC, false, 1, true)
  print("GOALS", HUD_X + 6, 58, C_LILAC, false, 1, true)
end

bake = function()
  local solid = function(a) return a ~= EMPTY end
  local dOpen = dist_field(function(a) return a == EMPTY end, 6)
  local dWall = dist_field(solid, 6)
  local rng = RNG(masterSeed + cur.idx * 31)
  cls(0)
  slingRim = {{}, {}}
  for y = 0, WH - 1 do
    for x = 0, WW - 1 do
      local i = y * WW + x
      local a, c = cmap[i]
      if a == EMPTY then
        local dw = dWall[i]
        c = dw <= 2 and sget(T_RIM, (x + y) % 8, 3 + dw) or tex16(T_FLOOR, x, y)
      elseif a == SLING then
        if dOpen[i] == 1 then
          local l = slingRim[x < CX and 1 or 2]
          l[#l + 1] = i
          c = C_GOLD
        else c = sget(T_SLING, x % 8, y % 8) end
      else
        local de = dOpen[i]
        c = de <= 4 and sget(T_RIM, (x + y) % 8, de - 1) or tex16(T_BARK, x, y)
      end
      pix(x, y, c)
    end
  end
  -- decorations on the wall mass (never on the playfield)
  for _ = 1, 40 do
    local x, y = rng.int(WW - 8), rng.int(WH - 8)
    if dOpen[(y + 4) * WW + x + 4] >= 5 and dOpen[y * WW + x] >= 2 and dOpen[(y + 7) * WW + x + 7] >= 2 then
      spr(rng.pick(DECOR), x, y, 0)
    end
  end
  -- top exit chevrons
  for k = 0, 2 do
    local y = 2 + k * 4
    for dx = -3, 3 do pix(CX + dx, y + math.abs(dx), C_FLOORL) end
  end
  bake_hud()
  memcpy(SNAP, 0, SCRBYTES)
end

-- ============================ drawing ============================
local function palswap(a, b) poke4(0x3FF0 * 2 + a, b) end
local function palreset() for i = 0, 15 do poke4(0x3FF0 * 2 + i, i) end end

local function draw_flipper(f)
  local k = (f.s // 1) // 2
  local id = 256 + (k // 4) * 48 + (k % 4) * 4
  if f.dir == 1 then spr(id, f.px - 6, f.py - 12, 0, 1, 0, 0, 4, 3)
  else spr(id, f.px - 25, f.py - 12, 0, 1, 1, 0, 4, 3) end
end

local function draw_world()
  local sx = (shake > 0) and (frame % 2 * 2 - 1) or 0
  memcpy(0, SNAP, SCRBYTES)

  for _, o in ipairs(cur.objs) do
    local x, y = o.x + sx, o.y
    if o.kind == "bumper" then
      spr(o.flash > 0 and 34 or 32, x - 8, y - 8 - (o.flash > 0 and 1 or 0), 0, 1, 0, 0, 2, 2)
    elseif o.kind == "gold" then
      spr(o.flash > 0 and 108 or 106, x - 8, y - 8, 0, 1, 0, 0, 2, 2)
    elseif o.kind == "lantern" then
      spr((frame // 8) % 2 == 0 and 96 or 98, x - 8, y - 7, 0, 1, 0, 0, 2, 2)
    elseif o.kind == "toad" then
      spr(o.lit and 38 or 36, x - 8, y - 9, 0, 1, 0, 0, 2, 2)
    elseif o.kind == "acorn" then
      if o.alive then spr(100 + math.min(2, o.hits) * 2, x - 8, y - 7, 0, 1, 0, 0, 2, 2) end
    elseif o.kind == "bud" then
      spr(o.lit and 11 or 10, x - 4, y - 4, 0)
    elseif o.kind == "hole" or o.kind == "warp" then
      if o.kind == "warp" then palswap(C_CYAN, C_PINK) palswap(C_LILAC, C_GOLD) end
      spr(44 + ((frame // 12) % 2) * 2, x - 8, y - 8, 0, 1, 0, 0, 2, 2)
      palreset()
    end
  end
  -- kit: kickback arrows, posts, updraft
  for i, side in ipairs({-1, 1}) do
    local lit = cur.kick[i] and (frame // 10) % 2 == 0
    spr(lit and 13 or 12, side_x(KIT.kick.dx, side) - 4, KIT.kick.y - 6, 0)
  end
  for _, p in ipairs(post_list()) do
    local blink = (cur.posts < 120 and cur.posts > 0 and p.y < 100) or
                  (cur.center < 120 and p.y > 100 and not cur.bonus)
    if not blink or frame % 8 < 5 then spr(30, p.x - 4, p.y - 4, 0) end
  end
  if cur.updraft > 0 then
    for y = 12, 80, 10 do
      local oy = (y - frame) % 70 + 12
      spr(28, CX - 4, oy, 0)
    end
  end
  for si, l in ipairs(slingRim) do
    if (cur.slingCool or 0) > 3 and ((si == 1) == (ball.x < CX)) then
      for _, i in ipairs(l) do pix(i % WW + sx, i // WW, C_WHITE) end
    end
  end
  for _, f in ipairs(cur.flippers) do draw_flipper(f) end

  local bx, by = ball.x // 1 + sx, ball.y // 1
  if state ~= "lost" and not (state == "hold" and holdT % 6 < 3) then
    spr((ball.rot // 64) % 4, bx - 4, by - 4, 0)
  end
  for _, p in ipairs(parts) do
    spr(4 + (3 - math.min(3, p.t // 6)), p.x - 4 + sx, p.y - 4, 0)
  end
  local fy = fairy.y + math.sin(frame / 20) * 2
  spr(40 + ((frame // 6) % 2) * 2, fairy.x - 8 + sx, fy - 8, 0, 1,
      fairy.tx < fairy.x and 1 or 0, 0, 2, 2)
end

local TRIG_SPR = {BUDS = 10, TOADS = 36, ACORN = 100}

local function draw_hud()
  local hx = HUD_X + 6
  print(string.format("%8d", score), hx, 24, C_WHITE, true, 1, false)
  for i = 1, 3 do spr(i <= balls and 0 or 9, hx + (i - 1) * 9, 33, 0) end
  if mult > 1 then print("x" .. mult, hx + 30, 35, C_GOLD, false, 1, true) end
  if saver > 0 and (saver > 120 or frame % 16 < 8) then print("SAVE", hx + 52, 35, C_CYAN, false, 1, true) end
  print("TABLE " .. cur.idx, hx, 45, cur.bonus and C_GOLD or C_LIME, false, 1, true)
  if floorIdx > 0 then print("FLOOR " .. floorIdx, hx + 40, 45, C_LILAC, false, 1, true) end
  -- goals: trigger -> reward with progress
  local y = 66
  if #cur.events == 0 then
    print(cur.bonus and "HIT THE RING" or "CLIMB!", hx, y, C_LILAC, false, 1, true)
  end
  for _, ev in ipairs(cur.events) do
    local n, tot = 0, #ev.members
    if ev.trigger == "ACORN" then n, tot = ev.members[1].hits, 3
      if not ev.members[1].alive then n = 3 end
    else for _, o in ipairs(ev.members) do if o.lit then n = n + 1 end end end
    local c = ev.times > 0 and C_LIME or C_WHITE
    print(ev.trigger .. " " .. n .. "/" .. tot, hx, y, c, false, 1, true)
    print(">" .. REWARD_LABEL[ev.reward], hx + 4, y + 7, ev.times > 0 and C_LIME or C_GOLD, false, 1, true)
    y = y + 16
  end
  -- the tower: tables around this one
  for k = -3, 3 do
    local idx = cur.idx + k
    if idx >= 0 then
      local ty = 104 - k * 5
      local t = tables[idx]
      local c = C_FLOOR
      if t and t.cleared then c = C_LIME elseif t and t.visited then c = C_MOSS end
      if is_bonus(idx) then c = C_GOLD end
      rect(229, ty, 6, 4, c)
      if k == 0 then rectb(228, ty - 1, 8, 6, C_WHITE) end
    end
  end
  if msgT > 0 and (msgT > 30 or frame % 8 < 4) then
    print(msg, hx, 127, C_GOLD, false, 1, true)
  elseif state == "ready" and frame % 40 < 30 then
    print("FLIP TO LAUNCH", hx, 127, C_LILAC, false, 1, true)
  end
  if state == "title" or state == "over" then
    rect(15, 46, 120, 40, C_KEY) rectb(15, 46, 120, 40, C_PINK) rectb(17, 48, 116, 36, C_MOSS)
    local t = state == "over" and "GAME OVER" or "FAIRY RING"
    print(t, CX - #t * 3, 54, C_GOLD)
    if state == "over" then print("REACHED TABLE " .. best, CX - 33, 64, C_LILAC, false, 1, true) end
    if frame % 40 < 28 then print("PRESS Z OR X", CX - 35, 74, C_LILAC) end
  end
end

local function update_fairy()
  if state == "play" then fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
  else fairy.tx, fairy.ty = CX + 40 + math.cos(frame / 70) * 10, 30 + math.sin(frame / 50) * 6 end
  fairy.x = fairy.x + (fairy.tx - fairy.x) * 0.04
  fairy.y = fairy.y + (fairy.ty - fairy.y) * 0.04
end

-- ============================ main ============================
function BOOT()
  masterSeed = 1
  enter_table(0)
  serve()
  state = "title"
end

function TIC()
  update()
  if state ~= "title" and state ~= "over" then physics() end
  transitions()
  update_fairy()
  draw_world()
  draw_hud()
end

-- test hook for the headless harness (harmless in the real cart)
FR = {
  ball = ball, cmap = cmap, WW = WW, WH = WH, CX = CX, TOY = TOY,
  set_pad = function(p) vpad = p end,
  get = function() return state, score, balls, cur.idx, saver, mult end,
  cur = function() return cur end,
  tables = function() return tables end,
  generate = generate, paint = paint_table, enter = enter_table,
  new_game = new_game, physics = physics, update = update,
  transitions = transitions, ring_test = ring_test,
  force_state = function(s) state = s end,
  floor = function() return floorIdx end,
  tic_draw = function() update_fairy() draw_world() draw_hud() end,
}
