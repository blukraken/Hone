-- The spell attack table: miss chance and partial resists by level gap.
--
-- Translated from MythicSim at commit 8e9b8df69ef9b27f16c23b51e1bb1686bd9f1d68,
-- src/mechanics/damage.rs (MIT, see NOTICE beside this file): a level gap above 0 adds 2% per
-- level to the resist coefficient, binary spells take no partial resist, and a spell never hits
-- more often than 99%.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local SpellTable = {}
ns.Engine.Core.SpellTable = SpellTable

SpellTable.LEVEL_RESIST_PER_LEVEL = 0.02
SpellTable.MIN_MISS = 0.01
SpellTable.CRIT_MULTIPLIER = 1.5

-- Resist coefficient against a target with no resistance, from the level gap alone.
function SpellTable.levelCoefficient(attackerLevel, targetLevel)
  local gap = targetLevel - attackerLevel
  if gap <= 0 then return 0 end
  local c = SpellTable.LEVEL_RESIST_PER_LEVEL * gap / 0.75
  return c < 1 and c or 1
end

-- Roll thresholds for a partial resist: a roll above `none` resists nothing, above `quarter`
-- a quarter, above `half` half, and anything lower three quarters.
function SpellTable.partialThresholds(coefficient)
  local v = coefficient * 3
  if v <= 1 then return 0.76 * v, 0.21 * v, 0.03 * v end
  if v <= 2 then
    v = v - 1
    return 0.76 + 0.24 * v, 0.21 + 0.57 * v, 0.03 + 0.19 * v
  end
  v = v - 2
  return 1, 0.78 + 0.18 * v, 0.22 + 0.58 * v
end

-- Damage share a partial resist roll leaves.
function SpellTable.partialMultiplier(roll, none, quarter, half)
  if roll > none then return 1 end
  if roll > quarter then return 0.75 end
  if roll > half then return 0.5 end
  return 0.25
end

-- Mean damage share partial resists leave at a coefficient, for analytic paths.
function SpellTable.partialMean(coefficient)
  local none, quarter, half = SpellTable.partialThresholds(coefficient)
  return (1 - none) + 0.75 * (none - quarter) + 0.5 * (quarter - half) + 0.25 * half
end

-- Miss chance from the table's base spell miss and the caster's spell hit percent.
function SpellTable.missChance(baseMiss, hitPercent)
  local miss = baseMiss - hitPercent / 100
  if miss < SpellTable.MIN_MISS then miss = SpellTable.MIN_MISS end
  return miss
end

return SpellTable
