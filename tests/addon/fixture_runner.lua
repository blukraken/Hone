-- Fixture runner for the MythicSim reference fixtures (Lua 5.1 / LuaJIT).
--
-- Loads every tests/fixtures/*.json, calls engine.evaluate(input) for each, and compares the
-- result with the fixture's output. Exit code 0 means all fixtures passed, 1 means any failed,
-- 2 means a usage or load error.
--
-- An engine is a table with evaluate(input) -> { dps = n, weights = { [stat] = n } }.
-- An engine may also define prepare(fixtures), called once before the first evaluate.
-- Built-in engines:
--   identity   returns each fixture's own expected values, so every fixture passes
--   perturbed  shifts one stat of each fixture past tolerance, so the run fails
--   hone       Hone's engine through Hone/Engine/Contract.lua, one snapshot per fixture
--              from tests/addon/engine/data/snapshots.lua
--
-- With --report --staged the hone engine runs the staged evaluator (Contract.begin, decision
-- 0014) once per fixture, --repeats times on one seed. It prints each stage's cumulative
-- milliseconds (the minimum over repeats), the fights each stat used, each weight's 95%
-- half-width and the minimum-spec forecast. os.clock reads wall time on the Windows Lua
-- build, so time it alone and pinned (tests/addon/engine/pinned.sh).
--
-- With --report --staged --pool N it runs N independent evaluates per fixture instead and
-- pools their stage 2 and stage 3 weights against MythicSim's pooled samples through
-- tests/addon/engine/compare.lua. --coverage adds, per fixture and stage, the share of
-- (seed, stat) pairs whose own 95% interval holds MythicSim's pooled mean, against
-- COVERAGE_LINE. A stat weighed as "zero" has no interval and is left out.
--
-- With --report --staged --seeds N it runs N evaluates per fixture, each once, on the pool's
-- seeds, and prints per stage the median and slowest cumulative ms, the slowest seed, the
-- fights per stat and the minimum-spec forecast. Stages 1 and 2 are judged on the slowest
-- seed (decision 0015); stage 3 has no line.
--
-- Report evaluates leave cap weights out (capWindow -1). The cost they time is the base run
-- and the weights, which is what the MODEL-06b checks price.
--
-- Usage: lua tests/addon/fixture_runner.lua --engine identity|perturbed|hone [options]

local USAGE = [[
usage: lua tests/addon/fixture_runner.lua --engine NAME [options]

  --engine NAME      identity | perturbed | hone
  --fixtures DIR     directory of fixture JSON files (default: tests/fixtures beside this script)
  --tolerance REL    relative tolerance used when a fixture's tolerance is null (default 1e-6)
  --iterations N     hone only: fights per evaluation (default: the fixture's own count,
                     or 1500 with --report)
  --path NAME        hone only: event | hybrid | formula (default event)
  --report           hone: needs --staged; other engines: each fixture's dps and weights
                     beside the reference
  --staged           hone --report: the staged evaluator's per-stage time, fights and
                     half-widths, one evaluate per fixture timed --repeats times
  --repeats N        hone --report --staged: timed repeats per fixture (default 5)
  --pool N           hone --report --staged: N independent evaluates per fixture, pooled
                     at stage 2 and stage 3 through compare.lua
  --coverage         with --pool: share of (seed, stat) pairs whose own interval holds
                     MythicSim's pooled mean, per fixture at stages 2 and 3
  --seeds N          hone --report --staged: N seeds per fixture, each run once; per stage
                     the median and slowest ms and the fights per stat
  --only ID          run only the fixture with this id (repeatable)
  --help             show this text

exit codes: 0 all fixtures pass, 1 at least one mismatch, 2 usage or load error,
            3 the engine raised a Lua error
]]

local DEFAULT_TOLERANCE = 1e-6

local BATCH_SEED = 100000
local STAGED_REPEATS = 5

-- Pooled evaluates sit this many seeds apart. A stepper's batch k runs on its seed + k, and
-- Core/Defaults stageMaxFights caps it well under this many batches.
local POOL_STRIDE = 1000

-- Cumulative ms stages 1 and 2 must land under (decision 0014). Stage 3 has no line and runs
-- in the background (decision 0015).
local STAGE_LINES = { 150, 1000 }
local STAGE_NAMES = { "first", "verdicts", "final" }

-- Share of (seed, stat) pairs whose own interval must hold MythicSim's pooled mean.
local COVERAGE_LINE = 0.90

-- Minimum-spec machine over the owner's, measured in MODEL-02 a1.txt (4,700 / 1,950).
local MIN_SPEC_FACTOR = 2.41

------------------------------------------------------------------------------
-- Minimal JSON decoder
------------------------------------------------------------------------------

local NULL = setmetatable({}, { __tostring = function() return "null" end })

local function decode_json(text, where)
  local pos = 1

  local function fail(msg)
    error(string.format("%s: JSON error at byte %d: %s", where, pos, msg), 0)
  end

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
  end

  local function utf8_char(cp)
    if cp < 0x80 then
      return string.char(cp)
    elseif cp < 0x800 then
      return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      return string.char(0xE0 + math.floor(cp / 0x1000),
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end

  local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

  local function parse_string()
    pos = pos + 1
    local parts = {}
    while true do
      local stop = text:find('["\\]', pos)
      if not stop then fail("unterminated string") end
      parts[#parts + 1] = text:sub(pos, stop - 1)
      if text:sub(stop, stop) == '"' then
        pos = stop + 1
        return table.concat(parts)
      end
      local esc = text:sub(stop + 1, stop + 1)
      if esc == "u" then
        local cp = tonumber(text:sub(stop + 2, stop + 5), 16)
        if not cp then fail("bad \\u escape") end
        pos = stop + 6
        if cp >= 0xD800 and cp < 0xDC00 and text:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(text:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo < 0xE000 then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        parts[#parts + 1] = utf8_char(cp)
      elseif escapes[esc] then
        parts[#parts + 1] = escapes[esc]
        pos = stop + 2
      else
        fail("bad escape \\" .. esc)
      end
    end
  end

  local parse_value

  local function parse_array()
    local out = {}
    pos = pos + 1
    skip()
    if text:sub(pos, pos) == "]" then pos = pos + 1 return out end
    while true do
      out[#out + 1] = parse_value()
      skip()
      local c = text:sub(pos, pos)
      pos = pos + 1
      if c == "]" then return out end
      if c ~= "," then pos = pos - 1 fail("expected , or ]") end
    end
  end

  local function parse_object()
    local out = {}
    pos = pos + 1
    skip()
    if text:sub(pos, pos) == "}" then pos = pos + 1 return out end
    while true do
      skip()
      if text:sub(pos, pos) ~= '"' then fail("expected object key") end
      local key = parse_string()
      skip()
      if text:sub(pos, pos) ~= ":" then fail("expected :") end
      pos = pos + 1
      out[key] = parse_value()
      skip()
      local c = text:sub(pos, pos)
      pos = pos + 1
      if c == "}" then return out end
      if c ~= "," then pos = pos - 1 fail("expected , or }") end
    end
  end

  function parse_value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == '"' then return parse_string() end
    if text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
    if text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
    if text:sub(pos, pos + 3) == "null" then pos = pos + 4 return NULL end
    local num = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num and #num > 0 then
      pos = pos + #num
      local n = tonumber(num)
      if not n then fail("bad number " .. num) end
      return n
    end
    fail("unexpected character '" .. c .. "'")
  end

  local value = parse_value()
  skip()
  if pos <= #text then fail("trailing data") end
  return value
end

------------------------------------------------------------------------------
-- Fixture loading
------------------------------------------------------------------------------

local function script_dir()
  local src = (arg and arg[0]) or ""
  local dir = src:match("^(.*)[/\\][^/\\]*$")
  return dir or "."
end

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function list_json(dir)
  local cmd
  if is_windows() then
    cmd = 'dir /b "' .. dir:gsub("/", "\\") .. '\\*.json" 2>nul'
  else
    cmd = "ls '" .. dir .. "' 2>/dev/null"
  end
  local names = {}
  local pipe = io.popen(cmd)
  if not pipe then return names end
  for line in pipe:lines() do
    line = line:gsub("\r$", "")
    if line:match("%.json$") then names[#names + 1] = line end
  end
  pipe:close()
  table.sort(names)
  return names
end

local function read_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then error(err, 0) end
  local data = fh:read("*a")
  fh:close()
  return data
end

local function load_fixtures(dir)
  local fixtures = {}
  for _, name in ipairs(list_json(dir)) do
    local path = dir .. "/" .. name
    local fx = decode_json(read_file(path), name)
    local out = fx.output
    if type(fx.id) ~= "string" or type(fx.input) ~= "table"
        or type(out) ~= "table" or type(out.dps) ~= "number" or type(out.weights) ~= "table" then
      error(name .. ": not a fixture record (needs id, input, output.dps, output.weights)", 0)
    end
    fx.file = name
    fixtures[#fixtures + 1] = fx
  end
  return fixtures
end

------------------------------------------------------------------------------
-- Stub engines
------------------------------------------------------------------------------

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function make_stub(shift)
  local expected_by_input = {}
  local engine = {}

  function engine.prepare(fixtures)
    for _, fx in ipairs(fixtures) do expected_by_input[fx.input] = fx.output end
  end

  function engine.evaluate(input)
    local expected = expected_by_input[input]
    local result = { dps = expected.dps, weights = {} }
    for stat, value in pairs(expected.weights) do result.weights[stat] = value end
    if shift then shift(result) end
    return result
  end

  return engine
end

-- Hone's engine. Loads Hone/Engine the way the .toc will, then maps each fixture's input
-- to the normalized snapshot captured for that fixture id.
local function make_hone(opts)
  local Loader = dofile(script_dir() .. "/engine/loader.lua")
  local root = Loader.root()
  local ns = Loader.load(root)
  local snapshots = dofile(root .. "/tests/addon/engine/data/snapshots.lua")
  local by_input = {}
  local engine = {}

  function engine.prepare(fixtures)
    for _, fx in ipairs(fixtures) do
      local snapshot = snapshots[fx.id]
      if not snapshot then error("no snapshot for fixture " .. fx.id, 0) end
      local encounter = fx.input.request.encounter
      by_input[fx.input] = {
        snapshot = snapshot,
        scenario = {
          seed = fx.output.seed,
          iterations = opts.iterations or fx.output.iterations,
          duration = encounter.duration,
          durationVariation = encounter.durationVariation,
          path = opts.path,
        },
      }
    end
  end

  function engine.evaluate(input)
    local case = by_input[input]
    return ns.Engine.Contract.evaluate(case.snapshot, case.scenario)
  end

  -- Drives one stepper to stage 3 with step(huge), which returns at every stage boundary.
  -- Returns the cumulative ms and the result at each stage the stepper stopped at.
  local function driveStaged(case, scenario)
    local Weights = ns.Engine.Core.Weights
    collectgarbage("collect")
    local t0 = os.clock()
    local st = ns.Engine.Contract.begin(case.snapshot, scenario)
    local at, results = {}, {}
    while not st.done do
      st:step(math.huge)
      local ms = (os.clock() - t0) * 1000
      for s = 1, st.stage do
        if not at[s] then at[s], results[s] = ms, st:result() end
      end
    end
    for s = 1, Weights.FINAL_STAGE do
      if not at[s] then at[s], results[s] = math.huge, st:result() end
    end
    return at, results, st
  end

  local function stagedScenario(case, seed, delta)
    local scenario = {}
    for k, v in pairs(case.scenario) do scenario[k] = v end
    scenario.seed = seed
    scenario.weightDelta = delta
    scenario.capWindow = -1
    return scenario
  end

  -- T1: one evaluate per fixture, timed --repeats times, with every stage's time, fights and
  -- half-widths.
  function engine.stagedReport(fx)
    local Compare = dofile(root .. "/tests/addon/engine/compare.lua")
    local ref = Compare.loadReference()
    local mcase = ref.cases[fx.id]
    if not mcase then error("no pooled MythicSim samples for " .. fx.id, 0) end
    local case = by_input[fx.input]
    local stats = ref.stats
    local Defaults = ns.Engine.Core.Defaults
    local scenario = stagedScenario(case, BATCH_SEED, ref.delta)
    local best, lists, results = {}, {}, nil
    for k = 1, opts.repeats or STAGED_REPEATS do
      local at, res = driveStaged(case, scenario)
      results = res
      for s = 1, 3 do
        lists[s] = lists[s] or {}
        lists[s][k] = string.format("%.0f", at[s])
        if not best[s] or at[s] < best[s] then best[s] = at[s] end
      end
    end
    local reference = Compare.mythicsimSamples(mcase, ref.delta, stats)
    print(string.format("%s  staged, seed %d", fx.id, BATCH_SEED))
    local misses = 0
    for s = 1, 3 do
      local r = results[s]
      local line = STAGE_LINES[s]
      local over = line and not (best[s] < line)
      if over then misses = misses + 1 end
      local verdict = line and string.format("line %d ms %s", line, over and "MISS" or "under") or "no line"
      print(string.format("  stage %d %-9s %6.0f ms cumulative (min of %d: %s), %s; %d fights;"
        .. " minimum spec x%.2f: %.0f ms", s, STAGE_NAMES[s], best[s], #lists[s], table.concat(lists[s], " "),
        verdict, r.fightsTotal, MIN_SPEC_FACTOR, best[s] * MIN_SPEC_FACTOR))
      print(string.format("    %-13s %9s %9s %8s %9s %9s %7s %7s %6s  %s", "stat", "weight", "mythicsim", "rel",
        "hw95", s == 2 and "hw x30" or "hw/w", "met", "fights", "batch", "kind"))
      for _, stat in ipairs(stats) do
        local w, hw = r.weights[stat], r.halfWidths[stat]
        local m = Compare.summary(reference[stat]).mean
        local measure, met
        if s == 2 then
          measure = string.format("%.4f", hw * Defaults.stakePoints)
          met = hw == 0 or hw * Defaults.stakePoints < Defaults.stageStake
        else
          measure = w ~= 0 and string.format("%.2f%%", hw / math.abs(w) * 100) or "-"
          met = hw == 0 or hw < Defaults.stageRelative * math.abs(w)
        end
        if s == 1 then met = true end
        print(string.format("    %-13s %9.5f %9.5f %+7.2f%% %9.5f %9s %7s %7d %6d  %s", stat, w, m,
          m ~= 0 and (w - m) / math.abs(m) * 100 or 0, hw, measure, met and "yes" or "no", r.fights[stat],
          r.batches[stat], r.kinds[stat]))
      end
    end
    local first = results[1]
    local perFight = best[1] / first.fightsTotal
    print(string.format("  stage 1 room: %.3f ms per fight, so %d ms buys %d fights (it ran %d)", perFight,
      STAGE_LINES[1], math.floor(STAGE_LINES[1] / perFight), first.fightsTotal))
    print("")
    return { best = best, fights = { results[1].fightsTotal, results[2].fightsTotal, results[3].fightsTotal },
             misses = misses }
  end

  -- T2: --pool independent evaluates per fixture, pooled through compare.lua at stage 2 and
  -- stage 3. Evaluate k runs on seed BATCH_SEED + k * POOL_STRIDE, so no two share a batch.
  function engine.poolReport(fx)
    local Compare = dofile(root .. "/tests/addon/engine/compare.lua")
    local ref = Compare.loadReference()
    local mcase = ref.cases[fx.id]
    if not mcase then error("no pooled MythicSim samples for " .. fx.id, 0) end
    local case = by_input[fx.input]
    local stats = ref.stats
    local samples, widths, dps, ms, fights = { {}, {}, {} }, { {}, {}, {} }, {}, { 0, 0, 0 }, { 0, 0, 0 }
    local slowest = { 0, 0, 0 }
    for s = 1, 3 do
      for _, stat in ipairs(stats) do samples[s][stat], widths[s][stat] = {}, {} end
    end
    local n = opts.pool
    local kinds
    for k = 1, n do
      local at, res = driveStaged(case, stagedScenario(case, BATCH_SEED + k * POOL_STRIDE, ref.delta))
      kinds = res[3].kinds
      for s = 1, 3 do
        for _, stat in ipairs(stats) do
          samples[s][stat][k], widths[s][stat][k] = res[s].weights[stat], res[s].halfWidths[stat]
        end
        ms[s] = ms[s] + at[s] / n
        if at[s] > slowest[s] then slowest[s] = at[s] end
        fights[s] = fights[s] + res[s].fightsTotal / n
      end
      dps[k] = res[3].dps
    end
    local reference = Compare.mythicsimSamples(mcase, ref.delta, stats)
    local verdicts = {}
    for _, s in ipairs({ 2, 3 }) do
      local r = Compare.fixture(samples[s], reference, stats)
      print(string.format("== stage %d (%s), %d evaluates pooled, %.0f ms mean and %.0f ms slowest, %.0f fights mean"
        .. " per evaluate", s, STAGE_NAMES[s], n, ms[s], slowest[s], fights[s]))
      Compare.printFixture(fx.id, r, stats)
      -- How often one evaluate's own 95% interval holds MythicSim's pooled mean.
      local parts, held, pairs_ = {}, 0, 0
      for _, stat in ipairs(stats) do
        local m, hits = Compare.summary(reference[stat]).mean, 0
        for k = 1, n do
          if math.abs(samples[s][stat][k] - m) <= widths[s][stat][k] then hits = hits + 1 end
        end
        parts[#parts + 1] = string.format("%s %d/%d", stat, hits, n)
        if kinds[stat] ~= "zero" then held, pairs_ = held + hits, pairs_ + n end
      end
      print("  own interval holds mythicsim: " .. table.concat(parts, "  "))
      r.coverage = pairs_ > 0 and held / pairs_ or 1
      if opts.coverage then
        print(string.format("  COVERAGE %s stage %d: %d/%d (seed, stat) pairs, %.1f%%, line %.0f%% %s", fx.id, s,
          held, pairs_, r.coverage * 100, COVERAGE_LINE * 100, r.coverage >= COVERAGE_LINE and "met" or "MISS"))
      end
      verdicts[s] = r
    end
    local d, m = Compare.summary(dps), Compare.summary(mcase.base)
    print(string.format("  dps engine %.2f +- %.2f  mythicsim %.2f +- %.2f  gap %+.2f%%", d.mean, 1.96 * d.se,
      m.mean, 1.96 * m.se, (d.mean - m.mean) / m.mean * 100))
    print("")
    return { pass2 = verdicts[2].pass, pass3 = verdicts[3].pass, order2 = verdicts[2].orderPass,
             order3 = verdicts[3].orderPass, coverage2 = verdicts[2].coverage,
             coverage3 = verdicts[3].coverage }
  end

  local function median(list)
    local sorted = {}
    for i, x in ipairs(list) do sorted[i] = x end
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
  end

  -- T3: --seeds evaluates per fixture, each run once on the pool's seeds. Per stage the median
  -- and slowest cumulative ms, and the fights per stat (median and most over the seeds).
  function engine.seedsReport(fx)
    local Compare = dofile(root .. "/tests/addon/engine/compare.lua")
    local ref = Compare.loadReference()
    local case = by_input[fx.input]
    local stats = ref.stats
    local n = opts.seeds
    local ms, fights, perStat, kinds = { {}, {}, {} }, { {}, {}, {} }, { {}, {}, {} }, nil
    for s = 1, 3 do
      for _, stat in ipairs(stats) do perStat[s][stat] = {} end
    end
    for k = 1, n do
      local at, res = driveStaged(case, stagedScenario(case, BATCH_SEED + k * POOL_STRIDE, ref.delta))
      kinds = res[3].kinds
      for s = 1, 3 do
        ms[s][k], fights[s][k] = at[s], res[s].fightsTotal
        for _, stat in ipairs(stats) do perStat[s][stat][k] = res[s].fights[stat] end
      end
    end
    print(string.format("%s  %d seeds (%d + k x %d), each run once", fx.id, n, BATCH_SEED, POOL_STRIDE))
    local misses, slowest = 0, {}
    for s = 1, 3 do
      local worst, worstK = -1, 0
      for k = 1, n do
        if ms[s][k] > worst then worst, worstK = ms[s][k], k end
      end
      slowest[s] = worst
      local line = STAGE_LINES[s]
      local over = line and not (worst < line)
      if over then misses = misses + 1 end
      local verdict = line and string.format("slowest vs line %d ms %s", line, over and "MISS" or "under")
        or "no line"
      print(string.format("  stage %d %-9s median %6.0f ms  slowest %6.0f ms (seed %d)  %s;"
        .. " minimum spec x%.2f: median %.0f ms, slowest %.0f ms", s, STAGE_NAMES[s], median(ms[s]), worst,
        BATCH_SEED + worstK * POOL_STRIDE, verdict, MIN_SPEC_FACTOR, median(ms[s]) * MIN_SPEC_FACTOR,
        worst * MIN_SPEC_FACTOR))
      local parts = { string.format("total %d / %d (slowest seed %d)", median(fights[s]),
        math.max(unpack(fights[s])), fights[s][worstK]) }
      for _, stat in ipairs(stats) do
        if kinds[stat] ~= "zero" then
          parts[#parts + 1] = string.format("%s %d / %d", stat, median(perStat[s][stat]),
            math.max(unpack(perStat[s][stat])))
        end
      end
      print("    fights, median / most: " .. table.concat(parts, ", "))
    end
    print("")
    return { slowest = slowest, misses = misses }
  end

  return engine
end

local ENGINES = {
  hone = make_hone,
  identity = function() return make_stub(nil) end,
  perturbed = function()
    -- Moves the first weight (alphabetical) well past any plausible tolerance.
    return make_stub(function(result)
      local stat = sorted_keys(result.weights)[1]
      result.weights[stat] = result.weights[stat] * 1.5 + 1
    end)
  end,
}

------------------------------------------------------------------------------
-- Comparison
------------------------------------------------------------------------------

local report

local function within(got, want, rel)
  if type(got) ~= "number" or got ~= got then return false end
  return math.abs(got - want) <= rel * math.max(math.abs(want), 1e-9)
end

local function compare(fx, result, default_tol)
  local failures = {}
  local tol = default_tol
  if type(fx.tolerance) == "number" then tol = fx.tolerance end
  local want = fx.output

  if type(result) ~= "table" then
    return { { stat = "result", want = "table", got = tostring(result) } }
  end
  if not within(result.dps, want.dps, tol) then
    failures[#failures + 1] = { stat = "dps", want = want.dps, got = result.dps }
  end
  local got_weights = type(result.weights) == "table" and result.weights or {}
  for _, stat in ipairs(sorted_keys(want.weights)) do
    local w = want.weights[stat]
    if not within(got_weights[stat], w, tol) then
      failures[#failures + 1] = { stat = "weights." .. stat, want = w, got = got_weights[stat] }
    end
  end
  return failures
end

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------

-- One fixture's result beside its reference: dps, gap, weights, cap weights, coverage.
report = function(fx, result)
  local want = fx.output
  local gap = (result.dps - want.dps) / want.dps * 100
  print(string.format("REPORT %s dps %.1f reference %.1f (stdev %.1f) gap %+.1f%%",
    fx.id, result.dps, want.dps, want.dps_stdev or 0, gap))
  local weights = type(result.weights) == "table" and result.weights or {}
  for _, stat in ipairs(sorted_keys(want.weights)) do
    print(string.format("REPORT %s   weight %-13s %9.4f reference %9.4f", fx.id, stat,
      weights[stat] or 0 / 0, want.weights[stat]))
  end
  local caps = type(result.capWeights) == "table" and result.capWeights or {}
  for _, stat in ipairs(sorted_keys(caps)) do
    local cw = caps[stat]
    print(string.format("REPORT %s   cap    %-13s below %.4f above %.4f (value %s cap %s)",
      fx.id, stat, cw.below, cw.above, tostring(cw.value), tostring(cw.cap)))
  end
  if type(result.coverage) == "table" then
    print(string.format("REPORT %s   coverage complete=%s unmodeled=%s", fx.id,
      tostring(result.coverage.complete), table.concat(result.coverage.unmodeled or {}, ",")))
  end
end

------------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------------

local function parse_args(argv)
  local opts = { tolerance = DEFAULT_TOLERANCE, fixtures = script_dir() .. "/../fixtures" }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--report" then
      opts.report = true
    elseif a == "--staged" then
      opts.staged = true
    elseif a == "--coverage" then
      opts.coverage = true
    elseif a == "--engine" or a == "--fixtures" or a == "--tolerance" or a == "--iterations"
        or a == "--path" or a == "--only" or a == "--pool" or a == "--repeats" or a == "--seeds" then
      i = i + 1
      if not argv[i] then return nil, a .. " needs a value" end
      if a == "--engine" then opts.engine = argv[i]
      elseif a == "--fixtures" then opts.fixtures = argv[i]
      elseif a == "--path" then opts.path = argv[i]
      elseif a == "--pool" then
        opts.pool = tonumber(argv[i])
        if not opts.pool or opts.pool < 2 then return nil, "--pool needs a number of at least 2" end
      elseif a == "--seeds" then
        opts.seeds = tonumber(argv[i])
        if not opts.seeds or opts.seeds < 1 then return nil, "--seeds needs a number of at least 1" end
      elseif a == "--repeats" then
        opts.repeats = tonumber(argv[i])
        if not opts.repeats then return nil, "--repeats needs a number" end
      elseif a == "--only" then
        opts.only = opts.only or {}
        opts.only[argv[i]] = true
      elseif a == "--iterations" then
        opts.iterations = tonumber(argv[i])
        if not opts.iterations then return nil, "--iterations needs a number" end
      else
        opts.tolerance = tonumber(argv[i])
        if not opts.tolerance then return nil, "--tolerance needs a number" end
      end
    else
      return nil, "unknown argument " .. a
    end
    i = i + 1
  end
  return opts
end

local function main()
  local opts, err = parse_args(arg or {})
  if not opts then
    io.stderr:write("error: ", err, "\n", USAGE)
    return 2
  end
  if opts.help then
    io.write(USAGE)
    return 0
  end
  if not opts.engine then
    io.stderr:write("error: --engine is required\n", USAGE)
    return 2
  end
  local factory = ENGINES[opts.engine]
  if not factory then
    io.stderr:write("error: unknown engine '", opts.engine, "'\n", USAGE)
    return 2
  end

  local ok, fixtures = pcall(load_fixtures, opts.fixtures)
  if not ok then
    io.stderr:write("error: ", tostring(fixtures), "\n")
    return 2
  end
  if opts.only then
    local kept = {}
    for _, fx in ipairs(fixtures) do
      if opts.only[fx.id] then kept[#kept + 1] = fx end
    end
    fixtures = kept
  end
  if #fixtures == 0 then
    io.stderr:write("error: no fixtures found in ", opts.fixtures, "\n")
    return 2
  end
  if (opts.path or opts.staged or opts.pool) and opts.engine ~= "hone" then
    io.stderr:write("error: --path, --staged and --pool need --engine hone\n")
    return 2
  end
  if opts.engine == "hone" and opts.report and not opts.staged then
    io.stderr:write("error: hone --report needs --staged (the event path is staged, decision 0014)\n")
    return 2
  end
  if (opts.pool or opts.seeds) and not (opts.report and opts.staged) then
    io.stderr:write("error: --pool and --seeds need --report --staged\n")
    return 2
  end
  if opts.pool and opts.seeds then
    io.stderr:write("error: --pool and --seeds are separate reports\n")
    return 2
  end
  if opts.coverage and not opts.pool then
    io.stderr:write("error: --coverage needs --pool\n")
    return 2
  end

  local built, engine = pcall(factory, opts)
  if built and engine.prepare then
    built, engine = pcall(function()
      engine.prepare(fixtures)
      return engine
    end)
  end
  if not built then
    io.stderr:write("error: engine ", opts.engine, ": ", tostring(engine), "\n")
    return 3
  end

  if opts.report and opts.staged and opts.pool then
    local errored, agree2, agree3, order2, order3, covered = 0, 0, 0, 0, 0, 0
    local coverageLines = {}
    print(string.format("staged pooled report, engine hone, path %s, %d evaluates per fixture, seeds %d + k x %d,"
      .. " cap weights off", opts.path or "event", opts.pool, BATCH_SEED, POOL_STRIDE))
    print("")
    for _, fx in ipairs(fixtures) do
      local ran, r = xpcall(function() return engine.poolReport(fx) end, debug.traceback)
      if not ran then
        errored = errored + 1
        print(string.format("ERROR %s %s", fx.id, tostring(r)))
      else
        if r.pass2 then agree2 = agree2 + 1 end
        if r.pass3 then agree3 = agree3 + 1 end
        if r.order2 then order2 = order2 + 1 end
        if r.order3 then order3 = order3 + 1 end
        if r.coverage2 >= COVERAGE_LINE and r.coverage3 >= COVERAGE_LINE then covered = covered + 1 end
        coverageLines[#coverageLines + 1] = string.format("%s %.1f%% / %.1f%%", fx.id, r.coverage2 * 100,
          r.coverage3 * 100)
      end
    end
    print(string.format("stage 2: %d fixtures, %d agree, stat order agrees on %d", #fixtures, agree2, order2))
    print(string.format("stage 3: %d fixtures, %d agree, stat order agrees on %d", #fixtures, agree3, order3))
    if opts.coverage then
      print("coverage at stage 2 / stage 3: " .. table.concat(coverageLines, ", "))
      print(string.format("coverage: %d fixtures, %d at or over %.0f%% at both stages", #fixtures, covered,
        COVERAGE_LINE * 100))
    end
    if errored > 0 then return 3 end
    local ok = agree2 == #fixtures and agree3 == #fixtures
    if opts.coverage then ok = ok and covered == #fixtures end
    return ok and 0 or 1
  end

  if opts.report and opts.staged and opts.seeds then
    local errored, misses, lines = 0, 0, {}
    print(string.format("staged seeds report, engine hone, path %s, %d seeds per fixture, each run once,"
      .. " os.clock (wall on this build), cap weights off", opts.path or "event", opts.seeds))
    print(string.format("lines on the slowest seed: stage 1 under %d ms, stage 2 under %d ms, cumulative;"
      .. " stage 3 no line", STAGE_LINES[1], STAGE_LINES[2]))
    print("")
    for _, fx in ipairs(fixtures) do
      local ran, r = xpcall(function() return engine.seedsReport(fx) end, debug.traceback)
      if not ran then
        errored = errored + 1
        print(string.format("ERROR %s %s", fx.id, tostring(r)))
      else
        misses = misses + r.misses
        lines[#lines + 1] = string.format("%s %.0f / %.0f / %.0f ms", fx.id, r.slowest[1], r.slowest[2],
          r.slowest[3])
      end
    end
    print("slowest seed, stage 1 / 2 / 3 cumulative ms: " .. table.concat(lines, ", "))
    print(string.format("%d fixtures, %d stage 1 or 2 times at or over their line on the slowest seed", #fixtures,
      misses))
    if errored > 0 then return 3 end
    return misses == 0 and 0 or 1
  end

  if opts.report and opts.staged then
    local errored, misses, lines = 0, 0, {}
    print(string.format("staged report, engine hone, path %s, os.clock (wall on this build), cap weights off",
      opts.path or "event"))
    print(string.format("lines: stage 1 under %d ms, stage 2 under %d ms, cumulative; stage 3 no line",
      STAGE_LINES[1], STAGE_LINES[2]))
    print("")
    for _, fx in ipairs(fixtures) do
      local ran, r = xpcall(function() return engine.stagedReport(fx) end, debug.traceback)
      if not ran then
        errored = errored + 1
        print(string.format("ERROR %s %s", fx.id, tostring(r)))
      else
        misses = misses + r.misses
        lines[#lines + 1] = string.format("%s %.0f / %.0f / %.0f ms (%d / %d / %d fights)", fx.id, r.best[1],
          r.best[2], r.best[3], r.fights[1], r.fights[2], r.fights[3])
      end
    end
    print("stage 1 / 2 / 3 cumulative ms: " .. table.concat(lines, ", "))
    print(string.format("%d fixtures, %d stage times at or over their line", #fixtures, misses))
    if errored > 0 then return 3 end
    return misses == 0 and 0 or 1
  end

  local failed, errored = 0, 0
  for _, fx in ipairs(fixtures) do
    local ran, result = xpcall(function() return engine.evaluate(fx.input) end, debug.traceback)
    local failures
    if ran then
      failures = compare(fx, result, opts.tolerance)
      if opts.report then report(fx, result) end
    else
      errored = errored + 1
      print(string.format("ERROR %s %s", fx.id, tostring(result)))
      failures = { { stat = "evaluate", want = "result", got = "Lua error" } }
    end
    if #failures == 0 then
      print(string.format("PASS %s", fx.id))
    else
      failed = failed + 1
      for _, f in ipairs(failures) do
        print(string.format("FAIL %s %s expected %s got %s", fx.id, f.stat,
          tostring(f.want), tostring(f.got)))
      end
    end
  end

  print(string.format("%d fixtures, %d passed, %d failed (engine %s)",
    #fixtures, #fixtures - failed, failed, opts.engine))
  if errored > 0 then return 3 end
  return failed == 0 and 0 or 1
end

os.exit(main())
