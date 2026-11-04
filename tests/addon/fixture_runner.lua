-- Fixture runner for the MythicSim reference fixtures (Lua 5.1 / LuaJIT).
--
-- Loads every tests/fixtures/*.json, calls engine.evaluate(input) for each, and compares the
-- result with the fixture's output. Exit code 0 means all fixtures passed, 1 means any failed,
-- 2 means a usage or load error.
--
-- An engine is a table with evaluate(input) -> { dps = n, weights = { [stat] = n } }.
-- An engine may also define prepare(fixtures), called once before the first evaluate.
-- Two stubs are built in until the real model exists.
--   identity   returns each fixture's own expected values, so every fixture passes
--   perturbed  shifts one stat of each fixture past tolerance, so the run fails
--
-- Usage: lua tests/addon/fixture_runner.lua --engine identity|perturbed [options]

local USAGE = [[
usage: lua tests/addon/fixture_runner.lua --engine NAME [options]

  --engine NAME      identity | perturbed
  --fixtures DIR     directory of fixture JSON files (default: tests/fixtures beside this script)
  --tolerance REL    relative tolerance used when a fixture's tolerance is null (default 1e-6)
  --help             show this text

exit codes: 0 all fixtures pass, 1 at least one mismatch, 2 usage or load error
]]

local DEFAULT_TOLERANCE = 1e-6

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

local ENGINES = {
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
-- Main
------------------------------------------------------------------------------

local function parse_args(argv)
  local opts = { tolerance = DEFAULT_TOLERANCE, fixtures = script_dir() .. "/../fixtures" }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--engine" or a == "--fixtures" or a == "--tolerance" then
      i = i + 1
      if not argv[i] then return nil, a .. " needs a value" end
      if a == "--engine" then opts.engine = argv[i]
      elseif a == "--fixtures" then opts.fixtures = argv[i]
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
  if #fixtures == 0 then
    io.stderr:write("error: no fixtures found in ", opts.fixtures, "\n")
    return 2
  end

  local engine = factory()
  if engine.prepare then engine.prepare(fixtures) end

  local failed = 0
  for _, fx in ipairs(fixtures) do
    local ran, result = pcall(engine.evaluate, fx.input)
    local failures
    if ran then
      failures = compare(fx, result, opts.tolerance)
    else
      failures = { { stat = "evaluate", want = "result", got = tostring(result) } }
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
  return failed == 0 and 0 or 1
end

os.exit(main())
