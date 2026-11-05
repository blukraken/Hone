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
--   paired differences and its se their spread over sqrt(n), with n - 1 degrees of freedom.
-- Stage 2, verdicts. Batch k of stageBatchSize fights runs on seed + k, stratified. Once a
--   stat has stageMinBatches batches, the spread of its batch means gives a second estimate
--   with batches - 1 degrees of freedom. It is combined with stage 1 by inverse variance, and
--   the combination takes the Welch-Satterthwaite degrees of freedom. Until then the weight is
--   stage 1's. The stage holds when every half-width x stakePoints is under stageStake DPS.
-- Stage 3, final. The same batches, until every half-width is under stageRelative x |weight|.
--
-- Every half-width is t(stageQuantile, df) x se at the estimate's own degrees of freedom, so
-- an estimate from few batches carries the wider interval its spread has earned.
--
-- A unit of work is stage 1's runs, or one batch for one stat. The next unit goes to the stat
-- whose half-width is furthest over the next stage's target. A stat's batch k pairs with base
-- batch k, which runs first when no earlier unit ran it. A pathwise stat's unit is the next
-- base batch. step(fights) runs at most that many fights and returns early when a stage
-- completes. The stepper is done at stage 3, or once a unit would start past stageMaxFights.
------------------------------------------------------------------------------

local sqrt, huge, min, abs = math.sqrt, math.huge, math.min, math.abs
local log, exp = math.log, math.exp

local FINAL_STAGE = 3
Weights.FINAL_STAGE = FINAL_STAGE

------------------------------------------------------------------------------
-- Student t quantile
--
-- The engine's one t quantile. From df 5 up it is the Cornish-Fisher expansion in 1/df (good
-- to 1e-3), the same as tests/addon/engine/compare.lua. Below df 5 it inverts the exact t
-- distribution through the regularized incomplete beta, because a Welch-Satterthwaite df is
-- not a whole number and the expansion drifts there.
------------------------------------------------------------------------------

-- Acklam's normal quantile.
local NA = { -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
             1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 }
local NB = { -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
             6.680131188771972e+01, -1.328068155288572e+01 }
local NC = { -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
             -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 }
local ND = { 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
             3.754408661907416e+00 }

local function normalQuantile(p)
  if p < 0.02425 then
    local q = sqrt(-2 * log(p))
    return (((((NC[1] * q + NC[2]) * q + NC[3]) * q + NC[4]) * q + NC[5]) * q + NC[6]) /
      ((((ND[1] * q + ND[2]) * q + ND[3]) * q + ND[4]) * q + 1)
  elseif p > 1 - 0.02425 then
    return -normalQuantile(1 - p)
  end
  local q = p - 0.5
  local r = q * q
  return (((((NA[1] * r + NA[2]) * r + NA[3]) * r + NA[4]) * r + NA[5]) * r + NA[6]) * q /
    (((((NB[1] * r + NB[2]) * r + NB[3]) * r + NB[4]) * r + NB[5]) * r + 1)
end
Weights.normalQuantile = normalQuantile

-- Lanczos log gamma, for x >= 0.5.
local LANCZOS = { 0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
                  -176.61502916214059, 12.507343278686905, -0.13857109526572012,
                  9.9843695780195716e-6, 1.5056327351493116e-7 }

local function logGamma(x)
  x = x - 1
  local a, t = LANCZOS[1], x + 7.5
  for i = 1, 8 do a = a + LANCZOS[i + 1] / (x + i) end
  return 0.5 * log(2 * math.pi) + (x + 0.5) * log(t) - t + log(a)
end

-- Continued fraction of the incomplete beta, by Lentz's method.
local function betaFraction(a, b, x)
  local tiny = 1e-300
  local c, d = 1, 1 - (a + b) * x / (a + 1)
  if abs(d) < tiny then d = tiny end
  d = 1 / d
  local h = d
  for m = 1, 300 do
    local m2 = 2 * m
    local aa = m * (b - m) * x / ((a - 1 + m2) * (a + m2))
    d = 1 + aa * d
    if abs(d) < tiny then d = tiny end
    c = 1 + aa / c
    if abs(c) < tiny then c = tiny end
    d = 1 / d
    h = h * d * c
    aa = -(a + m) * (a + b + m) * x / ((a + m2) * (a + 1 + m2))
    d = 1 + aa * d
    if abs(d) < tiny then d = tiny end
    c = 1 + aa / c
    if abs(c) < tiny then c = tiny end
    d = 1 / d
    local del = d * c
    h = h * del
    if abs(del - 1) < 1e-14 then break end
  end
  return h
end

-- Regularized incomplete beta I_x(a, b), given lnBeta = log B(a, b).
local function incompleteBeta(a, b, x, lnBeta)
  if x <= 0 then return 0 end
  if x >= 1 then return 1 end
  local front = exp(a * log(x) + b * log(1 - x) - lnBeta)
  if x < (a + 1) / (a + b + 2) then return front * betaFraction(a, b, x) / a end
  return 1 - front * betaFraction(b, a, 1 - x) / b
end

-- Cornish-Fisher t quantile, for p > 0.5.
local function expansionT(p, df)
  local z = normalQuantile(p)
  local z2 = z * z
  local g1 = (z2 + 1) * z / 4
  local g2 = ((5 * z2 + 16) * z2 + 3) * z / 96
  local g3 = (((3 * z2 + 19) * z2 + 17) * z2 - 15) * z / 384
  local g4 = ((((79 * z2 + 776) * z2 + 1482) * z2 - 1920) * z2 - 945) * z / 92160
  return z + g1 / df + g2 / df ^ 2 + g3 / df ^ 3 + g4 / df ^ 4
