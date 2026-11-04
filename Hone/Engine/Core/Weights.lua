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

-- Forward-difference weight of every stat in `stats`, per point.
function Weights.forward(dpsOf, snapshot, base, stats, delta)
  local weights = {}
  for _, stat in ipairs(stats) do
    weights[stat] = (dpsOf(Weights.shift(snapshot, stat, delta)) - base) / delta
  end
  return weights
end

-- One-sided weights for each stat that sits within `window * delta` of a cap.
-- `caps` maps a stat to the stat value where its cap is. Both slopes are taken at the cap
-- itself, so `below` is the loss per point under it and `above` the gain per point past it.
function Weights.caps(dpsOf, snapshot, base, caps, delta, window)
  local out = {}
  for _, stat in ipairs(Table.sortedKeys(caps)) do
    local cap = caps[stat]
    local value = (snapshot.stats and snapshot.stats[stat]) or 0
    if math.abs(value - cap) <= window * delta then
      local toCap = cap - value
      local atCap = toCap == 0 and base or dpsOf(Weights.shift(snapshot, stat, toCap))
      local below = (atCap - dpsOf(Weights.shift(snapshot, stat, toCap - delta))) / delta
      local above = (dpsOf(Weights.shift(snapshot, stat, toCap + delta)) - atCap) / delta
      out[stat] = { below = below, above = above, cap = cap, value = value }
    end
  end
  return out
end

return Weights
