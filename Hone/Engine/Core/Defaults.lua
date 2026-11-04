-- Tunable engine numbers. A scenario field of the same name overrides each one.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Core = ns.Engine.Core or {}

ns.Engine.Core.Defaults = {

  -- Simulation length and sampling.
  iterations = 400,
  seed = 42,
  duration = 120,
  durationVariation = 15,

  -- Finite-difference step, in the stat's own units.
  weightDelta = 100,

  -- A stat sits at a cap when it is within this many steps of it.
  capWindow = 1,
}

return ns.Engine.Core.Defaults
