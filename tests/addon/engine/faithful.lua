-- T2: the event sim with every estimator option off is main's EventSim at 11ba1ed, bit for bit.
--
-- Per fixture, main's EventSim.run (read from git) and the worktree's EventSim.run take the
-- same Rng and FIGHTS fights. The sequential mode runs with the tally on, as main always did,
-- and the run must match per-fight dps, the final Rng state, the Windfury counters and every
-- tally cell. The optimised configuration (tally off) must match per-fight dps and Rng state.
--
-- The rotation poll skip is checked on the evaluate's own options too: indexed draws with
-- every estimator option, stratified over a 29-fight batch and unstratified, run with the
-- skip on and with every pass run (opts.everyPass). Per-fight dps and both pathwise slopes
-- must match bit for bit. The line also gives the share of passes the skip left out.
--
-- Usage: lua tests/addon/engine/faithful.lua [FIGHTS] [SEED]
-- Exit: 0 every fixture identical, 1 any mismatch.

local Harness = dofile((arg[0]:gsub("[^/\\]+$", "")) .. "harness.lua")
local ns = Harness.load()
local main = Harness.loadMain()
local Rng = ns.Engine.Core.Rng
local New, Old = ns.Engine.Classes.Shaman.EventSim, main.Engine.Classes.Shaman.EventSim
local OldRng = main.Engine.Core.Rng

local fights = tonumber(arg[1]) or 500
local seed = tonumber(arg[2]) or 4242
local Enhancement = ns.Engine.Classes.Shaman.Enhancement

-- Evaluate options, skip on or off, with a pass counter.
local function evaluateOptions(strata, everyPass)
  local o = Enhancement.eventOptions({}, strata)
  o.everyPass, o.passes = everyPass, { run = 0, skipped = 0 }
  return o
end

local function sameList(x, y)
  local bad = (#x == fights and #y == fights) and 0 or 1
  for i = 1, fights do if x[i] ~= y[i] then bad = bad + 1 end end
  return bad
end

local function tallyEqual(x, y)
  for name, row in pairs(x) do
    local other = y[name]
    if not other then return false end
    for k, v in pairs(row) do if other[k] ~= v then return false end end
  end
  for name in pairs(y) do if not x[name] then return false end end
  return true
end

print(string.format("faithful: main EventSim at %s vs worktree EventSim, %d fights per fixture, seed %d",
  Harness.MAIN, fights, seed))
local total, allOk = 0, true
for _, id in ipairs(Harness.FIXTURES) do
  local snapshot, scenario = Harness.snapshots[id], Harness.scenario(id)
  local ro = OldRng.new(seed)
  local a, wa, ta = Old.run(Old.character(snapshot), scenario, ro, fights)

  for _, mode in ipairs({ { "sequential", { tally = true } }, { "optimised", {} } }) do
    local rn = Rng.new(seed)
    local b, wb, tb = New.run(New.character(snapshot), scenario, rn, fights, mode[2])
    local bad = (#a == fights and #b == fights) and 0 or 1
    for i = 1, fights do if a[i] ~= b[i] then bad = bad + 1 end end
    local rngSame = ro.s1 == rn.s1 and ro.s2 == rn.s2
    local wfSame = (wa == nil) == (wb == nil)
      and (wa == nil or (wa.eligible == wb.eligible and wa.rolls == wb.rolls and wa.procs == wb.procs))
    local tallyNote = "off"
    local ok = bad == 0 and rngSame and wfSame
    if mode[2].tally then
      local same = tallyEqual(ta, tb)
      tallyNote = same and "same" or "DIFF"
      ok = ok and same
    end
    print(string.format("%-28s %-10s fights %d  mismatches %d  rng state %s  windfury %s  tally %s  %s",
      id, mode[1], fights, bad, rngSame and "same" or "DIFF", wfSame and "same" or "DIFF", tallyNote,
      ok and "IDENTICAL" or "DIFFERENT"))
    total = total + bad
    if not ok then allOk = false end
  end

  for _, mode in ipairs({ { "skip lhs29", 29 }, { "skip plain", nil } }) do
    local char = New.character(snapshot)
    local on, off = evaluateOptions(mode[2], false), evaluateOptions(mode[2], true)
    local b, _, _, sb = New.run(char, scenario, seed, fights, on)
    local c, _, _, sc = New.run(char, scenario, seed, fights, off)
    local bad = sameList(b, c) + sameList(sb.dAP, sc.dAP) + sameList(sb.dSP, sc.dSP)
    local passes = on.passes.run + on.passes.skipped
    local ok = bad == 0 and passes == off.passes.run and off.passes.skipped == 0
    print(string.format("%-28s %-10s fights %d  mismatches %d  passes %d, skipped %d (%.1f%%)  %s", id, mode[1],
      fights, bad, passes, on.passes.skipped, on.passes.skipped / passes * 100, ok and "IDENTICAL" or "DIFFERENT"))
    total = total + bad
    if not ok then allOk = false end
  end
end
print(string.format("%d fixtures x 4 modes x %d fights: %d mismatches, %s", #Harness.FIXTURES, fights, total,
  allOk and "IDENTICAL" or "DIFFERENT"))
os.exit(allOk and 0 or 1)
