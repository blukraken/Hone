-- T2: the engine contract (Hone/Engine/Contract.lua).
--
-- Exercises register, lookup and evaluate with a fake model whose slopes are known, the staged
-- stepper with a fake fightPlan model, then the Enhancement model on captured snapshots. The engine loads inside a sandbox that holds only
-- Lua 5.1's standard library, so any read of a WoW API global fails the run.
--
-- Usage: lua tests/addon/engine/contract_spec.lua
-- Exit: 0 every check passes, 1 any check fails.

local Loader = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "loader.lua")
local root = Loader.root()

------------------------------------------------------------------------------
-- Sandbox: the engine sees only the standard library
------------------------------------------------------------------------------

local STANDARD = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawset",
  "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
  "math", "string", "table", "os", "_VERSION",
}

local unknownGlobals = {}

local function sandbox()
  local env = {}
  for _, name in ipairs(STANDARD) do env[name] = _G[name] end
  env._G = env
  setmetatable(env, {
    __index = function(_, key)
      unknownGlobals[#unknownGlobals + 1] = tostring(key)
      return nil
    end,
    __newindex = function(_, key)
      error("engine wrote global " .. tostring(key), 2)
    end,
  })
  return env
end

local env = sandbox()
local ns = {}
for _, list in ipairs({ Loader.CORE, Loader.CLASSES }) do
  for _, rel in ipairs(list) do
    local chunk = assert(loadfile(root .. "/" .. rel))
    setfenv(chunk, env)
    chunk("Hone", ns)
  end
end

local Contract = ns.Engine.Contract

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

local function near(a, b, tol)
  return type(a) == "number" and math.abs(a - b) <= (tol or 1e-9)
end

local function raises(fn, pattern)
  local ok, err = pcall(fn)
  return not ok and (pattern == nil or tostring(err):find(pattern, 1, true) ~= nil), tostring(err)
end

------------------------------------------------------------------------------
-- A fake model with known slopes
------------------------------------------------------------------------------

-- dps = 100 + 2*power + 3*min(skill, 50) + 1*clamp(skill - 50, 0, 30) + 0.5*max(skill - 80, 0)
-- Skill has two caps, at 50 and 80.
local function piecewise(skill)
  return 3 * math.min(skill, 50) + 1 * math.max(math.min(skill, 80) - 50, 0) + 0.5 * math.max(skill - 80, 0)
end
local fake = {
  weightStats = { "power", "skill" },
  simulate = function(snapshot)
    local s = snapshot.stats
    return { dps = 100 + 2 * s.power + piecewise(s.skill), iterations = 1 }
  end,
  caps = function() return { skill = { 80, 50 }, power = { 1000 } } end,
  coverage = function(snapshot) return snapshot.unmodeled or {} end,
}

check("register rejects a missing class token",
  raises(function() Contract.register(nil, "SPEC", fake) end, "class token"))
check("register rejects a model without simulate",
  raises(function() Contract.register("TESTCLASS", "SPEC", { weightStats = {} }) end, "simulate"))
check("register rejects a model without weightStats",
  raises(function() Contract.register("TESTCLASS", "SPEC", { simulate = fake.simulate }) end, "weightStats"))

Contract.register("TESTCLASS", "LINEAR", fake)
check("lookup finds a registered model", Contract.lookup("TESTCLASS", "LINEAR") == fake)
check("lookup misses an unregistered spec", Contract.lookup("TESTCLASS", "OTHER") == nil)
check("evaluate names the missing model",
  raises(function() Contract.evaluate({ class = "NOPE", spec = "X", stats = {} }) end, "NOPE/X"))

local atCap = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 50 } },
  { weightDelta = 1 })
check("dps comes from simulate", near(atCap.dps, 100 + 20 + 150))
check("weights are forward slopes per point", near(atCap.weights.power, 2) and near(atCap.weights.skill, 1),
  string.format("power %s skill %s", tostring(atCap.weights.power), tostring(atCap.weights.skill)))
local list = atCap.capWeights.skill
local cw = list and list[1]
check("capWeights are a list per stat", type(list) == "table" and #list == 1, list and tostring(#list))
check("capWeights at a cap give the slope below", cw ~= nil and near(cw.below, 3), cw and tostring(cw.below))
check("capWeights at a cap give the slope above", cw ~= nil and near(cw.above, 1), cw and tostring(cw.above))
check("capWeights report the cap and the value", cw ~= nil and cw.cap == 50 and cw.value == 50)
check("capWeights skip a stat far from its cap", atCap.capWeights.power == nil)

local nearCap = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 54 } },
  { weightDelta = 10 })
