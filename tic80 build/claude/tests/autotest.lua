
-- ===================== AUTOTEST (appended by run_tests.py) =====================
-- Drives the real game code with a virtual pad, prints results with trace(),
-- dumps screenshots as hex rows ("SHOT name" + 136 lines) and exits.
local realBOOT = BOOT
local _trace = trace
local function trace(m) _trace(m .. "\n") end
local P = {}
local function pad_set(t) for k in pairs(P) do P[k] = nil end for k, v in pairs(t) do P[k] = v end end

local function step(n, padt)
  for _ = 1, n or 1 do
    if padt then pad_set(padt) end
    FR.update()
    local st = FR.get()
    if st ~= "title" and st ~= "over" then FR.physics() end
    FR.transitions()
  end
end

local function shot(name)
  FR.tic_draw()
  trace("SHOT " .. name)
  for y = 0, 135 do
    local row = {}
    for x = 0, 239 do row[#row + 1] = string.format("%x", pix(x, y)) end
    trace(table.concat(row))
  end
end

BURY_DEPTH = 6 -- ball centre more than 2 px inside a wall
local function speed(b) return math.sqrt(b.vx * b.vx + b.vy * b.vy) end
local function idx() return select(4, FR.get()) end

-- a simple player: flip when the ball is falling into a flipper's reach
local function bot_pad(b, t)
  local p = {}
  for _, f in ipairs(t.flippers) do
    local dx, dy = (b.x - f.px) * f.dir, b.y - f.py
    if dx > -4 and dx < 24 and dy > -16 and dy < 6 and b.vy > -0.5 then
      if f.dir == 1 then p[2] = true else p[4] = true end
    end
  end
  return p
end

function BOOT()
  local t0 = time()
  realBOOT()
  trace(string.format("boot %.0f ms", time() - t0))
  FR.set_pad(P)
  local b = FR.ball

  -- 1. generation sweep: what do generated tables contain?
  local t1 = time()
  local nTables, nObjs, nEvents, nExtra, kinds, pieces = 0, 0, 0, 0, {}, {}
  for seed = 1, 4 do
    FR.new_game(seed)
    for i = 0, 29 do
      local t = FR.generate(i)
      nTables = nTables + 1
      nObjs = nObjs + #t.objs
      nEvents = nEvents + #t.events
      nExtra = nExtra + #t.flippers - 2
      for _, o in ipairs(t.objs) do kinds[o.kind] = (kinds[o.kind] or 0) + 1 end
      pieces[t.left.name] = (pieces[t.left.name] or 0) + 1
      pieces[t.right.name] = (pieces[t.right.name] or 0) + 1
    end
  end
  local ks, ps = {}, {}
  for k, v in pairs(kinds) do ks[#ks + 1] = k .. "=" .. v end
  for k, v in pairs(pieces) do ps[#ps + 1] = k .. "=" .. v end
  table.sort(ks) table.sort(ps)
  trace(string.format("gen: %d tables in %.0f ms, avg objs %.1f, avg goals %.2f, extra flippers %d",
    nTables, time() - t1, nObjs / nTables, nEvents / nTables, nExtra))
  trace("  kinds: " .. table.concat(ks, " "))
  trace("  pieces: " .. table.concat(ps, " "))

  -- 1b. controls: each side's buttons move ONLY that side's flippers
  local function flipper_states(padt)
    FR.new_game(1) FR.force_state("play")
    b.x, b.y, b.vx, b.vy = 75, 40, 0, 0
    step(6, padt)
    local l, r = 0, 0
    for _, f in ipairs(FR.cur().flippers) do
      if f.dir == 1 then l = math.max(l, f.s) else r = math.max(r, f.s) end
    end
    return l, r
  end
  local ok = true
  for _, c in ipairs({{"dpad", {[0] = true}, "L"}, {"left", {[2] = true}, "L"},
      {"A", {[4] = true}, "R"}, {"B", {[5] = true}, "R"}}) do
    local l, r = flipper_states(c[2])
    local good = (c[3] == "L" and l > 10 and r == 0) or (c[3] == "R" and r > 10 and l == 0)
    if not good then ok = false trace(string.format("  CONTROL FAIL %s: left=%d right=%d", c[1], l, r)) end
  end
  trace("controls: " .. (ok and "ok (d-pad = left only, A/B = right only)" or "FAILED"))

  -- 1c. the three things from the playtest video
  -- (a) kickback must put the ball back on the playfield
  for _, side in ipairs({-1, 1}) do
    FR.new_game(1) FR.force_state("play")
    local t = FR.cur()
    t.kick[1], t.kick[2] = true, true
    b.x, b.y, b.vx, b.vy, b.noflip = 75 + side * 64, 92, 0, 1.0, false
    local peak = 999
    for i = 1, 120 do step(1, {}) peak = math.min(peak, b.y) end
    trace(string.format("kickback %s: peak y=%.0f (outlane top is y 86) %s", side < 0 and "L" or "R",
      peak, peak < 80 and "ok" or "TOO LOW"))
  end
  -- (b) cradle jiggle: drop onto a held flipper, measure bobbing once settled
  for _, side in ipairs({-1, 1}) do
    FR.new_game(1) FR.force_state("play")
    b.x, b.y, b.vx, b.vy, b.noflip = 75 + side * 15, 80, 0, 0, false
    local padt = side < 0 and {[2] = true} or {[4] = true}
    step(180, padt)
    local y0, y1, x0, x1 = 999, -999, 999, -999
    for i = 1, 120 do
      step(1, padt)
      y0, y1 = math.min(y0, b.y), math.max(y1, b.y)
      x0, x1 = math.min(x0, b.x), math.max(x1, b.x)
    end
    -- (c) release: how many frames until the ball rolls 10 px away?
    local sx, sy, rolled = b.x, b.y, nil
    for i = 1, 120 do
      step(1, {})
      if not rolled and ((b.x - sx)^2 + (b.y - sy)^2) > 100 then rolled = i end
    end
    local f = FR.cur().flippers[side < 0 and 1 or 2]
    local along = ((sx - f.px) * f.dir) -- px from the pivot toward the tip
    trace(string.format("cradle %s at (%.1f,%.1f), %.1f px along flipper: jiggle x %.2f y %.2f px; on release rolls 10px in %s frames",
      side < 0 and "L" or "R", sx, sy, along, x1 - x0, y1 - y0, tostring(rolled or "NEVER")))
  end

  -- 1d. a ball draining UNDER a flipper must not be scooped back up by a flip
  for _, side in ipairs({-1, 1}) do
    FR.new_game(1) FR.force_state("play")
    local f = FR.cur().flippers[side < 0 and 1 or 2]
    -- 8 px along the resting flipper, 9 px below its centre line, falling
    b.x, b.y, b.vx, b.vy, b.noflip = f.px - side * 8, f.py + 3.6 + 9, 0, 0.8, false
    local padt = side < 0 and {[2] = true} or {[4] = true}
    local minY = 999
    for i = 1, 30 do step(1, padt) minY = math.min(minY, b.y) end
    trace(string.format("under-flipper %s: start y %.0f, min y %.0f -> %s", side < 0 and "L" or "R",
      f.py + 12.6, minY, minY > f.py and "stays down (ok)" or "SCOOPED UP"))
  end

  -- 2. launch on table 0
  FR.new_game(1)
  step(1, {[2] = true})
  local minY = 999
  for i = 1, 120 do step(1, {}) minY = math.min(minY, b.y) end
  trace(string.format("launch: peak y=%.0f (table %d)", minY, idx()))

  -- 3. cradle + full shot from the left flipper
  FR.new_game(1)
  FR.force_state("play")
  b.x, b.y, b.vx, b.vy, b.noflip = 58, 90, 0, 0, false
  step(150, {[2] = true})
  trace(string.format("cradle L: (%.1f,%.1f) v=%.2f", b.x, b.y, speed(b)))
  step(20, {})
  local peak, climbed = 999, false
  step(1, {[2] = true})
  for i = 1, 150 do step(1, {[2] = true}) peak = math.min(peak, b.y) if idx() > 0 then climbed = true end end
  trace(string.format("shot L after release: peak y=%.0f climbed=%s", peak, tostring(climbed)))

  -- 4. flip timing: ball rolling down the left flipper, flip at different moments
  for _, fp in ipairs(FLIP_SWEEP or {TUNE.flip}) do
  TUNE.flip = fp
  local tipPeaks = {}
  for _, delay in ipairs({4, 8, 12, 16, 20}) do
    FR.new_game(1) FR.force_state("play")
    b.x, b.y, b.vx, b.vy, b.noflip = 52, 104, 0.2, 0.3, false
    step(delay, {})
    local pk, up = 999, false
    for i = 1, 160 do step(1, {[2] = i < 25}) pk = math.min(pk, b.y) if idx() > 0 then up = true end end
    tipPeaks[#tipPeaks + 1] = string.format("d%d:%s", delay, up and "UP" or string.format("%.0f", pk))
  end
  trace("flip timing @" .. fp .. " (peak y / UP=climbed): " .. table.concat(tipPeaks, " "))
  end

  -- 5. playability: bot plays each table from a fresh launch, per flip power
  for _, fp in ipairs(FLIP_SWEEP or {TUNE.flip}) do
  TUNE.flip = fp
  local lines = {}
  local totalUp, totalDown, totalTO, totalTraps, totalLoops = 0, 0, 0, 0, 0
  for ti = 0, (BOT_TABLES or 19) do
    local up, down, timeout, frames, traps, trapAt, loops = 0, 0, 0, 0, 0, {}, 0
    local info
    for trial = 1, 6 do
      FR.new_game(7)
      FR.enter(ti)
      local t0 = FR.cur()
      info = string.format("%-9s|%-9s objs %d goals %d flips %d", t0.left.name, t0.right.name,
        #t0.objs, #t0.events, #t0.flippers)
      FR.force_state("play")
      b.x, b.y, b.vx, b.vy, b.noflip = 75 + (trial - 3.5) * 6, 128, (trial % 3 - 1) * 0.3, -2.9, true
      b.caps, b.traps, b.selfCaps, b.flipSince = 0, 0, 0, nil
      local result = "timeout"
      for f = 1, 3600 do
        local t = FR.cur()
        pad_set(bot_pad(b, t))
        FR.update()
        if FR.get() ~= "over" then FR.physics() end
        FR.transitions()
        local now = idx()
        if (b.selfCaps or 0) >= 2 then loops = loops + 1 b.selfCaps = 0
          trapAt[#trapAt + 1] = "LOOP" end
        if (b.traps or 0) > 0 then traps = traps + b.traps b.traps = 0
          trapAt[#trapAt + 1] = string.format("(%d,%d)", b.x // 1, b.y // 1) end
        if now > ti then result = "up" frames = frames + f break end
        if now < ti or FR.get() == "lost" or FR.get() == "ready" then result = "down" break end
        if b.x < 0 or b.x > 150 then result = "ESCAPE" break end
      end
      if result == "up" then up = up + 1 elseif result == "down" then down = down + 1
      else timeout = timeout + 1 end
    end
    totalUp, totalDown, totalTO = totalUp + up, totalDown + down, totalTO + timeout
    totalTraps = totalTraps + traps
    totalLoops = totalLoops + loops
    lines[#lines + 1] = string.format("  T%-2d %s : up %d down %d stay %d traps %d %s %s",
      ti, info, up, down, timeout, traps, table.concat(trapAt, ""),
      up > 0 and string.format("(avg %.0fs to climb)", frames / up / 60) or "")
  end
  trace("bot playability, flip power " .. fp .. " (6 launches/table, 60s max):")
  if not FLIP_SWEEP then for _, l in ipairs(lines) do trace(l) end end
  trace(string.format("  total: up %d down %d stay %d  TRAPS %d  LOOPS %d", totalUp, totalDown, totalTO, totalTraps, totalLoops))
  end

  -- 5b. loop/trap hunt across many seeds (bot, 30 s per table)
  do
    local runs, loops, traps, where = 0, 0, 0, {}
    for seed = 1, 20 do
      for ti = 0, 12 do
        FR.new_game(seed * 13 + 5)
        FR.enter(ti)
        FR.force_state("play")
        b.x, b.y, b.vx, b.vy, b.noflip = 75, 128, 0, -2.9, true
        b.caps, b.traps, b.selfCaps, b.flipSince = 0, 0, 0, nil
        runs = runs + 1
        for f = 1, 1800 do
          pad_set(bot_pad(b, FR.cur()))
          FR.update()
          if FR.get() ~= "over" then FR.physics() end
          FR.transitions()
          if idx() ~= ti or FR.get() == "lost" or FR.get() == "ready" then break end
        end
        if (b.selfCaps or 0) >= 2 then loops = loops + 1 where[#where + 1] = "L" .. seed * 13 + 5 .. "/" .. ti end
        if (b.traps or 0) > 0 then traps = traps + 1 where[#where + 1] = "T" .. seed * 13 + 5 .. "/" .. ti end
      end
    end
    trace(string.format("hunt: %d runs, loops %d, trapped %d %s", runs, loops, traps, table.concat(where, " ")))
  end

  -- 6. chaos: random balls + random flipping on many tables
  math.randomseed(99)
  local escapes, buried, frames = 0, 0, 0
  for run = 1, 30 do
    FR.new_game(run)
    FR.enter(run % 15)
    FR.force_state("play")
    b.x, b.y = 30 + math.random() * 90, 10 + math.random() * 70
    b.vx, b.vy, b.noflip = (math.random() - 0.5) * 6, (math.random() - 0.5) * 6, false
    local _, _, _, _, _, bur = FR.ring_test(b.x, b.y)
    if not bur then
      for i = 1, 1500 do
        step(1, {[2] = math.random() < 0.3, [4] = math.random() < 0.3})
        frames = frames + 1
        local h, _, _, push = FR.sdf_test(b.x, b.y)
        if h and push > BURY_DEPTH then buried = buried + 1 end
        if b.x < -2 or b.x > 152 then escapes = escapes + 1 break end
        local s = FR.get()
        if s == "lost" or s == "over" then break end
      end
    end
  end
  trace(string.format("chaos: %d frames, escapes=%d buriedFrames=%d", frames, escapes, buried))

  -- screenshots of a few generated tables
  for _, ti in ipairs({0, 4, 6, 9, 13}) do
    FR.new_game(7)
    FR.enter(ti)
    FR.force_state("play")
    b.x, b.y, b.vx, b.vy = 75, 60, 0, 0
    shot("table_" .. ti)
  end
  FR.new_game(7)
  FR.force_state("title")
  shot("title")
  exit()
end
