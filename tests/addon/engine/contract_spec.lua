-- T2: the engine contract (Hone/Engine/Contract.lua).
--
-- Exercises register, lookup and evaluate with a fake model whose slopes are known, then the
-- Enhancement model on a captured snapshot. The engine loads inside a sandbox that holds only
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
-- The weigh hook
------------------------------------------------------------------------------

local weighCalls = 0
Contract.register("TESTCLASS", "BATCHED", {
  weightStats = { "power" },
  simulate = function(s) return { dps = 100 + 2 * s.stats.power } end,
  weigh = function(s, _, stats, steps)
    weighCalls = weighCalls + 1
    return { dps = 100 + 2 * s.stats.power, weights = { power = 2 }, fights = { power = 7 }, batches = 3,
             stepSeen = steps[stats[1]] }
  end,
})
local batched = Contract.evaluate({ class = "TESTCLASS", spec = "BATCHED", stats = { power = 5 } }, { weightDelta = 4 })
check("a model's weigh replaces simulate for the base and the weights",
  weighCalls == 1 and near(batched.dps, 110) and near(batched.weights.power, 2) and batched.run.stepSeen == 4)
check("evaluate passes on the fights and batches weigh reports", batched.fights.power == 7 and batched.batches == 3)

------------------------------------------------------------------------------
-- Enhancement weights: pathwise, derived and the stop rule
------------------------------------------------------------------------------

local Enh = Contract.lookup("SHAMAN", "ENHANCEMENT")
local EventSim = ns.Engine.Classes.Shaman.EventSim
local hitcapSnap = snapshots["enh60-rockbiter-2h38-hitcap"]
local perPoint = hitcapSnap.model.perPoint
local batch = { iterations = 199, seed = 7, duration = 120, durationVariation = 15, capWindow = -1 }
local one = Contract.evaluate(hitcapSnap, batch)
check("strength and attack power come from the pathwise slopes",
  one.run.plan.strength.kind == "pathwise" and one.run.plan.attack_power.kind == "pathwise"
    and near(one.weights.strength, perPoint.strength.attackPower * one.weights.attack_power, 1e-12))
check("agility is the crit weight times the perPoint ratio", one.run.plan.agility.kind == "derived"
  and near(one.weights.agility, one.weights.crit_rating * perPoint.agility.meleeCritPercent
    / perPoint.crit_rating.meleeCritPercent, 1e-12))

local byDifference = {}
for k, v in pairs(batch) do byDifference[k] = v end
byDifference.event = { pathwise = false }
byDifference.stats = { "strength", "attack_power" }
local fd = Contract.evaluate(hitcapSnap, byDifference)
check("the pathwise strength slope equals the +100 forward difference on the same draws",
  fd.run.plan.strength.kind == "simulated" and math.abs(fd.weights.strength / one.weights.strength - 1) < 1e-6
    and math.abs(fd.weights.attack_power / one.weights.attack_power - 1) < 1e-6,
  string.format("fd %.8f pathwise %.8f", fd.weights.strength, one.weights.strength))

local agileAp = {}
for k, v in pairs(hitcapSnap) do agileAp[k] = v end
agileAp.model = {}
for k, v in pairs(hitcapSnap.model) do agileAp.model[k] = v end
agileAp.model.perPoint = {}
for k, v in pairs(perPoint) do agileAp.model.perPoint[k] = v end
agileAp.model.perPoint.agility = { meleeCritPercent = perPoint.agility.meleeCritPercent, attackPower = 1 }
check("agility from crit refuses a perPoint.agility with an attack power term",
  raises(function() Contract.evaluate(agileAp, batch) end, "agility from crit"))

local staked = {}
for k, v in pairs(batch) do staked[k] = v end
staked.stopRule = "dps"
local rule = ns.Engine.Core.Defaults.stopRules.dps
local stop = Contract.evaluate(hitcapSnap, staked)
local stakeOk, detail = stop.batches >= ns.Engine.Core.Defaults.stopMinBatches, ""
for stat, w in pairs(stop.weights) do
  local se = stop.run.se[stat]
  if stop.run.settled[stat] and not (rule.z * se * rule.points < rule.stake) then
    stakeOk, detail = false, stat
  end
  if stop.fights[stat] % ns.Engine.Core.Defaults.stopBatchSize ~= 0 or stop.fights[stat] > stop.iterations then
    stakeOk, detail = false, stat .. " fights " .. tostring(stop.fights[stat])
  end
end
check("the dps stop rule stops every weight under the stake, in whole batches", stakeOk
  and next(stop.run.settled) ~= nil, detail)

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
