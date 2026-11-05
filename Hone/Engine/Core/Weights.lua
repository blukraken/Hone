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

return Weights
