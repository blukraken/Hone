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

------------------------------------------------------------------------------
-- Substreams by jump-ahead (L'Ecuyer's block splitting)
--
-- Stepping a component n times multiplies its state by A^n mod M, so a stream can jump to
-- any position in O(log n) without drawing. A seed's stream is cut into blocks. Block b
-- starts at position b * BLOCK, and key k sits KEY_BLOCK * k further on inside it, so every
-- (seed, block, key) owns a disjoint run of KEY_BLOCK draws of one generator.
-- mulmod splits one factor into 16-bit halves, so every product stays below 2^53.
------------------------------------------------------------------------------

Rng.M1, Rng.A1, Rng.M2, Rng.A2 = M1, A1, M2, A2
Rng.BLOCK = 2 ^ 40
Rng.KEY_BLOCK = 2 ^ 20

-- Callers use keys in [0, KEY_LIMIT). Keys from KEY_LIMIT to twice it are their reserved
-- twins (Rng.twinKey).
Rng.KEY_LIMIT = 2 ^ 19

-- a * b mod m for a, b < m < 2^31, exact in doubles.
local function mulmod(a, b, m)
  local bh = floor(b / 65536)
  return ((a * bh) % m * 65536 + a * (b - bh * 65536)) % m
end
Rng.mulmod = mulmod

-- a^n mod m by squaring.
local function powmod(a, n, m)
  local r = 1
  while n > 0 do
    local half = floor(n / 2)
    if n - 2 * half == 1 then r = mulmod(r, a, m) end
    a = mulmod(a, a, m)
    n = half
  end
  return r
end
Rng.powmod = powmod

-- The multipliers that advance both components n steps.
function Rng.jumpMultipliers(n)
  return powmod(A1, n, M1), powmod(A2, n, M2)
end

-- Advances this stream n steps without drawing.
function methods:jump(n)
  local j1, j2 = Rng.jumpMultipliers(n)
  self.s1, self.s2 = mulmod(self.s1, j1, M1), mulmod(self.s2, j2, M2)
  return self
end

local BLOCK1, BLOCK2 = Rng.jumpMultipliers(Rng.BLOCK)

-- State at the start of block b of the seed's stream. Block 0 is Rng.new(seed) itself.
function Rng.blockState(seed, b)
  local base = Rng.new(seed)
  return mulmod(base.s1, powmod(BLOCK1, b, M1), M1), mulmod(base.s2, powmod(BLOCK2, b, M2), M2)
end

-- Multipliers from a block's start to key k inside it. Keys repeat, so they are cached.
local keyCache = {}
function Rng.keyMultipliers(k)
  local j = keyCache[k]
  if not j then
    if k < 0 or k >= 2 * Rng.KEY_LIMIT or k ~= floor(k) then
      error(string.format("substream key %s outside [0, %d)", tostring(k), 2 * Rng.KEY_LIMIT), 2)
    end
    local j1, j2 = Rng.jumpMultipliers(k * Rng.KEY_BLOCK)
    j = { j1, j2 }
    keyCache[k] = j
  end
  return j[1], j[2]
end

-- The reserved twin of key k, for draws that must never share a run with the key's own.
function Rng.twinKey(k)
  return Rng.KEY_LIMIT + k
end

-- The uniform a state pair gives, as next() computes it.
function Rng.uniform(s1, s2)
  return ((s1 - s2) % (M1 - 1)) / (M1 - 1)
end

return Rng
