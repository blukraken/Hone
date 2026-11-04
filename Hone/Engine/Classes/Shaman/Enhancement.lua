-- Enhancement Shaman model, the first class behind the engine contract.
--
-- An event loop over one fight at a time: both hands' swing timers, Stormstrike and a GCD
-- rotation shaped like MythicSim's Enhancement APL. Flurry, Rage of the Farseer and haste
-- rating move the swing timers. Windfury Weapon, white hits, Stormstrike's strike and
-- Flametongue deal damage. Other GCD users take their GCD but deal none, and coverage
-- names them. MODEL-02 owns damage accuracy.
--
-- Snapshot fields read
--   stats, anchor            stat totals now and when the sheet values were read
--   statMultipliers          sheet points per stat point, for strength, agility, intellect
--   sheet                    meleeHitPercent, spellDamage, spellCritPercent, spellHitPercent
--   combat                   attackPower and meleeCritPercent with the fight's buffs up
--   weapons                  mainHand and offHand as { min, max, speed }
--   imbues                   mainHand and offHand imbue names
--   talents                  talent ranks by name
--   level, targetLevel, targetArmor

local _, ns = ...
local Engine = ns.Engine
local Core = Engine.Core
local Shaman = Engine.Classes.Shaman
local Data = Shaman.Data
local AttackTable, Stats, Rng = Core.AttackTable, Core.Stats, Core.Rng
local WindfuryWeapon = Shaman.WindfuryWeapon

local MISS, DODGE, GLANCE, CRIT = AttackTable.MISS, AttackTable.DODGE, AttackTable.GLANCE, AttackTable.CRIT
local rollWhite, rollSpecial = AttackTable.rollWhite, AttackTable.rollSpecial
local huge, sqrt = math.huge, math.sqrt

local Enhancement = {}
Shaman.Enhancement = Enhancement

Enhancement.weightStats = {
  "strength", "agility", "intellect", "attack_power", "hit_rating", "crit_rating", "haste_rating",
}

Enhancement.MODELED_IMBUES = { WindfuryWeapon = true, FlametongueWeapon = true, RockbiterWeapon = true,
                               NoImbue = true }

-- Mechanics the skeleton knows the fight has but does not model.
Enhancement.UNMODELED = {
  "lightning_bolt_damage", "shock_damage", "lava_lash_damage", "searing_totem_damage",
  "stormstrike_nature_bonus", "elemental_devastation", "mana", "item_procs",
  "racial_cooldowns", "consumables", "weapon_sync", "spell_partial_resists",
}

------------------------------------------------------------------------------
-- Character from snapshot
------------------------------------------------------------------------------

function Enhancement.derive(snapshot)
  local s = snapshot.stats or {}
  local a = snapshot.anchor or s
  local mult = snapshot.statMultipliers or {}
  local sheet = snapshot.sheet or {}
  local combat = snapshot.combat or {}
  local talents = snapshot.talents or {}
  local level = snapshot.level or 60

  local function delta(stat) return (s[stat] or 0) - (a[stat] or 0) end

  local dex = talents.mental_dexterity or 0
  local apPerInt = dex > 0 and Data.attackPowerPerIntellectByMentalDexterity[dex] or 0

  local ap = (combat.attackPower or sheet.attackPower or 0) + delta("attack_power")
    + Data.attackPowerPerStrength * delta("strength") * (mult.strength or 1)
    + apPerInt * delta("intellect") * (mult.intellect or 1)
  local crit = (combat.meleeCritPercent or sheet.meleeCritPercent or 0)
    + Data.critPercentPerAgility * delta("agility") * (mult.agility or 1)
    + Stats.percentFromRating("crit_rating", delta("crit_rating"), level)
  local hit = (sheet.meleeHitPercent or 0) + Stats.percentFromRating("hit_rating", delta("hit_rating"), level)
  local haste = 1 + Stats.percentFromRating("haste_rating", s.haste_rating or 0, level) / 100

  local mh = snapshot.weapons and snapshot.weapons.mainHand
  local oh = snapshot.weapons and snapshot.weapons.offHand
  local dualWield = oh ~= nil
  local tbl = AttackTable.forLevels(level, snapshot.targetLevel or level)
  local spellHit = (sheet.spellHitPercent or 0) / 100
  local spellMiss = Data.baseSpellMiss - spellHit

  return {
    level = level,
    attackPower = ap,
    critPercent = crit,
    hitPercent = hit,
    haste = haste,
    mainHand = mh,
    offHand = oh,
    dualWield = dualWield,
    table = tbl,
    chances = AttackTable.chances(tbl, hit, crit, dualWield),
    armor = AttackTable.armorMultiplier(snapshot.targetArmor or 0, level),
    talents = talents,
    imbues = snapshot.imbues or {},
    spellDamage = sheet.spellDamage or 0,
    spellCrit = (sheet.spellCritPercent or 0) / 100,
    spellMiss = spellMiss > 0 and spellMiss or 0,
  }
