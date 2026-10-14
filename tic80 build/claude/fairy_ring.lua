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
--    flippers. Bumpers and slingshots use Pokemon's ADDITIVE rule: a 1/4
--    bounce, then a fixed push along the normal (the old Infinity "reset
--    velocity, fixed kick" rule is still available as TUNE.kick = "reset").

-- ============================ constants ============================
local GRAV    = 0.06     -- px/frame^2 (Infinity: 34.3 u/s^2 at 6.8 px/u)
local VMAX    = 7.99     -- per-axis velocity clamp
local STEPMAX = 4.996    -- per-axis movement clamp: the ring can't skip 5px walls
local BR      = 4        -- ball radius = ring probe radius
local WW, WH  = 150, 136 -- one table = one screen (22 x 20 Infinity units)
local CX      = 75       -- table centre line
local SNAP    = 0x8000   -- map RAM: baked background of the current table
local SCRBYTES = 16320
-- game-over art (art/import_gameover.py, packed by build.py): the image in
-- the 2nd half of map RAM, one 16-colour palette per scanline in music-
-- pattern RAM (no music yet), the game's own palette saved right after
local OVER_IMG = SNAP + SCRBYTES
local OVER_PAL = 0x11164
local GAME_PAL = OVER_PAL + 136 * 48

-- tuned feel (px/frame)
-- kicker strengths per rule: "add" = Pokemon (bounce 1/4 + push),
-- "reset" = Infinity (zero the velocity, then push)
local KICKS = {
  add   = {bumper = 2.0, sling = 2.0},  -- Pokemon: +$0200 along the normal
  reset = {bumper = 2.2, sling = 1.6},  -- Infinity: 18.75 / 12.5 u/s
}
local KICK_POST   = 1.2
-- scales Pokemon's flipper lever impulse; global so tests can sweep it
TUNE = {flip = 0.6, kick = "add"}
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
  -- the guide's lower leg is flush with the RESTING flipper's top surface
  -- (26.5 deg, tangent to the hub) offset by its own radius, and it runs
  -- into the hub: no notch beside the pivot for the ball to sit in
  guide = {57,88, 57,98.4, 21,116.4},       -- capsule chain, r = 2
                                            -- (ends 4 px past the pivot, so a
                                            -- cradled ball rests on the flipper
                                            -- body, not balanced on the hub)
  sling = {43,72, 43,90, 33,94},            -- triangle; face = pt1 -> pt3
                                            -- (inlane under it stays 14+ px wide)
  pivot = {dx = 25, y = 118},
  kick  = {dx = 64, y = 102},               -- kickback: in the straight part
                                            -- of the outlane, fires straight up
  post  = {dx = 64, y = 86},                -- outlane side post (blocker)
}
local CENTER_POST = {x = CX, y = 131}

-- ============================ toy catalogue ============================
-- r = collision radius, m = placement clearance margin (Infinity's
-- ObjectPlacement radius, scaled 6.8 px/unit), notc = keep off the centre
local TOY = {
  bumper  = {r = 6, m = 14, notc = true, kicker = true},
  gold    = {r = 6, m = 14, notc = true, kicker = true}, -- score bumper
  pixie   = {r = 5, m = 16, travel = 14, kicker = true}, -- moving; bursts
  hole    = {r = 4, m = 12, notc = true},   -- fairy ring: hold + eject
  well    = {r = 5, m = 14, notc = true},   -- wishing well: roulette, ejects down
  acorn   = {r = 5, m = 13},                -- bash toy (3 hits)
  shroom  = {r = 6, m = 24, clear = 16},    -- mushroom colony (big stage)
  small   = {r = 3, m = 0},                 -- colony stage 2 (spawned)
  spore   = {r = 0, m = 0},                 -- colony stage 3 rollover (spawned)
  bud     = {r = 0, m = 7},                 -- rollover sensor (groups of 3)
}
local CATCHER = {hole = true, well = true} -- capture the ball

