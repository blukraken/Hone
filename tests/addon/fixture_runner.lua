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
-- With --report the hone engine is judged by the pooled comparison instead: per fixture it
-- runs --batches evaluations on seeds BATCH_SEED + k, pools their weights, and compares them
-- with MythicSim's pooled samples (tests/addon/engine/compare.lua). It prints per-stat
-- agreement, stat order, how each weight is found, the fights each stat needs for 3% and
-- milliseconds per evaluate from os.clock.
--
-- With --report --stop-rule NAME each fixture runs one evaluate under that stop rule
-- (Core/Defaults stopRules: dps is decision 0013's stake, rel3 the flat 3%), --repeats times
-- on the same seed. It prints the minimum milliseconds, the fights each stat used, each
-- weight's 95% half-width and its DPS stake over 30 points, and the minimum-spec forecast.
-- os.clock reads wall time on the Windows Lua build, so time it alone and pinned
-- (tests/addon/engine/pinned.sh).
--
-- Report evaluates leave cap weights out (capWindow -1). The cost they time is the base run
-- and the weights, which is what the MODEL-06 checks price.
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
  --report           hone: T1 pooled weight comparison, stat order and CPU per evaluate;
                     other engines: each fixture's dps and weights beside the reference
  --batches N        hone --report only: evaluations pooled per fixture (default 20)
  --stop-rule NAME   hone --report only: one evaluate per fixture under stop rule NAME
                     (dps | rel3), timed --repeats times
  --repeats N        hone --report --stop-rule only: timed repeats per fixture (default 5)
  --agility-sim      hone only: simulate agility instead of scaling the crit weight
  --only ID          run only the fixture with this id (repeatable)
  --help             show this text

exit codes: 0 all fixtures pass, 1 at least one mismatch, 2 usage or load error,
            3 the engine raised a Lua error
]]

local DEFAULT_TOLERANCE = 1e-6

