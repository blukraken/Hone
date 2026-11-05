-- Shared pieces for the event path's faithfulness and timing scripts.
--
-- Loads the worktree's engine, the fixture snapshots and encounters, and main's engine at a
-- pinned commit read straight from git, so a script can run both side by side.

local Harness = {}

local Loader = dofile((debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):gsub("[^/]+$", "")) .. "loader.lua")
Harness.Loader = Loader
Harness.root = Loader.root()

-- The commit main's EventSim is pinned to for T2 and T4.
Harness.MAIN = "11ba1ed"

Harness.FIXTURES = {
  "enh60-rockbiter-2h38-hitcap", "enh60-rockbiter-2h38-vs60", "enh60-rockbiter-dw29-hit97",
  "enh60-windfury-dw20-29", "enh60-windfury-dw26-29",
}

function Harness.load()
  local ns = Loader.load(Harness.root)
  Harness.ns = ns
  Harness.snapshots = dofile(Harness.root .. "/tests/addon/engine/data/snapshots.lua")
  return ns
end

-- Encounter numbers from the fixture file.
function Harness.scenario(id)
  local fh = assert(io.open(Harness.root .. "/tests/fixtures/" .. id .. ".json", "rb"))
  local text = fh:read("*a")
  fh:close()
  return {
    duration = tonumber(text:match('"duration":%s*([%d%.]+)')),
    durationVariation = tonumber(text:match('"durationVariation":%s*([%d%.]+)')),
  }
end

local function gitShow(rev, path)
  local cmd = string.format('git -C "%s" show %s:%s', Harness.root, rev, path)
  local pipe = assert(io.popen(cmd, "r"))
  local text = pipe:read("*a")
  pipe:close()
  assert(#text > 0, "git show returned nothing for " .. rev .. ":" .. path)
  return text
end

-- Main's engine at `rev` (default Harness.MAIN): core, Shaman data, Windfury and EventSim.
function Harness.loadMain(rev)
  rev = rev or Harness.MAIN
  local ns = {}
  local files = {}
  for _, rel in ipairs(Loader.CORE) do files[#files + 1] = rel end
  files[#files + 1] = "Hone/Engine/Classes/Shaman/Data.lua"
  files[#files + 1] = "Hone/Engine/Classes/Shaman/WindfuryWeapon.lua"
  files[#files + 1] = "Hone/Engine/Classes/Shaman/EventSim.lua"
  for _, rel in ipairs(files) do
    local chunk = assert(loadstring(gitShow(rev, rel), "@" .. rev .. ":" .. rel))
    chunk("Hone", ns)
  end
  return ns
end

return Harness
