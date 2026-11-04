-- Rating conversions by character level. Values for level 60 follow MythicSim at the pin
-- (src/prepare/character.rs and src/prepare/sim.rs).

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local Stats = {}
ns.Engine.Core.Stats = Stats

-- Rating points per 1% of the matching chance.
Stats.RATING_PER_PERCENT = {
  [60] = {
    hit_rating = 10,
    crit_rating = 14,
    haste_rating = 10,
    expertise_rating = 10,
    dodge_rating = 12,
    parry_rating = 15,
    block_rating = 5,
  },
}

function Stats.ratingPerPercent(stat, level)
  local byLevel = Stats.RATING_PER_PERCENT[level]
  if not byLevel or not byLevel[stat] then
    error(string.format("no %s conversion for level %s", tostring(stat), tostring(level)), 2)
  end
  return byLevel[stat]
end

-- Percentage points that `rating` points of `stat` give at `level`.
function Stats.percentFromRating(stat, rating, level)
  return rating / Stats.ratingPerPercent(stat, level)
end

-- Rating points that sit `percent` percentage points away.
function Stats.ratingFromPercent(stat, percent, level)
  return percent * Stats.ratingPerPercent(stat, level)
end

return Stats
