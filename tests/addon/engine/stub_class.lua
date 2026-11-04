-- T3: a second class registers and evaluates through the contract with no engine edits.
--
-- The stub is a Warrior that only auto attacks with one weapon. It reuses Core's RNG,
-- attack table and rating conversions, and registers itself exactly as Enhancement does.
-- Nothing in Hone/Engine/Contract.lua or Hone/Engine/Core/ changes for it.
--
-- Usage: lua tests/addon/engine/stub_class.lua
-- Exit: 0 every check passes, 1 any check fails.

local Loader = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "loader.lua")
local ns = Loader.load(Loader.root())
local Engine = ns.Engine
local Core = Engine.Core
local Contract = Engine.Contract

------------------------------------------------------------------------------
-- The stub model
------------------------------------------------------------------------------

local Stub = {
  weightStats = { "strength", "attack_power", "hit_rating", "crit_rating" },
  apPerStrength = 2,
  swings = 40,
}

local function derive(snapshot)
  local s = snapshot.stats
  local level = snapshot.level
  local tbl = Core.AttackTable.forLevels(level, snapshot.targetLevel)
  local hit = Core.Stats.percentFromRating("hit_rating", s.hit_rating, level)
  local crit = 5 + Core.Stats.percentFromRating("crit_rating", s.crit_rating, level)
  return {
    level = level,
    table = tbl,
    chances = Core.AttackTable.chances(tbl, hit, crit, false),
    attackPower = s.attack_power + Stub.apPerStrength * s.strength,
    armor = Core.AttackTable.armorMultiplier(snapshot.targetArmor, level),
  }
end

function Stub.simulate(snapshot, scenario)
  local char = derive(snapshot)
  local w = snapshot.weapon
  local rng = Core.Rng.new(scenario.seed)
  local AT = Core.AttackTable
  local total = 0
  for _ = 1, scenario.iterations do
    for _ = 1, Stub.swings do
      local base = w.min + (w.max - w.min) * rng:next() + char.attackPower / 14 * w.speed
      local outcome = AT.rollWhite(char.chances, rng:next())
      if outcome == AT.CRIT then
        total = total + base * char.armor * AT.CRIT_MULTIPLIER
      elseif outcome == AT.GLANCE then
        total = total + base * char.armor * char.table.glanceMultiplier
      elseif outcome == AT.HIT then
        total = total + base * char.armor
      end
    end
  end
  return { dps = total / (scenario.iterations * Stub.swings * w.speed), iterations = scenario.iterations }
end

function Stub.caps(snapshot)
  local char = derive(snapshot)
  local cap = Core.AttackTable.whiteHitCap(char.table, false)
  return { hit_rating = Core.Stats.ratingFromPercent("hit_rating", cap, snapshot.level) }
end

function Stub.coverage()
  return { "rage", "abilities", "procs" }
end

Contract.register("WARRIOR", "STUB", Stub)

------------------------------------------------------------------------------
-- Checks
------------------------------------------------------------------------------

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

local snapshot = {
  class = "WARRIOR", spec = "STUB", level = 60, targetLevel = 63, targetArmor = 976,
  stats = { strength = 300, attack_power = 600, hit_rating = 80, crit_rating = 140 },
  weapon = { min = 150, max = 250, speed = 3.0 },
}
local result = Contract.evaluate(snapshot, { iterations = 300, seed = 7 })

print(string.format("registered: %s", table.concat(Contract.registered(), ", ")))
print(string.format("WARRIOR/STUB dps %.3f", result.dps))
for _, stat in ipairs(Stub.weightStats) do
  print(string.format("  weight %-13s %.5f", stat, result.weights[stat]))
end
for stat, cw in pairs(result.capWeights) do
  print(string.format("  cap    %-13s below %.5f above %.5f (value %s cap %s)", stat, cw.below, cw.above,
    tostring(cw.value), tostring(cw.cap)))
end
print(string.format("  coverage complete=%s unmodeled=%s", tostring(result.coverage.complete),
  table.concat(result.coverage.unmodeled, ",")))

check("the stub registers beside Enhancement",
  Contract.lookup("WARRIOR", "STUB") == Stub and Contract.lookup("SHAMAN", "ENHANCEMENT") ~= nil)
check("the stub evaluates to a positive dps", type(result.dps) == "number" and result.dps > 0)
local weighed = true
for _, stat in ipairs(Stub.weightStats) do
  if type(result.weights[stat]) ~= "number" then weighed = false end
end
check("every stub stat gets a weight", weighed)
check("strength weighs twice attack power", math.abs(result.weights.strength - 2 * result.weights.attack_power) < 1e-9,
  string.format("%.6f vs %.6f", result.weights.strength, 2 * result.weights.attack_power))
local cw = result.capWeights.hit_rating
check("hit at the white cap gets one-sided weights", cw ~= nil and cw.cap == 90 and cw.below > 0 and cw.above == 0,
  cw and string.format("cap %s below %s above %s", tostring(cw.cap), tostring(cw.below), tostring(cw.above)))
check("coverage names the stub's gaps", result.coverage.complete == false and #result.coverage.unmodeled == 3)

print(string.format("%d checks, %d passed, %d failed", passed + failed, passed, failed))
os.exit(failed == 0 and 0 or 1)
