-- Core/Rng: the sequential stream is unchanged and jump-ahead substreams match brute force.
--
-- Usage: lua tests/addon/engine/rng_spec.lua
-- Exit: 0 every check passes, 1 any check fails.

local Loader = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "loader.lua")
local ns = Loader.load(Loader.root(), { classes = {} })
local Rng = ns.Engine.Core.Rng

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

-- Rng.new(42)'s first draws and state at 11ba1ed, before the substream API existed.
local r = Rng.new(42)
local a, b, c = r:next(), r:next(), r:next()
check("Rng.new and next are unchanged from 11ba1ed",
  a == 0.076416507629593677 and b == 0.93325663742612619 and c == 0.016773053185307689
    and r.s1 == 304195719 and r.s2 == 268175863,
  string.format("%.17g %.17g %.17g %d %d", a, b, c, r.s1, r.s2))

-- mulmod against plain products small enough to be exact.
local ok, bad = true, ""
local probe = Rng.new(7)
for _ = 1, 2000 do
  local m = probe:next() < 0.5 and Rng.M1 or Rng.M2
  local x = math.floor(probe:next() * m)
  local y = math.floor(probe:next() * 2 ^ 21)
  if Rng.mulmod(x, y, m) ~= (x * y) % m then ok, bad = false, x .. " * " .. y end
end
check("mulmod equals the exact product mod m where that fits in 53 bits", ok, bad)
check("mulmod is exact at the top of the range",
  Rng.mulmod(Rng.M1 - 1, Rng.M1 - 1, Rng.M1) == 1 and Rng.mulmod(Rng.M2 - 1, Rng.M2 - 1, Rng.M2) == 1)
check("powmod obeys a^(m-1) = 1 for the prime moduli",
  Rng.powmod(Rng.A1, Rng.M1 - 1, Rng.M1) == 1 and Rng.powmod(Rng.A2, Rng.M2 - 1, Rng.M2) == 1)

-- A jump of n equals n plain steps, for both state components and the next uniform.
local function brute(seed, n)
  local s = Rng.new(seed)
  for _ = 1, n do s:next() end
  return s
end
for _, n in ipairs({ 0, 1, 2, 7, 1000, 65537, 2 ^ 20 }) do
  local want = brute(99, n)
  local got = Rng.new(99):jump(n)
  local u1, u2 = want:next(), got:next()
  check(string.format("jump(%d) matches %d brute-force steps", n, n),
    want.s1 == got.s1 and want.s2 == got.s2 and u1 == u2,
    string.format("brute %d %d jump %d %d", want.s1, want.s2, got.s1, got.s2))
end

-- Jumps compose, so a block start reached by one big jump equals the sum of small ones.
local x = Rng.new(5):jump(2 ^ 40):jump(3 * 2 ^ 20)
local s1, s2 = Rng.blockState(5, 1)
local k1, k2 = Rng.keyMultipliers(3)
local y1, y2 = Rng.mulmod(s1, k1, Rng.M1), Rng.mulmod(s2, k2, Rng.M2)
check("blockState and keyMultipliers land where one long jump lands", x.s1 == y1 and x.s2 == y2)
local z = Rng.new(5)
for _ = 1, 4 do z:jump(2 ^ 38) end
check("four jumps of 2^38 equal one block", z.s1 == s1 and z.s2 == s2)
check("blockState(seed, 0) is the seed's own stream",
  select(1, Rng.blockState(11, 0)) == Rng.new(11).s1 and select(2, Rng.blockState(11, 0)) == Rng.new(11).s2)
check("Rng.uniform gives next()'s value", (function()
  local q = Rng.new(3)
  local p1, p2 = q.s1, q.s2
  p1, p2 = (Rng.A1 * p1) % Rng.M1, (Rng.A2 * p2) % Rng.M2
  return Rng.uniform(p1, p2) == q:next()
end)())
check("a key outside the reserved range is refused", not pcall(Rng.keyMultipliers, 2 * Rng.KEY_LIMIT))
check("twin keys sit above every caller key", Rng.twinKey(0) == Rng.KEY_LIMIT)

print(string.format("%d checks, %d passed, %d failed", passed + failed, passed, failed))
os.exit(failed == 0 and 0 or 1)