end

------------------------------------------------------------------------------
-- One fight
------------------------------------------------------------------------------

local function weaponDamage(rng, weapon, ap)
  return weapon.min + (weapon.max - weapon.min) * rng:next() + ap / Data.attackPowerPerDps * weapon.speed
end

-- Runs `iterations` fights on `rng`. Returns per-fight dps values, the Windfury rule and the
-- cast counts summed over every fight.
function Enhancement.run(char, scenario, rng, iterations)
  local talents = char.talents
  local c = char.chances
  local tbl = char.table
  local armor = char.armor
  local critMult = AttackTable.CRIT_MULTIPLIER
  local mh, oh = char.mainHand, char.offHand
  local ap = char.attackPower

  local windfury = (char.imbues.mainHand == "WindfuryWeapon") and WindfuryWeapon.new(talents) or nil
  local wfAp = windfury and windfury.attackPower or 0
  local ftOff = char.dualWield and char.imbues.offHand == "FlametongueWeapon"
  local ftBase = ftOff and (Data.flametongue.baseDamagePerSpeed * oh.speed
    + Data.flametongue.spellPowerCoefficient * char.spellDamage) or 0

  local flurryRank = talents.flurry or 0
  local flurrySpeed = flurryRank > 0 and Data.flurry.speedByRank[flurryRank] or 1
  local hasStormstrike = (talents.stormstrike or 0) > 0
  local hasRotF = (talents.rage_of_the_farseer or 0) > 0
  local hasMaelstrom = (talents.maelstrom_weapon or 0) > 0
  local gcd, reaction = Data.gcd, Data.reaction
  local ssCd, llCd, shockCd = Data.stormstrike.cooldown, Data.lavaLash.cooldown, Data.shock.cooldown
  local fsDuration = Data.flameShock.duration
  local totemDuration, totemMin = Data.searingTotem.duration, Data.searingTotem.minRemaining
  local mswMax = Data.maelstrom.maxStacks
  local mswMh = Data.maelstrom.ppm * mh.speed / 60
  local mswOh = oh and Data.maelstrom.ppm * oh.speed / 60 or 0
  local rotf = Data.rageOfTheFarseer
  local glanceMult, glanceSpread = tbl.glanceMultiplier, tbl.glanceSpread
  local spellMiss, spellCrit, ftCrit = char.spellMiss, char.spellCrit, Data.flametongue.critMultiplier
  local whiteC = { whiteMiss = c.whiteMiss, dodge = c.dodge, glance = c.glance, crit = c.crit }

  local dpsValues = {}
  local counts = { mainHand = 0, offHand = 0, stormstrike = 0, stormstrikeStrike = 0, lavaLash = 0,
                   earthShock = 0, flameShock = 0, lightningBolt = 0, searingTotem = 0 }
  local duration0, variation = scenario.duration, scenario.durationVariation

  for iter = 1, iterations do
    local fightEnd = duration0 + variation * (2 * rng:next() - 1)
    local damage = 0
    local now = 0

    -- Swing timers and speed.
    local mhNext, ohNext = 0, oh and 0 or huge
    local flurry, flurryIcd = 0, -huge
    local rotfUntil = hasRotF and rotf.duration or -huge
    local speed = char.haste * (hasRotF and rotf.speed or 1)

    -- Rotation state.
    local gcdReady, ssReady, llReady, shockReady = 0, 0, 0, 0
    local fsUntil, totemUntil = -huge, totemDuration - gcd
    local msw = 0
    local rotNext = 0

    if windfury then windfury:reset() end

    local function setSpeed(newSpeed)
      if newSpeed == speed then return end
      local ratio = speed / newSpeed
      if mhNext > now then mhNext = now + (mhNext - now) * ratio end
      if ohNext > now and ohNext < huge then ohNext = now + (ohNext - now) * ratio end
      speed = newSpeed
    end

    local function currentSpeed()
      local s = char.haste
      if now < rotfUntil then s = s * rotf.speed end
      if flurry > 0 then s = s * flurrySpeed end
      return s
    end

    -- A melee hit's Flurry and Maelstrom effects. `white` marks an auto attack.
    local function afterMelee(outcome, white, mainHand)
      if flurrySpeed > 1 then
        if outcome == CRIT then
          flurry = Data.flurry.charges
          setSpeed(currentSpeed())
        elseif white and flurry > 0 and flurryIcd <= now then
          flurryIcd = now + Data.flurry.chargeIcd
          flurry = flurry - 1
          if flurry == 0 then setSpeed(currentSpeed()) end
        end
      end
      if hasMaelstrom and outcome >= GLANCE and msw < mswMax then
        if rng:next() < (mainHand and mswMh or mswOh) then
          msw = msw + 1
          if msw == mswMax and rotNext > now + reaction and gcdReady <= now + reaction then
            rotNext = now + reaction
          end
        end
      end
    end

    local function strikeDamage(base, outcome)
      if outcome == CRIT then return base * armor * critMult end
      if outcome >= GLANCE then return base * armor end
      return 0
    end

    local function windfuryStrikes(count)
      for _ = 1, count do
        local base = weaponDamage(rng, mh, ap + wfAp)
        local outcome = rollSpecial(c, rng, true)
        damage = damage + strikeDamage(base, outcome)
        afterMelee(outcome, false, true)
      end
    end

    local function flametongue()
      if rng:next() < spellMiss then return end
      local hitDamage = ftBase
      if rng:next() < spellCrit then hitDamage = hitDamage * ftCrit end
      damage = damage + hitDamage
    end

    local function swing(mainHand)
      local weapon = mainHand and mh or oh
      local base = weaponDamage(rng, weapon, ap)
      if not mainHand then base = base * 0.5 end
      local outcome = rollWhite(whiteC, rng:next())
      if outcome == GLANCE then
        damage = damage + base * armor * (glanceMult + glanceSpread * (2 * rng:next() - 1))
      else
        damage = damage + strikeDamage(base, outcome)
      end
      local landed = outcome >= GLANCE
      if mainHand then
        counts.mainHand = counts.mainHand + 1
        mhNext = now + weapon.speed / speed
      else
        counts.offHand = counts.offHand + 1
        ohNext = now + weapon.speed / speed
      end
      local strikes = 0
      if mainHand and windfury then strikes = windfury:onHit(now, landed, rng) end
      if strikes > 0 then windfuryStrikes(strikes) end
      if not mainHand and ftOff and landed then flametongue() end
      afterMelee(outcome, true, mainHand)
    end

    local function stormstrike()
      counts.stormstrike = counts.stormstrike + 1
      local cast = rollSpecial(c, rng, true)
      if cast == MISS or cast == DODGE then return end
      counts.stormstrikeStrike = counts.stormstrikeStrike + 1
      local base = weaponDamage(rng, mh, ap)
      local outcome = rollSpecial(c, rng, false)
      damage = damage + strikeDamage(base, outcome)
      local strikes = windfury and windfury:onHit(now, true, rng) or 0
      if strikes > 0 then windfuryStrikes(strikes) end
      afterMelee(outcome, false, true)
    end

    -- One rotation decision on the GCD. Returns when it next wants to act.
    local function decide()
      if gcdReady > now then return gcdReady end
      if hasStormstrike and ssReady <= now then
        stormstrike()
        ssReady, gcdReady = now + ssCd, now + gcd
        return gcdReady
      end
      if msw >= mswMax then
        msw = 0
        counts.lightningBolt = counts.lightningBolt + 1
        gcdReady = now + gcd
        return gcdReady
      end
      if totemUntil <= now and fightEnd - now >= totemMin then
        counts.searingTotem = counts.searingTotem + 1
        totemUntil, gcdReady = now + totemDuration, now + gcd
        return gcdReady
      end
      if fsUntil <= now and shockReady <= now then
        counts.flameShock = counts.flameShock + 1
        fsUntil, shockReady, gcdReady = now + fsDuration, now + shockCd, now + gcd
        return gcdReady
      end
      if llReady <= now then
        counts.lavaLash = counts.lavaLash + 1
        llReady, gcdReady = now + llCd, now + gcd
        return gcdReady
      end
      if shockReady <= now then
        counts.earthShock = counts.earthShock + 1
        shockReady, gcdReady = now + shockCd, now + gcd
        return gcdReady
      end
      local wake = shockReady
      if hasStormstrike and ssReady < wake then wake = ssReady end
      if llReady < wake then wake = llReady end
      if totemUntil > now and totemUntil < wake and fightEnd - totemUntil >= totemMin then
        wake = totemUntil
      end
      return wake
    end

    while true do
      local t, kind = mhNext, 1
      if ohNext < t then t, kind = ohNext, 2 end
      if rotNext < t then t, kind = rotNext, 3 end
      if rotfUntil > now and rotfUntil < t then t, kind = rotfUntil, 4 end
      if t >= fightEnd then break end
      now = t
      if kind == 1 then
        swing(true)
      elseif kind == 2 then
        swing(false)
      elseif kind == 3 then
        rotNext = decide()
        if rotNext <= now then error("rotation stalled at " .. now, 0) end
      else
        rotfUntil = -huge
        setSpeed(currentSpeed())
      end
    end

    dpsValues[iter] = damage / fightEnd
  end

  return dpsValues, windfury, counts