-- MODEL-06 T3: every stat should need fewer fights than this for 3%.
local FIGHTS_LINE = 900
local REPORT_BATCHES = 20
local REPORT_ITERATIONS = 1500
local BATCH_SEED = 100000
local STOP_REPEATS = 5

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
          agilityFromCrit = not opts.agilitySim,
        },
      }
    end
  end

  function engine.evaluate(input)
    local case = by_input[input]
    return ns.Engine.Contract.evaluate(case.snapshot, case.scenario)
  end

  -- T1-method report: pooled weights over batches against MythicSim's pooled samples.
  function engine.report(fx)
    local Compare = dofile(root .. "/tests/addon/engine/compare.lua")
    local ref = Compare.loadReference()
    local mcase = ref.cases[fx.id]
    if not mcase then error("no pooled MythicSim samples for " .. fx.id, 0) end
    local case = by_input[fx.input]
    local stats = ref.stats
    local samples, cpu, dps = {}, 0, {}
    for _, stat in ipairs(stats) do samples[stat] = {} end
    local batches = opts.batches or REPORT_BATCHES
    local scenario = {}
    for k, v in pairs(case.scenario) do scenario[k] = v end
    scenario.iterations = opts.iterations or REPORT_ITERATIONS
    scenario.weightDelta = ref.delta
    scenario.capWindow = -1
    local plan
    for k = 1, batches do
      scenario.seed = BATCH_SEED + k
      local t0 = os.clock()
      local result = ns.Engine.Contract.evaluate(case.snapshot, scenario)
      cpu = cpu + (os.clock() - t0)
      dps[k] = result.dps
      plan = result.run.plan
      for _, stat in ipairs(stats) do samples[stat][k] = result.weights[stat] end
    end
    local r = Compare.fixture(samples, Compare.mythicsimSamples(mcase, ref.delta, stats), stats)
    local d = Compare.summary(dps)
    local mbase = Compare.summary(mcase.base)
    r.cpuPerEvaluate = cpu / batches * 1000
    Compare.printFixture(fx.id, r, stats)
    print(string.format("  dps engine %.2f +- %.2f  mythicsim %.2f +- %.2f  gap %+.2f%%", d.mean, 1.96 * d.se,
      mbase.mean, 1.96 * mbase.se, (d.mean - mbase.mean) / mbase.mean * 100))
    local sims, sources = 1, {}
    for _, stat in ipairs(stats) do
      local entry = plan and plan[stat] or { kind = "simulated" }
      if entry.kind == "simulated" then sims = sims + 1 end
      sources[#sources + 1] = stat .. " " .. (entry.kind == "derived" and ("from " .. entry.from) or entry.kind)
    end
    for _, entry in pairs(plan or {}) do
      if entry.hidden then sims = sims + 1 end
    end
    print("  weights: " .. table.concat(sources, ", "))
    print(string.format("  cpu %.1f ms per evaluate (%d fights x %d sims, %.4f ms per fight), %d batches",
      r.cpuPerEvaluate, scenario.iterations, sims, r.cpuPerEvaluate / (scenario.iterations * sims), batches))
    -- Fights each weight needs to sit within 3% of MythicSim's at 95%, from the spread of the
    -- batch weights.
    local need, worst, parts = 0, "-", {}
    for _, stat in ipairs(stats) do
      local e, m = r.stats[stat].engine, r.stats[stat].reference
      local n = 0
      if m.mean ~= 0 and e.sd > 0 then n = scenario.iterations * (1.96 * e.sd / (0.03 * math.abs(m.mean))) ^ 2 end
      parts[#parts + 1] = string.format("%s %.0f", stat, n)
      if n > need then need, worst = n, stat end
    end
    r.fightsFor3 = need
    print("  fights for 3%: " .. table.concat(parts, "  "))
    print(string.format("  worst %s %.0f fights (line %d)", worst, need, FIGHTS_LINE))
    print("")
    return r
  end

  -- One evaluate under a stop rule, timed. Weights beside MythicSim's pooled means.
  function engine.stopReport(fx)
    local Compare = dofile(root .. "/tests/addon/engine/compare.lua")
    local ref = Compare.loadReference()
    local mcase = ref.cases[fx.id]
    local case = by_input[fx.input]
    local stats = ref.stats
    local Defaults = ns.Engine.Core.Defaults
    if not Defaults.stopRules[opts.stopRule] then error("no stop rule named " .. tostring(opts.stopRule), 0) end
    local scenario = {}
    for k, v in pairs(case.scenario) do scenario[k] = v end
    scenario.seed = BATCH_SEED
    scenario.weightDelta = ref.delta
    scenario.capWindow = -1
    scenario.stopRule = opts.stopRule
    local best, runs, result = math.huge, {}, nil
    for k = 1, opts.repeats or STOP_REPEATS do
      collectgarbage("collect")
      local t0 = os.clock()
      result = ns.Engine.Contract.evaluate(case.snapshot, scenario)
      local ms = (os.clock() - t0) * 1000
      runs[k] = string.format("%.0f", ms)
      if ms < best then best = ms end
    end
    local reference = Compare.mythicsimSamples(mcase, ref.delta, stats)
    print(string.format("%s  stop rule %s", fx.id, opts.stopRule))
    print(string.format("  %-13s %10s %10s %8s %10s %8s %7s  %s", "stat", "engine", "mythicsim", "rel",
      "hw95", "stake", "fights", "source"))
    for _, stat in ipairs(stats) do
      local w, se = result.weights[stat], result.run.se[stat]
      local m = Compare.summary(reference[stat]).mean
      local entry = result.run.plan[stat]
      print(string.format("  %-13s %10.5f %10.5f %+7.2f%% %10.5f %8.4f %7d  %s", stat, w, m,
        m ~= 0 and (w - m) / math.abs(m) * 100 or 0, 1.96 * se, 1.96 * se * 30, result.fights[stat],
        entry.kind == "derived" and ("from " .. entry.from) or entry.kind))
    end
    local total = result.run.fightsTotal
    print(string.format("  dps %.2f  batches %d of %d fights  fights run %d", result.dps, result.batches,
      Defaults.stopBatchSize, total))
    print(string.format("  cpu %.1f ms per evaluate (min of %d: %s), %.4f ms per fight; minimum spec x%.2f: %.0f ms",
      best, #runs, table.concat(runs, " "), best / total, MIN_SPEC_FACTOR, best * MIN_SPEC_FACTOR))
    print("")
    return { ms = best, fights = total, batches = result.batches }
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
    elseif a == "--agility-sim" then
      opts.agilitySim = true
    elseif a == "--engine" or a == "--fixtures" or a == "--tolerance" or a == "--iterations"
        or a == "--path" or a == "--batches" or a == "--only" or a == "--stop-rule" or a == "--repeats" then
      i = i + 1
      if not argv[i] then return nil, a .. " needs a value" end
      if a == "--engine" then opts.engine = argv[i]
      elseif a == "--fixtures" then opts.fixtures = argv[i]
      elseif a == "--path" then opts.path = argv[i]
      elseif a == "--stop-rule" then opts.stopRule = argv[i]
      elseif a == "--repeats" then
        opts.repeats = tonumber(argv[i])
        if not opts.repeats then return nil, "--repeats needs a number" end
      elseif a == "--only" then
        opts.only = opts.only or {}
        opts.only[argv[i]] = true
      elseif a == "--batches" then
        opts.batches = tonumber(argv[i])
        if not opts.batches then return nil, "--batches needs a number" end
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
  if (opts.path or opts.batches or opts.stopRule) and opts.engine ~= "hone" then
    io.stderr:write("error: --path, --batches and --stop-rule need --engine hone\n")
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

  if opts.report and opts.stopRule and engine.stopReport then
    local errored, cpu, over = 0, {}, 0
    print(string.format("stop-rule report, engine hone, path %s, rule %s, os.clock (wall on this build), cap weights off",
      opts.path or "event", opts.stopRule))
    print("")
    for _, fx in ipairs(fixtures) do
      local ran, r = xpcall(function() return engine.stopReport(fx) end, debug.traceback)
      if not ran then
        errored = errored + 1
        print(string.format("ERROR %s %s", fx.id, tostring(r)))
      else
        cpu[#cpu + 1] = string.format("%s %.0f ms (%d fights)", fx.id, r.ms, r.fights)
        if r.ms >= 100 then over = over + 1 end
      end
    end
    print("ms per evaluate: " .. table.concat(cpu, ", "))
    print(string.format("%d fixtures, %d at or over the 100 ms line", #fixtures, over))
    if errored > 0 then return 3 end
    return over == 0 and 0 or 1
  end

  if opts.report and engine.report then
    local failed, errored, cpu, orders, fightsOver = 0, 0, {}, 0, 0
    print(string.format("pooled report, engine hone, path %s, cap weights off", opts.path or "event"))
    print("")
    for _, fx in ipairs(fixtures) do
      local ran, r = xpcall(function() return engine.report(fx) end, debug.traceback)
      if not ran then
        errored = errored + 1
        print(string.format("ERROR %s %s", fx.id, tostring(r)))
      else
        if not r.pass then failed = failed + 1 end
        if r.orderPass then orders = orders + 1 end
        cpu[#cpu + 1] = string.format("%s %.0f ms (worst stat %.0f fights for 3%%)", fx.id, r.cpuPerEvaluate,
          r.fightsFor3)
        if r.fightsFor3 >= FIGHTS_LINE then fightsOver = fightsOver + 1 end
      end
    end
    print(string.format("%d fixtures, %d agree, %d disagree, stat order agrees on %d (path %s)",
      #fixtures, #fixtures - failed - errored, failed + errored, orders, opts.path or "event"))
    print("cpu per evaluate: " .. table.concat(cpu, ", "))
    print(string.format("fixtures with a stat at or over %d fights for 3%%: %d", FIGHTS_LINE, fightsOver))
    if errored > 0 then return 3 end
    return failed == 0 and 0 or 1
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
