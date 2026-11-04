-- Loads the Hone engine outside the game the way a .toc would: each file receives
-- (addonName, ns) as its varargs and adds itself to the shared ns.
--
-- Usage:
--   local Loader = dofile("tests/addon/engine/loader.lua")
--   local ns = Loader.load(Loader.root())              -- core, contract and every class
--   local ns = Loader.load(Loader.root(), { classes = {} })   -- core and contract only

local Loader = {}

Loader.CORE = {
  "Hone/Engine/Core/Table.lua",
  "Hone/Engine/Core/Defaults.lua",
  "Hone/Engine/Core/Rng.lua",
  "Hone/Engine/Core/Stats.lua",
  "Hone/Engine/Core/AttackTable.lua",
  "Hone/Engine/Core/SpellTable.lua",
  "Hone/Engine/Core/Weights.lua",
  "Hone/Engine/Contract.lua",
}

Loader.CLASSES = {
  "Hone/Engine/Classes/Shaman/Data.lua",
  "Hone/Engine/Classes/Shaman/WindfuryWeapon.lua",
  "Hone/Engine/Classes/Shaman/EventSim.lua",
  "Hone/Engine/Classes/Shaman/Enhancement.lua",
}

-- Repository root, from this file's own path (tests/addon/engine/loader.lua).
function Loader.root()
  local info = debug.getinfo(1, "S").source
  local path = info:sub(1, 1) == "@" and info:sub(2) or info
  path = path:gsub("\\", "/")
  local root = path:match("^(.*)/tests/addon/engine/[^/]*$")
  return root or "."
end

function Loader.loadFile(root, rel, ns)
  local chunk, err = loadfile(root .. "/" .. rel)
  if not chunk then error(err, 0) end
  chunk("Hone", ns)
end

function Loader.load(root, opts)
  opts = opts or {}
  local ns = opts.ns or {}
  for _, rel in ipairs(Loader.CORE) do Loader.loadFile(root, rel, ns) end
  for _, rel in ipairs(opts.classes or Loader.CLASSES) do Loader.loadFile(root, rel, ns) end
  return ns
end

return Loader