local ncw = nearCap.capWeights.skill and nearCap.capWeights.skill[1]
check("capWeights near a cap are taken at the cap", ncw ~= nil and near(ncw.below, 3) and near(ncw.above, 1),
  ncw and string.format("below %s above %s", tostring(ncw.below), tostring(ncw.above)))
check("a scenario field overrides the default step", near(nearCap.weights.power, 2) and nearCap.steps.power == 10)

-- Both caps sit within the window: a 30-point step and a value of 65 reach 50 and 80.
local both = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 65 } },
  { weightSteps = { power = 1, skill = 30 } })
local bl = both.capWeights.skill or {}
check("a stat with two caps in reach reports both, sorted", #bl == 2 and bl[1].cap == 50 and bl[2].cap == 80,
  string.format("%d entries", #bl))
check("each cap has its own one-sided slopes", #bl == 2 and near(bl[1].below, 3) and near(bl[1].above, 1)
  and near(bl[2].below, 1) and near(bl[2].above, 0.5),
  #bl == 2 and string.format("%s %s %s %s", bl[1].below, bl[1].above, bl[2].below, bl[2].above) or "")

local perStat = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 20 } },
  { weightSteps = { power = 7, skill = 4 } })
check("each stat takes its own step", perStat.steps.power == 7 and perStat.steps.skill == 4
  and near(perStat.weights.power, 2) and near(perStat.weights.skill, 3))

local stops = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 45 } },
  { weightSteps = { power = 1, skill = 100 } })
check("a step that would cross a cap stops at it", stops.steps.skill == 5 and near(stops.weights.skill, 3),
  string.format("step %s weight %s", tostring(stops.steps.skill), tostring(stops.weights.skill)))

local defaults = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 200 } })
check("default steps come per stat from Defaults", defaults.steps.power == ns.Engine.Core.Defaults.weightDelta
  and defaults.steps.skill == ns.Engine.Core.Defaults.weightDelta)

check("caps that are not lists are refused", raises(function()
  Contract.register("TESTCLASS", "BADCAPS", { weightStats = { "power" }, simulate = fake.simulate,
    caps = function() return { power = 50 } end })
  Contract.evaluate({ class = "TESTCLASS", spec = "BADCAPS", stats = { power = 1, skill = 1 } })
end, "list of caps"))

check("coverage is complete with nothing unmodeled",
  atCap.coverage.complete == true and #atCap.coverage.unmodeled == 0)
local partial = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 1, skill = 1 },
  unmodeled = { "procs", "pets" } })
check("coverage names each unmodeled mechanic", partial.coverage.complete == false
  and partial.coverage.unmodeled[1] == "procs" and partial.coverage.unmodeled[2] == "pets")

local snapshot = { class = "TESTCLASS", spec = "LINEAR", stats = { power = 3, skill = 7 } }
Contract.evaluate(snapshot)
check("evaluate leaves the snapshot unchanged", snapshot.stats.power == 3 and snapshot.stats.skill == 7)

------------------------------------------------------------------------------
-- Enhancement through the contract
------------------------------------------------------------------------------

local snapshots = dofile(root .. "/tests/addon/engine/data/snapshots.lua")
local scenario = { iterations = 200, seed = 42, duration = 120, durationVariation = 15 }

check("Enhancement registers as SHAMAN/ENHANCEMENT", Contract.lookup("SHAMAN", "ENHANCEMENT") ~= nil)

local hitcap = Contract.evaluate(snapshots["enh60-rockbiter-2h38-hitcap"], scenario)
check("Enhancement returns a positive dps", type(hitcap.dps) == "number" and hitcap.dps > 0, tostring(hitcap.dps))
local allWeights = true
for _, stat in ipairs(Contract.lookup("SHAMAN", "ENHANCEMENT").weightStats) do
  if type(hitcap.weights[stat]) ~= "number" or hitcap.weights[stat] ~= hitcap.weights[stat] then allWeights = false end
end
check("Enhancement weighs every stat it lists", allWeights)
local hcw = hitcap.capWeights.hit_rating and hitcap.capWeights.hit_rating[1]
check("Enhancement at the special hit cap reports one-sided hit weights",
  hcw ~= nil and hcw.below > 0 and hcw.above == 0 and hcw.cap == 90,
  hcw and string.format("below %s above %s cap %s", tostring(hcw.below), tostring(hcw.above), tostring(hcw.cap)))
