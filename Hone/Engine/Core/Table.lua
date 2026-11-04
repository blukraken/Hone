-- Small table helpers shared by the engine.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

local Table = {}
ns.Engine.Core.Table = Table

-- Deep copy of plain data. Functions and metatables are not copied.
function Table.copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = Table.copy(v) end
  return out
end

-- New table holding `defaults` with every non-nil field of `overrides` on top.
function Table.merge(defaults, overrides)
  local out = Table.copy(defaults)
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do out[k] = Table.copy(v) end
  end
  return out
end

function Table.sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

return Table
