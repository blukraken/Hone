-- Stat weights by finite differences over a class's simulate function.
--
-- Every run uses the scenario's seed, so the base and each perturbed run share their random
-- stream and the difference carries less noise than either run alone.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local Table = ns.Engine.Core.Table

local Weights = {}
ns.Engine.Core.Weights = Weights

-- The snapshot with `amount` added to one stat.
function Weights.shift(snapshot, stat, amount)
  local out = Table.copy(snapshot)
  out.stats = out.stats or {}
  out.stats[stat] = (out.stats[stat] or 0) + amount
  return out
end

-- The step of every stat in `stats`. A stat's step is `steps[stat]`, else `fallback`. A step
-- that would carry the stat past a cap above it stops at that cap, so the weight is the slope
-- below the cap.
function Weights.steps(snapshot, stats, steps, fallback, caps)
  local out = {}
  for _, stat in ipairs(stats) do
    local step = (steps and steps[stat]) or fallback
    local value = (snapshot.stats and snapshot.stats[stat]) or 0
    for _, cap in ipairs(caps[stat] or {}) do
      if cap > value and cap < value + step then step = cap - value end
    end
    out[stat] = step
  end
  return out
end

-- Forward-difference weight of every stat in `stats`, per point, at each stat's own step.
function Weights.forward(dpsOf, snapshot, base, stats, steps)
  local weights = {}
  for _, stat in ipairs(stats) do
    local step = steps[stat]
    weights[stat] = (dpsOf(Weights.shift(snapshot, stat, step)) - base) / step
  end
  return weights
end

