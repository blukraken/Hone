-- T1: Windfury Weapon proc rate, Hone's Lua rule against MythicSim at the pin.
--
-- Proc rate = Windfury procs / eligible swings, where an eligible swing is a landed hit the
-- Windfury trigger hears (main hand autos and Stormstrike's main hand strike), not counting
-- Windfury's own strikes. Both sides run independent batches of fights; each side's
-- standard error is the spread of its batch rates over sqrt(batches). The case passes when
-- |rate_hone - rate_mythicsim| < 2 * sqrt(se_hone^2 + se_mythicsim^2).
--
-- MythicSim's counts are captured by tests/addon/engine/capture_mythicsim.py into
-- tests/addon/engine/data/windfury_mythicsim.lua.
--
-- Usage: lua tests/addon/engine/windfury_parity.lua [--batches N] [--iterations N]
-- Exit: 0 every case passes, 1 any case fails.

local Loader = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "loader.lua")
local root = Loader.root()
local ns = Loader.load(root)
local Engine = ns.Engine
local Enhancement = Engine.Classes.Shaman.Enhancement
local WindfuryWeapon = Engine.Classes.Shaman.WindfuryWeapon
local Data = Engine.Classes.Shaman.Data
local Rng = Engine.Core.Rng

local snapshots = dofile(root .. "/tests/addon/engine/data/snapshots.lua")
local reference = dofile(root .. "/tests/addon/engine/data/windfury_mythicsim.lua")

local CASES = { "enh60-windfury-dw20-29", "enh60-windfury-dw26-29", "enh60-windfury-2h38-hitcap" }
local SEED_BASE = 7000

local batches, iterations = 10, 3000
for i = 1, #arg do
  if arg[i] == "--batches" then batches = tonumber(arg[i + 1]) end
  if arg[i] == "--iterations" then iterations = tonumber(arg[i + 1]) end
end

local function summarize(runs)
  local procs, eligible, sum = 0, 0, 0
  for _, r in ipairs(runs) do
    procs, eligible = procs + r.procs, eligible + r.eligible
    sum = sum + r.procs / r.eligible
  end
  local mean = sum / #runs
  local sq = 0
  for _, r in ipairs(runs) do
    local d = r.procs / r.eligible - mean
    sq = sq + d * d
  end
  local sd = math.sqrt(sq / (#runs - 1))
  local rate = procs / eligible
  return {
    rate = rate,
    se = sd / math.sqrt(#runs),
    seBinomial = math.sqrt(rate * (1 - rate) / eligible),
    procs = procs,
    eligible = eligible,
    batches = #runs,
    iterations = runs[1].iterations,
  }
end

-- MythicSim action ids of the casts the Lua rotation counts, for the timeline comparison.
local ACTIONS = {
  { "mainHand", '{"otherId": "OtherActionAttack", "tag": 1}' },
  { "offHand", '{"otherId": "OtherActionAttack", "tag": 2}' },
  { "stormstrike", '{"spellId": 17364}' },
  { "stormstrikeStrike", '{"spellId": 17364, "tag": 1}' },
  { "lavaLash", '{"spellId": 408345}' },
  { "lightningBolt", '{"spellId": 15208}' },
}

local function honeRuns(snapshot)
  local char = Enhancement.derive(snapshot)
  local scenario = { duration = 120, durationVariation = 15 }
  local runs, totals = {}, {}
  for k = 1, batches do
    local rng = Rng.new(SEED_BASE + k)
    local _, rule, counts = Enhancement.run(char, scenario, rng, iterations)
    runs[k] = { procs = rule.procs, eligible = rule.eligible, rolls = rule.rolls, iterations = iterations }
    for name, n in pairs(counts) do totals[name] = (totals[name] or 0) + n end
  end
  return runs, totals
end

print(string.format("MythicSim %s at %s", reference.engine, reference.pin))
print(string.format("Hone: %d batches x %d fights per case, seeds %d+k", batches, iterations, SEED_BASE))
print(string.format("Rule: chance %.2f, icd %.1fs, %d strikes", Data.windfury.chance, Data.windfury.icd,
  Data.windfury.strikes))
print("")

local failed = 0
for _, id in ipairs(CASES) do
  local snapshot = assert(snapshots[id], "no snapshot for " .. id)
  local ref = assert(reference.cases[id], "no MythicSim capture for " .. id)

  local ap = WindfuryWeapon.attackPower(snapshot.talents)
  local apRef = snapshot.reference.windfuryAttackPower
  local apOk = math.abs(ap - apRef) < 1e-6

  local m = summarize(ref.runs)
  local runs, totals = honeRuns(snapshot)
  local h = summarize(runs)
  local diff = h.rate - m.rate
  local seDiff = math.sqrt(h.se ^ 2 + m.se ^ 2)
  local z = diff / seDiff
  local pass = apOk and math.abs(diff) < 2 * seDiff

  print(id)
  print(string.format("  strike attack power  hone %.1f  mythicsim %.1f  %s", ap, apRef, apOk and "match" or "MISMATCH"))
  print(string.format("  mythicsim  rate %.5f  se %.5f (binomial %.5f)  procs %d / eligible %d  (%d x %d fights)",
    m.rate, m.se, m.seBinomial, m.procs, m.eligible, m.batches, m.iterations))
  print(string.format("  hone       rate %.5f  se %.5f (binomial %.5f)  procs %d / eligible %d  (%d x %d fights)",
    h.rate, h.se, h.seBinomial, h.procs, h.eligible, h.batches, h.iterations))
  print(string.format("  eligible per fight  hone %.2f  mythicsim %.2f",
    h.eligible / (h.batches * h.iterations), m.eligible / (m.batches * m.iterations)))
  local perFight = snapshot.reference.mythicsim.castsPerFight
  for _, a in ipairs(ACTIONS) do
    print(string.format("  per fight %-18s hone %7.3f  mythicsim %7.3f", a[1],
      (totals[a[1]] or 0) / (batches * iterations), perFight[a[2]] or 0))
  end
  print(string.format("  diff %+.5f  se_diff %.5f  |z| %.2f  limit 2.00  %s", diff, seDiff, math.abs(z),
    pass and "PASS" or "FAIL"))
  print("")
  if not pass then failed = failed + 1 end
end

print(string.format("%d cases, %d passed, %d failed", #CASES, #CASES - failed, failed))
os.exit(failed == 0 and 0 or 1)
