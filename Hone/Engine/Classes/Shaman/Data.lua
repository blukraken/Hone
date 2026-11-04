-- Shaman rule numbers at level 60, translated from MythicSim at commit
-- 8e9b8df69ef9b27f16c23b51e1bb1686bd9f1d68 (MIT, see NOTICE beside this file).
-- Each entry names the MythicSim source it came from. The character's own numbers (sheet,
-- spell damage, procs, rotation) come from the snapshot's `model` field instead.

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

  -- talents/flurry.rs: charges spent by white hits at most once per charge cooldown, and the
  -- aura's 15 s duration.
  flurry = { chargeIcd = 0.5, duration = 15 },

  -- The player's reaction time when the snapshot carries none.
  reaction = 0.1,

  -- core/fight.rs SPELL_BATCH_WINDOW and core/fight/cast.rs MAX_SPELL_QUEUE_WINDOW.
  spellBatchWindow = 0.01,
  spellQueueWindow = 0.4,

  -- spells/weapon_sync.rs: a delayed off hand swing lands this long after the main hand's.
  weaponSyncLag = 0.1,

  -- Weapon damage per point of attack power per second of swing (melee.rs weapon_damage).
  attackPowerPerDps = 14,
}

return ns.Engine.Classes.Shaman.Data
