-- Per-action parity of a Hone path against MythicSim, one fixture at a time.
--
-- For each action the report gives casts, outcome shares and damage per fight on both sides,
-- from Hone's tallies and the per-action metrics capture_mythicsim.py stores in the snapshot.
-- It is a diagnostic: it locates a dps gap, the weight comparison judges it.
--
-- Usage: lua tests/addon/engine/actions_report.lua [--path event] [--iterations N] [--seed S] [id ...]

local Loader = dofile((arg[0]:gsub("[^/\]+$", "")) .. "loader.lua")
local root = Loader.root()
local ns = Loader.load(root)
local snapshots = dofile(root .. "/tests/addon/engine/data/snapshots.lua")
local Contract = ns.Engine.Contract

local opts = { path = "event", iterations = 3000, seed = 4242, ids = {} }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--path" then opts.path = arg[i + 1] i = i + 1
  elseif a == "--iterations" then opts.iterations = tonumber(arg[i + 1]) i = i + 1
  elseif a == "--seed" then opts.seed = tonumber(arg[i + 1]) i = i + 1
  else opts.ids[#opts.ids + 1] = a end
  i = i + 1
end
if #opts.ids == 0 then
  opts.ids = { "enh60-rockbiter-2h38-hitcap", "enh60-rockbiter-2h38-vs60", "enh60-rockbiter-dw29-hit97",
               "enh60-windfury-dw20-29", "enh60-windfury-dw26-29" }
end

-- Hone action names and the MythicSim metric keys they match.
local ACTIONS = {
  { "mainHand", '{"otherId": "OtherActionAttack", "tag": 1}' },
  { "offHand", '{"otherId": "OtherActionAttack", "tag": 2}' },
  { "windfuryTotemAttack", '{"otherId": "OtherActionAttack", "tag": 25584}' },
  { "windfuryMainHand", '{"spellId": 439440}' },
  { "stormstrike", '{"spellId": 17364}' },
  { "stormstrikeMainHand", '{"spellId": 17364, "tag": 1}' },
  { "lightningBolt", '{"spellId": 15208}' },
  { "earthShock", '{"spellId": 10414}' },
  { "flameShock", '{"spellId": 29228}' },
  { "flameShockDot", '{"spellId": 29228, "tag": 1}' },
  { "fireNova", '{"spellId": 408345}' },
  { "searingTotemAttack", '{"spellId": 10436}' },
  { "flametongue", '{"spellId": 16344}' },
  { "dragonbreathChili", '{"spellId": 15851}' },
  { "Iceblade Hacker", '{"spellId": 1298414}' },
  { "manaPotion", '{"itemId": 13444}' },
  { "manaRune", '{"itemId": 12662}' },
}

for _, id in ipairs(opts.ids) do
  local snap = assert(snapshots[id], "no snapshot " .. id)
  local impl = Contract.lookup(snap.class, snap.spec)
  local t0 = os.clock()
  -- Real outcomes on sampled fight ends, so per-fight counts and crit shares compare with
  -- MythicSim's; the Flurry listener order stays as production runs it.
  local event = {}
  for k, v in pairs(impl.SEQUENTIAL or {}) do event[k] = v end
  event.flurryFirst = true
  local run = impl.simulate(snap, { path = opts.path, seed = opts.seed, iterations = opts.iterations,
    event = event, tally = true,
    duration = 120, durationVariation = 15 })
  local cpu = os.clock() - t0
  local ref = snap.reference.mythicsim
  local n = opts.iterations
  print(string.format("%s  path %s  dps hone %.2f  mythicsim %.2f  gap %+.2f%%  (%d fights, %.3f ms per fight)",
    id, opts.path, run.dps, ref.dps, (run.dps - ref.dps) / ref.dps * 100, n, cpu * 1000 / n))
  print(string.format("  %-20s %15s %15s %13s %13s %13s %17s", "action", "casts h/m", "dmg/fight h/m",
    "crit% h/m", "miss% h/m", "glance% h/m", "dmg share h/m"))
  local totalH, totalM = 0, 0
  for _, row in pairs(run.tally or {}) do totalH = totalH + row.damage / n end
  for _, m in pairs(ref.actionsPerFight or {}) do totalM = totalM + (m.damage or 0) end
  for _, a in ipairs(ACTIONS) do
    local hrow = run.tally and run.tally[a[1]]
    local mrow = ref.actionsPerFight and ref.actionsPerFight[a[2]]
    if hrow or mrow then
      hrow = hrow or { casts = 0, hits = 0, crits = 0, misses = 0, dodges = 0, glances = 0, damage = 0 }
      mrow = mrow or {}
      local function pct(row, field, per)
        local c = (row.casts or 0)
        if c == 0 then return 0 end
        return (row[field] or 0) / c * 100 * (per or 1)
      end
      local hc, mc = hrow.casts / n, mrow.casts or 0
      -- MythicSim counts a dot's ticks as hits and crits, not casts.
      if mc == 0 and (mrow.hits or 0) > 0 then
        mc = (mrow.hits or 0) + (mrow.crits or 0) + (mrow.misses or 0) + (mrow.dodges or 0) + (mrow.glances or 0)
      end
      local mcrow = { casts = mc, crits = mrow.crits, misses = mrow.misses, glances = mrow.glances }
      print(string.format("  %-20s %7.2f/%-7.2f %7.1f/%-7.1f %6.2f/%-6.2f %6.2f/%-6.2f %6.2f/%-6.2f %8.2f%%/%-7.2f%%",
        a[1], hc, mc, hrow.damage / n, mrow.damage or 0,
        pct({ casts = hrow.casts, crits = hrow.crits }, "crits"), pct(mcrow, "crits"),
        pct({ casts = hrow.casts, misses = hrow.misses }, "misses"), pct(mcrow, "misses"),
        pct({ casts = hrow.casts, glances = hrow.glances }, "glances"), pct(mcrow, "glances"),
        totalH > 0 and hrow.damage / n / totalH * 100 or 0, totalM > 0 and (mrow.damage or 0) / totalM * 100 or 0))
    end
  end
  print("")
end
