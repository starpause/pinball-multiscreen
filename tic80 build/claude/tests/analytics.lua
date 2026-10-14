
-- ===================== TABLE ANALYTICS (appended by run_analytics.py) =====================
-- Plays generated tables with the bot and prints one CSV row per launch:
-- the table's features + what happened. Seeds/tables/trials come from
-- globals injected by run_analytics.py (A_SEED0, A_SEEDS, A_TABLES, A_TRIALS).
local realBOOT = BOOT
local _trace = trace
local function trace(m) _trace(m .. "\n") end
local P = {}
local function pad_set(t) for k in pairs(P) do P[k] = nil end for k, v in pairs(t) do P[k] = v end end
local function idx() return select(4, FR.get()) end

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

local KINDS = {"bumper", "gold", "pixie", "hole", "well", "acorn", "shroom", "bud"}

function BOOT()
  realBOOT()
  FR.set_pad(P)
  local b = FR.ball
  local header = {"seed", "table", "left", "right", "objs"}
  for _, k in ipairs(KINDS) do header[#header + 1] = "n_" .. k end
  for _, h in ipairs({"goals", "rewards", "flippers", "kickL", "kickR", "bonus",
      "trial", "result", "frames", "exit_x", "goals_done", "score"}) do header[#header + 1] = h end
  trace("CSV," .. table.concat(header, ","))
  for seed = A_SEED0, A_SEED0 + A_SEEDS - 1 do
    for ti = 0, A_TABLES - 1 do
      for trial = 1, A_TRIALS do
        FR.new_game(seed)
        FR.enter(ti)
        FR.force_state("play")
        local t = FR.cur()
        local counts = {}
        for _, o in ipairs(t.objs) do counts[o.kind] = (counts[o.kind] or 0) + 1 end
        local rewards = {}
        for _, e in ipairs(t.events) do rewards[#rewards + 1] = e.trigger .. ">" .. e.reward end
        local row = {seed, ti, t.left.name, t.right.name, #t.objs}
        for _, k in ipairs(KINDS) do row[#row + 1] = counts[k] or 0 end
        row[#row + 1] = #t.events
        row[#row + 1] = table.concat(rewards, "|")
        row[#row + 1] = #t.flippers
        row[#row + 1] = t.kick[1] and 1 or 0
        row[#row + 1] = t.kick[2] and 1 or 0
        row[#row + 1] = t.bonus and 1 or 0
        -- launch from the bottom like a fresh ball, slightly varied
        b.x, b.y = 75 + (trial - (A_TRIALS + 1) / 2) * 5, 128
        b.vx, b.vy, b.noflip = ((trial % 3) - 1) * 0.3, -2.9, true
        local s0 = select(2, FR.get())
        local result, frames, exitx = "stay", A_FRAMES, -1
        for f = 1, A_FRAMES do
          pad_set(bot_pad(b, FR.cur()))
          for _, e in ipairs(FR.extras()) do
            local q = bot_pad(e, FR.cur())
            if q[2] then P[2] = true end if q[4] then P[4] = true end
          end
          local lastx = b.x
          FR.update()
          if FR.get() ~= "over" then FR.physics() end
          FR.transitions()
          local now = idx()
          if now > ti then result, frames = "up", f break end
          if now < ti or FR.get() == "lost" or FR.get() == "ready" then
            result, frames, exitx = "down", f, lastx // 1
            break
          end
        end
        local done = 0
        for _, e in ipairs(t.events) do if e.times > 0 then done = done + 1 end end
        row[#row + 1] = trial
        row[#row + 1] = result
        row[#row + 1] = frames
        row[#row + 1] = exitx
        row[#row + 1] = done
        row[#row + 1] = select(2, FR.get()) - s0
        for i = 1, #row do row[i] = tostring(row[i]) end
        trace("CSV," .. table.concat(row, ","))
      end
    end
  end
  trace("DONE")
  exit()
end