end

------------------------------------------------------------------------------
-- Contract functions
------------------------------------------------------------------------------

local function meanAndStdev(values)
  local n, sum = #values, 0
  for i = 1, n do sum = sum + values[i] end
  local mean = sum / n
  local sq = 0
  for i = 1, n do
    local d = values[i] - mean
    sq = sq + d * d
  end
  return mean, n > 1 and sqrt(sq / (n - 1)) or 0
end

function Enhancement.simulate(snapshot, scenario)
  local char = Enhancement.derive(snapshot)
  local rng = Rng.new(scenario.seed)
  local values, windfury = Enhancement.run(char, scenario, rng, scenario.iterations)
  local mean, stdev = meanAndStdev(values)
  local out = { dps = mean, dpsStdev = stdev, iterations = #values }
  if windfury then
    out.windfury = { eligible = windfury.eligible, rolls = windfury.rolls, procs = windfury.procs }
  end
  return out
end

-- The hit cap nearest the current hit rating: special attacks', or white attacks' when
-- dual wielding puts it closer.
function Enhancement.caps(snapshot)
  local char = Enhancement.derive(snapshot)
  local level = char.level
  local rating = (snapshot.stats and snapshot.stats.hit_rating) or 0
  local best
  local caps = { AttackTable.specialHitCap(char.table) }
  if char.dualWield then caps[2] = AttackTable.whiteHitCap(char.table, true) end
  for _, capPercent in ipairs(caps) do
    local capRating = rating + Stats.ratingFromPercent("hit_rating", capPercent - char.hitPercent, level)
    if not best or math.abs(capRating - rating) < math.abs(best - rating) then best = capRating end
  end
  return { hit_rating = best }
end

function Enhancement.coverage(snapshot)
  local out = {}
  for _, name in ipairs(Enhancement.UNMODELED) do out[#out + 1] = name end
  local imbues = snapshot.imbues or {}
  for _, hand in ipairs({ "mainHand", "offHand" }) do
    local imbue = imbues[hand]
    if imbue and not Enhancement.MODELED_IMBUES[imbue] then out[#out + 1] = "imbue:" .. imbue end
  end
  if (snapshot.level or 60) ~= 60 then out[#out + 1] = "level:" .. tostring(snapshot.level) end
  return out
end

Engine.Contract.register("SHAMAN", "ENHANCEMENT", Enhancement)

return Enhancement
