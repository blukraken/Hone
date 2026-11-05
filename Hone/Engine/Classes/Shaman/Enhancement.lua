-- Enhancement Shaman model, the first class behind the engine contract.
--
-- simulate dispatches on scenario.path. Each path reads the snapshot's `model` field, which
-- carries the character sheet, buffs, spells and rotation (see EventSim.character).
--   event    EventSim: every swing, cast and proc on an event queue
--
-- weigh is the contract's batch hook. Per batch it runs the base snapshot once and each
-- simulated stat once on the same seed, so every weight is a paired forward difference.
--   pathwise  a stat whose perPoint terms are only attack power and spell damage
--             (strength, attack power) takes its weight from the base run's
--             dDamage/dAttackPower and dDamage/dSpellDamage, with no run of its own
--   derived   agility moves only melee crit on this class, so its weight is the crit
--             weight times perPoint.agility / perPoint.crit_rating (asserted below);
--             scenario.agilityFromCrit = false simulates it instead
--   simulated every other stat, at its +step from the scenario
-- With scenario.stopRule set, batches of stopBatchSize fights repeat and each weight stops
-- by the named rule (Core/Defaults stopRules), with se from the batch means. Without one, a
-- single batch of scenario.iterations fights runs.
--
-- Snapshot fields read
--   stats, anchor            stat totals now and when the sheet values were read
--   model                    sheet, perPoint, buffs, spells, talentEffects, mana, procs, rotation
--   weapons                  mainHand and offHand as { min, max, speed }
--   imbues                   mainHand and offHand imbue names
--   talents                  talent ranks by name
--   level, targetLevel

local _, ns = ...
local Engine = ns.Engine
local Core = Engine.Core
local Shaman = Engine.Classes.Shaman
local AttackTable, Stats, Weights = Core.AttackTable, Core.Stats, Core.Weights

local Enhancement = {}
Shaman.Enhancement = Enhancement

Enhancement.weightStats = {
  "strength", "agility", "intellect", "attack_power", "hit_rating", "crit_rating", "haste_rating",
}

Enhancement.MODELED_IMBUES = { WindfuryWeapon = true, FlametongueWeapon = true, RockbiterWeapon = true,
                               NoImbue = true }

-- Mechanics the fixtures carry that no path models.
Enhancement.UNMODELED = {
  "improved_stormstrike_regen", "five_second_rule", "lightning_overload", "spell_travel_time",
}

