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

-- dps = 100 + 2*power + 3*min(skill, 50) + 0.5*max(skill - 50, 0)
local fake = {
  weightStats = { "power", "skill" },
  simulate = function(snapshot)
    local s = snapshot.stats
    local skill = s.skill
    local dps = 100 + 2 * s.power + 3 * math.min(skill, 50) + 0.5 * math.max(skill - 50, 0)
    return { dps = dps, iterations = 1 }
  end,
  caps = function() return { skill = 50, power = 1000 } end,
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
check("weights are forward slopes per point", near(atCap.weights.power, 2) and near(atCap.weights.skill, 0.5),
  string.format("power %s skill %s", tostring(atCap.weights.power), tostring(atCap.weights.skill)))
local cw = atCap.capWeights.skill
check("capWeights at a cap give the slope below", cw ~= nil and near(cw.below, 3), cw and tostring(cw.below))
check("capWeights at a cap give the slope above", cw ~= nil and near(cw.above, 0.5), cw and tostring(cw.above))
check("capWeights report the cap and the value", cw ~= nil and cw.cap == 50 and cw.value == 50)
check("capWeights skip a stat far from its cap", atCap.capWeights.power == nil)

local nearCap = Contract.evaluate({ class = "TESTCLASS", spec = "LINEAR", stats = { power = 10, skill = 54 } },
  { weightDelta = 10 })
local ncw = nearCap.capWeights.skill
check("capWeights near a cap are taken at the cap", ncw ~= nil and near(ncw.below, 3) and near(ncw.above, 0.5),
  ncw and string.format("below %s above %s", tostring(ncw.below), tostring(ncw.above)))
check("a scenario field overrides the default step", near(nearCap.weights.power, 2))

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
local hcw = hitcap.capWeights.hit_rating
check("Enhancement at the special hit cap reports one-sided hit weights",
  hcw ~= nil and hcw.below > 0 and hcw.above == 0 and hcw.cap == 90,
  hcw and string.format("below %s above %s cap %s", tostring(hcw.below), tostring(hcw.above), tostring(hcw.cap)))
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
