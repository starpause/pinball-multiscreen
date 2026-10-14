
-- ===================== AUTOTEST (appended by run_tests.py) =====================
-- Drives the real game code with a virtual pad, prints results with trace(),
-- dumps screenshots as hex rows ("SHOT name" + 136 lines) and exits.
local function _run_autotest_setup()
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

  -- 1e. a goal pays out ONCE per completion (acorn stays broken for 10 s)
  do
    FR.new_game(7)
    local found
    for ti = 0, 20 do
      local t = FR.generate(ti)
      for _, ev in ipairs(t.events) do if ev.trigger == "ACORN" then found = ti break end end
      if found then break end
    end
    FR.enter(found) FR.force_state("play")
    local t = FR.cur()
    local ev
    for _, e in ipairs(t.events) do if e.trigger == "ACORN" then ev = e end end
    local a = ev.members[1]
    b.x, b.y, b.vx, b.vy = 75, 60, 0, 0
    a.alive, a.hits = false, 3 -- break it
    local s0 = select(2, FR.get())
    for i = 1, 300 do step(1, {}) end
    trace(string.format("acorn goal on table %d: paid %d time(s) in 5 s (score +%d) %s", found, ev.times,
      select(2, FR.get()) - s0, ev.times == 1 and "ok" or "MULTI-PAY BUG"))
  end

  -- 1f. new mechanics
  local function find_table(pred)
    for ti = 0, 40 do
      local t = FR.generate(ti)
      if pred(t) then return ti end
    end
  end
  -- mushroom colony: big -> 3 small -> 2 spores -> goal, then regrows
  do
    FR.new_game(7)
    local ti = find_table(function(t)
      for _, e in ipairs(t.events) do if e.trigger == "SHROOM" then return true end end
    end)
    FR.enter(ti) FR.force_state("play")
    local ev
    for _, e in ipairs(FR.cur().events) do if e.trigger == "SHROOM" then ev = e end end
    local big = ev.members[1]
    local function hit(o)
      b.x, b.y, b.vx, b.vy, b.noflip = o.x, o.y - o.r - 6, 0, 1.5, false
      for i = 1, 60 do
        step(1, {})
        if not o.alive then return true end
      end
    end
    hit(big)
    local st2 = ev.stage
    local smalls = {}
    for _, o in ipairs(ev.smalls) do smalls[#smalls + 1] = o end
    for _, o in ipairs(smalls) do hit(o) end
    local nSpores, sameSpots = #ev.spores, true
    for i, sp in ipairs(ev.spores) do
      if math.abs(sp.x - smalls[i].x) > 0.1 or math.abs(sp.y - smalls[i].y) > 0.1 then sameSpots = false end
    end
    for _, sp in ipairs(ev.spores) do
      b.x, b.y, b.vx, b.vy = sp.x, sp.y - 1, 0, 0.3
      step(2, {})
    end
    step(2, {})
    local paid = ev.times
    FR.force_state("ready") -- park the ball (out of play) while the colony regrows
    for i = 1, 620 do step(1, {}) end
    FR.force_state("play")
    local alive = 0
    for _, o in ipairs(ev.smalls) do if o.alive then alive = alive + 1 end end
    trace(string.format("colony (table %d): big->stage %d, %d spores in the smalls' spots=%s, paid %d, regrew %d smalls %s",
      ti, st2, nSpores, tostring(sameSpots), paid, alive,
      (st2 == 2 and nSpores == 3 and sameSpots and paid == 1 and ev.stage == 2 and alive == 3) and "ok" or "PROBLEM"))
  end
  -- multiball: 2 extra balls, they resolve without errors
  do
    FR.new_game(7) FR.enter(3) FR.force_state("play")
    b.x, b.y, b.vx, b.vy, b.noflip = 75, 60, 0, 0, false
    FR.grant_reward("MULTIBALL")
    local n0 = #FR.extras()
    local maxE, gone = n0, nil
    for i = 1, 1800 do
      pad_set(bot_pad(b, FR.cur()))
      FR.update() if FR.get() ~= "over" then FR.physics() end FR.transitions()
      for _, e in ipairs(FR.extras()) do
        local p = bot_pad(e, FR.cur())
        if p[2] then P[2] = true end if p[4] then P[4] = true end
      end
      if #FR.extras() == 0 and not gone then gone = i end
    end
    trace(string.format("multiball: spawned %d extras, all resolved after %s frames, state %s %s", n0,
      tostring(gone), FR.get(), n0 == 2 and "ok" or "PROBLEM"))
  end
  -- wishing well: catches the ball, grants a wish, drops it toward the flippers
  do
    FR.new_game(7)
    local ti = find_table(function(t)
      for _, o in ipairs(t.objs) do if o.kind == "well" then return true end end
    end)
    if ti then
      FR.enter(ti) FR.force_state("play")
      local w
      for _, o in ipairs(FR.cur().objs) do if o.kind == "well" then w = o end end
      FR.set_balls(2)
      b.x, b.y, b.vx, b.vy, b.noflip = w.x, w.y - 12, 0, 1.0, false
      local held, after = false, nil
      for i = 1, 200 do
        step(1, {})
        if FR.get() == "hold" then held = true end
        if held and FR.get() == "play" and not after then after = {b.vx, b.vy} end
      end
      trace(string.format("well (level %d): caught=%s, ejected v=(%.1f,%.1f) downward=%s wishes=%d %s", ti + 1,
        tostring(held), after and after[1] or 0, after and after[2] or 0, tostring(after and after[2] > 0),
        FR.run().wishes or 0, (held and after and after[2] > 0) and "ok" or "PROBLEM"))
    else trace("well: none generated in levels 1-41") end
  end
  -- fairy ring launcher: LED circles, a flip fires that way; gold lap = more power
  do
    FR.new_game(7)
    local ti = find_table(function(t)
      for _, o in ipairs(t.objs) do if o.kind == "hole" and not o.queenRing and not o.court then return true end end
    end)
    FR.enter(ti) FR.force_state("play")
    local ring
    for _, o in ipairs(FR.cur().objs) do if o.kind == "hole" and not o.queenRing then ring = o end end
    local function shoot(waitFrames)
      FR.cur().holeCool = 0
      ring.inside = false
      b.x, b.y, b.vx, b.vy, b.noflip = ring.x, ring.y - 6, 0, 0.6, false
      for i = 1, 30 do step(1, {}) if FR.get() == "aim" then break end end
      local aimed = FR.get() == "aim"
      step(waitFrames, {})                 -- let the LED travel (button released)
      step(1, {[4] = true})                -- flip: fire
      return aimed, FR.get(), math.sqrt(b.vx * b.vx + b.vy * b.vy)
    end
    local a1, s1, v1 = shoot(10)                       -- first lap: silver
    local a2, s2, v2 = shoot(math.floor(2 * math.pi / 0.07) + 10) -- second lap: gold
    trace(string.format("ring launcher (level %d): aimed=%s/%s, silver speed %.1f, gold speed %.1f %s", ti + 1,
      tostring(a1), tostring(a2), v1, v2, (a1 and a2 and s1 == "play" and v2 > v1 + 1) and "ok" or "PROBLEM"))
  end
  -- bonus fairy: summon, hit her
  do
    FR.new_game(7) FR.enter(2) FR.force_state("play")
    b.x, b.y, b.vx, b.vy = 75, 60, 0, 0
    FR.grant_reward("FAIRY")
    local mode1 = FR.fairy.mode
    local s0 = select(2, FR.get())
    FR.fairy.x, FR.fairy.y = b.x, b.y
    FR.fairy.tx, FR.fairy.ty = b.x, b.y
    step(2, {})
    trace(string.format("fairy: summoned=%s caught=%s bonus +%d %s", mode1, tostring(FR.fairy.mode == "follow"),
      select(2, FR.get()) - s0, (mode1 == "bonus" and FR.fairy.mode == "follow") and "ok" or "PROBLEM"))
  end

  -- 1g. poo piles, fairy level, game over
  do -- poo: a ball rolling into one is lost, relaunched on the same level
    FR.new_game(7)
    local ti = find_table(function(t) return t.poo and #t.poo > 0 end)
    FR.enter(ti) FR.force_state("play")
    local p = FR.cur().poo[1]
    FR.set_balls(3)
    FR.cur().center = 0
    b.x, b.y, b.vx, b.vy, b.noflip, b.above = p.x, p.y - 10, 0, 1.2, false, true
    for i = 1, 120 do step(1, {}) end
    local _, _, nb, lvl, _ = FR.get()
    trace(string.format("poo (level %d at %d,%d): balls 3->%d, still on level %d, state %s, pile off=%s %s",
      ti + 1, p.x, p.y, nb, lvl + 1, FR.get(), tostring(p.off > 0),
      (nb == 2 and lvl == ti and FR.get() == "ready") and "ok" or "PROBLEM"))
    -- a ball coming up from BELOW that falls straight back onto the pile is safe
    p.off = 0
    FR.cur().center = 0
    FR.force_state("play")
    b.x, b.y, b.vx, b.vy, b.noflip, b.above = p.x, p.y + 6, 0, -0.8, true, false
    for i = 1, 90 do step(1, {}) end
    local _, _, nb2 = FR.get()
    trace(string.format("poo from below: balls %d->%d %s", nb, nb2, nb2 == nb and "ok (safe)" or "PROBLEM"))
  end
  do -- the fairy level: queen lands, evolves, shields with 5 fairies, devolves on defeat
    FR.new_game(7) FR.enter(9) FR.force_state("play")
    local t = FR.cur()
    local q = t.queen
    -- 1. Queen flies down and lands
    for i = 1, 60 do
      b.x, b.y, b.vx, b.vy = 75, 80, 0, 0
      step(1, {})
      if q.state == "landed" then break end
    end
    local landedOk = q.state == "landed"

    -- 2. Test bramble collision
    local brambleCount0 = #t.brambles
    local b1 = t.brambles[1]
    b.x, b.y, b.vx, b.vy, b.noflip = b1.x, b1.y + 10, 0, -1.8, false
    for i = 1, 30 do step(1, {}) if b1.hp <= 0 then break end end
    local brambleBroke = b1.hp <= 0

    -- 3. Hit landed queen -> immediately enters evolving state AND summons 5 minions with invulnerability
    b.x, b.y, b.vx, b.vy, b.noflip = q.x, q.y + 14, 0, -1.8, false
    for i = 1, 30 do step(1, {}) if q.state == "evolving" then break end end
    local evolveSpawnOk = q.state == "evolving" and q.minions and #q.minions == 5 and (q.shieldInvuln or 0) > 0

    -- Wait for evolution and shieldInvuln to expire -> shield state
    for i = 1, 100 do
      b.x, b.y, b.vx, b.vy = 75, 110, 0, 0
      step(1, {})
      if q.state == "shield" and (q.shieldInvuln or 0) <= 0 then break end
    end
    local shieldOk = q.state == "shield" and q.minions and #q.minions == 5

    -- 4. Pop all 5 minions
    for k = 1, 5 do
      local m = q.minions[k]
      for tries = 1, 10 do
        if not m.alive then break end
        b.x, b.y, b.vx, b.vy, b.noflip = m.x, m.y + 7, 0, -1.6, false
        for i = 1, 15 do
          step(1, {})
          if not m.alive then break end
        end
      end
    end
    for i = 1, 20 do b.x, b.y, b.vx, b.vy = 75, 110, 0, 0 step(1, {}) end
    local vulnOk = q.state == "vulnerable"

    -- 5. Hit vulnerable queen -> devolves, defeated, and flies out!
    FR.set_balls(2)
    b.x, b.y, b.vx, b.vy, b.noflip = q.x, q.y + 18, 0, -1.8, false
    for i = 1, 30 do step(1, {}) if q.state == "devolving" then break end end
    local devolveOk = q.state == "devolving"
    for i = 1, 160 do
      b.x, b.y, b.vx, b.vy = 75, 110, 0, 0
      step(1, {})
      if q.gone then break end
    end

    local _, _, nb = FR.get()
    trace(string.format("fairy boss: landed=%s bramble=%s spawn=%s shield=%s vuln=%s devolve=%s defeated=%s, balls 2->%d, checkpoint lv %d %s",
      tostring(landedOk), tostring(brambleBroke), tostring(evolveSpawnOk), tostring(shieldOk), tostring(vulnOk),
      tostring(devolveOk), tostring(q.gone == true), nb, FR.floor() + 1,
      (landedOk and brambleBroke and evolveSpawnOk and shieldOk and vulnOk and devolveOk and q.gone and nb == 2 and FR.floor() == 9) and "ok" or "PROBLEM"))
    -- below the checkpoint the drain is guarded
    FR.enter(5) FR.force_state("play")
    b.x, b.y, b.vx, b.vy = 75, 118, 0, 1.0
    for i = 1, 60 do step(1, {}) end
    trace(string.format("protected level 6: ball after centre drain attempt y=%.0f (%s)", b.y,
      (select(4, FR.get()) == 5 and b.y < 136) and "guarded ok" or "DRAINED"))
  end
  do -- boss rush mode: lv1 normal, lv2 boss, lv3 normal, lv4 boss, 1 ball start
    FR.boss_rush(true)
    FR.new_game(1)
    local _, _, brBalls = FR.get()
    local t0 = FR.generate(0)
    local t1 = FR.generate(1)
    local t2 = FR.generate(2)
    local t3 = FR.generate(3)
    trace(string.format("boss rush mode: lv1 bonus=%s lv2 bonus=%s lv3 bonus=%s lv4 bonus=%s, balls=%d %s",
      tostring(t0.bonus == true), tostring(t1.bonus == true), tostring(t2.bonus == true), tostring(t3.bonus == true), brBalls,
      (not t0.bonus and t1.bonus and not t2.bonus and t3.bonus and brBalls == 1) and "ok" or "PROBLEM"))
    FR.boss_rush(false)
  end
  trace("table codes: level1=" .. FR.tcode(0) .. " level10=" .. FR.tcode(9))
  do -- weak climbs: a shot that barely leaves the top must arrive with
       -- enough momentum to get up into the new table (Infinity relaunches)
    local peaks, times = {}, {}
    for k = 1, 10 do
      FR.new_game(30 + k) FR.enter(2) FR.force_state("play")
      b.x, b.y, b.vx, b.vy, b.noflip = 75 + (k - 5) * 3, 1, (k % 3 - 1) * 0.4, -1.2, false
      local arrived, peak, t = nil, 999, nil
      for i = 1, 400 do
        step(1, {})
        local lv = select(4, FR.get())
        if lv == 3 and not arrived then arrived = i end
        if arrived and lv == 3 then peak = math.min(peak, b.y) end
        if arrived and lv < 3 then t = i - arrived break end
      end
      peaks[#peaks + 1] = peak
      times[#times + 1] = t or 400
    end
    local sp, st = 0, 0
    for i = 1, 10 do sp, st = sp + peaks[i], st + times[i] end
    trace(string.format("weak climbs: arriving ball rises to y=%.0f on average, %.1fs before it could drain",
      sp / 10, st / 10 / 60))
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
  -- action shot: multiball + summoned fairy + a colony mid-way
  FR.new_game(7) FR.enter(13) FR.force_state("play")
  b.x, b.y, b.vx, b.vy, b.noflip = 60, 90, 0.5, 0, false
  FR.grant_reward("MULTIBALL") FR.grant_reward("FAIRY")
  step(24, {})
  shot("action")
  -- the fairy level and the game-over screen
  FR.new_game(7) FR.enter(9) FR.force_state("play")
  local q = FR.cur().queen
  q.state = "shield"
  q.x, q.y = 75, 44
  q.minions = {}
  for i = 1, 5 do
    local a = (i - 1) * (2 * math.pi / 5)
    q.minions[i] = {alive = true, x = q.x + math.cos(a) * 22, y = q.y + math.sin(a) * 22}
  end
  b.x, b.y = 40, 100
  shot("fairy_level")
  FR.new_game(7) FR.enter(3)
  for L = 0, 6 do FR.run()[L] = {t = 600 + L * 300, loss = L % 3, drop = L % 2, climb = 1, clear = 300 + L * 200} end
  FR.force_state("over")
  FR.draw_over()
  trace("SHOT game_over")
  for y = 0, 135 do
    local row = {}
    for x = 0, 239 do row[#row + 1] = string.format("%x", pix(x, y)) end
    trace(table.concat(row))
  end
  FR.force_state("stats")
  FR.draw_stats()
  trace("SHOT stats_page")
  for y = 0, 135 do
    local row = {}
    for x = 0, 239 do row[#row + 1] = string.format("%x", pix(x, y)) end
    trace(table.concat(row))
  end
  FR.new_game(7)
  FR.force_state("title")
  shot("title")
  exit()
end
end
_run_autotest_setup()
