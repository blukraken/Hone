-- T3: the staged stepper is resumable and slice-safe.
--
-- Per fixture it drives Contract.begin to stage 3 in one call (run), then in steps of 1, 7
-- and 29 fights, and requires every result to be identical: at each stage boundary and at the
-- end, every weight, half-width, fight count and batch count, the stage, the total fights and
-- the dps.
--
-- It then times the slowest single fight. os.clock reads wall time in 1 ms steps on this
-- Windows build, so one fight cannot be timed alone. Every fight the step-1 drive ran is
-- replayed SCREEN_REPEATS times, the SLOW_CANDIDATES slowest are replayed SLOW_REPEATS
-- times, and the slowest mean is the fight's cost. The step-1 drive's own wall time over its
-- fights, less the one-call drive's, is the stepper's cost per step. Their sum must stay under
-- STEP_LIMIT_MS (SP-32's callback limit). Run it alone and pinned (tests/addon/engine/pinned.sh).
--
-- Usage: lua tests/addon/engine/stepper_spec.lua [--only ID]
-- Exit: 0 every check passes, 1 any check fails.

local Harness = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "harness.lua")
local ns = Harness.load()
local Contract = ns.Engine.Contract

local SEED = 100000
local SIZES = { 1, 7, 29 }
local SCREEN_REPEATS = 3
local SLOW_CANDIDATES = 25
local SLOW_REPEATS = 40
local STEP_LIMIT_MS = 2.0

local only
for i = 1, #arg do
  if arg[i] == "--only" then only = arg[i + 1] end
end

local clock, huge = os.clock, math.huge
local passed, failed = 0, 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function scenarioOf(id)
  local sc = Harness.scenario(id)
  sc.seed, sc.capWindow = SEED, -1
  return sc
end

-- Field by field equality of two stepper results; returns false and the first difference.
local function same(a, b, stats)
  for _, key in ipairs({ "stage", "fightsTotal", "dps", "dpsStdev" }) do
    if a[key] ~= b[key] then return false, key end
  end
  for _, stat in ipairs(stats) do
    for _, key in ipairs({ "weights", "halfWidths", "fights", "batches" }) do
      if a[key][stat] ~= b[key][stat] then return false, key .. "." .. stat end
    end
  end
  return true
end

