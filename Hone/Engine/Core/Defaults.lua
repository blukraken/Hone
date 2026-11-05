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

  -- Staged weights (decision 0014; the stepper in Core/Weights.lua describes each stage).
  -- Contract.evaluate drives the stepper to `stage`.
  stage = 3,

  -- Stage 1, first answer: this many fights in all, split evenly over the base run and every
  -- simulated stat, unstratified, se from the per-fight spread.
  stageFirstFights = 100,

  -- Stages 2 and 3: stratified batches of this many fights (prime, so it is the stratum
  -- count). A stat's batch means give its se once it has stageMinBatches of them.
  stageBatchSize = 29,
  stageMinBatches = 4,

  -- Variance of a stratified batch mean over (unstratified per-fight variance / batch size),
  -- the floor under a simulated stat's batch variance (Core/Weights.lua, Stepper:estimate).
  -- tests/addon/engine/stratification_gain.lua measures it per fixture and stat. This is the
  -- largest fixture median (0.751) rounded up, so the floor errs wide.
  stageStratificationGain = 0.76,

  -- Every half-width is t(stageQuantile, df) x se, a two-sided 95% interval at the estimate's
  -- own degrees of freedom.
  stageQuantile = 0.975,

  -- Stage 2, verdicts: every half-width times stakePoints under stageStake DPS.
  stageStake = 1.0,
  stakePoints = 30,

  -- Stage 3, final: every half-width under stageRelative of its weight.
  stageRelative = 0.03,

  -- A stepper stops at this many fights whatever stage it reached.
  stageMaxFights = 20000,
}

return ns.Engine.Core.Defaults
