-- Pooled gate over any snapshot set and MythicSim reference, for builds that have no fixture.
--
-- Per case it runs BATCHES evaluates of ITERATIONS fights on seeds 100000 + k through
-- Contract.evaluate and judges the pooled weights with tests/addon/engine/compare.lua, as
-- fixture_runner.lua --report does for the fixtures.
--
-- Usage: lua tests/addon/engine/pooled_set.lua SNAPSHOTS REFERENCE [BATCHES] [ITERATIONS]
--          [--agility-sim] [--duration S] [--variation S]
-- Exit: 0 every case agrees, 1 any case disagrees.

local Harness = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "harness.lua")
local ns = Harness.load()
local Compare = dofile(Harness.root .. "/tests/addon/engine/compare.lua")

local positional, flags = {}, {}
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--agility-sim" then flags.agilitySim = true
  elseif a == "--duration" then flags.duration = tonumber(arg[i + 1]) i = i + 1
  elseif a == "--variation" then flags.variation = tonumber(arg[i + 1]) i = i + 1
  else positional[#positional + 1] = a end
  i = i + 1
end
local snapPath, refPath = positional[1], positional[2]
assert(snapPath and refPath, "usage: pooled_set.lua SNAPSHOTS REFERENCE [BATCHES] [ITERATIONS]")
local batches, iterations = tonumber(positional[3]) or 20, tonumber(positional[4]) or 199
local snapshots, ref = dofile(snapPath), dofile(refPath)
local stats = ref.stats or Harness.ns.Engine.Classes.Shaman.Enhancement.weightStats
local BATCH_SEED = 100000

local ids = {}
for id in pairs(ref.cases) do ids[#ids + 1] = id end
table.sort(ids)

print(string.format("pooled set: %d cases, %d x %d fights, delta %d, agility %s", #ids, batches, iterations, ref.delta,
  flags.agilitySim and "simulated" or "from crit"))
print("")
local agree, orders = 0, 0
for _, id in ipairs(ids) do
  local snapshot = assert(snapshots[id], "no snapshot for " .. id)
  local scenario = {
    iterations = iterations, weightDelta = ref.delta, capWindow = -1,
    duration = flags.duration or 120, durationVariation = flags.variation or 15,
    agilityFromCrit = not flags.agilitySim,
  }
  local samples, dps = {}, {}
  for _, stat in ipairs(stats) do samples[stat] = {} end
  for k = 1, batches do
    scenario.seed = BATCH_SEED + k
    local r = ns.Engine.Contract.evaluate(snapshot, scenario)
    dps[k] = r.dps
    for _, stat in ipairs(stats) do samples[stat][k] = r.weights[stat] end
  end
  local mcase = ref.cases[id]
  local r = Compare.fixture(samples, Compare.mythicsimSamples(mcase, ref.delta, stats), stats)
  Compare.printFixture(id, r, stats)
  local d, m = Compare.summary(dps), Compare.summary(mcase.base)
  print(string.format("  dps engine %.2f +- %.2f  mythicsim %.2f +- %.2f  gap %+.2f%%", d.mean, 1.96 * d.se,
    m.mean, 1.96 * m.se, (d.mean - m.mean) / m.mean * 100))
  print("")
  if r.pass then agree = agree + 1 end
  if r.orderPass then orders = orders + 1 end
end
print(string.format("%d cases, %d agree, stat order agrees on %d", #ids, agree, orders))
os.exit(agree == #ids and 0 or 1)
