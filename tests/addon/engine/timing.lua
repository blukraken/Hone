-- T4: solitary ms per fight of main's EventSim at 11ba1ed against the worktree's.
--
-- Each cell is the minimum over REPEATS runs of FIGHTS fights, timed with os.clock. On this
-- Windows Lua build os.clock reads wall time, so run it alone and pinned to one core:
--   cmd /c "start /affinity 4 /b /wait build\lua\bin\lua.exe tests/addon/engine/timing.lua 300 5"
-- Columns
--   main        EventSim at 11ba1ed (read from git), tally on as it always was
--   sequential  the worktree's EventSim, stream draws, every estimator option off, tally off
--   production  indexed draws with every estimator option a 199-fight evaluate batch uses
--
-- Usage: lua tests/addon/engine/timing.lua [FIGHTS] [REPEATS]

local Harness = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "harness.lua")
local ns = Harness.load()
local main = Harness.loadMain()
local New, Old = ns.Engine.Classes.Shaman.EventSim, main.Engine.Classes.Shaman.EventSim
local Enhancement = ns.Engine.Classes.Shaman.Enhancement

local fights, repeats = tonumber(arg[1]) or 300, tonumber(arg[2]) or 5
local SEED = 4242
local clock, huge = os.clock, math.huge

local function minOf(f)
  local best = huge
  for _ = 1, repeats do
    collectgarbage("collect")
    local t0 = clock()
    f()
    local ms = (clock() - t0) * 1000 / fights
    if ms < best then best = ms end
  end
  return best
end

-- The options an evaluate's 199-fight batch runs with, stratification included.
local production = Enhancement.eventOptions({}, 199)
local labels = {}
for k, v in pairs(production) do labels[#labels + 1] = k .. "=" .. tostring(v) end
table.sort(labels)

print(string.format("timing: os.clock (wall on this build), min of %d repeats of %d fights, ms per fight", repeats,
  fights))
print("production options: " .. table.concat(labels, " "))
print(string.format("%-28s %10s %11s %11s %9s %9s", "fixture", "main", "sequential", "production", "x seq",
  "x prod"))
local worst = huge
for _, id in ipairs(Harness.FIXTURES) do
  local snapshot, scenario = Harness.snapshots[id], Harness.scenario(id)
  local oldChar, newChar = Old.character(snapshot), New.character(snapshot)
  local a = minOf(function() Old.run(oldChar, scenario, main.Engine.Core.Rng.new(SEED), fights) end)
  local b = minOf(function() New.run(newChar, scenario, SEED, fights, {}) end)
  local c = minOf(function() New.run(newChar, scenario, SEED, fights, production) end)
  print(string.format("%-28s %10.3f %11.3f %11.3f %8.2fx %8.2fx", id, a, b, c, a / b, a / c))
  if a / b < worst then worst = a / b end
end
print(string.format("slowest sequential speedup %.2fx (line 2x)", worst))
