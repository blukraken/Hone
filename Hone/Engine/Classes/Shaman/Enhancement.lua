-- Enhancement Shaman model, the first class behind the engine contract.
--
-- simulate dispatches on scenario.path. Each path reads the snapshot's `model` field, which
-- carries the character sheet, buffs, spells and rotation (see EventSim.character).
--   event    EventSim: every swing, cast and proc on an event queue
--
-- fightPlan is the contract's stepper hook (Core/Weights.lua runs the stages). Every weight
-- is a paired forward difference on the same seed as the base run.
--   pathwise  a stat whose perPoint terms are only attack power and spell damage
--             (strength, attack power) takes its weight from the base run's
--             dDamage/dAttackPower and dDamage/dSpellDamage, with no run of its own
--   zero      melee hit at or past its last cap has no run and a weight of 0
--   simulated every other stat, agility included, at its +step from the scenario
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
-- overrides any of them. `stratify` stratifies a batch whose stratum count is prime.
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

-- The EventSim options under `scenario`, stratified over `strata` fights when it is prime.
function Enhancement.eventOptions(scenario, strata)
  local o = {}
  for k, v in pairs(Enhancement.EVENT_OPTIONS) do o[k] = v end
  for k, v in pairs(scenario.event or {}) do o[k] = v end
  if o.draws == "indexed" and o.stratify and strata and isPrime(strata) then o.lhs = strata end
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
-- Staged weights
------------------------------------------------------------------------------

local function onlyFields(rates, allowed)
  for field in pairs(rates or {}) do
    if not allowed[field] then return false end
  end
  return true
end

-- How each stat gets its weight (Core/Weights stepper kinds).
--   pathwise   perPoint terms are only attack power and spell damage, so the weight is the
--              base run's per-fight slopes times those rates
--   zero       melee hit at or past its last cap, which moves nothing the event path reads
--   simulated  every other stat, at its +step
function Enhancement.weightKinds(snapshot, scenario, stats)
  local perPoint = snapshot.model.perPoint or {}
  local opts = Enhancement.eventOptions(scenario)
  local caps = Enhancement.caps(snapshot)
  local kinds = {}
  for _, stat in ipairs(stats) do
    local rates = perPoint[stat]
    local list = caps[stat]
    local value = snapshot.stats and snapshot.stats[stat] or 0
    if opts.pathwise and rates and next(rates) and onlyFields(rates, Enhancement.PATHWISE_FIELDS) then
      kinds[stat] = "pathwise"
    elseif list and #list > 0 and value >= math.max(unpack(list)) - 1e-9
        and onlyFields(rates, { meleeHitPercent = true }) then
      kinds[stat] = "zero"
    else
      kinds[stat] = "simulated"
    end
  end
  return kinds
end

-- The contract's stepper hook. run(stat, seed, strata, first, count) runs fights first ..
-- first + count - 1 of the base snapshot (stat nil) or of the snapshot at +steps[stat], with
-- the base run's pathwise weights per fight.
function Enhancement.fightPlan(snapshot, scenario, stats, steps)
  local EventSim = Shaman.EventSim
  local kinds = Enhancement.weightKinds(snapshot, scenario, stats)
  local perPoint = snapshot.model.perPoint or {}
  local chars = { [0] = EventSim.character(snapshot) }
  local pathwise = {}
  for _, stat in ipairs(stats) do
    if kinds[stat] == "simulated" then
      chars[stat] = EventSim.character(Weights.shift(snapshot, stat, steps[stat]))
    elseif kinds[stat] == "pathwise" then
      pathwise[#pathwise + 1] = stat
    end
  end
  local optsFor = { [false] = Enhancement.eventOptions(scenario) }

  local function run(stat, seed, strata, first, count)
    local opts = optsFor[strata or false]
    if not opts then
      opts = Enhancement.eventOptions(scenario, strata)
      optsFor[strata] = opts
    end
    opts.first = first
    local values, _, _, slopes = EventSim.run(chars[stat or 0], scenario, seed, count, opts)
    local pw
    if not stat and #pathwise > 0 then
      pw = {}
      for _, name in ipairs(pathwise) do
        local list = {}
        for i = 1, count do
          local w = 0
          for field, rate in pairs(perPoint[name]) do
            w = w + rate * slopes[Enhancement.PATHWISE_FIELDS[field]][i]
          end
          list[i] = w
        end
        pw[name] = list
      end
    end
    return values, pw
  end

  return { kinds = kinds, run = run }
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