-- Drives a fresh stepper to the end in steps of `size` (nil: one run call). Returns the
-- results at each stage boundary, the final result, the wall ms, the fights each step-1 call
-- ran and the step-1 readings.
local function drive(snapshot, scenario, size, record)
  collectgarbage("collect")
  local st = Contract.begin(snapshot, scenario)
  local calls, readings = {}, {}
  local run = st.plan.run
  if record then
    st.plan.run = function(stat, seed, strata, first, count)
      calls[#calls + 1] = { stat = stat, seed = seed, strata = strata, first = first, count = count }
      return run(stat, seed, strata, first, count)
    end
  end
  local boundaries, last = {}, 0
  local t0 = clock()
  if not size then
    st:run(ns.Engine.Core.Weights.FINAL_STAGE)
    boundaries[#boundaries + 1] = st:result()
  else
    while not st.done do
      local t = clock()
      st:step(size)
      readings[#readings + 1] = math.floor((clock() - t) * 1000 + 0.5)
      if st.stage ~= last then
        last = st.stage
        boundaries[#boundaries + 1] = st:result()
      end
    end
  end
  local ms = (clock() - t0) * 1000
  st.plan.run = run
  return { boundaries = boundaries, final = st:result(), ms = ms, calls = calls, readings = readings, stepper = st }
end

-- Mean ms of one fight over `repeats` replays.
local function fightMs(plan, call, repeats)
  local t0 = clock()
  for _ = 1, repeats do plan.run(call.stat, call.seed, call.strata, call.first, 1) end
  return (clock() - t0) * 1000 / repeats
end

print(string.format("stepper_spec: Contract.begin to stage 3, seed %d, steps of %s fights against one run call",
  SEED, table.concat(SIZES, ", ")))
print("timer: os.clock, wall time on this Windows Lua 5.1.5 build, 1 ms resolution")
print("")

local slowest = {}
for _, id in ipairs(Harness.FIXTURES) do
  if not only or only == id then
    local snapshot, scenario = Harness.snapshots[id], scenarioOf(id)
    local whole = drive(snapshot, scenario, nil)
    local stats = whole.stepper.stats
    local r = whole.final
    print(string.format("%s  one call: stage %d, %d fights, %.0f ms", id, r.stage, r.fightsTotal, whole.ms))

    -- One run call to each stage, keyed by the stage it stopped at.
    local refs = {}
    for s = 1, ns.Engine.Core.Weights.FINAL_STAGE do
      local ref = Contract.begin(snapshot, scenario)
      ref:run(s)
      refs[ref.stage] = ref:result()
    end

    local stepOne
    for _, size in ipairs(SIZES) do
      local d = drive(snapshot, scenario, size, size == 1)
      if size == 1 then stepOne = d end
      local ok, why = same(d.final, r, stats)
      local stagesSeen = {}
      for _, b in ipairs(d.boundaries) do
        stagesSeen[#stagesSeen + 1] = tostring(b.stage)
        local okB, whyB = same(b, refs[b.stage] or {}, stats)
        if not okB then ok, why = false, "stage " .. b.stage .. " " .. tostring(whyB) end
      end
      check(string.format("%s steps of %d give the one-call result (boundaries at stages %s, %d steps)",
        id, size, table.concat(stagesSeen, " "), #d.readings), ok, why)
    end

    -- The slowest single fight.
    local plan = stepOne.stepper.plan
    local screened = {}
    for i, call in ipairs(stepOne.calls) do
      screened[i] = { call = call, ms = fightMs(plan, call, SCREEN_REPEATS) }
    end
    table.sort(screened, function(a, b) return a.ms > b.ms end)
    local worst, worstCall = 0, nil
    for i = 1, math.min(SLOW_CANDIDATES, #screened) do
      local ms = fightMs(plan, screened[i].call, SLOW_REPEATS)
      if ms > worst then worst, worstCall = ms, screened[i].call end
    end
    local overhead = (stepOne.ms - whole.ms) / #stepOne.calls
    if overhead < 0 then overhead = 0 end
    local histogram = {}
    for _, ms in ipairs(stepOne.readings) do histogram[ms] = (histogram[ms] or 0) + 1 end
    local bins = {}
    for ms = 0, 20 do
      if histogram[ms] then bins[#bins + 1] = string.format("%d ms x%d", ms, histogram[ms]) end
    end
    local mean = whole.ms / r.fightsTotal
    print(string.format("  fights %d  mean %.3f ms per fight  slowest fight %.3f ms (%s, seed %d, strata %s, fight %d)",
      #stepOne.calls, mean, worst, worstCall.stat or "base", worstCall.seed, tostring(worstCall.strata), worstCall.first))
    print(string.format("  step-1 drive %.0f ms vs one call %.0f ms: %.3f ms stepper cost per step", stepOne.ms,
      whole.ms, overhead))
    print("  step-1 readings at 1 ms resolution: " .. table.concat(bins, ", "))
    slowest[#slowest + 1] = string.format("%s %.3f ms", id, worst + overhead)
    check(string.format("%s slowest one-fight step %.3f ms (fight %.3f + stepper %.3f) is under %.1f ms", id,
      worst + overhead, worst, overhead, STEP_LIMIT_MS), worst + overhead < STEP_LIMIT_MS)
    print("")
  end
end

print("slowest one-fight step per fixture: " .. table.concat(slowest, ", "))
print(string.format("%d checks, %d passed, %d failed", passed + failed, passed, failed))
os.exit(failed == 0 and 0 or 1)
