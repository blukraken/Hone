-- Shaman rule numbers at level 60, translated from MythicSim at commit
-- 8e9b8df69ef9b27f16c23b51e1bb1686bd9f1d68 (MIT, see NOTICE beside this file).
-- Each entry names the MythicSim source it came from. Values marked "unverified" have no
-- fixture that checks them yet.

local _, ns = ...
ns.Engine = ns.Engine or {}
ns.Engine.Classes = ns.Engine.Classes or {}
ns.Engine.Classes.Shaman = ns.Engine.Classes.Shaman or {}

ns.Engine.Classes.Shaman.Data = {

  -- prepare/imbues.rs register_windfury_imbue, spells/windfury_weapon.rs
  windfury = {
    chance = 0.2,
    icd = 1.5,
    strikes = 2,

    -- Spell 16361's effect at level 60 (prepare.rs windfury_ap_bonus).
    attackPower = 333,
  },

  -- Elemental Weapons (16266) raises Windfury's attack power. Rank 3 is checked by the
  -- prepared value 466.2; ranks 1 and 2 are unverified.
  elementalWeapons = { 0.13, 0.27, 0.40 },

  -- talents/flurry.rs and the prepared flurry effect at 5 ranks. Lower ranks are unverified.
  flurry = {
    speedByRank = { 1.05, 1.10, 1.15, 1.20, 1.25 },
    charges = 3,
    chargeIcd = 0.5,
  },

  -- Rage of the Farseer, cast at the pull by the APL's autocast.
  rageOfTheFarseer = { speed = 1.3, duration = 25, cooldown = 180 },

  -- spells/stormstrike.rs and the prepared spell's cooldown.
  stormstrike = { cooldown = 8 },

  -- Prepared Maelstrom Weapon effect: per landed melee hit, chance = ppm * weapon speed / 60
  -- (0.4333 at 2.6 and 0.4833 at 2.9 in the prepared chances), five stacks.
  maelstrom = { ppm = 10, maxStacks = 5 },

  -- Prepared spell cooldowns and durations of the GCD users the rotation models.
  gcd = 1.5,
  reaction = 0.1,
  lavaLash = { cooldown = 6 },
  shock = { cooldown = 6 },
  flameShock = { duration = 21 },
  searingTotem = { duration = 55, minRemaining = 20 },

  -- prepare/imbues.rs Flametongue: base damage at the off hand's speed, spell power share.
  flametongue = { baseDamagePerSpeed = 81.49 / 2.9, spellPowerCoefficient = 0.10000000149,
                  critMultiplier = 1.5 },

  -- Sheet conversions per point (prepare.rs NewShaman, measured on the fixtures).
  attackPowerPerStrength = 2,
  critPercentPerAgility = 0.0508,
  attackPowerPerIntellectByMentalDexterity = { 1 / 3, 2 / 3, 1 },

  -- Spell miss chance against a level 63 target (prepared attack_table).
  baseSpellMiss = 0.17,

  attackPowerPerDps = 14,
}

return ns.Engine.Classes.Shaman.Data
