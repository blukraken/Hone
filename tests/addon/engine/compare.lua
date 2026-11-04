-- T1: pooled stat-weight comparison of an engine against MythicSim.
--
-- Each side gives weight samples per stat. A MythicSim sample is one seed's
-- (dps_plus - dps_base) / delta, from tests/addon/engine/data/weights_mythicsim.lua. An engine
-- sample is one batch's weight from Contract.evaluate on its own seed. Samples are pooled per
-- side, and the difference of the two means gets a Welch t interval.
--
-- A stat agrees when
--   |mean_engine - mean_mythicsim| <= max(t_0.975 * se_diff, FLOOR_RELATIVE * |mean_mythicsim|)
-- which is the owner's target: inside the 95% interval, or within 3% relative where that
-- interval is narrower.
--
-- Stat order agrees unless a pair is inverted. A pair counts as inverted when MythicSim
-- resolves its order (the paired difference's 95% interval excludes zero), the engine's point
-- estimates order it the other way, and the two paired differences differ by more than their
-- own 95% interval. A pair MythicSim cannot order is never counted.
--
-- Usage
--   lua tests/addon/engine/compare.lua --selftest [--splits N] [--seed S]
--   dofile("tests/addon/engine/compare.lua") from another script returns the module.
--
-- The self-test is the identity engine fed MythicSim's own samples. Each split shuffles one
-- fixture's seeds into two halves, scores one half as the engine against the other as the
-- reference, and counts a false fail whenever the gate fails. A split of the whole set fails
-- when any of the five fixtures fails. Exit 0 when that rate is under the limit.

local Compare = {}

Compare.FLOOR_RELATIVE = 0.03
Compare.LEVEL = 0.95
Compare.SELFTEST_LIMIT = 0.05
Compare.SELFTEST_SPLITS = 2000
Compare.SELFTEST_SEED = 20261104

local sqrt, abs, floor = math.sqrt, math.abs, math.floor

------------------------------------------------------------------------------
-- Statistics
------------------------------------------------------------------------------

function Compare.summary(values)
  local n, sum = #values, 0
  for i = 1, n do sum = sum + values[i] end
  local mean = sum / n
  local sq = 0
  for i = 1, n do
    local d = values[i] - mean
    sq = sq + d * d
  end
  local sd = n > 1 and sqrt(sq / (n - 1)) or 0
  return { n = n, mean = mean, sd = sd, se = sd / sqrt(n) }
end

-- Standard normal quantile (Acklam's rational approximation, relative error below 1.2e-9).
local A = { -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
            1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 }
local B = { -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
            6.680131188771972e+01, -1.328068155288572e+01 }
local C = { -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
            -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 }
local D = { 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
            3.754408661907416e+00 }

function Compare.normalQuantile(p)
  local q, r
  if p < 0.02425 then
    q = sqrt(-2 * math.log(p))
    return (((((C[1] * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5]) * q + C[6]) /
      ((((D[1] * q + D[2]) * q + D[3]) * q + D[4]) * q + 1)
  elseif p > 1 - 0.02425 then
    return -Compare.normalQuantile(1 - p)
  end
  q = p - 0.5
  r = q * q
  return (((((A[1] * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * r + A[6]) * q /
    (((((B[1] * r + B[2]) * r + B[3]) * r + B[4]) * r + B[5]) * r + 1)
end

-- Student t quantile by the Cornish-Fisher expansion in 1/df (good to 1e-3 from df 5 up).
function Compare.tQuantile(p, df)
  local z = Compare.normalQuantile(p)
  if df == math.huge then return z end
  if df < 2 then df = 2 end
  local z2 = z * z
  local g1 = (z2 + 1) * z / 4
  local g2 = ((5 * z2 + 16) * z2 + 3) * z / 96
  local g3 = (((3 * z2 + 19) * z2 + 17) * z2 - 15) * z / 384
  local g4 = ((((79 * z2 + 776) * z2 + 1482) * z2 - 1920) * z2 - 945) * z / 92160
  return z + g1 / df + g2 / df ^ 2 + g3 / df ^ 3 + g4 / df ^ 4
end

-- Welch interval half-width of mean(a) - mean(b) at `level`.
function Compare.welch(a, b, level)
  local va, vb = a.se * a.se, b.se * b.se
  local se = sqrt(va + vb)
  if se == 0 then return 0, se, math.huge end
  local da = a.n > 1 and va * va / (a.n - 1) or 0
  local db = b.n > 1 and vb * vb / (b.n - 1) or 0
  local df = (da + db) > 0 and (va + vb) ^ 2 / (da + db) or math.huge
  return Compare.tQuantile(1 - (1 - level) / 2, df) * se, se, df
end

------------------------------------------------------------------------------
-- Samples
------------------------------------------------------------------------------

-- MythicSim weight samples by stat from one captured case, optionally a subset of seed indices.
function Compare.mythicsimSamples(case, delta, stats, indices)
  local out = {}
  for _, stat in ipairs(stats) do
    local plus, values = case.plus[stat], {}
    if indices then
      for i, k in ipairs(indices) do values[i] = (plus[k] - case.base[k]) / delta end
    else
      for k = 1, #case.base do values[k] = (plus[k] - case.base[k]) / delta end
    end
    out[stat] = values
  end
  return out
end

------------------------------------------------------------------------------
-- Comparison
------------------------------------------------------------------------------

function Compare.stat(engineValues, referenceValues, opts)
  opts = opts or {}
  local level = opts.level or Compare.LEVEL
  local floorRel = opts.floorRelative or Compare.FLOOR_RELATIVE
  local e, m = Compare.summary(engineValues), Compare.summary(referenceValues)
  local diff = e.mean - m.mean
  local halfwidth, se, df = Compare.welch(e, m, level)
  local floorAbs = floorRel * abs(m.mean)
  local limit = halfwidth > floorAbs and halfwidth or floorAbs
  return {
    engine = e, reference = m, diff = diff, halfwidth = halfwidth, se = se, df = df,
    relative = m.mean ~= 0 and diff / abs(m.mean) or (diff == 0 and 0 or math.huge),
    limit = limit, basis = halfwidth > floorAbs and "interval" or "3%",
    passInterval = abs(diff) <= halfwidth,
    pass = abs(diff) <= limit,
  }
end

local function pairDiffs(samples, a, b)
  local out, sa, sb = {}, samples[a], samples[b]
  for i = 1, #sa do out[i] = sa[i] - sb[i] end
  return out
end

-- Pairwise order check. Returns the list of inverted pairs and the point-estimate orders.
function Compare.order(engineSamples, referenceSamples, stats, opts)
  opts = opts or {}
  local level = opts.level or Compare.LEVEL
  local inversions, pointInversions = {}, 0
  for i = 1, #stats do
    for j = i + 1, #stats do
      local a, b = stats[i], stats[j]
      local m = Compare.summary(pairDiffs(referenceSamples, a, b))
      local e = Compare.summary(pairDiffs(engineSamples, a, b))
      local opposite = (e.mean > 0 and m.mean < 0) or (e.mean < 0 and m.mean > 0)
      if opposite then pointInversions = pointInversions + 1 end
      local df = m.n - 1
      local resolved = m.se == 0 and m.mean ~= 0
        or (m.se > 0 and abs(m.mean) > Compare.tQuantile(1 - (1 - level) / 2, df) * m.se)
      if resolved and opposite then
        local halfwidth = Compare.welch(e, m, level)
        if abs(e.mean - m.mean) > halfwidth then
          inversions[#inversions + 1] = { a = a, b = b, engine = e.mean, reference = m.mean }
        end
      end
    end
  end
  return inversions, pointInversions
end

local function ranked(samples, stats)
  local means, list = {}, {}
  for _, stat in ipairs(stats) do
    means[stat] = Compare.summary(samples[stat]).mean
    list[#list + 1] = stat
  end
  table.sort(list, function(x, y) return means[x] > means[y] end)
  return list
end

-- One fixture: per-stat results, the order check and the verdict.
function Compare.fixture(engineSamples, referenceSamples, stats, opts)
  local out = { stats = {}, pass = true, statFails = 0 }
  for _, stat in ipairs(stats) do
    local r = Compare.stat(engineSamples[stat], referenceSamples[stat], opts)
    out.stats[stat] = r
    if not r.pass then
      out.pass = false
      out.statFails = out.statFails + 1
    end
  end
  out.inversions, out.pointInversions = Compare.order(engineSamples, referenceSamples, stats, opts)
  out.orderPass = #out.inversions == 0
  if not out.orderPass then out.pass = false end
  out.engineOrder = ranked(engineSamples, stats)
  out.referenceOrder = ranked(referenceSamples, stats)
  return out
end

function Compare.printFixture(id, r, stats, write)
  write = write or print
  write(string.format("%s  %s", id, r.pass and "AGREE" or "DISAGREE"))
  write(string.format("  %-13s %10s %10s %10s %8s %10s %10s %-8s %s", "stat", "engine", "mythicsim",
    "diff", "rel", "ci95", "limit", "basis", "verdict"))
  for _, stat in ipairs(stats) do
    local s = r.stats[stat]
    write(string.format("  %-13s %10.5f %10.5f %+10.5f %+7.2f%% %10.5f %10.5f %-8s %s  (n %d/%d)",
      stat, s.engine.mean, s.reference.mean, s.diff, s.relative * 100, s.halfwidth, s.limit,
      s.basis, s.pass and "pass" or "FAIL", s.engine.n, s.reference.n))
  end
  write("  order engine     " .. table.concat(r.engineOrder, " > "))
  write("  order mythicsim  " .. table.concat(r.referenceOrder, " > "))
  if #r.inversions == 0 then
    write(string.format("  order agrees (%d point inversions, none resolved)", r.pointInversions))
  else
    for _, inv in ipairs(r.inversions) do
      write(string.format("  order INVERTED %s vs %s: engine %+.5f mythicsim %+.5f", inv.a, inv.b,
        inv.engine, inv.reference))
    end
  end
end

------------------------------------------------------------------------------
-- Self-test
------------------------------------------------------------------------------

local function scriptDir()
  local info = debug.getinfo(1, "S").source
  local path = info:sub(1, 1) == "@" and info:sub(2) or info
  return (path:gsub("\\", "/"):match("^(.*)/[^/]*$")) or "."
end

function Compare.loadReference()
  return dofile(scriptDir() .. "/data/weights_mythicsim.lua")
end

function Compare.selftest(opts)
  opts = opts or {}
  local splits = opts.splits or Compare.SELFTEST_SPLITS
  local Loader = dofile(scriptDir() .. "/loader.lua")
  local ns = Loader.load(Loader.root(), { classes = {} })
  local rng = ns.Engine.Core.Rng.new(opts.seed or Compare.SELFTEST_SEED)
  local ref = Compare.loadReference()
  local stats = ref.stats
  local ids = {}
  for id in pairs(ref.cases) do ids[#ids + 1] = id end
  table.sort(ids)

  local tally = {}
  for _, id in ipairs(ids) do
    tally[id] = { fixtureFails = 0, orderFails = 0, stat = {}, statRaw = {} }
    for _, stat in ipairs(stats) do tally[id].stat[stat], tally[id].statRaw[stat] = 0, 0 end
  end
  local runFails = 0

  for _ = 1, splits do
    local runFailed = false
    for _, id in ipairs(ids) do
      local case = ref.cases[id]
      local n = #case.base
      local perm = {}
      for i = 1, n do perm[i] = i end
      for i = n, 2, -1 do
        local j = floor(rng:next() * i) + 1
        perm[i], perm[j] = perm[j], perm[i]
      end
      local half = floor(n / 2)
      local a, b = {}, {}
      for i = 1, half do a[i] = perm[i] end
      for i = half + 1, 2 * half do b[#b + 1] = perm[i] end
      local r = Compare.fixture(Compare.mythicsimSamples(case, ref.delta, stats, a),
        Compare.mythicsimSamples(case, ref.delta, stats, b), stats)
      local t = tally[id]
      for _, stat in ipairs(stats) do
        if not r.stats[stat].pass then t.stat[stat] = t.stat[stat] + 1 end
        if not r.stats[stat].passInterval then t.statRaw[stat] = t.statRaw[stat] + 1 end
      end
      if not r.orderPass then t.orderFails = t.orderFails + 1 end
      if not r.pass then
        t.fixtureFails = t.fixtureFails + 1
        runFailed = true
      end
    end
    if runFailed then runFails = runFails + 1 end
  end
  return { ids = ids, stats = stats, tally = tally, splits = splits, runFails = runFails, ref = ref }
end

local function mainSelftest(argv)
  local opts = {}
  for i = 1, #argv do
    if argv[i] == "--splits" then opts.splits = tonumber(argv[i + 1]) end
    if argv[i] == "--seed" then opts.seed = tonumber(argv[i + 1]) end
  end
  local r = Compare.selftest(opts)
  local ref = r.ref
  print(string.format("MythicSim %s at %s", ref.engine, ref.pin))
  print(string.format("Reference: %d seeds x %d fights per fixture, weights at +%d",
    #ref.cases[r.ids[1]].base, ref.iterations, ref.delta))
  print(string.format("Self-test: identity engine fed MythicSim's own samples, %d random half splits"
    .. " (seed %d)", r.splits, opts.seed or Compare.SELFTEST_SEED))
  print(string.format("Gate: |diff| <= max(t95 * se_diff, %.0f%% of |mythicsim|) per stat, no resolved"
    .. " order inversion", Compare.FLOOR_RELATIVE * 100))
  print("")
  print("Full-set reference weights (all seeds pooled), mean and 95% half-width")
  for _, id in ipairs(r.ids) do
    local samples = Compare.mythicsimSamples(ref.cases[id], ref.delta, r.stats)
    local parts = {}
    for _, stat in ipairs(r.stats) do
      local s = Compare.summary(samples[stat])
      local hw = Compare.tQuantile(0.975, s.n - 1) * s.se
      parts[#parts + 1] = string.format("%s %.4f+-%.4f", stat, s.mean, hw)
    end
    print(string.format("  %-28s %s", id, table.concat(parts, "  ")))
  end
  print("")
  print("False-fail rate per stat: gate (raw 95% interval alone in brackets)")
  for _, id in ipairs(r.ids) do
    local t = r.tally[id]
    local parts = {}
    for _, stat in ipairs(r.stats) do
      parts[#parts + 1] = string.format("%s %.3f (%.3f)", stat, t.stat[stat] / r.splits,
        t.statRaw[stat] / r.splits)
    end
    print(string.format("  %-28s %s", id, table.concat(parts, "  ")))
  end
  print("")
  print("False-fail rate per fixture (any stat or order)")
  local sumFixture = 0
  for _, id in ipairs(r.ids) do
    local t = r.tally[id]
    sumFixture = sumFixture + t.fixtureFails
    print(string.format("  %-28s fixture %.4f  order %.4f", id, t.fixtureFails / r.splits,
      t.orderFails / r.splits))
  end
  local rate = r.runFails / r.splits
  print("")
  print(string.format("Mean per-fixture false-fail rate: %.4f", sumFixture / (r.splits * #r.ids)))
  print(string.format("Five-fixture false-fail rate (any fixture fails): %.4f (%d of %d splits)",
    rate, r.runFails, r.splits))
  local pass = rate < Compare.SELFTEST_LIMIT
  print(string.format("Limit %.2f: %s", Compare.SELFTEST_LIMIT, pass and "PASS" or "FAIL"))
  return pass and 0 or 1
end

local isMain = arg and arg[0] and arg[0]:gsub("\\", "/"):match("compare%.lua$")
if isMain then
  local argv = arg
  local selftest = false
  for i = 1, #argv do if argv[i] == "--selftest" then selftest = true end end
  if not selftest then
    io.stderr:write("usage: lua tests/addon/engine/compare.lua --selftest [--splits N] [--seed S]\n"
      .. "Engine comparisons run through tests/addon/fixture_runner.lua --engine hone --report.\n")
    os.exit(2)
  end
  os.exit(mainSelftest(argv))
end

return Compare
