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

  -- Finite-difference step of a stat weightSteps leaves out, in the stat's own units.
  weightDelta = 100,

  -- Finite-difference step per stat. These match the MythicSim reference weights (+100).
  weightSteps = {
    strength = 100, agility = 100, intellect = 100, attack_power = 100,
    hit_rating = 100, crit_rating = 100, haste_rating = 100,
  },

  -- A stat sits at a cap when it is within this many steps of it.
  capWindow = 1,

  -- Stop rules for a model that weighs in batches. A scenario's stopRule names one; without
  -- it a model runs one batch of `iterations` fights.
  --   stake     a weight stops when z * se * points < stake, in DPS (decision 0013)
  --   relative  a weight stops when z * se <= relative * |weight|
  stopRules = {
    dps = { z = 1.96, points = 30, stake = 0.3 },
    rel3 = { z = 1.96, relative = 0.03 },
  },

  -- Batch shape under a stop rule. se comes from batch means, so at least two batches run.
  -- The batch size is prime so stratified draws can use it as their stratum count.
  stopBatchSize = 199,
  stopMinBatches = 2,
  stopMaxBatches = 100,
}

return ns.Engine.Core.Defaults