-- One-sided weights at every cap within `window` steps of a stat's value. `caps` maps a stat
-- to a list of the stat values where its caps are. Both slopes are taken at the cap itself, so
-- `below` is the loss per point under it and `above` the gain per point past it. Each stat's
-- entries are sorted by cap. `base` is the dps at the snapshot, or a function that gives it,
-- called only when a stat sits exactly at a cap.
function Weights.caps(dpsOf, snapshot, base, caps, steps, fallback, window)
  local baseValue = type(base) == "number" and base or nil
  local function baseOf()
    if not baseValue then baseValue = base() end
    return baseValue
  end
  local out = {}
  for _, stat in ipairs(Table.sortedKeys(caps)) do
    local step = (steps and steps[stat]) or fallback
    local value = (snapshot.stats and snapshot.stats[stat]) or 0
    local list = {}
    for _, cap in ipairs(caps[stat]) do list[#list + 1] = cap end
    table.sort(list)
    local entries = {}
    for _, cap in ipairs(list) do
      if math.abs(value - cap) <= window * step then
        local toCap = cap - value
        local atCap = toCap == 0 and baseOf() or dpsOf(Weights.shift(snapshot, stat, toCap))
        local below = (atCap - dpsOf(Weights.shift(snapshot, stat, toCap - step))) / step
        local above = (dpsOf(Weights.shift(snapshot, stat, toCap + step)) - atCap) / step
        entries[#entries + 1] = { below = below, above = above, cap = cap, value = value }
      end
    end
    if #entries > 0 then out[stat] = entries end
  end
  return out
end

------------------------------------------------------------------------------
-- Staged weights (decision 0014)
--
-- A stepper weighs every stat in three stages. Each stage is the same paired forward
-- difference with more fights, so there is one estimator. A model hands it a plan:
--   plan.kinds[stat]  "simulated" (a run of its own at +steps[stat]), "pathwise" (a per-fight
--                     slope the base run reports) or "zero" (no run, the weight is 0)
--   plan.run(stat, seed, strata, first, count)
--                     fights first .. first + count - 1 of one run. stat nil is the base
--                     snapshot, else the snapshot at +steps[stat]. strata nil leaves the
--                     fights unstratified; a prime strata stratifies a batch of that many.
--                     Returns per-fight dps and, for the base run, { [stat] = per-fight
--                     weights } for every pathwise stat.
-- Fight f of a run must depend only on (seed, strata, f), so steps of any size give the same
-- answer. The numbers below are Core/Defaults fields, which a scenario overrides.
--
-- Stage 1, first answer. stageFirstFights fights split evenly over the base run and every
--   simulated stat, on scenario.seed, unstratified. A weight is the mean of its per-fight
--   paired differences and its se their spread over sqrt(n).
-- Stage 2, verdicts. Batch k of stageBatchSize fights runs on seed + k, stratified. Once a
--   stat has stageMinBatches batches, the spread of its batch means gives a second estimate,
--   combined with stage 1 by inverse variance; until then its weight is stage 1's. The stage
--   holds when every stageZ x se x stakePoints is under stageStake DPS.
-- Stage 3, final. The same batches, until every stageZ x se is under stageRelative x |weight|.
--
-- A unit of work is stage 1's runs, or one batch for one stat. The next unit goes to the stat
-- whose half-width is furthest over the next stage's target. A stat's batch k pairs with base
-- batch k, which runs first when no earlier unit ran it. A pathwise stat's unit is the next
-- base batch. step(fights) runs at most that many fights and returns early when a stage
-- completes. The stepper is done at stage 3, or once a unit would start past stageMaxFights.
------------------------------------------------------------------------------

local sqrt, huge, min, abs = math.sqrt, math.huge, math.min, math.abs

local FINAL_STAGE = 3
Weights.FINAL_STAGE = FINAL_STAGE

-- Mean of values[1..n] and the variance of that mean.
local function meanVar(values, n)
  n = n or #values
  if n == 0 then return nil, huge end
  local sum = 0
  for i = 1, n do sum = sum + values[i] end
  local mean = sum / n
  if n < 2 then return mean, huge end
  local sq = 0
  for i = 1, n do
    local d = values[i] - mean
    sq = sq + d * d
  end
  return mean, sq / (n - 1) / n
end
Weights.meanVar = meanVar

-- Inverse-variance combination of two estimates. A zero variance wins outright.
local function combine(m1, v1, m2, v2)
  if m1 == nil or v1 == huge then return m2, v2 end
  if v1 == 0 and v2 == 0 then return (m1 + m2) / 2, 0 end
  if v1 == 0 then return m1, 0 end
  if v2 == 0 then return m2, 0 end
  local w1, w2 = 1 / v1, 1 / v2
  return (m1 * w1 + m2 * w2) / (w1 + w2), 1 / (w1 + w2)
end
Weights.combine = combine

local Stepper = {}
Stepper.__index = Stepper

-- A stepper over `plan` for `stats` (their order breaks ties) at `steps`, with the stage
-- numbers and seed read from `scenario`.
function Weights.stepper(plan, stats, steps, scenario)
  local self = setmetatable({
    plan = plan, stats = stats, steps = steps, seed = scenario.seed,
    firstFights = scenario.stageFirstFights, batchSize = scenario.stageBatchSize,
    minBatches = scenario.stageMinBatches, z = scenario.stageZ, stake = scenario.stageStake,
    points = scenario.stakePoints, relative = scenario.stageRelative, maxFights = scenario.stageMaxFights,
    stage = 0, done = false, fightsTotal = 0, unit = nil,
    first = { base = {}, plus = {}, pw = {} },
    base = {}, baseDone = 0, plus = {}, means = {}, simulated = {},
  }, Stepper)
  for _, stat in ipairs(stats) do
    local kind = assert(plan.kinds[stat], "plan has no kind for " .. tostring(stat))
    self.plus[stat], self.means[stat] = {}, {}
    if kind == "simulated" then
      self.simulated[#self.simulated + 1] = stat
      self.first.plus[stat] = {}
    elseif kind == "pathwise" then
      self.first.pw[stat] = {}
    end
  end
  return self
end

-- Per-fight stage 1 samples of one stat.
function Stepper:firstSamples(stat)
  if self.plan.kinds[stat] == "pathwise" then return self.first.pw[stat] end
  local base, plus, step = self.first.base, self.first.plus[stat], self.steps[stat]
  local out = {}
  for i = 1, min(#base, #plus) do out[i] = (plus[i] - base[i]) / step end
  return out
end

-- Weight, variance of the weight, fights behind it and batches in it.
function Stepper:estimate(stat)
  if self.plan.kinds[stat] == "zero" then return 0, 0, 0, 0 end
  local samples = self:firstSamples(stat)
  local m, v = meanVar(samples)
  local means = self.means[stat]
  local nb = #means
  if nb >= self.minBatches then
    local m2, v2 = meanVar(means)
    m, v = combine(m, v, m2, v2)
  end
  return m, v, #samples + nb * self.batchSize, nb
end

-- Half-width over the target of `stage`. Under 1, or a half-width of 0, meets it.
function Stepper:gap(stat, stage)
  local w, v = self:estimate(stat)
  local hw = self.z * sqrt(v)
  if hw == 0 then return 0 end
  local target = stage == 2 and self.stake / self.points or self.relative * abs(w or 0)
  if target == 0 then return huge end
  return hw / target
end

local function meets(self, stage)
  for _, stat in ipairs(self.stats) do
    if self:gap(stat, stage) >= 1 then return false end
  end
  return true
end

local function segment(stat, seed, strata, count, sink, pw)
  return { stat = stat, seed = seed, strata = strata, count = count, ran = 0, sink = sink, pw = pw }
end

-- The base run's segment for batch k, with sinks for its pathwise slopes.
function Stepper:baseSegment(k)
  local batch = { dps = {}, pw = {} }
  for _, stat in ipairs(self.stats) do
    if self.plan.kinds[stat] == "pathwise" then batch.pw[stat] = {} end
  end
  self.base[k] = batch
  return segment(nil, self.seed + k, self.batchSize, self.batchSize, batch.dps, batch.pw)
end

function Stepper:firstUnit()
  local per = math.floor(self.firstFights / (1 + #self.simulated))
  if per < 2 then per = 2 end
  local first = self.first
  local segs = { segment(nil, self.seed, nil, per, first.base, first.pw) }
  for _, stat in ipairs(self.simulated) do
    segs[#segs + 1] = segment(stat, self.seed, nil, per, first.plus[stat])
  end
  return { kind = "first", segs = segs, at = 1 }
end

-- The next unit, or nil once the stepper is done.
function Stepper:nextUnit()
  if self.stage == 0 then return self:firstUnit() end
  if self.stage >= FINAL_STAGE or self.fightsTotal >= self.maxFights then
    self.done = true
    return nil
  end
  local target, pick, worst = self.stage + 1, nil, 1
  for _, stat in ipairs(self.stats) do
    local g = self:gap(stat, target)
    if g >= worst and not (pick and g == worst) then pick, worst = stat, g end
  end
  if not pick then
    self.done = true
    return nil
  end
  if self.plan.kinds[pick] == "pathwise" then
    local k = self.baseDone + 1
    return { kind = "batch", k = k, segs = { self:baseSegment(k) }, at = 1 }
  end
  local k = #self.means[pick] + 1
  local segs = {}
  if k > self.baseDone then segs[1] = self:baseSegment(k) end
  local plus = {}
  self.plus[pick][k] = plus
  segs[#segs + 1] = segment(pick, self.seed + k, self.batchSize, self.batchSize, plus)
  return { kind = "batch", k = k, stat = pick, segs = segs, at = 1 }
end

-- Books a finished unit and moves the stage on as far as the data now reaches.
function Stepper:finish(unit)
  if unit.kind == "first" then
    self.stage = 1
  else
    local k = unit.k
    if k > self.baseDone then
      self.baseDone = k
      for _, stat in ipairs(self.stats) do
        local list = self.base[k].pw[stat]
        if list then self.means[stat][k] = (meanVar(list)) end
      end
    end
    local stat = unit.stat
    if stat then
      local base, plus, step = self.base[k].dps, self.plus[stat][k], self.steps[stat]
      local sum = 0
      for i = 1, #plus do sum = sum + (plus[i] - base[i]) / step end
      self.means[stat][k] = sum / #plus
    end
  end
  while self.stage < FINAL_STAGE and meets(self, self.stage + 1) do self.stage = self.stage + 1 end
end

-- Runs at most `fights` fights and returns how many ran. Returns early when a stage completes.
function Stepper:step(fights)
  local ran, startStage = 0, self.stage
  while ran < fights and not self.done do
    local unit = self.unit or self:nextUnit()
    if not unit then break end
    self.unit = unit
    local seg = unit.segs[unit.at]
    local count = min(fights - ran, seg.count - seg.ran)
    local values, pw = self.plan.run(seg.stat, seg.seed, seg.strata, seg.ran + 1, count)
    local sink, n = seg.sink, #seg.sink
    for i = 1, count do sink[n + i] = values[i] end
    if seg.pw then
      for stat, list in pairs(seg.pw) do
        local from, m = pw[stat], #list
        for i = 1, count do list[m + i] = from[i] end
      end
    end
    seg.ran = seg.ran + count
    ran = ran + count
    self.fightsTotal = self.fightsTotal + count
    if seg.ran == seg.count then unit.at = unit.at + 1 end
    if unit.at > #unit.segs then
      self.unit = nil
      self:finish(unit)
      if self.stage >= FINAL_STAGE then self.done = true end
      if self.stage ~= startStage then break end
    end
  end
  return ran
end

-- Steps until the stepper reaches `stage` or is done.
function Stepper:run(stage)
  while self.stage < stage and not self.done do self:step(huge) end
  return self
end

-- The current answer: { stage, done, weights, halfWidths, se, fights, batches, fightsTotal,
-- dps, dpsStdev, kinds, steps }. fights[stat] counts the paired fights behind the weight, or
-- the base fights for a pathwise stat.
function Stepper:result()
  local out = { stage = self.stage, done = self.done, weights = {}, halfWidths = {}, se = {}, fights = {},
                batches = {}, fightsTotal = self.fightsTotal, kinds = self.plan.kinds, steps = self.steps }
  for _, stat in ipairs(self.stats) do
    local w, v, fights, nb = self:estimate(stat)
    out.weights[stat], out.se[stat], out.halfWidths[stat] = w, sqrt(v), self.z * sqrt(v)
    out.fights[stat], out.batches[stat] = fights, nb
  end
  local all = {}
  for i, x in ipairs(self.first.base) do all[i] = x end
  for k = 1, self.baseDone do
    for _, x in ipairs(self.base[k].dps) do all[#all + 1] = x end
  end
  local mean, var = meanVar(all)
  out.dps = mean
  out.dpsStdev = #all > 1 and sqrt(var * #all) or 0
  return out
end

return Weights