-- goal definitions: trigger -> reward (Infinity's event model)
local TRIGGERS = {  -- weight = Infinity trigger chance %
  {kind = "BUDS", w = 50}, {kind = "ACORN", w = 62}, {kind = "SHROOM", w = 40},
}
local REWARDS = {   -- weight = Infinity event chance %
  {kind = "KICKBACK", w = 50}, {kind = "POSTS", w = 50},
  {kind = "CENTER", w = 72}, {kind = "UPDRAFT", w = 50},
  {kind = "MULT", w = 41}, {kind = "JACKPOT", w = 29}, {kind = "MULTIBALL", w = 38},
}
-- BUDS always summon the bonus FAIRY (not in the random reward pool)
local REWARD_LABEL = {KICKBACK = "KICKBACK", POSTS = "SIDE POSTS",
  CENTER = "CENTER POST", UPDRAFT = "UPDRAFT", MULT = "MULT +1", JACKPOT = "JACKPOT",
  MULTIBALL = "MULTIBALL", FAIRY = "FAIRY"}
local TRIGGER_LABEL = {BUDS = "BUDS", ACORN = "ACORN", SHROOM = "SHROOMS"}

-- ============================ table generation ============================
local masterSeed = 1
local bossRush = false
local function is_bonus(idx)
  return bossRush and (idx % 2 == 1) or (idx > 0 and (idx + 1) % 10 == 0)
end
-- players see LEVEL idx+1 (level 10, 20, ... are the fairy levels) and a
-- short table code from (seed, level) so a table can be named / replayed
local B36 = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"
local function code4(n)
  local out = ""
  for _ = 1, 4 do
    local d = n % #B36
    out = B36:sub(d + 1, d + 1) .. out
    n = n // #B36
  end
  return out
end
local function tcode(idx)
  return "T" .. code4((((masterSeed * 2654435761) ~ (idx * 40503 + 977)) & 0xFFFFFF))
end

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
  if not cmap_clear(x, y, (def.clear or def.r) + GAP) then return false end
  if def.travel then
    for dx = -def.travel, def.travel, 4 do
      if not cmap_clear(x + dx, y, def.r + BR + 2) then return false end
    end
  end
  local ring = def == TOY.hole or def == TOY.well
  if ring then
    local rings = 0
    for _, o in ipairs(t.objs) do if CATCHER[o.kind] then rings = rings + 1 end end
    if rings >= 2 then return false end -- Infinity: max 2 hold holes per table
  end
  for _, o in ipairs(t.objs) do
    local od = TOY[o.kind]
    local need = math.max(def.m, od.m) + (extra or 0)
    if ring and CATCHER[o.kind] then need = math.max(need, 36) end
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
  -- poo piles on some drains (Infinity's electric fences), ramped in so
  -- the early levels are friendly: none on levels 1-2, then centre/outlane
  -- 25/10% up to level 5, 40/20% up to level 9, Infinity's 50/25% after;
  -- never on fairy levels
  t.poo = {}
  local cP, oP = 0, 0
  if idx >= 2 and not t.bonus then
    if idx < 5 then cP, oP = 25, 10 elseif idx < 9 then cP, oP = 40, 20 else cP, oP = 50, 25 end
  end
  if rng.chance(cP) then t.poo[#t.poo + 1] = {x = CX, y = 132, off = 0} end
  for _, side in ipairs({-1, 1}) do
    if rng.chance(oP) then t.poo[#t.poo + 1] = {x = side_x(KIT.kick.dx - 28.5, side), y = 132, off = 0} end
  end
  -- keep the kit zone out of the scatter grid
  for i = #t.grid, 1, -1 do if t.grid[i].y > 76 then table.remove(t.grid, i) end end

  -- 3. piece slots: upper flipper (45%), alcove hole
  for si, side in ipairs({-1, 1}) do
    local pc = side < 0 and t.left or t.right
    if pc.flipper and not gentle and not t.bonus and rng.chance(45) then -- (fairy level: rings there)
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
    -- fairy queen boss level:
    -- 1. Queen flies down and lands with screen shake (shake = 14).
    -- 2. First hit: evolves / flickers into big multiframe fairy.
    -- 3. Second hit: summons shield ring of 5 circling fairies.
    -- 4. Destroying all 5 shield fairies makes queen core vulnerable.
    -- 5. Final hit devolves queen, spawns center updraft ramp, clears brambles, grants checkpoint + extra ball.
    local landX = rng.int(CX - 18, CX + 18)
    local landY = rng.int(38, 46)
    t.queen = {
      x = landX, y = WH + 16,
      landX = landX, landY = landY,
      apexY = landY - 14,
      state = "fly_in",
      landed = false,
      flyDown = false,
      vx = 0, vy = 0, moveT = 0,
      t = 0, cool = 0, flash = 0,
      tier = idx // (bossRush and 2 or 10),
      minions = {},
      shieldInvuln = 0,
      crater = nil
    }
    t.brambles = {}
    -- 2 layers of thorny brambles covering the top exit hole (x = 45 to 105, CX = 75)
    -- Layer 1 (lower, y = 12): 5 segments across x = 45..105 (centers at 51, 63, 75, 87, 99)
    for _, bx in ipairs({51, 63, 75, 87, 99}) do
      t.brambles[#t.brambles + 1] = {x = bx, y = 12, w = 12, layer = 1, hp = 1}
    end
    -- Layer 2 (upper, y = 6): 5 segments across x = 45..105
    for _, bx in ipairs({51, 63, 75, 87, 99}) do
      t.brambles[#t.brambles + 1] = {x = bx, y = 6, w = 12, layer = 2, hp = 1}
    end
    return t
  end

  -- 4. goals: 1 on gentle tables, else 1-3 (Infinity: Next(3)+1)
  local nGoals = gentle and 1 or 1 + rng.int(3)
  local usedReward, usedTrigger, centreTaken = {}, {}, false
  for _ = 1, nGoals do
    local tr = weighted(rng, TRIGGERS, function(e)
      return not usedTrigger[e.kind] and not (gentle and e.kind == "ACORN" and idx == 0)
    end)
    local rw
    if tr and tr.kind == "BUDS" then
      rw = {kind = "FAIRY"} -- rollovers always summon the bonus fairy
    else
      rw = weighted(rng, REWARDS, function(e)
        if usedReward[e.kind] then return false end
        if e.kind == "UPDRAFT" and (gentle or centreTaken) then return false end
        if e.kind == "MULTIBALL" and idx < 2 then return false end
        return true
      end)
    end
    if rw and tr then
      local members
      if tr.kind == "BUDS" then members = place(t, rng, "bud", 3, 13)
      elseif tr.kind == "SHROOM" then members = place(t, rng, "shroom")
      else members = place(t, rng, "acorn") end
      if members then
        usedReward[rw.kind], usedTrigger[tr.kind] = true, true
        if rw.kind == "UPDRAFT" then
          centreTaken = true
          claim(t, CX, 40, 18) -- keep the wind column clear
        end
        local ev = {trigger = tr.kind, reward = rw.kind, members = members,
          times = 0, stage = 1, smalls = {}, spores = {}}
        for _, m in ipairs(members) do m.ev = ev end
        t.events[#t.events + 1] = ev
      end
    end
  end

  -- 5. free toys: shuffled creators, each rolls its chance, up to a cap
  local cap = gentle and 3 or 4 + rng.int(4)
  local creators = {{"bumper", 85}, {"pixie", 65}, {"pixie", 65},
                    {"gold", 35}, {"hole", 15}}
  if not gentle then creators[#creators + 1] = {"well", 12} end
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
-- `ball` is the ball being simulated right now; physics() points it at
-- each ball in turn. mainBall is the player's ball, extras = multiball.
local mainBall = ball
local extras = {}

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
    -- Pokemon uses 1 + ...: a 1 px minimum push suits its 16 px ball but
    -- makes our 8 px ball visibly bob when resting, so the minimum is 0.4
    RUN[s*16+e] = {-math.cos(mid), -math.sin(mid), 0.4 + 4*(1 - math.cos(half))}
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

-- ============================ wall distance field ============================
-- Pokemon's 16-point ring samples whole pixels, so on an 8 px ball the
-- contact normal jumps in 22.5 deg steps as the ball drifts sub-pixel:
-- a resting ball jiggles. Walls therefore use a signed distance field,
-- built once per table (8SSEDT), sampled bilinearly: smooth normals and
-- exact penetration depth. (The ring stays for tests/diagnostics.)
local SD, NATTR = {}, {}

local function edt(src) -- nearest source pixel for every pixel
  local nx, ny = {}, {}
  for y = 0, WH - 1 do
    for x = 0, WW - 1 do
      local i = y * WW + x
      if src(cmap[i]) then nx[i], ny[i] = x, y else nx[i], ny[i] = -9999, -9999 end
    end
  end
  local function try(i, x, y, j)
    local cx, cy = nx[j], ny[j]
    local d = (cx - x)^2 + (cy - y)^2
    if d < (nx[i] - x)^2 + (ny[i] - y)^2 then nx[i], ny[i] = cx, cy end
  end
  for y = 0, WH - 1 do
    for x = 0, WW - 1 do
      local i = y * WW + x
      if x > 0 then try(i, x, y, i - 1) end
      if y > 0 then
        try(i, x, y, i - WW)
        if x > 0 then try(i, x, y, i - WW - 1) end
        if x < WW - 1 then try(i, x, y, i - WW + 1) end
      end
    end
    for x = WW - 2, 0, -1 do local i = y * WW + x try(i, x, y, i + 1) end
  end
  for y = WH - 1, 0, -1 do
    for x = WW - 1, 0, -1 do
      local i = y * WW + x
      if x < WW - 1 then try(i, x, y, i + 1) end
      if y < WH - 1 then
        try(i, x, y, i + WW)
        if x < WW - 1 then try(i, x, y, i + WW + 1) end
        if x > 0 then try(i, x, y, i + WW - 1) end
      end
    end
    for x = 1, WW - 1 do local i = y * WW + x try(i, x, y, i - 1) end
  end
  return nx, ny
end

local function build_sdf()
  local sx, sy = edt(function(a) return a ~= EMPTY end)
  local ex, ey = edt(function(a) return a == EMPTY end)
  for y = 0, WH - 1 do
    for x = 0, WW - 1 do
      local i = y * WW + x
      if cmap[i] == EMPTY then
        SD[i] = math.sqrt((sx[i] - x)^2 + (sy[i] - y)^2) - 0.5
        local ax, ay = sx[i], sy[i]
        NATTR[i] = (ax >= 0) and cmap[ay * WW + ax] or WALL
      else
        SD[i] = -(math.sqrt((ex[i] - x)^2 + (ey[i] - y)^2) - 0.5)
        NATTR[i] = cmap[i]
      end
    end
  end
end

local function sd_at(x, y) -- bilinear, pixel centres at i + 0.5
  local px, py = x - 0.5, y - 0.5
  local ix, iy = px // 1, py // 1
  local fx, fy = px - ix, py - iy
  local function g(cx, cy)
    if cx < 0 or cx >= WW then return -3 end -- solid beyond the sides
    if cy < 0 then cy = 0 elseif cy >= WH then cy = WH - 1 end
    return SD[cy * WW + cx]
  end
  local a, b = g(ix, iy), g(ix + 1, iy)
  local c, d = g(ix, iy + 1), g(ix + 1, iy + 1)
  return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
end

-- returns hit, nx, ny, push, attr  (same shape as ring_test)
local function sdf_test(bx, by)
  if by < -BR or by > WH + BR then return false end
  local d = sd_at(bx, by)
  if d >= BR then return false end
  local gx = sd_at(bx + 0.5, by) - sd_at(bx - 0.5, by)
  local gy = sd_at(bx, by + 0.5) - sd_at(bx, by - 0.5)
  local l = math.sqrt(gx * gx + gy * gy)
  if l < 1e-6 then return false end
  local ix = math.max(0, math.min(WW - 1, bx // 1))
  local iy = math.max(0, math.min(WH - 1, by // 1))
  return true, gx / l, gy / l, BR - d, NATTR[iy * WW + ix]
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
    -- a true solid: a ball above the flipper's centre line is pushed up,
    -- one below it is pushed DOWN. (Pokemon treats 14 px under the top
    -- surface as "inside" and pushes up, which scooped draining balls
    -- back up through the flipper; the swept state test already stops
    -- fast flips from passing through the ball.)
    local lim = FL_RH + (FL_RT - FL_RH) * t / FL_LEN + BR
    local h = dx*nux + dy*nuy
    if h >= 0 and h < lim then return nux, nuy, lim - h, d end
    if h < 0 and h > -lim then return -nux, -nuy, lim + h, d end
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
local holdT, holdObj, lostT, overT = 0, nil, 0, 0
local msg, msgT = "", 0
local shake, nudgeCool = 0, 0
local frame = 0
local touching, lastNx, lastNy = false, 0, 0
local lflip, rflip = false, false
local lostRespawn = "floor" -- where a lost ball comes back: "floor" or "here"
local aimT, aimArmed = 0, false
local AIM_SPEED = 0.07      -- radians per frame (a lap is ~1.5 s)
-- per-run analytics, shown on the game-over screen and saved to pmem
local run = {}
local function lvstat(idx)
  run[idx] = run[idx] or {t = 0, loss = 0, drop = 0, climb = 0, clear = nil}
  return run[idx]
end

local function say(m, t) msg, msgT = m, t or 120 end
local parts = {}
local function sparkle(x, y, n, dust)
  for _ = 1, n or 4 do
    if #parts >= 40 then return end
    parts[#parts + 1] = {x = x, y = y, vx = (math.random() - 0.5) * (dust and 1.4 or 2),
      vy = (math.random() - 0.5) * 2 - (dust and 0.2 or 0.5),
      t = (dust and 22 or 16) + math.random(0, 8), dust = dust}
  end
end
-- scoring makes sparkles at the ball: more points, more sparkles
local function add(p, x, y)
  local v = p * mult
  score = score + v
  local n = v < 150 and 2 or v < 600 and 3 or v < 1500 and 5 or v < 4000 and 7
    or v < 10000 and 9 or v < 30000 and 12 or 16
  sparkle(x or ball.x, y or ball.y, n)
end
-- the fairy: follows the ball; when summoned (BUDS) she glows and
-- flutters around the table, hit her with a ball for a big bonus
local fairy = {x = CX + 14, y = 115, tx = CX + 14, ty = 115, mode = "follow", t = 0, tier = 0}

local function boss_active()
  for _, t in pairs(tables) do
    if t.bonus and t.queen and t.queen.landed and not t.queen.gone then return true end
  end
  return false
end

local bake -- forward

local function get_table(idx)
  if not tables[idx] then tables[idx] = generate(idx) end
  return tables[idx]
end

local function enter_table(idx)
  if cur and cur.idx ~= idx then lvstat(cur.idx).leftAt = nil end
  cur = get_table(idx)
  paint_table(cur)
  build_sdf()
  cur.visited = true
  for i = #parts, 1, -1 do parts[i] = nil end
  if fairy.mode == "bonus" then fairy.mode = "follow" end -- she stays behind
  best = math.max(best, idx)
  lvstat(idx).enter = lvstat(idx).t
  for _, f in ipairs(cur.flippers) do f.s, f.prev, f.ds = 0, 0, 0 end
  bake()
end

local function serve()
  extras = {}
  ball.x, ball.y, ball.vx, ball.vy = CX, 129, 0, 0
  ball.noflip, ball.spin, ball.above = true, 0, false
  state = "ready"
  -- every new ball: a 5 s centre post; level 1 always re-lights its kickbacks
  cur.center = math.max(cur.center, 5 * 60)
  if cur.idx == 0 then cur.kick[1], cur.kick[2] = true, true end
end

local function new_game(seed)
  memcpy(0x3FC0, GAME_PAL, 48) -- back from the game-over palettes
  masterSeed = seed or ((tstamp() * 31 + time() // 1) % 1679615) + 1
  tables, floorIdx, best, run = {}, 0, 0, {}
  score, balls, mult, saver = 0, bossRush and 1 or 3, 1, 0
  fairy.tier = 0
  fairy.mode = "follow"
  fairy.x, fairy.y = CX + 14, 115
  fairy.tx, fairy.ty = CX + 14, 115
  enter_table(0)
  serve()
end

-- ============================ goals ============================
local function trigger_done(ev)
  if ev.trigger == "ACORN" then return not ev.members[1].alive end
  if ev.trigger == "SHROOM" then return ev.stage == 4 end
  for _, o in ipairs(ev.members) do if not o.lit then return false end end
  return true
end

local function spawn_extra(x, vx)
  extras[#extras + 1] = {x = x, y = WH - 4, vx = vx, vy = LAUNCH_VY, px = x, py = WH - 4,
    spin = 0, rot = 0, noflip = true}
end

local function grant_reward(rw)
  if rw == "KICKBACK" then cur.kick[1], cur.kick[2] = true, true
  elseif rw == "POSTS" then cur.posts = 30 * 60
  elseif rw == "CENTER" then cur.center = 30 * 60
  elseif rw == "UPDRAFT" then cur.updraft = 15 * 60
  elseif rw == "MULT" then mult = math.min(9, mult + 1)
  elseif rw == "JACKPOT" then add(5000 * (cur.idx + 1))
  elseif rw == "MULTIBALL" then spawn_extra(CX - 10, -0.4) spawn_extra(CX + 10, 0.4)
  elseif rw == "FAIRY" then
    if not boss_active() then
      fairy.mode, fairy.t = "bonus", 20 * 60
      fairy.tx, fairy.ty = CX, 40
    else
      return
    end
  end
  say(REWARD_LABEL[rw] .. "!")
end

local function remove_objs(list)
  for _, o in ipairs(list) do
    for i = #cur.objs, 1, -1 do if cur.objs[i] == o then table.remove(cur.objs, i) end end
  end
end

local function grant(ev)
  ev.times = ev.times + 1
  add(2500)
  grant_reward(ev.reward)
  -- re-arm the trigger so the goal can be earned again
  if ev.trigger == "ACORN" then
    local a = ev.members[1]
    a.alive, a.hits, a.respawn = false, 0, 10 * 60
  elseif ev.trigger == "SHROOM" then
    ev.regrow = 10 * 60 -- the colony grows back
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

-- edge-triggered: pay out once when the trigger completes, re-arm only
-- after it has reset (a broken acorn stays "done" until it regrows, so a
-- level check paid out every frame for 10 s: score and sparkle explosion)
local function check_goals()
  for _, ev in ipairs(cur.events) do
    local done = trigger_done(ev)
    if done and ev.armed ~= false then
      ev.armed = false
      grant(ev)
    elseif not done then
      ev.armed = true
    end
  end
end

-- ============================ objects ============================
-- mushroom colony: 1 big -> 3 small; each popped small leaves a spore
-- rollover in its spot; light all 3 spores -> done; later the spores
-- regrow into small mushrooms (stage 2 again)
local function colony_obj(ev, kind, x, y)
  local o = {kind = kind, x = x, y = y, x0 = x, r = kind == "small" and 3 or 0, alive = true,
    cool = 0, flash = 0, hits = 0, phase = 0, lit = false, ev = ev}
  cur.objs[#cur.objs + 1] = o
  return o
end

local function colony_grow_smalls(ev)
  local big = ev.members[1]
  remove_objs(ev.smalls)
  remove_objs(ev.spores)
  ev.smalls, ev.spores, ev.stage = {}, {}, 2
  for k = 0, 2 do
    local a = math.rad(-90 + k * 120)
    ev.smalls[#ev.smalls + 1] = colony_obj(ev, "small", big.x + math.cos(a) * 12, big.y + math.sin(a) * 12)
  end
end

local function colony_next(ev)
  if ev.stage == 1 then colony_grow_smalls(ev) end
end

local function colony_progress(ev) -- 0..7 for the HUD
  if ev.stage == 1 then return 0 end
  if ev.stage == 4 then return 7 end
  local n = 1
  for _, o in ipairs(ev.smalls) do if not o.alive then n = n + 1 end end
  for _, o in ipairs(ev.spores) do if o.lit then n = n + 1 end end
  return n
end

local function capture(o, frames)
  ball.x, ball.y, ball.vx, ball.vy = o.x, o.y, 0, 0
  holdT, holdObj, state = frames, o, "hold"
end

-- levels at or below the checkpoint keep their drain and outlanes blocked
local function protected() return floorIdx > 0 and cur.idx <= floorIdx end

local function post_list()
  local l = {}
  local guard = protected()
  if cur.center > 0 or guard then l[#l + 1] = {x = CENTER_POST.x, y = CENTER_POST.y, r = 4} end
  if cur.posts > 0 or guard then
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
    if o.alive and def.r > 0 and not CATCHER[o.kind] then
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
  if cur.brambles then
    for _, b in ipairs(cur.brambles) do
      if b.hp > 0 then
        local cx = math.max(b.x - b.w / 2, math.min(b.x + b.w / 2, ball.x))
        local cy = b.y
        local dx, dy = ball.x - cx, ball.y - cy
        local d = math.sqrt(dx*dx + dy*dy)
        local r = 3 + BR
        if (d < r and d > 0.01) or (ball.vy < 0 and math.abs(ball.x - b.x) <= b.w / 2 + BR and ball.y < b.y + r and (ball.py or ball.y) >= b.y - 2) then
          local nx, ny
          if d > 0.01 and dy >= 0 then
            nx, ny = dx / d, dy / d
          else
            nx, ny = 0, 1
          end
          ball.y = math.max(ball.y, cy + r + 0.5)
          return {kind = "bramble", bramble = b}, nx, ny
        end
      end
    end
  end
  local q = cur.queen
  if q and not q.gone then
    if (q.state == "shield" or q.state == "evolving") and q.minions then
      for _, m in ipairs(q.minions) do
        if m.alive then
          local dx, dy = ball.x - m.x, ball.y - m.y
          local d = math.sqrt(dx*dx + dy*dy)
          local mr = 6
          if d < mr + BR and d > 0.01 then
            local nx, ny = dx / d, dy / d
            ball.x, ball.y = m.x + nx * (mr + BR + 0.5), m.y + ny * (mr + BR + 0.5)
            return {kind = "minion", minion = m}, nx, ny
          end
        end
      end
    end
    if q.state ~= "fly_in" and q.state ~= "devolving" and q.state ~= "fly_out" then
      local qr = (q.state == "landed" or (q.state == "evolving" and q.t % 6 < 3)) and 7 or 11
      local dx, dy = ball.x - q.x, ball.y - q.y
      local d = math.sqrt(dx*dx + dy*dy)
      if d < qr + BR and d > 0.01 then
        local nx, ny = dx / d, dy / d
        ball.x, ball.y = q.x + nx * (qr + BR + 0.5), q.y + ny * (qr + BR + 0.5)
        return {kind = "queen"}, nx, ny
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
    if o.kind == "bud" or o.kind == "spore" then
      local inside = math.abs(ball.x - o.x) < 5 and math.abs(ball.y - o.y) < 5
      if inside and not o.inside then
        add(o.kind == "spore" and 300 or 100)
        if not o.lit then o.lit = true end
        if o.kind == "spore" then
          local ev = o.ev
          local all = #ev.spores == 3
          for _, sp in ipairs(ev.spores) do if not sp.lit then all = false end end
          if all and ev.stage == 2 then ev.stage = 4 end
        end
      end
      o.inside = inside
    elseif CATCHER[o.kind] and ball == mainBall then
      local d = math.sqrt((ball.x - o.x)^2 + (ball.y - o.y)^2)
      local reach = o.kind == "well" and o.r + BR - 1 or o.r
      if d < reach and not o.inside and (cur.holeCool or 0) <= 0 then
        o.inside = true
        ball.caps = (ball.caps or 0) + 1
        -- a capture with no flipper touch since the last one = the table
        -- is playing itself (tests count these as LOOPS)
        if ball.flipSince == false then ball.selfCaps = (ball.selfCaps or 0) + 1 end
        ball.flipSince = false
        add(o.kind == "well" and 1000 or 2500, o.x, o.y)
        say(o.kind == "well" and "WISHING WELL..." or "AIM AND FLIP!")
        o.flash = 30
        if o.kind == "hole" then
          -- aimable launcher: an LED circles the ring, flip to fire that way
          ball.x, ball.y, ball.vx, ball.vy = o.x, o.y, 0, 0
          state, holdObj, aimT, aimArmed = "aim", o, 0, false
        else
          capture(o, 100)
        end
        return
      end
      if d > reach + 5 then o.inside = false end
    end
  end
  for i, side in ipairs({-1, 1}) do
    local kx, ky = side_x(KIT.kick.dx, side), KIT.kick.y
    if cur.kick[i] and math.abs(ball.x - kx) < 5 and math.abs(ball.y - ky) < 6 and ball.vy > 0 then
      cur.kick[i] = false
      add(500)
      say("KICKBACK!")
      ball.x, ball.y = kx, ky
      ball.vx, ball.vy = 0, -3.6  -- straight up and out of the outlane
      shake = 4
    end
  end
  if cur.updraft and (cur.updraft == true or cur.updraft > 0) and math.abs(ball.x - CX) <= 12 and ball.y > 8 and ball.y < 88 then
    local dx = ball.x - CX
    ball.x = ball.x - dx * 0.12
    if ball.vy > -3.5 then
      ball.vy = -3.5
      shake = math.max(shake, 1)
    end
    if dx < -1.5 then
      ball.vx = math.max(ball.vx, 0.7)
    elseif dx > 1.5 then
      ball.vx = math.min(ball.vx, -0.7)
    else
      if math.abs(ball.vx) < 0.3 then
        ball.vx = (ball.x <= CX and 0.5 or -0.5)
      end
    end
    if frame % 4 == 0 then sparkle(ball.x, ball.y, 2, true) end
  end
  -- poo piles: a ball rolling down into one is lost (not during multiball,
  -- not when a post is guarding the drain)
  -- only a ball that has been in play above the flippers (not one that just
  -- came up from below or was just launched and fell straight back)
  if ball == mainBall and #extras == 0 and ball.vy > 0 and ball.above then
    for _, p in ipairs(cur.poo) do
      local guarded = (p.x == CX and (cur.center > 0 or protected())) or (p.x ~= CX and protected())
      if p.off <= 0 and not guarded and (ball.x - p.x)^2 + (ball.y - p.y)^2 < 36 then
        p.off = 300
        if saver > 0 then -- the ball saver covers poo too
          say("BALL SAVED")
          saver = 0
          sparkle(p.x, p.y - 3, 6, true)
          serve()
          return
        end
        ball.x, ball.y, ball.vx, ball.vy = p.x, p.y - 2, 0, 0
        say("SPLAT!", 90)
        shake = 8
        sparkle(p.x, p.y - 3, 8, true)
        state, lostT, lostRespawn = "lost", 50, "here"
        lvstat(cur.idx).loss = lvstat(cur.idx).loss + 1
        run.poo = (run.poo or 0) + 1
        return
      end
    end
  end
  if fairy.mode == "bonus" and (ball.x - fairy.x)^2 + (ball.y - fairy.y)^2 < 81 then
    fairy.mode = "follow"
    add(25000 * (cur.idx + 1), fairy.x, fairy.y)
    sparkle(fairy.x, fairy.y, 6, true)
    say("FAIRY CAUGHT!", 150)
    shake = 6
  end
end

-- ============================ physics frame ============================
local step_ball -- forward (defined below physics)
local game_over -- forward (defined in game flow)
local function physics()
  lflip, rflip = leftHeld(), rightHeld()
  for _, f in ipairs(cur.flippers) do
    -- (not `f.dir == 1 and lflip or rflip`: when lflip is false that
    -- expression falls through to rflip, so B/A moved both flippers)
    local held = rflip
    if f.dir == 1 then held = lflip end
    flipper_update(f, held)
  end
  for _, o in ipairs(cur.objs) do
    o.cool, o.flash = o.cool - 1, o.flash - 1
    if o.kind == "pixie" then
      o.phase = o.phase + 1
      o.x = o.x0 + math.sin(o.phase / 60) * (o.travel or TOY.pixie.travel)
    end
    if o.respawn then
      o.respawn = o.respawn - 1
      if o.respawn <= 0 then o.respawn, o.alive = nil, true end
    end
  end
  for _, ev in ipairs(cur.events) do
    if ev.regrow then
      ev.regrow = ev.regrow - 1
      if ev.regrow <= 0 then
        ev.regrow = nil
        colony_grow_smalls(ev) -- the spores grow back into small mushrooms
      end
    end
  end
  if state == "play" then step_ball() end
  if state == "play" or state == "hold" or state == "aim" then
    for _, e in ipairs(extras) do ball = e step_ball() end
    ball = mainBall
  end
  if cur.slingCool then cur.slingCool = cur.slingCool - 1 end
  check_goals()
end

-- one physics step for the current `ball`
step_ball = function()
  -- 1. gravity, clamp
  ball.vy = ball.vy + GRAV
  ball.vx = math.max(-VMAX, math.min(VMAX, ball.vx))
  ball.vy = math.max(-VMAX, math.min(VMAX, ball.vy))
  if ball.noflip and ball.vy > 0 then ball.noflip = false end

  -- 2. walls (ring probe)
  local hit, nx, ny, push, attr, buried = sdf_test(ball.x, ball.y)
  local kind = attr
  if buried then
    ball.x, ball.y = ball.px, ball.py
    ball.vx, ball.vy = -ball.vx * 0.5, -ball.vy * 0.5
    hit = false
  elseif hit then
    ball.x, ball.y = ball.x + nx*push, ball.y + ny*push
  end

  -- 3. toys, then flippers (flippers win); keep the wall normal so the
  -- ball can't keep sinking into the wall while resting on a flipper
  local wallHit, wnx, wny = hit, nx, ny
  local o, onx, ony = toy_collide()
  if o then hit, nx, ny, kind = true, onx, ony, o end
  local kick, amp, reset = 0, 0, false
  if not ball.noflip then
    for _, f in ipairs(cur.flippers) do
      local fh, fnx, fny, fpush, force = flipper_collide(f)
      if fh then
        hit, nx, ny, kind = true, fnx, fny, "flipper"
        ball.flipSince = true
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
        kick, reset = KICKS[TUNE.kick].sling, TUNE.kick == "reset"
        add(10)
      end
    elseif type(kind) == "table" then
      local k = kind.kind
      if k == "bumper" or k == "gold" or k == "pixie" then
        if kind.cool <= 0 then
          kind.cool, kind.flash = 6, 8
          kick, reset = KICKS[TUNE.kick].bumper, TUNE.kick == "reset"
          add(k == "gold" and 500 or k == "pixie" and 300 or 100)
          if k == "pixie" then -- bursts into dust, grows back
            kind.alive, kind.respawn = false, 6 * 60
            sparkle(kind.x, kind.y, 6, true)
          end
        end
      elseif k == "shroom" or k == "small" then
        amp, kick = 2, 1.0
        if kind.cool <= 0 then
          kind.cool, kind.alive = 10, false
          add(k == "shroom" and 500 or 250, kind.x, kind.y)
          sparkle(kind.x, kind.y, k == "shroom" and 5 or 3, true)
          local ev = kind.ev
          if k == "shroom" then colony_next(ev)
          else -- a spore rollover appears where the small mushroom was
            ev.spores[#ev.spores + 1] = colony_obj(ev, "spore", kind.x, kind.y)
          end
        end
      elseif k == "acorn" then
        amp, kick = 2, 0.8
        if kind.cool <= 0 then
          kind.cool, kind.flash = 12, 6
          kind.hits = kind.hits + 1
          add(150)
          if kind.hits >= 3 then kind.alive = false add(1000, kind.x, kind.y) sparkle(kind.x, kind.y, 5, true) end
        end
      elseif k == "post" then
        amp, kick = 2, KICK_POST
      elseif k == "bramble" then
        local b = kind.bramble
        amp, kick = 2, 1.2
        b.hp = b.hp - 1
        sparkle(b.x, b.y, 6, true)
        shake = 4
        add(500, b.x, b.y)
        if b.hp <= 0 then
          say("BRAMBLE BROKEN!", 40)
        end
      elseif k == "minion" then
        local m = kind.minion
        amp, kick = 2, 1.5
        local q = cur.queen
        if q and (q.shieldInvuln or 0) > 0 then
          sparkle(m.x, m.y, 4, false)
          say("SHIELD INVULNERABLE!", 30)
        else
          m.alive = false
          sparkle(m.x, m.y, 8, true)
          shake = 4
          add(2500, m.x, m.y)
          local left = 0
          if q and q.minions then
            for _, mm in ipairs(q.minions) do if mm.alive then left = left + 1 end end
          end
          if left > 0 then
            say(left .. " SHIELD FAIRIES LEFT", 60)
          end
        end
        if q then
          q.vx = (q.vx or 0) + nx * 0.8
          q.vy = (q.vy or 0) + ny * 0.8
        end
      elseif k == "queen" then
        local q = cur.queen
        amp, kick = 2, 1.6
        if q.cool <= 0 then
          q.cool = 15
          if q.state == "landed" then
            cur.kick[1], cur.kick[2] = true, true
            q.state = "evolving"
            q.t = 70
            q.evoT = 0
            q.flash = 70
            q.shieldInvuln = 70
            q.ringR = 0
            q.orbitAngle = 0
            q.minions = {}
            for i = 1, 5 do
              q.minions[i] = {alive = false, spawnT = 32 + (i - 1) * 7, x = q.x, y = q.y}
            end
            q.vx, q.vy = 0, 0
            q.recoilX, q.recoilY = 0, 0
            shake = 6
            add(5000, q.x, q.y)
            for s = 1, 5 do sparkle(q.x + (s - 3) * 6, q.y, 6, true) end
            say("KICKBACKS RESTORED! QUEEN EVOLVING...", 90)
          elseif q.state == "shield" or q.state == "evolving" then
            q.flash = 6
            shake = 3
            add(1000, q.x, q.y)
            sparkle(q.x, q.y, 4, false)
            say("SHIELD PROTECTS QUEEN!", 40)
          elseif q.state == "vulnerable" then
            q.state = "devolving"
            q.t = 70
            q.flash = 70
            add(10000, q.x, q.y)
            for s = 1, 6 do sparkle(q.x + (s - 3.5) * 8, q.y, 8, true) end
            say("FAIRY QUEEN DEFEATED!", 90)
          end
        end
        q.recoilX = (q.recoilX or 0) + nx * 1.5
        q.recoilY = (q.recoilY or 0) + ny * 1.5
        q.vx = (q.vx or 0) + nx * 0.5
        q.vy = (q.vy or 0) + ny * 0.5
      end
    end
  end
  touching, lastNx, lastNy = hit, nx, ny

  -- 5. response: Pokemon rotate-bounce (+ additive kick), or Infinity reset
  if hit and wallHit and kind ~= attr then
    -- second contact (wall under a flipper/toy): just stop sinking into it
    local vn = ball.vx*wnx + ball.vy*wny
    if vn < 0 then ball.vx, ball.vy = ball.vx - vn*wnx, ball.vy - vn*wny end
  end
  if hit then
    if reset then
      ball.vx, ball.vy = nx * kick, ny * kick
    else
      local tx, ty = -ny, nx
      local vn = ball.vx*nx + ball.vy*ny
      local vt = ball.vx*tx + ball.vy*ty
      -- resting contact: no micro-bounce (gravity alone pushes in ~0.06/f)
      if vn < 0 and vn > -0.25 and kick == 0 then vn = 0
      elseif vn < 0 then vn = -vn * (0.25 + 0.125*amp) end
      vn = vn + kick
      ball.vx, ball.vy = vt*tx + vn*nx, vt*ty + vn*ny
      ball.spin = math.max(-127, math.min(127, (vt * 4) // 1))
    end
  end
  -- 6. move
  if ball.y < 108 then ball.above = true end -- has been played on this table
  ball.px, ball.py = ball.x, ball.y
  ball.x = ball.x + math.max(-STEPMAX, math.min(STEPMAX, ball.vx))
  ball.y = ball.y + math.max(-STEPMAX, math.min(STEPMAX, ball.vy))
  ball.rot = (ball.rot + ball.spin) % 256

  sensors()
end

-- ============================ table transitions ============================
local function end_multiball()
  if #extras > 0 then
    add(5000 * #extras)
    say("MULTIBALL BONUS")
    extras = {}
  end
end

local function transitions()
  -- extra balls: out of the top = bonus, out of the bottom = gone
  for i = #extras, 1, -1 do
    local e = extras[i]
    if e.y < -6 then add(5000, e.x, 4) table.remove(extras, i)
    elseif e.y > WH + 6 then table.remove(extras, i) end
  end
  if state ~= "play" then return end
  if ball.y > WH + 6 and #extras > 0 then
    -- the main ball drained during multiball: an extra takes its place
    local e = table.remove(extras, 1)
    for k, v in pairs(e) do ball[k] = v end
    ball.trap = nil
    return
  end
  if ball.y < -6 then -- out of the top: climb
    if cur.brambles and #cur.brambles > 0 then
      for _, b in ipairs(cur.brambles) do
        if b.hp > 0 and math.abs(ball.x - b.x) <= (b.w / 2 + BR) then
          b.hp = b.hp - 1
          sparkle(b.x, b.y, 6, true)
          shake = 4
          add(500, b.x, b.y)
          say(b.hp <= 0 and "BRAMBLE BROKEN!" or "BRAMBLE BLOCKS PATH!", 40)
          ball.y = math.max(14, b.y + BR + 2)
          ball.vy = math.max(2.5, math.abs(ball.vy) * 0.8)
          return
        end
      end
    end
    end_multiball()
    local nxt = cur.idx + 1
    local fresh = not (tables[nxt] and tables[nxt].visited)
    local ls = lvstat(cur.idx)
    ls.climb = ls.climb + 1
    if not ls.clear then ls.clear = ls.t - (ls.enter or 0) end
    enter_table(nxt)
    ball.y = ball.y + WH
    ball.noflip, ball.above = true, false
    ball.vy = math.max(-3.5, math.min(ball.vy, -2.6))        -- arrive with steady momentum without overshooting
    ball.vx = math.max(-1.2, math.min(1.2, ball.vx))
    fairy.y = WH + 14
    fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
    lvstat(nxt).arrived = lvstat(nxt).t                 -- for bounce-back stats
    if fresh then -- a new level: score + a burst of sparkles at the ball
      add(1000 * nxt, ball.x, ball.y - 6)
      sparkle(ball.x, ball.y - 6, 6)
    end
    say(cur.bonus and ("BOSS LEVEL " .. (nxt + 1)) or ("LEVEL " .. (nxt + 1)))
  elseif ball.y > WH + 6 then -- out of the bottom
    if cur.idx <= floorIdx then
      if saver > 0 then
        say("BALL SAVED")
        saver = 0
        serve()
      else
        state, lostT, lostRespawn = "lost", 60, "floor"
        lvstat(cur.idx).loss = lvstat(cur.idx).loss + 1
        run.drain = (run.drain or 0) + 1
      end
    else
      end_multiball()
      local ls = lvstat(cur.idx)
      ls.drop = ls.drop + 1
      if ls.arrived and ls.t - ls.arrived < 240 then ls.bb = (ls.bb or 0) + 1
      elseif ball.px > 45 and ball.px < 105 then ls.dc = (ls.dc or 0) + 1
      else ls.dout = (ls.dout or 0) + 1 end
      enter_table(cur.idx - 1)
      ball.y = ball.y - WH
      ball.vx, ball.vy = ball.vx * 0.5, ball.vy * 0.1 -- Infinity's softened drop
      cur.center = math.max(cur.center, 5 * 60)       -- mercy post
      fairy.y = -14
      fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
      say("DOWN TO LEVEL " .. cur.idx + 1)
    end
  end
end

-- ============================ game flow ============================
-- persistent lifetime stats in pmem (survive between sessions):
-- 0 hiscore, 1 best level, 2 runs, 3 sum of levels reached, 4 balls lost
-- to poo, 5 balls lost on level-1 drains, 6 seconds played,
-- 16+L balls lost on level L+1, 64+L visits to level L+1, 112+L seconds there
local PM_HI, PM_BEST, PM_RUNS, PM_SUMLV, PM_POO, PM_DRAIN, PM_SECS = 0, 1, 2, 3, 4, 5, 6
local function pm_add(i, v) pmem(i, pmem(i) + v) end

game_over = function()
  state, overT = "over", 0
  local secs = 0
  for L, st in pairs(run) do
    if type(L) == "number" and L < 48 then
      pm_add(16 + L, st.loss)
      pm_add(64 + L, 1)
      pm_add(112 + L, st.t // 60)
      secs = secs + st.t // 60
    end
  end
  run.newHi = score > pmem(PM_HI)
  if run.newHi then pmem(PM_HI, score) end
  if best + 1 > pmem(PM_BEST) then pmem(PM_BEST, best + 1) end
  pm_add(PM_RUNS, 1)
  pm_add(PM_SUMLV, best + 1)
  pm_add(PM_POO, run.poo or 0)
  pm_add(PM_DRAIN, run.drain or 0)
  pm_add(PM_SECS, secs)
  -- one line for anyone running TIC-80 from a console (human analytics)
  local lv = {}
  for L = 0, best do
    local st = run[L]
    if st then
      lv[#lv + 1] = string.format("%d:%ds/%dloss/%ddrop(%dbb,%dc,%do)/%s", L + 1, st.t // 60, st.loss,
        st.drop, st.bb or 0, st.dc or 0, st.dout or 0, tcode(L))
    end
  end
  trace(string.format("RUNLOG seed=%s best=%d score=%d %s", code4(masterSeed), best + 1, score,
    table.concat(lv, " ")))
end

local cheatKeySeq, cheatBtnSeq = {9, 4, 11, 6, 1}, {0, 0, 1, 1, 2, 3, 2, 3}
local cheatKeyIdx, cheatBtnIdx, cheatTimeout = 1, 1, 0

local function check_cheat_input()
  if cheatTimeout > 0 then
    cheatTimeout = cheatTimeout - 1
    if cheatTimeout <= 0 then cheatBtnIdx = 1 end
  end

  for k = 1, 26 do
    if keyp(k) then
      if k == cheatKeySeq[cheatKeyIdx] then
        cheatKeyIdx = cheatKeyIdx + 1
        if cheatKeyIdx > #cheatKeySeq then
          cheatKeyIdx = 1
          bossRush = not bossRush
          shake = 14
          say(bossRush and "BOSS RUSH ACTIVATED!" or "NORMAL MODE ACTIVATED!", 180)
        end
      else
        cheatKeyIdx = (k == cheatKeySeq[1]) and 2 or 1
      end
    end
  end

  for b = 0, 3 do
    if btnp(b) then
      if b == cheatBtnSeq[cheatBtnIdx] then
        cheatBtnIdx = cheatBtnIdx + 1
        cheatTimeout = 180
        if cheatBtnIdx > #cheatBtnSeq then
          cheatBtnIdx = 1
          cheatTimeout = 0
          bossRush = not bossRush
          shake = 14
          say(bossRush and "BOSS RUSH ACTIVATED!" or "NORMAL MODE ACTIVATED!", 180)
        end
      else
        cheatBtnIdx = (b == cheatBtnSeq[1]) and 2 or 1
        cheatTimeout = (cheatBtnIdx > 1) and 180 or 0
      end
    end
  end
end

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

  if state == "title" or state == "over" then check_cheat_input() end

  if state == "title" then
    if not vpad then
      for i = 0, 5 do
        if btnp(i) then
          if i >= 4 or (cheatBtnIdx == 1 and not (i == 0)) then
            new_game()
            break
          end
        end
      end
    end
    return
  end
  if state == "over" then
    overT = overT + 1
    if not vpad and overT > 45 then
      -- D-pad: same tables again; A/B: brand new tables; X/Y: stats page
      if cheatBtnIdx == 1 then
        for i = 0, 3 do if btnp(i) then new_game(masterSeed) return end end
      end
      if btnp(4) or btnp(5) then new_game() return end
      if btnp(6) or btnp(7) then state = "stats" end
    end
    return
  end
  if state == "stats" then
    if not vpad and (btnp(6) or btnp(7)) then state = "over" end
    return
  end
  if state == "play" then lvstat(cur.idx).t = lvstat(cur.idx).t + 1 end
  for _, p in ipairs(cur.poo) do if p.off > 0 then p.off = p.off - 1 end end
  local q = cur.queen
  if q and not q.gone then
    if q.cool > 0 then q.cool = q.cool - 1 end
    if q.flash > 0 then q.flash = q.flash - 1 end
    if state == "play" then
      if q.state == "fly_in" then
        if not q.flyDown then
          q.y = q.y - 3.2
          q.x = q.landX + math.sin(q.y / 8) * 1.5
          if frame % 3 == 0 then sparkle(q.x, q.y + 4, 2, true) end
          if q.y <= q.apexY then
            q.y = q.apexY
            q.flyDown = true
          end
        else
          q.y = q.y + 3.6
          if q.y >= q.landY then
            q.y = q.landY
            q.x = q.landX
            q.landed = true
            q.state = "landed"
            shake = 14
            q.crater = {x = q.x, y = q.y + 6}
            for k = 1, 8 do sparkle(q.x + (k - 4.5) * 4, q.y + 6, 6, true) end
            say("FAIRY QUEEN LANDED!", 90)
          end
        end
      elseif q.state == "evolving" then
        q.evoT = (q.evoT or 0) + 1
        q.orbitAngle = (q.orbitAngle or 0) + 0.04
        -- Queen hovers stably during evolution
        q.x = q.landX + (q.recoilX or 0)
        q.y = q.landY + math.sin(q.evoT / 10) * 1.5 + (q.recoilY or 0)
        q.recoilX = (q.recoilX or 0) * 0.88
        q.recoilY = (q.recoilY or 0) * 0.88

        -- (1) Evolve bigger with flashing and sprite swap
        if q.evoT <= 20 then
          if q.evoT % 4 == 0 then sparkle(q.x + (q.evoT % 5 - 2) * 4, q.y + (q.evoT % 3 - 1) * 4, 3, true) end
        end

        -- (2) Ring grows around her
        if q.evoT >= 20 and q.evoT <= 35 then
          q.ringR = math.min(22, (q.evoT - 20) * 1.5)
        elseif q.evoT > 35 then
          q.ringR = 22
        end

        -- (3) The 5 fairies appear around her 1 by 1
        local R = q.ringR or 22
        for i, m in ipairs(q.minions) do
          local a = q.orbitAngle + (i - 1) * (2 * math.pi / 5)
          m.x = q.x + math.cos(a) * R
          m.y = q.y + math.sin(a) * R
          if not m.alive and q.evoT >= (m.spawnT or 0) then
            m.alive = true
            sparkle(m.x, m.y, 6, true)
            shake = math.max(shake, 2)
          end
        end

        -- (4) Her flashing stops and shield phase begins
        if q.evoT >= 70 then
          q.state = "shield"
          q.flash = 0
          q.shieldInvuln = 0
          for _, m in ipairs(q.minions) do m.alive = true end
          say("DESTROY THE 5 SHIELD FAIRIES!", 90)
        end
      elseif q.state == "shield" or q.state == "vulnerable" then
        -- Graceful, dramatic flight strictly above the kicker bumpers (y <= 52, kickers start at y = 72)
        local targetX = CX + math.sin(frame / 45) * 32 + math.cos(frame / 75) * 8
        local targetY = 38 + math.sin(frame / 32) * 10
        q.x = q.x + (targetX - q.x) * 0.05 + (q.recoilX or 0)
        q.y = q.y + (targetY - q.y) * 0.05 + (q.recoilY or 0)
        q.recoilX = (q.recoilX or 0) * 0.88
        q.recoilY = (q.recoilY or 0) * 0.88
        q.x = math.max(38, math.min(112, q.x))
        q.y = math.max(22, math.min(52, q.y))

        if q.shieldInvuln and q.shieldInvuln > 0 then
          q.shieldInvuln = q.shieldInvuln - 1
        end

        if q.state == "shield" then
          q.orbitAngle = (q.orbitAngle or 0) + 0.04
          local aliveCount = 0
          local R = 22
          for i, m in ipairs(q.minions) do
            if m.alive then
              aliveCount = aliveCount + 1
              local a = q.orbitAngle + (i - 1) * (2 * math.pi / 5)
              m.x = q.x + math.cos(a) * R
              m.y = q.y + math.sin(a) * R
            end
          end
          if aliveCount == 0 then
            q.state = "vulnerable"
            q.flash = 30
            shake = 6
            say("SHIELD BROKEN! QUEEN VULNERABLE!", 120)
          end
        end
      elseif q.state == "devolving" then
        -- (1) Shrinks and changes colors
        q.t = q.t - 1
        if q.t % 4 == 0 then sparkle(q.x + (q.t % 7 - 3) * 4, q.y + (q.t % 5 - 2) * 4, 4, true) end
        if q.t <= 0 then
          -- (2) Starts flying up
          q.state = "fly_out"
          q.vy = -3.0
          say("FAIRY QUEEN RETREATING!", 60)
        end
      elseif q.state == "fly_out" then
        -- (2) Flies up, breaking/destroying any remaining brambles along the way
        q.y = q.y + (q.vy or -3.0)
        q.x = q.x + math.sin(frame / 4) * 0.8
        if frame % 2 == 0 then sparkle(q.x, q.y + 4, 3, true) end
        if q.y < 24 and cur.brambles then
          for _, b in ipairs(cur.brambles) do
            if b.hp > 0 and math.abs(b.x - q.x) < 24 then
              b.hp = 0
              sparkle(b.x, b.y, 8, true)
              shake = math.max(shake, 3)
            end
          end
        end
        if q.y < 0 then cur.brambles = {} end
        -- (3) When she's gone, the updraft arrows appear for us to chase her
        if q.y < -20 then
          q.gone = true
          cur.updraft = true
          cur.updraftPerm = true
          for k = 1, 8 do sparkle(CX + (k - 4.5) * 10, 10, 8, true) end
          floorIdx = math.max(floorIdx, cur.idx)
          local curTier = q.tier or (cur.idx // (bossRush and 2 or 10))
          fairy.tier = math.max(fairy.tier or 0, curTier + 1)
          add(50000 * (curTier + 1), q.x, q.y)
          say("FAIRY QUEEN DEFEATED! CHASE HER UP!", 200)
          fairy.x, fairy.y = q.x, -20
          fairy.tx, fairy.ty = q.x, -20
        end
      end
    end
  end
  if cur.posts > 0 then cur.posts = cur.posts - 1 end
  if (cur.holeCool or 0) > 0 then cur.holeCool = cur.holeCool - 1 end
  if cur.center > 0 and not cur.bonus then cur.center = cur.center - 1 end
  if type(cur.updraft) == "number" and not cur.updraftPerm and cur.updraft > 0 then cur.updraft = cur.updraft - 1 end
  if saver > 0 and state == "play" then saver = saver - 1 end
  if fairy.mode == "bonus" then
    fairy.t = fairy.t - 1
    if fairy.t <= 0 then fairy.mode = "follow" say("FAIRY FLEW AWAY") end
  end

  if state == "ready" then
    if leftHeld() or rightHeld() then
      state = "play"
      ball.vy = LAUNCH_VY
      ball.vx = (frame % 7 - 3) * 0.1
      if saver == 0 then saver = 20 * 60 end -- Pokemon Pinball's 20 s
    end
  elseif state == "aim" then
    -- the LED goes round: silver lap = normal launch, gold lap = full power
    aimT = aimT + 1
    local held = leftHeld() or rightHeld()
    if not held then aimArmed = true end
    local lap = (aimT * AIM_SPEED) // (2 * math.pi)
    if (aimArmed and held) or lap >= 4 then
      local a = -math.pi / 2 + aimT * AIM_SPEED
      local power = lap % 2 == 1 and 4.8 or 3.4
      ball.vx, ball.vy = math.cos(a) * power, math.sin(a) * power
      if not (aimArmed and held) then
        -- nobody fired: drop it gently toward the flippers (never back in)
        ball.vx, ball.vy = (CX - ball.x) * 0.02, 1.2
      end
      ball.noflip, ball.above = false, true
      state = "play"
      cur.holeCool = 45
      sparkle(ball.x, ball.y, lap % 2 == 1 and 6 or 3)
    end
  elseif state == "hold" then
    holdT = holdT - 1
    if holdT <= 0 then
      state = "play"
      local o = holdObj
      if o.kind == "well" then
        -- the wish comes true, then the well drops the ball toward the flippers
        local wishes = {{"EXTRA BALL", 12}, {"BALL SAVER", 22}, {"KICKBACKS", 20}, {"POINTS", 32}}
        if cur.idx >= 2 then wishes[#wishes + 1] = {"MULTIBALL", 14} end
        local tot = 0
        for _, w in ipairs(wishes) do tot = tot + w[2] end
        local r, wish = math.random() * tot, wishes[1][1]
        for _, w in ipairs(wishes) do
          if r < w[2] then wish = w[1] break end
          r = r - w[2]
        end
        if wish == "EXTRA BALL" then balls = math.min(5, balls + 1)
        elseif wish == "BALL SAVER" then saver = 20 * 60
        elseif wish == "KICKBACKS" then cur.kick[1], cur.kick[2] = true, true
        elseif wish == "MULTIBALL" then grant_reward("MULTIBALL")
        else add(5000 * (cur.idx + 1), o.x, o.y) end
        say("WISH: " .. wish .. "!", 150)
        sparkle(o.x, o.y, 8)
        local side = o.x < CX and 1 or -1
        ball.vx, ball.vy = 1.2 * side, 1.0
        cur.holeCool = 90
        run.wishes = (run.wishes or 0) + 1
      else
        local side = o.x < CX and 1 or -1
        ball.vx, ball.vy = 1.6 * side, 1.6 -- eject down toward the flippers
        -- every ring ignores the ball for 1.5 s, so one ring can't feed
        -- another forever (a loop found in playtesting)
        cur.holeCool = 90
      end
    end
  elseif state == "play" then
    if nudgeHeld() and nudgeCool == 0 then
      nudgeCool, shake = 24, 7
      local dir = pad(2) and 1 or pad(3) and -1 or (ball.x < CX and 1 or -1)
      local inDanger = math.abs(ball.x - CX) > 36 and ball.y > 75
      if inDanger then
        ball.vx = ball.vx + dir * 2.4
        ball.vy = math.min(ball.vy * 0.4, -1.8)
        say("TILT SAVE!", 40)
      else
        ball.vx = ball.vx + dir * 1.5
        ball.vy = math.min(ball.vy, ball.vy - 1.2)
      end
      if touching then
        ball.vx = ball.vx + lastNx * 2.0
        ball.vy = ball.vy + lastNy * 2.0
      end
      sparkle(ball.x, ball.y, 4, true)
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
        if lostRespawn == "floor" and cur.idx ~= floorIdx then enter_table(floorIdx) end
        serve()
      else game_over() end
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

local RAINBOW = {
  {C_PINK, C_CYAN, C_LIME}, {C_GOLD, C_PINK, C_CYAN}, {C_RED, C_GOLD, C_LILAC},
  {C_LIME, C_LILAC, C_PINK}, {C_CYAN, C_LIME, C_GOLD}, {C_LILAC, C_RED, C_CYAN},
}
local function fairy_colors(tier)
  local t = tier or fairy.tier or 0
  local r = RAINBOW[t % #RAINBOW + 1]
  palswap(C_PINK, r[1]) palswap(C_CYAN, r[2]) palswap(C_LIME, r[3])
end

local function get_shake()
  if shake <= 0 then return 0, 0 end
  local amp = math.min(4, math.ceil(shake / 3))
  local sy = (shake % 2 == 1) and amp or -amp
  local sxb = ((shake // 2) % 2 == 1) and (amp >= 2 and 1 or 0) or (amp >= 2 and -1 or 0)
  return sxb * 2, sy
end

local function blit_snap(sx, sy)
  if sx == 0 and sy == 0 then
    memcpy(0, SNAP, SCRBYTES)
    return
  end
  local sxb = sx // 2
  local rowBytes = 120 - math.abs(sxb)
  local dstX = math.max(0, sxb)
  local srcX = math.max(0, -sxb)
  memset(0, 0, SCRBYTES)
  for y = 0, 135 do
    local sy_src = y - sy
    if sy_src >= 0 and sy_src < 136 then
      memcpy(y * 120 + dstX, SNAP + sy_src * 120 + srcX, rowBytes)
    end
  end
end

local function draw_flipper(f, sx, sy)
  sx = sx or 0
  sy = sy or 0
  local k = (f.s // 1) // 2
  local id = 256 + (k // 4) * 48 + (k % 4) * 4
  if f.dir == 1 then spr(id, f.px - 6 + sx, f.py - 12 + sy, 0, 1, 0, 0, 4, 3)
  else spr(id, f.px - 25 + sx, f.py - 12 + sy, 0, 1, 1, 0, 4, 3) end
end

local function draw_world(sx, sy)
  sx = sx or 0
  sy = sy or 0
  blit_snap(sx, sy)

  if cur.brambles then
    for _, b in ipairs(cur.brambles) do
      if b.hp > 0 then
        local tid = (b.layer == 2) and 228 or 224
        spr(tid, b.x - 8 + sx, b.y - 4 + sy, 0, 1, 0, 0, 2, 1)
      end
    end
  end

  for _, o in ipairs(cur.objs) do
    local x, y = o.x + sx, o.y + sy
    if o.kind == "bumper" then
      spr(o.flash > 0 and 34 or 32, x - 8, y - 8 - (o.flash > 0 and 1 or 0), 0, 1, 0, 0, 2, 2)
    elseif o.kind == "gold" then
      spr(o.flash > 0 and 108 or 106, x - 8, y - 8, 0, 1, 0, 0, 2, 2)
    elseif o.kind == "pixie" then
      if o.alive then spr((frame // 6) % 2 == 0 and 128 or 130, x - 8, y - 8, 0, 1, 0, 0, 2, 2) end
    elseif o.kind == "shroom" then
      if o.alive then spr(36, x - 8, y - 9, 0, 1, 0, 0, 2, 2) end
    elseif o.kind == "small" then
      if o.alive then spr(31, x - 4, y - 4, 0) end
    elseif o.kind == "spore" then
      spr(o.lit and 111 or 110, x - 4, y - 4, 0)
    elseif o.kind == "well" then
      local spin = state == "hold" and holdObj == o
      spr(spin and (frame // 4) % 2 == 0 and 138 or 136, x - 8, y - 9, 0, 1, 0, 0, 2, 2)
    elseif o.kind == "acorn" then
      if o.alive then spr(100 + math.min(2, o.hits) * 2, x - 8, y - 7, 0, 1, 0, 0, 2, 2) end
    elseif o.kind == "bud" then
      spr(o.lit and 11 or 10, x - 4, y - 4, 0)
    elseif o.kind == "hole" then
      if o.court then palswap(C_CYAN, C_GOLD) end
      spr(44 + ((frame // 12) % 2) * 2, x - 8, y - 8, 0, 1, 0, 0, 2, 2)
      palreset()
    end
  end
  -- kit: kickback arrows, posts, updraft
  for i, side in ipairs({-1, 1}) do
    local lit = cur.kick[i] and (frame // 10) % 2 == 0
    spr(lit and 13 or 12, side_x(KIT.kick.dx, side) - 4 + sx, KIT.kick.y - 10 + sy, 0)
  end
  for _, p in ipairs(post_list()) do
    local blink = (cur.posts < 120 and cur.posts > 0 and p.y < 100) or
                  (cur.center < 120 and p.y > 100 and not cur.bonus)
    if not blink or frame % 8 < 5 then spr(30, p.x - 4 + sx, p.y - 4 + sy, 0) end
  end
  if cur.updraft and (cur.updraft == true or cur.updraft > 0) then
    for y = 12, 80, 10 do
      local oy = (y - frame) % 70 + 12 + sy
      spr(28, CX - 4 + sx, oy, 0)
    end
  end
  for si, l in ipairs(slingRim) do
    if (cur.slingCool or 0) > 3 and ((si == 1) == (ball.x < CX)) then
      for _, i in ipairs(l) do pix(i % WW + sx, i // WW + sy, C_WHITE) end
    end
  end
  for _, f in ipairs(cur.flippers) do draw_flipper(f, sx, sy) end
  if state == "aim" and holdObj then
    -- the launcher LED: silver lap = normal, gold lap = full power
    local lap = (aimT * AIM_SPEED) // (2 * math.pi)
    local c = lap % 2 == 1 and C_GOLD or C_WHITE
    for k = 0, 2 do
      local a = -math.pi / 2 + (aimT - k * 3) * AIM_SPEED
      local px, py = holdObj.x + math.cos(a) * 9, holdObj.y + math.sin(a) * 9
      if k == 0 then circ(px + sx, py + sy, 1, c) else pix(px + sx, py + sy, k == 1 and c or C_LILAC) end
    end
  end
  for _, p in ipairs(cur.poo) do
    local guarded = (p.x == CX and (cur.center > 0 or protected())) or (p.x ~= CX and protected())
    if not guarded then spr(p.off > 0 and 127 or 126, p.x - 4 + sx, p.y - 5 + sy, 0) end
  end
  local q = cur.queen
  if q and q.crater then
    local cx, cy = q.crater.x + sx, q.crater.y + sy
    circb(cx, cy, 7, C_KEY)
    line(cx - 9, cy, cx - 4, cy, C_KEY)
    line(cx + 4, cy, cx + 10, cy - 1, C_KEY)
    line(cx - 3, cy + 3, cx - 6, cy + 7, C_KEY)
    line(cx + 3, cy + 3, cx + 6, cy + 6, C_KEY)
    line(cx - 2, cy - 3, cx - 5, cy - 6, C_KEY)
    line(cx + 2, cy - 3, cx + 5, cy - 5, C_KEY)
  end
  if q and not q.gone then
    local bob = (q.state == "landed") and 0 or math.sin(frame / 18) * 1.5
    local qTier = q.tier or (cur.idx // (bossRush and 2 or 10))

    if q.state == "fly_in" or q.state == "landed" then
      fairy_colors(qTier)
      if q.flash > 0 and frame % 4 < 2 then
        palswap(C_PINK, C_WHITE) palswap(C_CYAN, C_WHITE) palswap(C_LIME, C_WHITE)
      end
      spr(40 + ((frame // 6) % 2) * 2, q.x - 8 + sx, q.y - 8 + bob + sy, 0, 1, 0, 0, 2, 2)
      palreset()
    elseif q.state == "evolving" then
      local isBig = (q.evoT and q.evoT > 20) or (frame % 4 < 2)
      fairy_colors(qTier)
      if q.flash > 0 and frame % 4 < 2 then
        palswap(C_PINK, C_WHITE) palswap(C_CYAN, C_WHITE) palswap(C_LIME, C_WHITE)
      end
      if isBig then
        local animFrame = (frame // 6) % 4
        spr(160 + animFrame * 4, q.x - 16 + sx, q.y - 16 + bob + sy, 0, 1, 0, 0, 4, 4)
      else
        spr(40 + ((frame // 6) % 2) * 2, q.x - 8 + sx, q.y - 8 + bob + sy, 0, 1, 0, 0, 2, 2)
      end
      palreset()
      if q.ringR and q.ringR > 3 then
        circb(q.x + sx, q.y + bob + sy, q.ringR, (frame // 4) % 2 == 0 and C_GOLD or C_CYAN)
      end
    elseif q.state == "shield" or q.state == "vulnerable" then
      fairy_colors(qTier)
      if q.flash > 0 and frame % 4 < 2 then
        palswap(C_PINK, C_WHITE) palswap(C_CYAN, C_WHITE) palswap(C_LIME, C_WHITE)
      end
      local animFrame = (frame // 6) % 4
      spr(160 + animFrame * 4, q.x - 16 + sx, q.y - 16 + bob + sy, 0, 1, 0, 0, 4, 4)
      palreset()
    elseif q.state == "devolving" then
      local isSmall = frame % 4 >= 2
      if isSmall then
        fairy_colors(qTier + 1)
        spr(40 + ((frame // 6) % 2) * 2, q.x - 8 + sx, q.y - 8 + bob + sy, 0, 1, 0, 0, 2, 2)
      else
        fairy_colors(qTier)
        local animFrame = (frame // 6) % 4
        spr(160 + animFrame * 4, q.x - 16 + sx, q.y - 16 + bob + sy, 0, 1, 0, 0, 4, 4)
      end
      palreset()
    elseif q.state == "fly_out" then
      fairy_colors(qTier + 1)
      spr(40 + ((frame // 6) % 2) * 2, q.x - 8 + sx, q.y - 8 + bob + sy, 0, 1, 0, 0, 2, 2)
      palreset()
    end

    -- Draw shield minions if in shield or evolving state
    if (q.state == "shield" or q.state == "evolving") and q.minions then
      fairy_colors(qTier)
      for _, m in ipairs(q.minions) do
        if m.alive then
          spr(40 + ((frame // 6) % 2) * 2, m.x - 8 + sx, m.y - 8 + sy, 0, 1, 0, 0, 2, 2)
          if q.shieldInvuln and q.shieldInvuln > 0 then
            circb(m.x + sx, m.y + sy, 7, (frame // 4) % 2 == 0 and C_GOLD or C_WHITE)
          end
        end
      end
      palreset()
      if q.state == "shield" then
        circb(q.x + sx, q.y + bob + sy, 22 + (frame // 6) % 2, (frame // 4) % 2 == 0 and C_CYAN or C_WHITE)
      end
    elseif q.state == "vulnerable" then
      circb(q.x + sx, q.y + bob + sy, 15 + (frame // 4) % 3, (frame // 4) % 2 == 0 and C_GOLD or C_WHITE)
    end
  end

  for _, e in ipairs(extras) do
    spr((e.rot // 64) % 4, e.x // 1 - 4 + sx, e.y // 1 - 4 + sy, 0)
  end
  local slow = math.abs(ball.vx) + math.abs(ball.vy) < 0.6
  if not ball.dx or not slow then ball.dx, ball.dy = ball.x, ball.y
  else ball.dx, ball.dy = ball.dx + (ball.x - ball.dx) * 0.25, ball.dy + (ball.y - ball.dy) * 0.25 end
  local bx, by = (ball.dx + 0.5) // 1 + sx, (ball.dy + 0.5) // 1 + sy
  if state ~= "lost" and not (state == "hold" and holdT % 6 < 3) and not (state == "aim" and frame % 8 < 3) then
    spr((ball.rot // 64) % 4, bx - 4, by - 4, 0)
  end
  for _, p in ipairs(parts) do
    if p.dust then
      local c = p.t > 16 and C_GOLD or p.t > 8 and C_LILAC or C_FLOORL
      pix(p.x + sx, p.y + sy, c) pix(p.x + 1 + sx, p.y + sy, c)
    else
      spr(4 + (3 - math.min(3, p.t // 6)), p.x - 4 + sx, p.y - 4 + sy, 0)
    end
  end
  local fy = fairy.y + math.sin(frame / 20) * 2
  if boss_active() then return end
  fairy_colors(fairy.tier)
  if fairy.mode == "bonus" then
    -- summoned: golden glow, blinking when about to leave
    if fairy.t > 180 or frame % 8 < 5 then
      circb(fairy.x + sx, fy + sy, 8 + (frame // 6) % 2, C_GOLD)
      palswap(C_CYAN, C_GOLD) palswap(C_PINK, C_WHITE)
    end
  end
  spr(40 + ((frame // 6) % 2) * 2, fairy.x - 8 + sx, fy - 8 + sy, 0, 1,
      fairy.tx < fairy.x and 1 or 0, 0, 2, 2)
  palreset()
end


local function draw_hud(sx, sy)
  sx = sx or 0
  sy = sy or 0
  local hx = HUD_X + 6 + sx
  print(string.format("%8d", score), hx, 24 + sy, C_WHITE, true, 1, false)
  -- balls left as balls; used-up slots as faint empty rings (a lost ball
  -- used to be a little mushroom, which read as a remaining life)
  for i = 1, math.max(3, balls) do
    if i <= balls then spr(0, hx + (i - 1) * 9, 33 + sy, 0)
    else circb(hx + (i - 1) * 9 + 3, 36 + sy, 3, C_FLOORL) end
  end
  if mult > 1 then print("x" .. mult, hx + 30, 35 + sy, C_GOLD, false, 1, true) end
  if #extras > 0 then print("MULTIBALL +" .. #extras, hx, 52 + sy, C_CYAN, false, 1, true) end
  if saver > 0 and (saver > 120 or frame % 16 < 8) then print("SAVE", hx + 52, 35 + sy, C_CYAN, false, 1, true) end
  local lv = "LEVEL " .. cur.idx + 1
  print(lv, hx, 45 + sy, cur.bonus and C_GOLD or C_LIME, false, 1, true)
  print(tcode(cur.idx), hx + #lv * 4 + 4, 45 + sy, C_FLOORL, false, 1, true)
  if floorIdx > 0 and #extras == 0 then
    print("SAFE TO LV " .. floorIdx + 1, hx, 52 + sy, C_LILAC, false, 1, true)
  end
  -- goals: trigger -> reward with progress
  local y = 66 + sy
  local q = cur.queen
  if q then
    if q.gone or q.state == "fly_out" then
      print("DEFEATED!", hx, y, C_LIME, false, 1, true)
      print(">CLIMB ON", hx + 4, y + 7, C_LIME, false, 1, true)
    elseif q.state == "fly_in" or q.state == "landed" then
      print("FAIRY QUEEN", hx, y, C_WHITE, false, 1, true)
      print(">HIT HER!", hx + 4, y + 7, C_GOLD, false, 1, true)
    elseif q.state == "evolving" then
      print("GROWING...", hx, y, C_PINK, false, 1, true)
      print(">BEWARE SHIELD", hx + 4, y + 7, C_CYAN, false, 1, true)
    elseif q.state == "shield" then
      local mCount = 0
      if q.minions then for _, m in ipairs(q.minions) do if m.alive then mCount = mCount + 1 end end end
      print("SHIELD: " .. mCount .. "/5", hx, y, C_CYAN, false, 1, true)
      print(">POP FAIRIES", hx + 4, y + 7, C_CYAN, false, 1, true)
    elseif q.state == "vulnerable" then
      print("VULNERABLE!", hx, y, C_GOLD, false, 1, true)
      print(">STRIKE QUEEN", hx + 4, y + 7, C_GOLD, false, 1, true)
    elseif q.state == "devolving" then
      print("DEVOLVING...", hx, y, C_LILAC, false, 1, true)
    end
  elseif #cur.events == 0 then
    print("CLIMB!", hx, y, C_LILAC, false, 1, true)
  end
  for _, ev in ipairs(cur.events) do
    local n, tot = 0, #ev.members
    if ev.trigger == "ACORN" then n, tot = ev.members[1].hits, 3
      if not ev.members[1].alive then n = 3 end
    elseif ev.trigger == "SHROOM" then
      n, tot = colony_progress(ev), 7
    else for _, o in ipairs(ev.members) do if o.lit then n = n + 1 end end end
    local c = ev.times > 0 and C_LIME or C_WHITE
    print(TRIGGER_LABEL[ev.trigger] .. " " .. n .. "/" .. tot, hx, y, c, false, 1, true)
    print(">" .. REWARD_LABEL[ev.reward], hx + 4, y + 7, ev.times > 0 and C_LIME or C_GOLD, false, 1, true)
    y = y + 16
  end
  -- the tower: tables around this one
  for k = -3, 3 do
    local idx = cur.idx + k
    if idx >= 0 then
      local ty = 104 - k * 5 + sy
      local t = tables[idx]
      local c = C_FLOOR
      if t and t.cleared then c = C_LIME elseif t and t.visited then c = C_MOSS end
      if is_bonus(idx) then c = C_GOLD end
      rect(229 + sx, ty, 6, 4, c)
      if k == 0 then rectb(228 + sx, ty - 1, 8, 6, C_WHITE) end
    end
  end
  if cheatBtnIdx > 1 then
    local entered = string.sub("UUDDLRLR", 1, cheatBtnIdx - 1)
    local dots = string.rep(".", (frame // 12) % 3 + 1)
    print(entered .. dots, hx, 127 + sy, C_GOLD, false, 1, true)
  elseif msgT > 0 and (msgT > 30 or frame % 8 < 4) then
    print(msg, hx, 127 + sy, C_GOLD, false, 1, true)
  elseif state == "ready" and frame % 40 < 30 then
    print("FLIP TO LAUNCH", hx, 127 + sy, C_LILAC, false, 1, true)
  end
  if state == "title" then
    rect(15, 46, 120, 40, C_KEY) rectb(15, 46, 120, 40, C_PINK) rectb(17, 48, 116, 36, C_MOSS)
    print("FAIRY RING", CX - 30, 54, C_GOLD)
    if bossRush then
      print("BOSS RUSH", CX - 27, 40, (frame // 10) % 2 == 0 and C_GOLD or C_RED)
    elseif cheatBtnIdx > 1 then
      local entered = string.sub("UUDDLRLR", 1, cheatBtnIdx - 1)
      local dots = string.rep(".", (frame // 12) % 3 + 1)
      print(entered .. dots, CX - 20, 40, C_GOLD)
    end
    if frame % 40 < 28 then print("PRESS ANY BUTTON", CX - 47, 72, C_LILAC) end
  end
end

-- game over: the table blacks out, the fairy-in-thorns art, and stats
-- toughest / quickest level of this run
local function run_extremes()
  local hard, hardN, easy, easyT = nil, 0, nil, 1e9
  for L, st in pairs(run) do
    if type(L) == "number" then
      local bad = st.loss * 2 + st.drop
      if bad > hardN then hard, hardN = L, bad end
      if st.clear and st.clear < easyT then easy, easyT = L, st.clear end
    end
  end
  return hard, easy, easyT
end

local function draw_over()
  -- the art (its per-scanline palettes are switched in by BDR below)
  memcpy(0, OVER_IMG, SCRBYTES)
  -- stats panel on the right, clear of the fairy, the moon and the title.
  -- Only palette slots that are fixed on every scanline are used:
  -- 0 black, 3 muted, 7 lime, 10 red, 12 gold, 14 lilac, 15 white
  local px, py, pw, ph = 160, 29, 78, 105
  rect(px, py, pw, ph, C_KEY)
  rectb(px, py, pw, ph, C_LILAC)
  local x, y = px + 4, py + 4
  local function line(label, val, c)
    print(label, x, y, C_LILAC, false, 1, true)
    if val then print(val, x + 30, y, c or C_WHITE, false, 1, true) end
    y = y + 7
  end
  line("SCORE", tostring(score), run.newHi and C_GOLD or C_WHITE)
  line("LEVEL", tostring(best + 1))
  if bossRush then line("MODE", "BOSS RUSH", C_GOLD) end
  line("SEED", code4(masterSeed), C_FLOORL)
  y = y + 3
  local hard, easy, easyT = run_extremes()
  if hard then line("TOUGH", "LV" .. hard + 1 .. " " .. run[hard].loss .. "L " .. run[hard].drop .. "D", C_RED) end
  if easy then line("QUICK", "LV" .. easy + 1 .. " " .. string.format("%.1fs", easyT / 60), C_LIME) end
  y = y + 3
  line("BEST", tostring(pmem(PM_HI)), C_GOLD)
  line("AVG LV", string.format("%.1f", pmem(PM_SUMLV) / math.max(1, pmem(PM_RUNS))))
  print("X/Y: STATS", x, y + 1, C_LILAC, false, 1, true)
  -- continue, at the bottom, blinking
  if overT > 45 and frame % 40 < 28 then
    print("CONTINUE", x, py + ph - 24, C_GOLD, false, 1, true)
  end
  if overT > 45 then
    print("D-PAD: SAME", x, py + ph - 16, C_WHITE, false, 1, true)
    print("A/B: NEW TABLES", x, py + ph - 9, C_WHITE, false, 1, true)
  end
end

-- X/Y on the game-over screen: a full page of stats (game palette)
local function draw_stats()
  cls(C_KEY)
  print("STATS", 6, 4, C_GOLD, false, 1, false)
  print("THIS RUN  SEED " .. code4(masterSeed), 40, 5, C_FLOORL, false, 1, true)
  -- per level this run: time spent, balls lost, drops back down, clear time
  local x0, y = 6, 16
  print("LV  TIME LOST DROP CLEAR", x0, y, C_LILAC, true, 1, true)
  y = y + 8
  local levels = {}
  for L, _ in pairs(run) do if type(L) == "number" then levels[#levels + 1] = L end end
  -- longest first: players remember where they spent a lot of time
  table.sort(levels, function(a, b) return run[a].t > run[b].t end)
  local first, last = 1, math.min(#levels, 13)
  local hard, easy = run_extremes()
  for i = first, last do
    local L = levels[i]
    local st = run[L]
    local c = L == hard and C_RED or L == easy and C_LIME or C_WHITE
    print(string.format("%2d %4ds %4d %4d %5s", L + 1, st.t // 60, st.loss, st.drop,
      st.clear and string.format("%.1fs", st.clear / 60) or "-"), x0, y, c, true, 1, true)
    y = y + 8
  end
  -- lifetime (all sessions)
  local lx, ly = 140, 16
  local function life(label, val, c)
    print(label, lx, ly, C_LILAC, false, 1, true)
    print(val, lx + 52, ly, c or C_WHITE, false, 1, true)
    ly = ly + 8
  end
  print("ALL TIME", lx, 5, C_GOLD, false, 1, true)
  local runs = pmem(PM_RUNS)
  life("RUNS", tostring(runs))
  life("HIGH SCORE", tostring(pmem(PM_HI)), C_GOLD)
  life("TOP LEVEL", tostring(pmem(PM_BEST)))
  life("AVG LEVEL", string.format("%.1f", pmem(PM_SUMLV) / math.max(1, runs)))
  life("PLAY TIME", string.format("%dm", pmem(PM_SECS) // 60))
  life("LOST: POO", tostring(pmem(PM_POO)), C_RED)
  life("LOST: LV1", tostring(pmem(PM_DRAIN)), C_RED)
  -- the deadliest levels: balls lost per visit
  ly = ly + 4
  print("DEADLIEST LEVELS", lx, ly, C_LILAC, false, 1, true)
  ly = ly + 8
  local list = {}
  for L = 0, 47 do
    local v = pmem(64 + L)
    if v >= 1 and pmem(16 + L) > 0 then list[#list + 1] = {L, pmem(16 + L) / v, v} end
  end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(4, #list) do
    print(string.format("LV%-3d %.1f LOST/VISIT", list[i][1] + 1, list[i][2]), lx, ly, C_RED, false, 1, true)
    ly = ly + 7
  end
  if #list == 0 then print("NONE YET", lx, ly, C_FLOORL, false, 1, true) end
  if frame % 40 < 28 then print("X/Y: BACK", 6, 128, C_GOLD, false, 1, true) end
end

-- per-scanline palettes for the game-over art (rows 0-143 include the
-- 4-pixel border above and below the 136-line screen)
function BDR(row)
  if state == "over" then
    local y = row - 4
    if y < 0 then y = 0 elseif y > 135 then y = 135 end
    memcpy(0x3FC0, OVER_PAL + y * 48, 48)
  elseif state == "stats" and row == 0 then
    memcpy(0x3FC0, GAME_PAL, 48)
  end
end

local function update_fairy()
  if boss_active() then return end
  local speed = 0.04
  if fairy.mode == "bonus" then
    -- flutter between random spots over the playfield
    if frame % 70 == 0 or (fairy.x - fairy.tx)^2 + (fairy.y - fairy.ty)^2 < 9 then
      fairy.tx = 28 + math.random() * 94
      fairy.ty = 16 + math.random() * 60
    end
    speed = 0.03
  elseif state == "play" then
    fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
    speed = (fairy.y < 0 or fairy.y > WH) and 0.12 or 0.08
  else
    fairy.tx, fairy.ty = ball.x + 14 + math.cos(frame / 40) * 4, ball.y - 14 + math.sin(frame / 30) * 3
    speed = 0.08
  end
  fairy.x = fairy.x + (fairy.tx - fairy.x) * speed
  fairy.y = fairy.y + (fairy.ty - fairy.y) * speed
end

-- ============================ main ============================
function BOOT()
  memcpy(GAME_PAL, 0x3FC0, 48) -- keep the game palette (game over swaps it)
  masterSeed = 1
  enter_table(0)
  serve()
  state = "title"
  fairy.x, fairy.y = ball.x + 14, ball.y - 14
  fairy.tx, fairy.ty = ball.x + 14, ball.y - 14
end

function TIC()
  update()
  if state ~= "title" and state ~= "over" and state ~= "stats" then physics() end
  transitions()
  update_fairy()
  if state == "over" then draw_over() return end
  if state == "stats" then draw_stats() return end
  local sx, sy = get_shake()
  draw_world(sx, sy)
  draw_hud(sx, sy)
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
  transitions = transitions, ring_test = ring_test, sdf_test = sdf_test,
  force_state = function(s) state = s end,
  extras = function() return extras end,
  fairy = fairy,
  grant_reward = function(rw) grant_reward(rw) end,
  floor = function() return floorIdx end,
  run = function() return run end,
  draw_over = function() draw_over() end,
  draw_stats = function() draw_stats() end,
  set_balls = function(n) balls = n end,
  boss_rush = function(v) if v ~= nil then bossRush = v end return bossRush end,
  aim = function() return aimT, aimArmed end,
  tcode = tcode,
  floor = function() return floorIdx end,
  tic_draw = function() update_fairy() local sx, sy = get_shake() draw_world(sx, sy) draw_hud(sx, sy) end,
}