local dwCaps = Contract.lookup("SHAMAN", "ENHANCEMENT").caps(snapshots["enh60-windfury-dw26-29"]).hit_rating
check("Enhancement lists the special and white hit caps when dual wielding",
  type(dwCaps) == "table" and #dwCaps == 2 and math.abs(dwCaps[1] - 90) < 1e-9 and math.abs(dwCaps[2] - 280) < 1e-9,
  dwCaps and table.concat(dwCaps, ", "))
check("Enhancement names its unmodeled mechanics",
  hitcap.coverage.complete == false and #hitcap.coverage.unmodeled > 0)

local again = Contract.evaluate(snapshots["enh60-rockbiter-2h38-hitcap"], scenario)
check("the same seed gives the same result", again.dps == hitcap.dps and again.weights.strength == hitcap.weights.strength)

local odd = {}
for k, v in pairs(snapshots["enh60-windfury-dw26-29"]) do odd[k] = v end
odd.imbues = { mainHand = "WindfuryWeapon", offHand = "FrostbrandWeapon" }
local frost = Contract.evaluate(odd, { iterations = 20, seed = 1, duration = 120, durationVariation = 15 })
local named = false
for _, name in ipairs(frost.coverage.unmodeled) do
  if name == "imbue:FrostbrandWeapon" then named = true end
end
check("an unmodeled imbue appears in coverage", named)

------------------------------------------------------------------------------
-- The staged stepper (Core/Weights.lua) through a fake fightPlan model
------------------------------------------------------------------------------

-- Per-fight dps is 100 + 0.2 * power + 0.3 * skill plus noise drawn from (seed, f), and each
-- plus run adds noise of its own, so a weight's per-fight differences have a spread. edge
-- is pathwise at 0.1 per point plus noise; flat is zero. Slopes under 1 make 3% the stricter
-- target, so stage 3 needs more fights than stage 2.
local Rng = ns.Engine.Core.Rng
local function noise(seed, f, salt)
  return Rng.new(seed * 7919 + f * 104729 + salt):next() - 0.5
end
local SLOPES = { power = 0.2, skill = 0.3 }
local planCalls = 0
local staged = {
  weightStats = { "power", "skill", "edge", "flat" },
  simulate = function(s) return { dps = 100 + 0.2 * s.stats.power + 0.3 * s.stats.skill } end,
  fightPlan = function(snapshot, _, stats, steps)
    planCalls = planCalls + 1
    local kinds = { power = "simulated", skill = "simulated", edge = "pathwise", flat = "zero" }
    local base = 100 + 0.2 * snapshot.stats.power + 0.3 * snapshot.stats.skill
    local function run(stat, seed, strata, first, count)
      local values, pw = {}, { edge = {} }
      for i = 1, count do
        local f = first + i - 1
        local v = base + 40 * noise(seed, f, strata or 0)
        if stat then v = v + SLOPES[stat] * steps[stat] + 50 * noise(seed, f, #stat) end
        values[i] = v
        pw.edge[i] = 0.1 + 0.05 * noise(seed, f, 99)
      end
      return values, not stat and pw or nil
    end
    return { kinds = kinds, run = run }
  end,
}
Contract.register("TESTCLASS", "STAGED", staged)
local stagedSnap = { class = "TESTCLASS", spec = "STAGED", stats = { power = 5, skill = 9 } }
local Defaults, Weights = ns.Engine.Core.Defaults, ns.Engine.Core.Weights

local s3 = Contract.evaluate(stagedSnap, { seed = 5, capWindow = -1 })
local ok3, detail3 = s3.stage == 3, "stage " .. tostring(s3.stage)
for _, stat in ipairs({ "power", "skill", "edge" }) do
  local hw = s3.halfWidths[stat]
  if not (hw < Defaults.stageRelative * math.abs(s3.weights[stat])) then ok3, detail3 = false, stat end
end
check("evaluate drives a fightPlan model to stage 3, every half-width under 3% of its weight", ok3, detail3)
check("stage 3 weights sit near the true slopes",
  math.abs(s3.weights.power - 0.2) < 0.012 and math.abs(s3.weights.skill - 0.3) < 0.018
    and math.abs(s3.weights.edge - 0.1) < 0.006,
  string.format("power %.4f skill %.4f edge %.4f", s3.weights.power, s3.weights.skill, s3.weights.edge))
check("a zero stat has weight 0, half-width 0 and no fights",
  s3.weights.flat == 0 and s3.halfWidths.flat == 0 and s3.fights.flat == 0)

local s2 = Contract.evaluate(stagedSnap, { seed = 5, capWindow = -1, stage = 2 })
local ok2 = s2.stage == 2 and s2.iterations < s3.iterations
for _, stat in ipairs({ "power", "skill", "edge" }) do
  if not (s2.halfWidths[stat] * Defaults.stakePoints < Defaults.stageStake) then ok2 = false end
end
check("scenario.stage = 2 stops at verdict precision, with fewer fights than stage 3", ok2,
  string.format("stage %s fights %d vs %d", tostring(s2.stage), s2.iterations, s3.iterations))

local stepper = Contract.begin(stagedSnap, { seed = 5 })
local per = math.floor(Defaults.stageFirstFights / 3)
local firstRan = stepper:step(10 ^ 6)
check("stage 1 splits stageFirstFights evenly over the base run and the simulated stats, and step returns there",
  firstRan == 3 * per and stepper.stage >= 1 and stepper:result().fights.power == per,
  string.format("ran %d, stage %d", firstRan, stepper.stage))
local r1 = stepper:result()
check("result reports weights, half-widths, stage and fights at every stage",
  type(r1.weights.power) == "number" and type(r1.halfWidths.skill) == "number" and r1.stage == stepper.stage
    and r1.fightsTotal == firstRan)

local function drive(size)
  local st = Contract.begin(stagedSnap, { seed = 5 })
  while not st.done do st:step(size) end
  return st:result()
end
local whole, sameOk, sameDetail = drive(10 ^ 9), true, ""
for _, size in ipairs({ 1, 7, 29 }) do
  local r = drive(size)
  for _, stat in ipairs(staged.weightStats) do
    if r.weights[stat] ~= whole.weights[stat] or r.halfWidths[stat] ~= whole.halfWidths[stat]
        or r.fights[stat] ~= whole.fights[stat] then
      sameOk, sameDetail = false, size .. " " .. stat
    end
  end
  if r.fightsTotal ~= whole.fightsTotal or r.stage ~= whole.stage then sameOk, sameDetail = false, "size " .. size end
end
check("steps of 1, 7 and 29 fights give the result of one call", sameOk, sameDetail)

local cm, cv = Weights.combine(1, 1, 3, 1)
local zm, zv = Weights.combine(1, 0, 3, 1)
check("inverse-variance combination weights each estimate by its precision",
  near(cm, 2) and near(cv, 0.5) and zm == 1 and zv == 0)
check("begin refuses a model without fightPlan",
  raises(function() Contract.begin({ class = "TESTCLASS", spec = "LINEAR", stats = {} }, {}) end, "fightPlan"))

-- The variance floor. Stratified batches of this plan agree exactly, so their spread is 0, while
-- stage 1's unstratified fights carry noise. The batch variance must rise to stage 1's per-fight
-- variance x stageStratificationGain / batch fights, keeping batches - 1 degrees of freedom.
local floorPlan = {
  kinds = { power = "simulated" },
  run = function(stat, seed, strata, first, count)
    local values = {}
    for i = 1, count do
      local v = 100
      if stat then v = v + 20 + (strata and 0 or 50 * noise(seed, first + i - 1, 3)) end
      values[i] = v
    end
    return values
  end,
}
local floorScenario = {}
for k, v in pairs(Defaults) do floorScenario[k] = v end
floorScenario.seed = 5
local fst = Weights.stepper(floorPlan, { "power" }, { power = 100 }, floorScenario):run(2)
local fm, fv, _, fnb, fdf = fst:estimate("power")
local fsamples = fst:firstSamples("power")
local m1, v1 = Weights.meanVar(fsamples)
local lowest = v1 * #fsamples * Defaults.stageStratificationGain / (fnb * Defaults.stageBatchSize)
local _, wantV, wantDf = Weights.combine(m1, v1, 0.2, lowest, #fsamples - 1, fnb - 1)
check("a simulated stat's batch variance never falls below the stage 1 floor",
  fnb >= Defaults.stageMinBatches and fv > 0 and near(fv, wantV) and near(fdf, wantDf)
    and fst:result().halfWidths.power > 0,
  string.format("batches %d variance %.3g want %.3g df %.3g want %.3g", fnb, fv, wantV, fdf, wantDf))

------------------------------------------------------------------------------
-- Enhancement weights: kinds and pathwise slopes
------------------------------------------------------------------------------

local Enh = Contract.lookup("SHAMAN", "ENHANCEMENT")
local EventSim = ns.Engine.Classes.Shaman.EventSim
local hitcapSnap = snapshots["enh60-rockbiter-2h38-hitcap"]
local dw29Snap = snapshots["enh60-rockbiter-dw29-hit97"]
local plain = { duration = 120, durationVariation = 15 }
local kinds = Enh.weightKinds(hitcapSnap, plain, Enh.weightStats)
local dwKinds = Enh.weightKinds(dw29Snap, plain, Enh.weightStats)
check("strength and attack power are pathwise; agility, intellect, crit and haste are simulated",
  kinds.strength == "pathwise" and kinds.attack_power == "pathwise" and kinds.agility == "simulated"
    and kinds.intellect == "simulated" and kinds.crit_rating == "simulated" and kinds.haste_rating == "simulated")
check("hit at a two-hander's cap is zero; hit under the dual-wield white cap is simulated",
  kinds.hit_rating == "zero" and dwKinds.hit_rating == "simulated",
  tostring(kinds.hit_rating) .. " " .. tostring(dwKinds.hit_rating))

local o29 = Enh.eventOptions(plain, 29)
local atCap = EventSim.run(EventSim.character(hitcapSnap), plain, 7, 29, o29)
local past = EventSim.run(EventSim.character(ns.Engine.Core.Weights.shift(hitcapSnap, "hit_rating", 100)), plain, 7, 29, o29)
local hitSame = #atCap == 29
for i = 1, 29 do if atCap[i] ~= past[i] then hitSame = false end end
check("+100 hit past the cap changes no fight, so the zero kind is exact", hitSame)

local pwSteps = { strength = 100, attack_power = 100 }
local pwPlan = Enh.fightPlan(hitcapSnap, plain, { "strength", "attack_power" }, pwSteps)
local fdScenario = { duration = 120, durationVariation = 15, event = { pathwise = false } }
local fdPlan = Enh.fightPlan(hitcapSnap, fdScenario, { "strength", "attack_power" }, pwSteps)
local _, pw = pwPlan.run(nil, 7, 199, 1, 199)
local fdBase = fdPlan.run(nil, 7, 199, 1, 199)
local function fdMean(stat)
  local plus, sum = fdPlan.run(stat, 7, 199, 1, 199), 0
  for i = 1, 199 do sum = sum + (plus[i] - fdBase[i]) / 100 end
  return sum / 199
end
local function mean(list)
  local sum = 0
  for i = 1, #list do sum = sum + list[i] end
  return sum / #list
end
local fdStr, pwStr = fdMean("strength"), mean(pw.strength)
check("the pathwise strength slope equals the +100 forward difference on the same draws",
  fdPlan.kinds.strength == "simulated" and math.abs(fdStr / pwStr - 1) < 1e-6
    and math.abs(fdMean("attack_power") / mean(pw.attack_power) - 1) < 1e-6,
  string.format("fd %.8f pathwise %.8f", fdStr, pwStr))
check("a pathwise strength slope is perPoint.strength times the attack power slope",
  near(mean(pw.strength), hitcapSnap.model.perPoint.strength.attackPower * mean(pw.attack_power), 1e-12))

local split = EventSim.run(EventSim.character(dw29Snap), plain, 7, 29, o29)
local pieces, at = {}, 1
for _, n in ipairs({ 1, 7, 21 }) do
  local o = Enh.eventOptions(plain, 29)
  o.first = at
  local part = EventSim.run(EventSim.character(dw29Snap), plain, 7, n, o)
  for i = 1, n do pieces[at + i - 1] = part[i] end
  at = at + n
end
local splitSame = true
for i = 1, 29 do if split[i] ~= pieces[i] then splitSame = false end end
check("a stratified batch run in pieces (opts.first) equals the batch in one run", splitSame)

local first = Contract.evaluate(hitcapSnap, { seed = 3, capWindow = -1, stage = 1, duration = 120, durationVariation = 15 })
check("Enhancement's stage 1 runs stageFirstFights over the base run and its simulated stats",
  first.stage >= 1 and first.iterations <= Defaults.stageFirstFights and first.fights.agility > 0,
  string.format("stage %d fights %d", first.stage, first.iterations))

------------------------------------------------------------------------------
-- Draw discipline (EventSim.lua header)
------------------------------------------------------------------------------

local fh = assert(io.open(root .. "/Hone/Engine/Classes/Shaman/EventSim.lua", "rb"))
local source = fh:read("*a")
fh:close()
local draws, named = 0, 0
for args in source:gmatch("[^%w_]U%(([^%)]*)%)") do
  draws = draws + 1
  if args:match("^S_[%u_]+$") or args == "site" then named = named + 1 end
end
check("every random draw in EventSim names its site", draws > 0 and draws == named,
  string.format("%d of %d draws name a site", named, draws))
local enters, rooted = 0, 0
for args in source:gmatch("[^%w_]enter%(([^,%)]*)") do
  enters = enters + 1
  if args:match("^R%.[%u_]+$") or args == "root" then rooted = rooted + 1 end
end
check("every root event enters through a named root", enters > 0 and enters == rooted,
  string.format("%d of %d enter calls name a root", rooted, enters))

local siteSeen, sitesOk = {}, true
for _, v in pairs(EventSim.SITES) do
  if siteSeen[v] or v < 0 or v >= 32 then sitesOk = false end
  siteSeen[v] = true
end
local rootsOk = true
for _, v in pairs(EventSim.ROOTS) do if v < 16 or v >= 64 then rootsOk = false end end
for _, v in pairs(EventSim.NESTED) do if v < 0 or v > 3 then rootsOk = false end end
check("site numbers are distinct and fit the key's 32 sites", sitesOk)
check("roots sit in [16, 64) above every nested kind, so a nested context never equals a root", rootsOk)

local unique, duplicate = true, ""
for _, id in ipairs({ "enh60-rockbiter-2h38-hitcap", "enh60-windfury-dw26-29" }) do
  local snap = snapshots[id]
  local o = Enh.eventOptions({}, 199)
  o.audit = {}
  EventSim.run(EventSim.character(snap), { duration = 120, durationVariation = 15 }, 11, 6, o)
  local seen = {}
  for _, a in ipairs(o.audit) do
    local k = a.fight .. ":" .. a.key .. ":" .. a.slot
    if seen[k] then unique, duplicate = false, id .. " " .. k end
    seen[k] = true
  end
end
check("no (fight, key, slot) is drawn twice in a fight", unique, duplicate)

local strata = {}
local lhsOpts = Enh.eventOptions({}, 199)
lhsOpts.audit = {}
EventSim.run(EventSim.character(hitcapSnap), { duration = 120, durationVariation = 15 }, 11, 199, lhsOpts)
local fightEndKey = EventSim.ROOTS.FIGHT * 32 + EventSim.SITES.FIGHT_END
local hits = 0
for _, a in ipairs(lhsOpts.audit) do
  if a.key == fightEndKey then
    local s = math.floor(a.u * 199)
    if not strata[s] then hits = hits + 1 end
    strata[s] = true
  end
end
check("a stratified batch puts one fight in each of its 199 strata", hits == 199, tostring(hits))

------------------------------------------------------------------------------
-- Engine hygiene
------------------------------------------------------------------------------

check("the engine read no global outside the standard library", #unknownGlobals == 0,
  table.concat(unknownGlobals, ", "))

local probe = assert(loadstring("return GetTime, UnitStat"))
setfenv(probe, sandbox())
local before = #unknownGlobals
probe()
check("the sandbox records a WoW global read", #unknownGlobals == before + 2
  and unknownGlobals[before + 1] == "GetTime" and unknownGlobals[before + 2] == "UnitStat")

local CLASS_NAMES = {
  "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
  "DEATHKNIGHT", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock",
  "Druid", "Enhancement", "Windfury", "Stormstrike",
}
local named = {}
for _, rel in ipairs(Loader.CORE) do
  local fh = assert(io.open(root .. "/" .. rel, "rb"))
  local text = fh:read("*a")
  fh:close()
  for _, name in ipairs(CLASS_NAMES) do
    if text:find(name, 1, true) then named[#named + 1] = rel .. ":" .. name end
  end
end
check("Contract.lua and Core/ name no class", #named == 0, table.concat(named, ", "))

print(string.format("%d checks, %d passed, %d failed", passed + failed, passed, failed))
os.exit(failed == 0 and 0 or 1)
