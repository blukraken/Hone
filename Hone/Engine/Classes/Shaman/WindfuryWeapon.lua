-- Windfury Weapon, translated from MythicSim at commit
-- 8e9b8df69ef9b27f16c23b51e1bb1686bd9f1d68: src/classes/shaman/spells/windfury_weapon.rs
-- (on_trigger_hit, strike) and src/classes/shaman/prepare/imbues.rs
-- (register_windfury_imbue). MIT, see NOTICE beside this file.
--
-- The trigger hears landed hits of the imbued hand's spells: its auto attacks, its special
-- attacks and its own strikes. A hit outside the cooldown rolls the chance. A proc starts
-- the cooldown, then strikes twice with that hand at once. Each strike is the hand's weapon
-- damage with the rank's attack power added, rolled on the special attack table. The strikes
-- leave the swing timer alone.
--
-- Windfury's own strikes reach the trigger inside the cooldown their proc just started, so
-- they never roll. Callers therefore report only the other heard hits.

local _, ns = ...
local Shaman = ns.Engine.Classes.Shaman
local Data = Shaman.Data

local WindfuryWeapon = {}
Shaman.WindfuryWeapon = WindfuryWeapon

local methods = {}
local meta = { __index = methods }

-- The attack power each strike adds, from the rank and Elemental Weapons.
function WindfuryWeapon.attackPower(talents)
  local rank = talents and talents.elemental_weapons or 0
  local bonus = rank > 0 and Data.elementalWeapons[rank] or 0
  return Data.windfury.attackPower * (1 + bonus)
end

function WindfuryWeapon.new(talents)
  return setmetatable({
    chance = Data.windfury.chance,
    icd = Data.windfury.icd,
    strikes = Data.windfury.strikes,
    attackPower = WindfuryWeapon.attackPower(talents),
    readyAt = -math.huge,
    eligible = 0,
    rolls = 0,
    procs = 0,
  }, meta)
end

-- Starts a new fight. The counters run on across fights.
function methods:reset()
  self.readyAt = -math.huge
end

-- A hit the trigger hears. Returns the number of strikes to make.
function methods:onHit(now, landed, rng)
  if not landed then return 0 end
  self.eligible = self.eligible + 1
  if self.readyAt > now then return 0 end
  self.rolls = self.rolls + 1
  if not rng:proc(self.chance) then return 0 end
  self.readyAt = now + self.icd
  self.procs = self.procs + 1
  return self.strikes
end

return WindfuryWeapon
