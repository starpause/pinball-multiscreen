
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

function BOOT()
  local t0 = time()
  realBOOT()
  trace(string.format("boot %.0f ms", time() - t0))
  FR.set_pad(P)
  local b = FR.ball

  -- 1. full-power launch: where does the ball go?
  FR.new_game()
  step(45, {[1] = true})
  step(1, {})
  local path, minY, enteredField = {}, 999, false
  for i = 1, 400 do
    step(1, {})
    minY = math.min(minY, b.y)
    if b.x < 150 then enteredField = true end
    if i % 20 == 0 then path[#path + 1] = string.format("(%d,%d)", b.x // 1, b.y // 1) end
  end
  trace("launch full: minY=" .. (minY // 1) .. " entered=" .. tostring(enteredField) .. " " .. table.concat(path, " "))

  -- 2. weak launch should fall back and re-serve
  FR.new_game()
  step(2, {[1] = true}) step(1, {})
  step(300, {})
  trace("launch weak: state=" .. FR.get())

  -- 3. cradle: drop ball onto a held-up left flipper
  FR.new_game()
  local st = "play"
  b.x, b.y, b.vx, b.vy, b.grav = 60, 200, 0, 0, true
  FR.force_state("play")
  step(200, {[2] = true})
  trace(string.format("cradle L: ball (%.1f,%.1f) v=%.2f state=%s", b.x, b.y, speed(b), FR.get()))

  -- 4. flipper shot from the cradle: release, then press
  step(20, {})
  local hitY = 999
  step(1, {[2] = true})
  for i = 1, 120 do step(1, {[2] = true}) hitY = math.min(hitY, b.y) end
  trace(string.format("shot L: min y=%.0f  v after=%.2f", hitY, speed(b)))

  -- 5. chaos: random spawns + random flipping. Look for escapes / buried / stuck
  math.randomseed(1234)
  local escapes, stuck, drains, frames, buried = 0, 0, 0, 0, 0
  local maxSpeed = 0
  for run = 1, 40 do
    FR.new_game()
    FR.force_state("play")
    b.x, b.y = 20 + math.random() * 120, 20 + math.random() * 150
    b.vx, b.vy, b.grav = (math.random() - 0.5) * 8, (math.random() - 0.5) * 8, true
    local hit, nx, ny, push, attr, bur = FR.ring_test(b.x, b.y)
    if bur then b.x, b.y = 80, 120 end
    local still = 0
    for i = 1, 3000 do
      local l = math.random() < 0.3
      local r = math.random() < 0.3
      step(1, {[2] = l, [3] = r})
      frames = frames + 1
      maxSpeed = math.max(maxSpeed, speed(b))
      local _, _, _, _, _, bb = FR.ring_test(b.x, b.y)
      if bb then buried = buried + 1 end
      if b.x < 0 or b.x > 176 or b.y < -2 then escapes = escapes + 1 break end
      local s = FR.get()
      if s == "drain" or s == "plunge" then drains = drains + 1 break end
      if s == "play" and speed(b) < 0.05 then still = still + 1 else still = 0 end
      if still > 180 then
        stuck = stuck + 1
        trace(string.format("  stuck at (%.1f,%.1f)", b.x, b.y))
        break
      end
    end
  end
  trace(string.format("chaos: %d frames, drains=%d escapes=%d stuck=%d buriedFrames=%d maxSpeed=%.2f",
    frames, drains, escapes, stuck, buried, maxSpeed))

  -- 6. fairy ring capture + eject
  FR.new_game() FR.force_state("play")
  b.x, b.y, b.vx, b.vy, b.grav = FR.hole.x, FR.hole.y - 12, 0, 0.5, true
  local held = false
  for i = 1, 60 do step(1, {}) if FR.get() == "hold" then held = true end end
  local s1 = FR.get()
  step(80, {})
  trace(string.format("ring: captured=%s count=%d state after=%s ball=(%.0f,%.0f) v=(%.2f,%.2f)",
    tostring(held), FR.hole.count, FR.get(), b.x, b.y, b.vx, b.vy))

  -- 7. bumper kick: roll slowly into the bottom bumper from below
  FR.new_game() FR.force_state("play")
  local bp = FR.bumpers[3]
  b.x, b.y, b.vx, b.vy, b.grav = bp.x, bp.y + 16, 0, -1.0, true
  local vmax = 0
  for i = 1, 30 do step(1, {}) vmax = math.max(vmax, speed(b)) end
  trace(string.format("bumper: in 1.0 -> max out %.2f", vmax))

  -- 8. right flipper: drop on held right flipper, then shoot
  FR.new_game() FR.force_state("play")
  b.x, b.y, b.vx, b.vy, b.grav = 100, 200, 0, 0, true
  step(200, {[3] = true})
  trace(string.format("cradle R: ball (%.1f,%.1f) v=%.2f", b.x, b.y, speed(b)))
  step(25, {})
  local minYR, sawTop = 999, false
  for i = 1, 150 do
    step(1, {[3] = true})
    minYR = math.min(minYR, b.y)
    FR.tic_draw() -- also exercises view switching
    if select(4, FR.get()) == 1 then sawTop = true end
  end
  trace(string.format("shot R: min y=%.0f  top view shown=%s", minYR, tostring(sawTop)))

  -- screenshots
  FR.new_game()
  shot("bottom_plunge")
  FR.force_state("play")
  b.x, b.y = 90, 70
  FR.set_view(1)
  FR.bumpers[1].flash = 4
  FR.lanes[2].lit = true
  shot("top_play")
  FR.force_state("title")
  shot("title")
  exit()
end
