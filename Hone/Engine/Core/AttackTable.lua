-- The melee attack table: chances by level gap and the rolls that read them.
--
-- An attacker behind its target, so parry and block never apply. Gaps 0 and 3 match
-- MythicSim's prepared tables at the pin. Gaps 1 and 2 use the classic per-skill formulas
-- and are not yet checked against a reference.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local AttackTable = {}
ns.Engine.Core.AttackTable = AttackTable

-- Chances as fractions, keyed by target level minus attacker level.
AttackTable.BY_LEVEL_GAP = {
  [0] = { miss = 0.050, dodge = 0.050, glance = 0.10, glanceMultiplier = 0.95, glanceSpread = 0.04,
          hitSuppression = 0.00, critSuppression = 0.000 },
  [1] = { miss = 0.055, dodge = 0.055, glance = 0.20, glanceMultiplier = 0.85, glanceSpread = 0.06,
          hitSuppression = 0.00, critSuppression = 0.010 },
  [2] = { miss = 0.060, dodge = 0.060, glance = 0.30, glanceMultiplier = 0.75, glanceSpread = 0.08,
          hitSuppression = 0.00, critSuppression = 0.020 },
  [3] = { miss = 0.080, dodge = 0.065, glance = 0.40, glanceMultiplier = 0.65, glanceSpread = 0.10,
          hitSuppression = 0.01, critSuppression = 0.048 },
}

-- Extra white miss chance while dual wielding.
AttackTable.DUAL_WIELD_MISS = 0.19

-- Armor reduction: armor / (armor + ARMOR_BASE + ARMOR_PER_LEVEL * attacker level).
AttackTable.ARMOR_BASE = 400
AttackTable.ARMOR_PER_LEVEL = 85
AttackTable.ARMOR_CAP = 0.75

AttackTable.CRIT_MULTIPLIER = 2.0

function AttackTable.forLevels(attackerLevel, targetLevel)
  local gap = targetLevel - attackerLevel
  if gap < 0 then gap = 0 end
  local row = AttackTable.BY_LEVEL_GAP[gap]
  if not row then
    error(string.format("no attack table for a level gap of %d", gap), 2)
  end
  local out = {}
  for k, v in pairs(row) do out[k] = v end
  return out
end

function AttackTable.armorMultiplier(armor, attackerLevel)
  local reduction = armor / (armor + AttackTable.ARMOR_BASE + AttackTable.ARMOR_PER_LEVEL * attackerLevel)
  if reduction > AttackTable.ARMOR_CAP then reduction = AttackTable.ARMOR_CAP end
  if reduction < 0 then reduction = 0 end
  return 1 - reduction
end

-- Hit percent at which special attacks stop missing.
function AttackTable.specialHitCap(t)
  return (t.miss + t.hitSuppression) * 100
end

-- Hit percent at which white attacks stop missing.
function AttackTable.whiteHitCap(t, dualWield)
  return (t.miss + t.hitSuppression + (dualWield and AttackTable.DUAL_WIELD_MISS or 0)) * 100
end

-- Per-attack chances from the table and the attacker's hit and crit percent.
function AttackTable.chances(t, hitPercent, critPercent, dualWield)
  local hit = hitPercent / 100 - t.hitSuppression
  local white = t.miss + (dualWield and AttackTable.DUAL_WIELD_MISS or 0) - hit
  local special = t.miss - hit
  local crit = critPercent / 100 - t.critSuppression
  return {
    whiteMiss = white > 0 and white or 0,
    specialMiss = special > 0 and special or 0,
    dodge = t.dodge,
    glance = t.glance,
    crit = crit > 0 and crit or 0,
  }
end

-- Outcome codes shared by every roll.
AttackTable.MISS, AttackTable.DODGE, AttackTable.GLANCE = 1, 2, 3
AttackTable.CRIT, AttackTable.HIT = 4, 5

-- A white swing: one roll down the table.
function AttackTable.rollWhite(c, roll)
  local edge = c.whiteMiss
  if roll < edge then return 1 end
  edge = edge + c.dodge
  if roll < edge then return 2 end
  edge = edge + c.glance
  if roll < edge then return 3 end
  edge = edge + c.crit
  if roll < edge then return 4 end
  return 5
end

-- A special attack: a miss and dodge roll, then a separate crit roll.
-- `canMiss` false skips the first roll, as for strikes that always connect.
function AttackTable.rollSpecial(c, rng, canMiss)
  if canMiss ~= false then
    local roll = rng:next()
    if roll < c.specialMiss then return 1 end
    if roll < c.specialMiss + c.dodge then return 2 end
  end
  if rng:next() < c.crit then return 4 end
  return 5
end

function AttackTable.landed(outcome)
  return outcome >= 3
end

return AttackTable