end

-- Exact t quantile for p > 0.5, by Newton's method on the upper tail from the expansion. The
-- upper tail is I_x(df / 2, 1 / 2) / 2 at x = df / (df + t^2), and its slope is minus the
-- density.
local function exactT(p, df)
  local a = df / 2
  local lnBeta = logGamma(a) + logGamma(0.5) - logGamma(a + 0.5)
  local scale = exp(-lnBeta) / sqrt(df)
  local q, t = 1 - p, expansionT(p, df)
  for _ = 1, 50 do
    local t2 = t * t
    local upper = incompleteBeta(a, 0.5, df / (df + t2), lnBeta) / 2
    local density = scale * (1 + t2 / df) ^ (-(df + 1) / 2)
    local nextT = t + (upper - q) / density
    if nextT <= 0 then nextT = t / 2 end
    local done = abs(nextT - t) <= 1e-12 * t
    t = nextT
    if done then break end
  end
  return t
end

-- Student t quantile at probability p and df degrees of freedom. A df under 1 counts as 1.
function Weights.tQuantile(p, df)
  if df == huge then return normalQuantile(p) end
  if df < 1 then df = 1 end
  if p == 0.5 then return 0 end
  local upper = p > 0.5 and p or 1 - p
  local t = df < 5 and exactT(upper, df) or expansionT(upper, df)
  return p > 0.5 and t or -t
end
local tQuantile = Weights.tQuantile

------------------------------------------------------------------------------
-- Stepper
------------------------------------------------------------------------------

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

-- Inverse-variance combination of two estimates with df1 and df2 degrees of freedom. Returns
-- the mean, its variance and the Welch-Satterthwaite degrees of freedom. A zero variance wins
-- outright.
local function combine(m1, v1, m2, v2, df1, df2)
  if m1 == nil or v1 == huge then return m2, v2, df2 end
  if v1 == 0 and v2 == 0 then return (m1 + m2) / 2, 0, huge end
  if v1 == 0 then return m1, 0, huge end
  if v2 == 0 then return m2, 0, huge end
  local w1, w2 = 1 / v1, 1 / v2
  local w = w1 + w2
  local df = huge
  if df1 and df2 then df = w * w / (w1 * w1 / df1 + w2 * w2 / df2) end
  return (m1 * w1 + m2 * w2) / w, 1 / w, df
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
    minBatches = scenario.stageMinBatches, gain = scenario.stageStratificationGain,
    pathwiseGain = scenario.stagePathwiseGain,
    quantile = scenario.stageQuantile, stake = scenario.stageStake,
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

-- Weight, variance of the weight, fights behind it, batches in it and degrees of freedom.
--
-- The stop test (gap, below) reads this variance. A stat's batch-mean variance never falls
-- below its stage 1 per-fight variance x its kind's gain / its batch fights, and keeps
-- batches - 1 degrees of freedom. The gain is stageStratificationGain for a simulated stat and
-- stagePathwiseGain for a pathwise slope. A few batches can agree by luck, and the stepper
-- stops giving batches to a stat whose spread looks small, so without this floor that stat
-- stops on a too-narrow interval.
function Stepper:estimate(stat)
  local kind = self.plan.kinds[stat]
  if kind == "zero" then return 0, 0, 0, 0, huge end
  local samples = self:firstSamples(stat)
  local m, v = meanVar(samples)
  local n1 = #samples
  local df = n1 - 1
  local means = self.means[stat]
  local nb = #means
  if nb >= self.minBatches then
    local m2, v2 = meanVar(means)
    if v ~= huge then
      local gain = kind == "pathwise" and self.pathwiseGain or self.gain
      local floor = v * n1 * gain / (nb * self.batchSize)
      if v2 < floor then v2 = floor end
    end
    m, v, df = combine(m, v, m2, v2, df, nb - 1)
  end
  return m, v, n1 + nb * self.batchSize, nb, df
end

-- The 95% half-width of an estimate with variance v and df degrees of freedom.
function Stepper:halfWidth(v, df)
  if v == 0 then return 0 end
  if v == huge then return huge end
  return tQuantile(self.quantile, df) * sqrt(v)
end

-- Half-width over the target of `stage`. Under 1, or a half-width of 0, meets it.
function Stepper:gap(stat, stage)
  local w, v, _, _, df = self:estimate(stat)
  local hw = self:halfWidth(v, df)
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

-- The current answer: { stage, done, weights, halfWidths, se, df, fights, batches,
-- fightsTotal, dps, dpsStdev, kinds, steps }. fights[stat] counts the paired fights behind the
-- weight, or the base fights for a pathwise stat.
function Stepper:result()
  local out = { stage = self.stage, done = self.done, weights = {}, halfWidths = {}, se = {}, df = {},
                fights = {}, batches = {}, fightsTotal = self.fightsTotal, kinds = self.plan.kinds,
                steps = self.steps }
  for _, stat in ipairs(self.stats) do
    local w, v, fights, nb, df = self:estimate(stat)
    out.weights[stat], out.se[stat], out.halfWidths[stat] = w, sqrt(v), self:halfWidth(v, df)
    out.df[stat], out.fights[stat], out.batches[stat] = df, fights, nb
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
