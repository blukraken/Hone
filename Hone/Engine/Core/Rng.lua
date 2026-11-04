-- Seeded random numbers for the engine (pure Lua 5.1, no globals beyond the standard library).
--
-- L'Ecuyer's 1988 combined generator. Every product stays below 2^53, so plain doubles give
-- exact results and the same seed yields the same stream on every Lua 5.1 build.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local Rng = {}
ns.Engine.Core.Rng = Rng

local M1, A1 = 2147483563, 40014
local M2, A2 = 2147483399, 40692
local floor = math.floor

local methods = {}
local meta = { __index = methods }

-- Seeds are folded into both components so nearby seeds give unrelated streams.
function Rng.new(seed)
  seed = floor(tonumber(seed) or 0)
  local s1 = (seed % (M1 - 1)) + 1
  local s2 = (floor(seed / (M1 - 1)) * 7919 + seed * 31 + 12345) % (M2 - 1) + 1
  local self = setmetatable({ s1 = s1, s2 = s2 }, meta)

  -- Discard the first draws, which correlate with small seeds.
  for _ = 1, 8 do self:next() end
  return self
end

-- Uniform double in [0, 1).
function methods:next()
  local s1 = (A1 * self.s1) % M1
  local s2 = (A2 * self.s2) % M2
  self.s1, self.s2 = s1, s2
  local z = (s1 - s2) % (M1 - 1)
  return z / (M1 - 1)
end

-- True with probability `chance`, drawing nothing at the extremes.
function methods:proc(chance)
  if chance >= 1 then return true end
  if chance <= 0 then return false end
  return self:next() < chance
end

-- Uniform double in [lo, hi].
function methods:range(lo, hi)
  return lo + (hi - lo) * self:next()
end

return Rng
