-- The engine contract: a registry of class models and the one evaluate call.
--
-- A model registers under a class token and a spec token. Contract knows no class; it only
-- calls the model's functions and computes weights and cap weights from them.
--
-- A model is a table with:
--   weightStats                      list of stat names to weigh
--   simulate(snapshot, scenario)     -> { dps = n, dpsStdev = n?, iterations = n? }
--   caps(snapshot, scenario)?        -> { [stat] = { stat value of each cap, ... } }
--   coverage(snapshot, scenario)?    -> list of unmodeled mechanic names
--
-- A snapshot is plain data: { class = token, spec = token, stats = { [stat] = n }, ... }.
-- A model may read any other snapshot field it documents.
--
-- evaluate returns
--   dps, dpsStdev, iterations
--   weights[stat]                    forward difference per point
--   steps[stat]                      the step each weight used
--   capWeights[stat]                 list of { below = n, above = n, cap = n, value = n }, one
--                                    per cap within the scenario's capWindow, sorted by cap
--
-- A scenario's weightSteps sets each stat's step and weightDelta is the step of any stat it
-- leaves out. A scenario that sets weightDelta alone steps every stat by it. A step stops at a
-- cap rather than cross it.
--   coverage                         { complete = bool, unmodeled = { name, ... } }

local _, ns = ...
ns.Engine = ns.Engine or {}

local Core = ns.Engine.Core
local Table, Weights, Defaults = Core.Table, Core.Weights, Core.Defaults

local Contract = {}
ns.Engine.Contract = Contract

local registry = {}

function Contract.register(classToken, specToken, impl)
  assert(type(classToken) == "string" and classToken ~= "", "register: class token required")
  assert(type(specToken) == "string" and specToken ~= "", "register: spec token required")
  assert(type(impl) == "table", "register: model table required")
  assert(type(impl.simulate) == "function", "register: model needs simulate(snapshot, scenario)")
  assert(type(impl.weightStats) == "table", "register: model needs a weightStats list")
  registry[classToken] = registry[classToken] or {}
  registry[classToken][specToken] = impl
end

function Contract.lookup(classToken, specToken)
  local specs = registry[classToken]
  return specs and specs[specToken]
end

-- Sorted "CLASS/SPEC" names of every registered model.
function Contract.registered()
  local out = {}
  for class, specs in pairs(registry) do
    for spec in pairs(specs) do out[#out + 1] = class .. "/" .. spec end
  end
  table.sort(out)
  return out
end

function Contract.evaluate(snapshot, scenario)
  assert(type(snapshot) == "table", "evaluate: snapshot table required")
  local impl = Contract.lookup(snapshot.class, snapshot.spec)
  if not impl then
    error(string.format("evaluate: no model registered for %s/%s",
      tostring(snapshot.class), tostring(snapshot.spec)), 2)
  end
  local ownDeltaOnly = type(scenario) == "table" and scenario.weightDelta ~= nil
    and scenario.weightSteps == nil
  scenario = Table.merge(Defaults, scenario)
  if ownDeltaOnly then scenario.weightSteps = {} end

  local function dpsOf(s)
    local run = impl.simulate(s, scenario)
    assert(type(run) == "table" and type(run.dps) == "number", "simulate must return { dps = n }")
    return run.dps, run
  end

  local dps, run = dpsOf(snapshot)
  local stats = scenario.stats or impl.weightStats

  local unmodeled = impl.coverage and impl.coverage(snapshot, scenario) or {}
  local caps = impl.caps and impl.caps(snapshot, scenario) or {}
  for stat, list in pairs(caps) do
    assert(type(list) == "table", "caps must map each stat to a list of caps: " .. tostring(stat))
  end
  local steps = Weights.steps(snapshot, stats, scenario.weightSteps, scenario.weightDelta, caps)

  return {
    dps = dps,
    dpsStdev = run.dpsStdev,
    iterations = run.iterations,
    run = run,
    weights = Weights.forward(dpsOf, snapshot, dps, stats, steps),
    steps = steps,
    capWeights = Weights.caps(dpsOf, snapshot, dps, caps, scenario.weightSteps, scenario.weightDelta,
      scenario.capWindow),
    coverage = { complete = #unmodeled == 0, unmodeled = unmodeled },
  }
end

return Contract
