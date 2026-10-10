
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
  local totalUp, totalDown, totalTO, totalTraps = 0, 0, 0, 0
  for ti = 0, 19 do
    local up, down, timeout, frames, traps, trapAt = 0, 0, 0, 0, 0, {}
    local info
    for trial = 1, 6 do
      FR.new_game(7)
      FR.enter(ti)
      local t0 = FR.cur()
      info = string.format("%-9s|%-9s objs %d goals %d flips %d", t0.left.name, t0.right.name,
        #t0.objs, #t0.events, #t0.flippers)
      FR.force_state("play")
      b.x, b.y, b.vx, b.vy, b.noflip = 75 + (trial - 3.5) * 6, 128, (trial % 3 - 1) * 0.3, -2.9, true
      local result = "timeout"
      for f = 1, 3600 do
        local t = FR.cur()
        pad_set(bot_pad(b, t))
        FR.update()
        if FR.get() ~= "over" then FR.physics() end
        FR.transitions()
        local now = idx()
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
    lines[#lines + 1] = string.format("  T%-2d %s : up %d down %d stay %d traps %d %s %s",
      ti, info, up, down, timeout, traps, table.concat(trapAt, ""),
      up > 0 and string.format("(avg %.0fs to climb)", frames / up / 60) or "")
  end
  trace("bot playability, flip power " .. fp .. " (6 launches/table, 60s max):")
  if not FLIP_SWEEP then for _, l in ipairs(lines) do trace(l) end end
  trace(string.format("  total: up %d down %d stay %d  TRAPS %d", totalUp, totalDown, totalTO, totalTraps))
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
        local _, _, _, _, _, bb = FR.ring_test(b.x, b.y)
        if bb then buried = buried + 1 end
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
