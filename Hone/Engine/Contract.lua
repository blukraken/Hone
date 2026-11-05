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
--   fightPlan(snapshot, scenario, stats, steps)?
--                                    -> a plan for the staged stepper (Core/Weights.lua): how
--                                       each stat is weighed and a function that runs any range
--                                       of fights. Without it evaluate calls simulate once per
--                                       stat
--
-- A snapshot is plain data: { class = token, spec = token, stats = { [stat] = n }, ... }.
-- A model may read any other snapshot field it documents.
--
-- begin(snapshot, scenario) returns the staged stepper of a model with fightPlan: step(fights)
-- runs that many fights at most and result() gives the current weights, their 95% half-widths,
-- the stage reached and the fights behind each weight.
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
--   stage, halfWidths, fights, batches
--                                    the stepper's, when the model has fightPlan; evaluate
--                                    drives it to scenario.stage

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

-- The model, the merged scenario, the stats, their steps and their caps.
local function prepare(snapshot, scenario, who)
  assert(type(snapshot) == "table", who .. ": snapshot table required")
  local impl = Contract.lookup(snapshot.class, snapshot.spec)
  if not impl then
    error(string.format("%s: no model registered for %s/%s", who,
      tostring(snapshot.class), tostring(snapshot.spec)), 3)
  end
  local ownDeltaOnly = type(scenario) == "table" and scenario.weightDelta ~= nil
    and scenario.weightSteps == nil
  scenario = Table.merge(Defaults, scenario)
  if ownDeltaOnly then scenario.weightSteps = {} end
  local stats = scenario.stats or impl.weightStats
  local caps = impl.caps and impl.caps(snapshot, scenario) or {}
  for stat, list in pairs(caps) do
    assert(type(list) == "table", "caps must map each stat to a list of caps: " .. tostring(stat))
  end
  local steps = Weights.steps(snapshot, stats, scenario.weightSteps, scenario.weightDelta, caps)
  return impl, scenario, stats, steps, caps
end

local function stepperOf(impl, snapshot, scenario, stats, steps)
  return Weights.stepper(impl.fightPlan(snapshot, scenario, stats, steps), stats, steps, scenario)
end

function Contract.begin(snapshot, scenario)
  local impl, merged, stats, steps = prepare(snapshot, scenario, "begin")
  if not impl.fightPlan then error("begin: the model has no fightPlan", 2) end
  return stepperOf(impl, snapshot, merged, stats, steps)
end

function Contract.evaluate(snapshot, scenario)
  local impl, stats, steps, caps
  impl, scenario, stats, steps, caps = prepare(snapshot, scenario, "evaluate")

  local function dpsOf(s)
    local run = impl.simulate(s, scenario)
    assert(type(run) == "table" and type(run.dps) == "number", "simulate must return { dps = n }")
    return run.dps, run
  end

  local unmodeled = impl.coverage and impl.coverage(snapshot, scenario) or {}
  local dps, run, weights, capBase
  if impl.fightPlan then
    run = stepperOf(impl, snapshot, scenario, stats, steps):run(scenario.stage):result()
    dps, weights = run.dps, run.weights
    run.iterations = run.fightsTotal
    -- Cap weights pair with one simulate run of their own, so their base is that run.
    capBase = function() return (dpsOf(snapshot)) end
  else
    dps, run = dpsOf(snapshot)
    weights = Weights.forward(dpsOf, snapshot, dps, stats, steps)
    capBase = dps
  end

  return {
    dps = dps,
    dpsStdev = run.dpsStdev,
    iterations = run.iterations,
    run = run,
    weights = weights,
    steps = steps,
    stage = run.stage,
    halfWidths = run.halfWidths,
    fights = run.fights,
    batches = run.batches,
    capWeights = Weights.caps(dpsOf, snapshot, capBase, caps, scenario.weightSteps, scenario.weightDelta,
      scenario.capWindow),
    coverage = { complete = #unmodeled == 0, unmodeled = unmodeled },
  }
end

return Contract
