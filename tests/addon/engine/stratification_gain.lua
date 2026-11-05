-- Measures the stratification gain behind the stage stop's variance floor (MODEL-06d T1).
--
-- For every fixture and stat it runs, through the evaluate's own plan (Contract.begin):
--   unstratified  BATCHES x batch size fights on GAIN_SEED, the per-fight variance s2 of the
--                 paired difference, as stage 1 sees it
--   stratified    BATCHES batches of batch size fights on GAIN_SEED + k, stratified as stages
--                 2 and 3 run them, the variance of the batch means
-- and prints the ratio (batch-mean variance) / (s2 / batch size). A ratio under 1 is a gain
-- from stratification. Core/Defaults stageStratificationGain must be no stronger (no lower)
-- than the fixture median. The script reports each fixture's median over its simulated stats,
-- the median over every simulated (fixture, stat) pair, and the largest fixture median.
-- Pathwise stats are printed for reference and stay out of the medians, because the floor
-- only applies to simulated stats.
--
-- Usage: lua tests/addon/engine/stratification_gain.lua [BATCHES] [--only ID]

local Harness = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "harness.lua")
local ns = Harness.load()
local Compare = dofile(Harness.root .. "/tests/addon/engine/compare.lua")
local Defaults = ns.Engine.Core.Defaults

local GAIN_SEED = 7000000

local batches, only = 200, nil
local i = 1
while i <= #arg do
  if arg[i] == "--only" then only = arg[i + 1] i = i + 1
  else batches = tonumber(arg[i]) end
  i = i + 1
end
local size = Defaults.stageBatchSize

local function var(values)
  local n, sum = #values, 0
  for k = 1, n do sum = sum + values[k] end
  local mean, sq = sum / n, 0
  for k = 1, n do sq = sq + (values[k] - mean) ^ 2 end
  return sq / (n - 1), mean
end

local function median(list)
  local s = {}
  for k, x in ipairs(list) do s[k] = x end
  table.sort(s)
  local n = #s
  if n % 2 == 1 then return s[(n + 1) / 2] end
  return (s[n / 2] + s[n / 2 + 1]) / 2
end

-- Per-fight paired differences of `stat` over one run, or its pathwise slopes.
local function diffs(plan, steps, stat, base, basePw, seed, strata, count)
  if plan.kinds[stat] == "pathwise" then return basePw[stat] end
  local plus = plan.run(stat, seed, strata, 1, count)
  local out = {}
  for k = 1, count do out[k] = (plus[k] - base[k]) / steps[stat] end
  return out
end

local ref = Compare.loadReference()
print(string.format("stratification gain: %d stratified batches of %d (seeds %d + k) against %d unstratified"
  .. " fights (seed %d), per fixture and stat", batches, size, GAIN_SEED, batches * size, GAIN_SEED))
print("ratio = var(batch means) / (per-fight var / " .. size .. "); under 1 is a gain; batch-mean var has "
  .. (batches - 1) .. " df")
print("")

local fixtureMedians, all = {}, {}
local t0 = os.clock()
for _, id in ipairs(Harness.FIXTURES) do
  if not only or only == id then
    local scenario = Harness.scenario(id)
    scenario.seed, scenario.weightDelta, scenario.capWindow, scenario.path = GAIN_SEED, ref.delta, -1, "event"
    local st = ns.Engine.Contract.begin(Harness.snapshots[id], scenario)
    local plan, steps = st.plan, st.steps
    local n = batches * size
    local base, basePw = plan.run(nil, GAIN_SEED, nil, 1, n)
    local strat = {}
    for k = 1, batches do
      local b, pw = plan.run(nil, GAIN_SEED + k, size, 1, size)
      strat[k] = { dps = b, pw = pw }
    end
    print(id)
    print(string.format("  %-13s %-9s %12s %12s %12s %8s", "stat", "kind", "per-fight var", "var/" .. size,
      "batch var", "ratio"))
    local ratios = {}
    for _, stat in ipairs(st.stats) do
      local kind = plan.kinds[stat]
      if kind ~= "zero" then
        local perFight = var(diffs(plan, steps, stat, base, basePw, GAIN_SEED, nil, n))
        local means = {}
        for k = 1, batches do
          local _, m = var(diffs(plan, steps, stat, strat[k].dps, strat[k].pw, GAIN_SEED + k, size, size))
          means[k] = m
        end
        local batchVar = var(means)
        local ratio = batchVar / (perFight / size)
        print(string.format("  %-13s %-9s %12.6f %12.8f %12.8f %8.3f", stat, kind, perFight, perFight / size,
          batchVar, ratio))
        if kind == "simulated" then
          ratios[#ratios + 1] = ratio
          all[#all + 1] = ratio
        end
      end
    end
    local m = median(ratios)
    fixtureMedians[#fixtureMedians + 1] = m
    print(string.format("  median over %d simulated stats %.3f", #ratios, m))
    print("")
  end
end

local largest = math.max(unpack(fixtureMedians))
print(string.format("fixture medians: %s", (function()
  local parts = {}
  for k, m in ipairs(fixtureMedians) do parts[k] = string.format("%.3f", m) end
  return table.concat(parts, ", ")
end)()))
print(string.format("median over %d simulated (fixture, stat) pairs %.3f; largest fixture median %.3f; that"
  .. " rounded up to 2 places %.2f", #all, median(all), largest, math.ceil(largest * 100) / 100))
print(string.format("Core/Defaults stageStratificationGain %s", tostring(Defaults.stageStratificationGain)))
print(string.format("%.0f s", os.clock() - t0))