-- Event path options an evaluate uses (EventSim's header explains each). scenario.event
-- overrides any of them. `stratify` stratifies a batch whose fight count is prime.
Enhancement.EVENT_OPTIONS = {
  draws = "indexed", stratify = true, tableFlip = true, condDamage = true, window = true,
  pathwise = true, flurryFirst = true,
}

-- Every option off: main's EventSim at 11ba1ed, draw for draw.
Enhancement.SEQUENTIAL = {
  draws = "stream", stratify = false, tableFlip = false, condDamage = false, window = false,
  pathwise = false, flurryFirst = false,
}

-- perPoint fields the pathwise slopes cover, and the run slope each one reads.
Enhancement.PATHWISE_FIELDS = { attackPower = "dAP", spellDamage = "dSP" }

Enhancement.PATHS = {}

------------------------------------------------------------------------------
-- Statistics over fights
------------------------------------------------------------------------------

function Enhancement.meanAndStdev(values)
  local n, sum = #values, 0
  for i = 1, n do sum = sum + values[i] end
  local mean = sum / n
  local sq = 0
  for i = 1, n do
    local d = values[i] - mean
    sq = sq + d * d
  end
  return mean, n > 1 and math.sqrt(sq / (n - 1)) or 0
end

local function isPrime(n)
  if n < 2 or n ~= math.floor(n) then return false end
  for d = 2, math.floor(math.sqrt(n)) do
    if n % d == 0 then return false end
  end
  return true
end

-- The EventSim options for a run of `fights` fights under `scenario`.
function Enhancement.eventOptions(scenario, fights)
  local o = {}
  for k, v in pairs(Enhancement.EVENT_OPTIONS) do o[k] = v end
  for k, v in pairs(scenario.event or {}) do o[k] = v end
  if o.draws == "indexed" and o.stratify and fights and isPrime(fights) then o.lhs = fights end
  o.stratify = nil
  o.tally = scenario.tally
  return o
end

------------------------------------------------------------------------------
-- Event path
------------------------------------------------------------------------------

-- One run of `fights` fights on `seed`.
local function eventRun(snapshot, scenario, seed, fights)
  local EventSim = Shaman.EventSim
  local opts = Enhancement.eventOptions(scenario, fights)
  local values, windfury, tally, slopes = EventSim.run(EventSim.character(snapshot), scenario, seed, fights, opts)
  local mean, stdev = Enhancement.meanAndStdev(values)
  local out = { dps = mean, dpsStdev = stdev, iterations = #values, tally = opts.tally and tally or nil }
  if slopes then
    out.dAP = Enhancement.meanAndStdev(slopes.dAP)
    out.dSP = Enhancement.meanAndStdev(slopes.dSP)
  end
  if windfury then
    out.windfury = { eligible = windfury.eligible, rolls = windfury.rolls, procs = windfury.procs }
  end
  return out
end

Enhancement.PATHS.event = function(snapshot, scenario)
  return eventRun(snapshot, scenario, scenario.seed, scenario.iterations)
end

------------------------------------------------------------------------------
-- Weights in batches
------------------------------------------------------------------------------

local function onlyFields(rates, allowed)
  for field in pairs(rates or {}) do
    if not allowed[field] then return false end
  end
  return true
end

-- How each stat gets its weight: { kind = "pathwise", rates = perPoint[stat] },
-- { kind = "derived", from = stat, ratio = n } or { kind = "simulated" }.
function Enhancement.weightPlan(snapshot, scenario, stats)
  local perPoint = snapshot.model.perPoint or {}
  local opts = Enhancement.eventOptions(scenario)
  local plan = {}
  for _, stat in ipairs(stats) do
    local rates = perPoint[stat]
    if opts.pathwise and rates and next(rates) and onlyFields(rates, Enhancement.PATHWISE_FIELDS) then
      plan[stat] = { kind = "pathwise", rates = rates }
    elseif stat == "agility" and rates and perPoint.crit_rating and scenario.agilityFromCrit ~= false then
      -- Agility as scaled crit holds only while agility reaches nothing but melee crit.
      assert(onlyFields(rates, { meleeCritPercent = true }),
        "agility from crit needs perPoint.agility with melee crit alone (no attack power term)")
      assert(onlyFields(perPoint.crit_rating, { meleeCritPercent = true }) and perPoint.crit_rating.meleeCritPercent,
        "agility from crit needs perPoint.crit_rating with melee crit alone")
      plan[stat] = { kind = "derived", from = "crit_rating",
                     ratio = rates.meleeCritPercent / perPoint.crit_rating.meleeCritPercent }
    else
      plan[stat] = { kind = "simulated" }
    end
  end
  for _, entry in pairs(plan) do
    if entry.kind == "derived" and not plan[entry.from] then plan[entry.from] = { kind = "simulated", hidden = true } end
  end
  return plan
end

-- Whether a weight's batch-mean se meets the stop rule.
local function settled(rule, se, weight)
  if rule.stake then return rule.z * se * rule.points < rule.stake end
  return rule.z * se <= rule.relative * math.abs(weight)
end

local function summary(values)
  local mean, sd = Enhancement.meanAndStdev(values)
  return mean, #values > 1 and sd / math.sqrt(#values) or math.huge
end

-- The contract's batch hook. Returns { dps, dpsStdev, iterations, weights, se, fights,
-- batches, fightsTotal } where fights[stat] counts the fights the stat's own runs used
-- (a pathwise or derived stat reports the batches it waited for).
function Enhancement.weigh(snapshot, scenario, stats, steps)
  local plan = Enhancement.weightPlan(snapshot, scenario, stats)
  local rule = scenario.stopRule and assert(scenario.stopRules[scenario.stopRule],
    "no stop rule named " .. tostring(scenario.stopRule))
  local size = rule and scenario.stopBatchSize or scenario.iterations
  local minB, maxB = rule and scenario.stopMinBatches or 1, rule and scenario.stopMaxBatches or 1

  local order = {}
  for stat in pairs(plan) do order[#order + 1] = stat end
  table.sort(order)
  local samples, active, stoppedAt = {}, {}, {}
  for _, stat in ipairs(order) do samples[stat], active[stat] = {}, true end
  local base, perFight, total, b = {}, {}, 0, 0

  local function anyActive()
    for _, stat in ipairs(order) do
      if active[stat] then return true end
    end
    return false
  end

  while b < maxB and anyActive() do
    b = b + 1
    local seed = scenario.seed + b - 1
    local run = eventRun(snapshot, scenario, seed, size)
    base[b], perFight[b] = run.dps, run.dpsStdev
    total = total + size
    for _, stat in ipairs(order) do
      local entry = plan[stat]
      if active[stat] and entry.kind == "simulated" then
        local step = steps[stat] or scenario.weightDelta
        local plus = eventRun(Weights.shift(snapshot, stat, step), scenario, seed, size)
        samples[stat][b] = (plus.dps - run.dps) / step
        total = total + size
      elseif active[stat] and entry.kind == "pathwise" then
        local w = 0
        for field, rate in pairs(entry.rates) do w = w + rate * run[Enhancement.PATHWISE_FIELDS[field]] end
        samples[stat][b] = w
      end
    end
    for _, stat in ipairs(order) do
      local entry = plan[stat]
      if active[stat] and entry.kind == "derived" then samples[stat][b] = entry.ratio * samples[entry.from][b] end
    end
    if rule and b >= minB then
      for _, stat in ipairs(order) do
        if active[stat] then
          local mean, se = summary(samples[stat])
          if settled(rule, se, mean) then active[stat] = false end
        end
      end
      -- A source keeps running while a stat derived from it still needs batches.
      for _, stat in ipairs(order) do
        local entry = plan[stat]
        if active[stat] and entry.kind == "derived" then active[entry.from] = true end
      end
      for _, stat in ipairs(order) do
        if not active[stat] and not stoppedAt[stat] then stoppedAt[stat] = b end
      end
    end
  end

  local out = { weights = {}, se = {}, fights = {}, batches = b, fightsTotal = total, settled = {} }
  for _, stat in ipairs(order) do
    local mean, se = summary(samples[stat])
    if not plan[stat].hidden then
      out.weights[stat], out.se[stat] = mean, se
      out.fights[stat] = size * (stoppedAt[stat] or b)
      out.settled[stat] = stoppedAt[stat] ~= nil
    end
  end
  out.plan = plan
  out.dps = summary(base)
  out.dpsStdev = perFight[1]
  out.iterations = size * b
  out.batchDps = base
  return out
end

------------------------------------------------------------------------------
-- Contract functions
------------------------------------------------------------------------------

function Enhancement.simulate(snapshot, scenario)
  local path = scenario.path or "event"
  local run = Enhancement.PATHS[path]
  if not run then error("Enhancement has no path named " .. tostring(path), 2) end
  return run(snapshot, scenario)
end

-- Every hit cap in rating: special attacks', and white attacks' when dual wielding.
function Enhancement.caps(snapshot)
  local level = snapshot.level or 60
  local tbl = AttackTable.forLevels(level, snapshot.targetLevel or level)
  local model = snapshot.model
  local rating = (snapshot.stats and snapshot.stats.hit_rating) or 0
  local anchor = (snapshot.anchor and snapshot.anchor.hit_rating) or rating
  local hitPercent = model.sheet.meleeHitPercent
    + (model.perPoint.hit_rating and model.perPoint.hit_rating.meleeHitPercent or 0) * (rating - anchor)
  local dualWield = snapshot.weapons and snapshot.weapons.offHand ~= nil
  local list = { AttackTable.specialHitCap(tbl) }
  if dualWield then list[2] = AttackTable.whiteHitCap(tbl, true) end
  local out = {}
  for i, capPercent in ipairs(list) do
    out[i] = rating + Stats.ratingFromPercent("hit_rating", capPercent - hitPercent, level)
  end
  return { hit_rating = out }
end

function Enhancement.coverage(snapshot)
  local out = {}
  for _, name in ipairs(Enhancement.UNMODELED) do out[#out + 1] = name end
  local imbues = snapshot.imbues or {}
  for _, hand in ipairs({ "mainHand", "offHand" }) do
    local imbue = imbues[hand]
    if imbue and not Enhancement.MODELED_IMBUES[imbue] then out[#out + 1] = "imbue:" .. imbue end
  end
  if (snapshot.level or 60) ~= 60 then out[#out + 1] = "level:" .. tostring(snapshot.level) end
  return out
end

Engine.Contract.register("SHAMAN", "ENHANCEMENT", Enhancement)

return Enhancement
