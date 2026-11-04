-- Enhancement Shaman model, the first class behind the engine contract.
--
-- simulate dispatches on scenario.path. Each path reads the snapshot's `model` field, which
-- carries the character sheet, buffs, spells and rotation (see EventSim.character).
--   event    EventSim: every swing, cast and proc on an event queue
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
local AttackTable, Stats, Rng = Core.AttackTable, Core.Stats, Core.Rng

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

------------------------------------------------------------------------------
-- Event path
------------------------------------------------------------------------------

Enhancement.PATHS.event = function(snapshot, scenario)
  local EventSim = Shaman.EventSim
  local char = EventSim.character(snapshot)
  local rng = Rng.new(scenario.seed)
  local values, windfury, tally = EventSim.run(char, scenario, rng, scenario.iterations)
  local mean, stdev = Enhancement.meanAndStdev(values)
  local out = { dps = mean, dpsStdev = stdev, iterations = #values, tally = tally }
  if windfury then
    out.windfury = { eligible = windfury.eligible, rolls = windfury.rolls, procs = windfury.procs }
  end
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
