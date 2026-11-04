-- Enhancement event path: one fight at a time on an event queue.
--
-- Rules are translated from MythicSim at commit 8e9b8df69ef9b27f16c23b51e1bb1686bd9f1d68 (MIT,
-- see NOTICE beside this file). The numbers come from the snapshot's `model` field, which holds
-- the character sheet, its buffs, its spells and its rotation.
--
-- Timing rules
--   Both hands swing on their timers; the off hand starts half its base swing in, and both
--   start a random 0 to 100 ms late (melee.rs reset_auto_attacks_of, randomize_melee_timing).
--   The rotation runs at the end of each GCD, after each main hand swing, and one reaction time
--   after every swing. When nothing is castable it waits for the later of one reaction time
--   and the GCD. A spell ready within 400 ms is queued for the moment it is ready.
--   Flurry, Maelstrom Weapon, Elemental Devastation, Crusader, Judgement of Wisdom and
--   Dragonbreath Chili act one spell batch window (10 ms) after the hit that triggers them.

local _, ns = ...
local Engine = ns.Engine
local Core = Engine.Core
local Shaman = Engine.Classes.Shaman
local Data = Shaman.Data
local AttackTable, SpellTable, Stats = Core.AttackTable, Core.SpellTable, Core.Stats
local WindfuryWeapon = Shaman.WindfuryWeapon

local MISS, DODGE, GLANCE, CRIT, HIT = AttackTable.MISS, AttackTable.DODGE, AttackTable.GLANCE,
  AttackTable.CRIT, AttackTable.HIT
local huge, floor = math.huge, math.floor

local EventSim = {}
Shaman.EventSim = EventSim

------------------------------------------------------------------------------
-- Character
------------------------------------------------------------------------------

-- The fight-invariant character: sheet values with the snapshot's stat changes applied.
function EventSim.character(snapshot)
  local model = assert(snapshot.model, "the event path needs snapshot.model")
  local s, a = snapshot.stats or {}, snapshot.anchor or snapshot.stats or {}
  local sheet, perPoint = model.sheet, model.perPoint or {}
  local level = snapshot.level or 60

  local function value(field)
    local v = sheet[field] or 0
    for stat, rates in pairs(perPoint) do
      local rate = rates[field]
      if rate then v = v + rate * ((s[stat] or 0) - (a[stat] or 0)) end
    end
    return v
  end

  local hasteRating = (s.haste_rating or 0)
  local char = {
    level = level,
    targetLevel = snapshot.targetLevel or level,
    attackPower = value("attackPower"),
    meleeCritPercent = value("meleeCritPercent") + (sheet.meleeCritBonusPercent or 0),
    meleeHitPercent = value("meleeHitPercent"),
    spellDamage = value("spellDamage"),
    fireDamage = sheet.fireDamage or 0,
    natureDamage = sheet.natureDamage or 0,
    spellCritPercent = value("spellCritPercent"),
    spellHitPercent = value("spellHitPercent"),
    mana = value("mana"),
    haste = 1 + Stats.percentFromRating("haste_rating", hasteRating, level) / 100,
    mainHand = snapshot.weapons.mainHand,
    offHand = snapshot.weapons.offHand,
    imbues = snapshot.imbues or {},
    talents = snapshot.talents or {},
    model = model,
  }
  char.dualWield = char.offHand ~= nil

  local t = model.attackTable
  local hit = char.meleeHitPercent / 100 - t.hitSuppression
  local whiteMiss = t.miss + (char.dualWield and AttackTable.DUAL_WIELD_MISS or 0) - hit
  local specialMiss = t.miss - hit
  char.whiteMiss = whiteMiss > 0 and whiteMiss or 0
  char.specialMiss = specialMiss > 0 and specialMiss or 0
  char.dodge = t.dodge
  char.glance = t.glance
  char.glanceMultiplier, char.glanceSpread = t.glanceMultiplier, t.glanceSpread
  char.critSuppression = t.critSuppression
  char.armor = AttackTable.armorMultiplier(model.armor, level)
  char.spellMiss = SpellTable.missChance(model.spellMiss, char.spellHitPercent)
  char.resistCoefficient = SpellTable.levelCoefficient(level, char.targetLevel)
  return char
end

------------------------------------------------------------------------------
-- Event queue: a binary heap of { time, seq, kind, a, b }
------------------------------------------------------------------------------

local function heapPush(h, n, ev)
  n = n + 1
  h[n] = ev
  local i = n
  while i > 1 do
    local p = floor(i / 2)
    local hp, hi = h[p], h[i]
    if hp[1] < hi[1] or (hp[1] == hi[1] and hp[2] < hi[2]) then break end
    h[p], h[i] = hi, hp
    i = p
  end
  return n
end

local function heapPop(h, n)
  local top = h[1]
  h[1] = h[n]
  h[n] = nil
  n = n - 1
  local i = 1
  while true do
    local l, r, m = 2 * i, 2 * i + 1, i
    if l <= n and (h[l][1] < h[m][1] or (h[l][1] == h[m][1] and h[l][2] < h[m][2])) then m = l end
    if r <= n and (h[r][1] < h[m][1] or (h[r][1] == h[m][1] and h[r][2] < h[m][2])) then m = r end
    if m == i then break end
    h[i], h[m] = h[m], h[i]
    i = m
  end
  return top, n
end

-- Event kinds.
local EV_ROTATION, EV_QUEUED, EV_FLURRY, EV_MAELSTROM, EV_DEVASTATION = 1, 2, 3, 4, 5
local EV_CRUSADER, EV_JUDGEMENT, EV_CHILI, EV_SEARING, EV_FLAMESHOCK = 6, 7, 8, 9, 10
local EV_MANA, EV_FARSEER_END, EV_FLURRY_END = 11, 12, 13

------------------------------------------------------------------------------
-- Fights
------------------------------------------------------------------------------

-- Runs `iterations` fights. Returns per-fight dps, the Windfury rule and per-action tallies.
function EventSim.run(char, scenario, rng, iterations)
  local model = char.model
  local spells, buffs, talentFx, mana0 = model.spells, model.buffs or {}, model.talentEffects or {},
    model.mana
  local rot = model.rotation
  local mh, oh = char.mainHand, char.offHand
  local dualWield = char.dualWield
  local armor = char.armor
  local reaction = model.reactionTime or Data.reaction
  local batch = Data.spellBatchWindow
  local queueWindow = Data.spellQueueWindow
  local critMult, spellCritMult = AttackTable.CRIT_MULTIPLIER, SpellTable.CRIT_MULTIPLIER
  local partialNone, partialQuarter, partialHalf = SpellTable.partialThresholds(char.resistCoefficient)

  -- Imbues and procs.
  local windfury = (char.imbues.mainHand == "WindfuryWeapon") and WindfuryWeapon.new(char.talents) or nil
  if windfury and spells.windfury then windfury.attackPower = spells.windfury.attackPower end
  local wfHears = {}
  for _, name in ipairs(spells.windfury and spells.windfury.triggers or {}) do wfHears[name] = true end
  local ft = dualWield and char.imbues.offHand == "FlametongueWeapon" and spells.flametongue or nil
  local ftHears = {}
  for _, name in ipairs(ft and ft.triggers or {}) do ftHears[name] = true end
  local wft = buffs.windfuryTotem
  local wftTriggers, wftSpenders = {}, {}
  for _, name in ipairs(wft and wft.triggers or {}) do wftTriggers[name] = true end
  for _, name in ipairs(wft and wft.spenders or {}) do wftSpenders[name] = true end
  local crusader = buffs.crusader
  local crusaderChance = crusader and crusader.chances or {}
  local bloodFury, farseer = buffs.bloodFury, buffs.rageOfTheFarseer
  local devastation = talentFx.elementalDevastation
  local focus = talentFx.elementalFocus
  local maelstrom = talentFx.maelstromWeapon
  local maelstromChance = maelstrom and maelstrom.chances or {}
  local flurryFx = talentFx.flurry
  local jow = mana0.judgement
  local chili, iceblade
  local chiliHears, icebladeChance = {}, {}
  for _, p in ipairs(model.procs or {}) do
    if p.name == "dragonbreathChili" then
      chili = p
      for _, name in ipairs(p.triggers or {}) do chiliHears[name] = true end
    elseif p.kind == "weaponCritOnly" then
      iceblade = p
      icebladeChance = p.chances or {}
    end
  end

  local syncDelay = dualWield and model.weaponSync == "delay"
  local syncWait = flurryFx and flurryFx.chargeIcd or Data.flurry.chargeIcd

  local steps = rot.steps
  local nSteps = #steps
  local fnManaPercent = (rot.fireNovaManaPercent or 30) / 100
  local searingMin = rot.searingMinRemaining or 20

  -- Spells the rotation casts.
  local SS, LB, ES, FS, FSD = spells.stormstrike, spells.lightningBolt, spells.earthShock,
    spells.flameShock, spells.flameShockDot
  local FN, ST, STA = spells.fireNova, spells.searingTotem, spells.searingTotemAttack

  local tally = {}
  local function count(name, field, amount)
    local row = tally[name]
    if not row then
      row = { casts = 0, hits = 0, crits = 0, misses = 0, dodges = 0, glances = 0, damage = 0, boosted = 0 }
      tally[name] = row
    end
    row[field] = row[field] + (amount or 1)
  end

  local dpsValues = {}
  local duration0, variation = scenario.duration, scenario.durationVariation

  -- Fight state, reset by each fight.
  local h, hn, seq
  local now, fightEnd, damage
  local mhNext, ohNext, speed
  local manaNow, manaMax
  local gcdReady, rotationAt, rotationGen, queuedGen, queuedSpell
  local cooldownReady
  local bfUntil, rotfUntil, hsUntilMh, hsUntilOh, edUntil, ccUntil
  local flurryCharges, flurryIcd, flurryGen
  local msw, mswUntil
  local ssDebuffUntil, ssDebuffCharges
  local wftProcUntil, wftCharges, wftIcd
  local fsUntil, fsTicksLeft, fsTickBase, fsGen
  local totemUntil, searingGen
  local chiliIcd
  local potionReady, runeReady

  -- Weapon sync "delay" (spells/weapon_sync.rs), run as the main hand swing's replacement, so
  -- before each main hand swing and each totem extra attack: an off hand swing more than
  -- Flurry's charge cooldown away waits until just after the next main hand swing.
  local function syncOffHand()
    if syncDelay and ohNext - now > syncWait then
      local nextOh = now + mh.speed / speed + Data.weaponSyncLag
      if nextOh > ohNext then ohNext = nextOh end
    end
  end

  local function push(t, kind, a, b)
    seq = seq + 1
    hn = heapPush(h, hn, { t, seq, kind, a, b })
  end

  ----------------------------------------------------------------------------
  -- Stats that change in the fight
  ----------------------------------------------------------------------------

  local function attackPower()
    local ap = char.attackPower
    if crusader then
      if hsUntilMh > now then ap = ap + crusader.attackPower end
      if hsUntilOh > now then ap = ap + crusader.attackPower end
    end
    if wft and wftProcUntil > now and wftCharges > 0 then ap = ap + wft.attackPower end
    if bloodFury and bfUntil > now then ap = ap * bloodFury.attackPowerMultiplier end
    return ap
  end

  local function spellPower(school)
    local sp = char.spellDamage
    if bloodFury and bfUntil > now then sp = sp * bloodFury.spellDamageMultiplier end
    if school == "fire" then return sp + char.fireDamage end
    if school == "nature" then return sp + char.natureDamage end
    return sp
  end

  -- Physical crit chance. Elemental Devastation raises only melee attacks, not item procs.
  local function meleeCrit(noDevastation)
    local c = char.meleeCritPercent
    if devastation and edUntil > now and not noDevastation then c = c + devastation.meleeCritPercent end
    c = c / 100 - char.critSuppression
    return c > 0 and c or 0
  end

  local function currentSpeed()
    local s = char.haste
    if farseer and rotfUntil > now then s = s * farseer.speed end
    if flurryCharges > 0 then s = s * flurryFx.speed end
    return s
  end

  local function setSpeed(newSpeed)
    if newSpeed == speed then return end
    local ratio = speed / newSpeed
    if mhNext > now and mhNext < huge then mhNext = now + (mhNext - now) * ratio end
    if ohNext > now and ohNext < huge then ohNext = now + (ohNext - now) * ratio end
    speed = newSpeed
  end

  local function gainMana(amount)
    manaNow = manaNow + amount
    if manaNow > manaMax then manaNow = manaMax end
  end

  ----------------------------------------------------------------------------
  -- Damage
  ----------------------------------------------------------------------------

  local function partial()
    return SpellTable.partialMultiplier(rng:next(), partialNone, partialQuarter, partialHalf)
  end

  -- A magic hit and crit roll for a spell table entry `sp`. `base` is the roll before spell
  -- power. Returns damage dealt and whether it landed and crit.
  local function spellDamage(name, sp, base, targetMult, direct)
    if direct and jow and rng:next() < jow.chance then push(now + batch, EV_JUDGEMENT) end
    local dmg = (base + sp.coefficient * (spellPower(sp.school) + (sp.bonusSpellPower or 0))) * sp.multiplier
    if not sp.binary then dmg = dmg * partial() end
    dmg = dmg * (targetMult or 1)
    count(name, "casts")
    if targetMult and targetMult ~= 1 then count(name, "boosted") end
    if rng:next() < char.spellMiss then
      count(name, "misses")
      return 0, false, false
    end
    local crit = rng:next() < (char.spellCritPercent + sp.critBonusPercent) / 100
    if crit then
      dmg = dmg * spellCritMult
      count(name, "crits")
    else
      count(name, "hits")
    end
    damage = damage + dmg
    count(name, "damage", dmg)
    return dmg, true, crit
  end

  local function roll(sp)
    local v = sp.variance or 0
    if v == 0 then return sp.average end
    local lo = sp.average * (1 - v / 2)
    return lo + sp.average * v * rng:next()
  end

  local function weaponDamage(weapon, ap)
    return weapon.min + (weapon.max - weapon.min) * rng:next() + weapon.speed * ap / Data.attackPowerPerDps
  end

  ----------------------------------------------------------------------------
  -- Melee results and what they trigger
  ----------------------------------------------------------------------------

  local swing, windfuryStrikes

  local function onMeleeResult(name, outcome, dealt, white, mainHand)
    local landed = outcome >= GLANCE
    -- Windfury Weapon.
    if windfury and wfHears[name] and name ~= "windfuryMainHand" then
      local strikes = windfury:onHit(now, landed, rng)
      if strikes > 0 then windfuryStrikes(strikes) end
    end
    -- Party Windfury Totem: charges spent by landed hits, then a new proc.
    if wft then
      if wftSpenders[name] and landed and dealt > 0 and wftProcUntil > now and wftCharges > 0 then
        wftCharges = wftCharges - 1
      end
      if wftTriggers[name] and landed and dealt > 0 and wftIcd <= now then
        if rng:next() < wft.chance then
          wftIcd = now + wft.icd
          wftProcUntil = now + wft.duration
          wftCharges = wft.charges - (white and 1 or 0)
          syncOffHand()
          swing("windfuryTotemAttack", true)
        end
      end
    end
    -- Flametongue Weapon.
    if ft and ftHears[name] and landed then
      spellDamage("flametongue", ft, ft.average)
    end
    -- Iceblade-style weapon procs: a fixed hit with the physical crit roll.
    if iceblade and landed and dealt > 0 then
      local chance = icebladeChance[name]
      if chance and rng:next() < chance then
        local dmg = iceblade.min * iceblade.multiplier * partial()
        count(iceblade.name, "casts")
        if rng:next() < meleeCrit(true) then
          dmg = dmg * critMult
          count(iceblade.name, "crits")
        else
          count(iceblade.name, "hits")
        end
        damage = damage + dmg
        count(iceblade.name, "damage", dmg)
      end
    end
    -- Delayed procs.
    if flurryFx then push(now + batch, EV_FLURRY, outcome == CRIT, white) end
    if maelstrom and landed then
      local chance = maelstromChance[name]
      if chance and rng:next() < chance then push(now + batch, EV_MAELSTROM) end
    end
    if crusader and landed then
      local chance = crusaderChance[name]
      if chance and rng:next() < chance then push(now + batch, EV_CRUSADER, mainHand) end
    end
    if jow and rng:next() < jow.chance then push(now + batch, EV_JUDGEMENT) end
    if chili and chiliHears[name] and landed and chiliIcd <= now then
      if rng:next() < chili.chance then
        chiliIcd = now + chili.icd
        push(now + chili.delay, EV_CHILI)
      end
    end
  end

  local function strikeDamage(base, outcome)
    if outcome == CRIT then return base * armor * critMult end
    if outcome >= GLANCE then return base * armor end
    return 0
  end

  local function tallyMelee(name, outcome, dealt)
    count(name, "casts")
    if outcome == MISS then count(name, "misses")
    elseif outcome == DODGE then count(name, "dodges")
    elseif outcome == GLANCE then count(name, "glances")
    elseif outcome == CRIT then count(name, "crits")
    else count(name, "hits") end
    if dealt > 0 then count(name, "damage", dealt) end
  end

  -- A white swing of either hand, or the totem's extra attack (`name` says which).
  swing = function(name, mainHand)
    local weapon = mainHand and mh or oh
    local base = weaponDamage(weapon, attackPower())
    if not mainHand then base = base * 0.5 end
    local r = rng:next()
    local crit = meleeCrit()
    local outcome
    local edge = char.whiteMiss
    if r < edge then outcome = MISS
    else
      edge = edge + char.dodge
      if r < edge then outcome = DODGE
      else
        edge = edge + char.glance
        if r < edge then outcome = GLANCE
        elseif r < edge + crit then outcome = CRIT
        else outcome = HIT end
      end
    end
    local dealt
    if outcome == GLANCE then
      dealt = base * armor * (char.glanceMultiplier + char.glanceSpread * (2 * rng:next() - 1))
    else
      dealt = strikeDamage(base, outcome)
    end
    damage = damage + dealt
    tallyMelee(name, outcome, dealt)
    onMeleeResult(name, outcome, dealt, true, mainHand)
  end

  -- A special attack's crit-only roll after a landed cast.
  local function special(name, weapon, ap, half, canMiss)
    local outcome
    if canMiss then
      local r = rng:next()
      if r < char.specialMiss then outcome = MISS
      elseif r < char.specialMiss + char.dodge then outcome = DODGE end
    end
    local dealt = 0
    if not outcome then
      local base = weaponDamage(weapon, ap)
      if half then base = base * 0.5 end
      outcome = rng:next() < meleeCrit() and CRIT or HIT
      dealt = strikeDamage(base, outcome)
    end
    damage = damage + dealt
    tallyMelee(name, outcome, dealt)
    return outcome, dealt
  end

  windfuryStrikes = function(n)
    for _ = 1, n do
      local outcome, dealt = special("windfuryMainHand", mh, attackPower() + windfury.attackPower, false, true)
      onMeleeResult("windfuryMainHand", outcome, dealt, false, true)
    end
  end

  ----------------------------------------------------------------------------
  -- Spell casts
  ----------------------------------------------------------------------------

  local CONSUMES_CLEARCASTING = { lightningBolt = true, fireNova = true, flameShock = true, earthShock = true }
  local FOCUS_ROLLS = { lightningBolt = true, fireNova = true, flameShock = true, earthShock = true }

  local function costOf(name, sp)
    if focus and ccUntil > now and CONSUMES_CLEARCASTING[name] then return 0 end
    if name == "lightningBolt" and maelstrom and msw >= maelstrom.maxStacks and mswUntil > now then return 0 end
    return sp.cost or 0
  end

  local function readyAt(sp)
    if not sp.cooldownGroup then return -huge end
    return cooldownReady[sp.cooldownGroup] or -huge
  end

  local function startCooldown(sp)
    if sp.cooldownGroup then cooldownReady[sp.cooldownGroup] = now + sp.cooldown end
  end

  -- Spell crits that start Elemental Devastation.
  local function devastate(crit)
    if devastation and crit then push(now + batch, EV_DEVASTATION) end
  end

  local function completeCast(name)
    if focus then
      if ccUntil > now and CONSUMES_CLEARCASTING[name] then ccUntil = -huge end
      if FOCUS_ROLLS[name] and rng:next() < focus.chance then ccUntil = now + focus.duration end
    end
  end

  local cast = {}

  function cast.stormstrike()
    local r = rng:next()
    count("stormstrike", "casts")
    if r < char.specialMiss then count("stormstrike", "misses") return end
    if r < char.specialMiss + char.dodge then count("stormstrike", "dodges") return end
    count("stormstrike", "hits")
    ssDebuffUntil = now + SS.debuffDuration
    ssDebuffCharges = SS.debuffCharges
    local outcome, dealt = special("stormstrikeMainHand", mh, attackPower(), false, false)
    onMeleeResult("stormstrikeMainHand", outcome, dealt, false, true)
  end

  local function stormstrikeMultiplier(spends)
    if ssDebuffUntil > now and ssDebuffCharges > 0 then
      return SS.debuffMultiplier, spends
    end
    return 1, false
  end

  function cast.lightningBolt()
    local mult, spends = stormstrikeMultiplier(true)
    local dmg, landed, crit = spellDamage("lightningBolt", LB, roll(LB), mult, true)
    if spends and landed and dmg > 0 then ssDebuffCharges = ssDebuffCharges - 1 end
    msw, mswUntil = 0, -huge
    devastate(crit)
  end

  function cast.earthShock()
    local mult = stormstrikeMultiplier(false)
    local _, _, crit = spellDamage("earthShock", ES, roll(ES), mult, true)
    devastate(crit)
  end

  function cast.flameShock()
    local _, landed, crit = spellDamage("flameShock", FS, roll(FS), 1, true)
    if landed then
      fsGen = fsGen + 1
      fsTicksLeft = FSD.ticks
      fsTickBase = FSD.tickBase + FSD.tickCoefficient * spellPower(FSD.school)
      fsUntil = now + FSD.ticks * FSD.tickPeriod
      push(now + FSD.tickPeriod, EV_FLAMESHOCK, fsGen)
    end
    devastate(crit)
  end

  function cast.fireNova()
    spellDamage("fireNova", FN, roll(FN), 1, true)
  end

  function cast.searingTotem()
    totemUntil = now + ST.duration
    searingGen = searingGen + 1
    push(now + ST.tickPeriod, EV_SEARING, searingGen, ST.ticks)
  end

  function cast.strengthOfEarthTotem() end
  function cast.graceOfAirTotem() end

  local SPELL_OF = {
    stormstrike = "stormstrike", lightningBoltMaelstrom = "lightningBolt", earthShock = "earthShock",
    flameShock = "flameShock", fireNovaClearcasting = "fireNova", fireNovaMana = "fireNova",
    searingTotem = "searingTotem", strengthOfEarthTotem = "strengthOfEarthTotem",
    graceOfAirTotem = "graceOfAirTotem",
  }

  -- Whether a step's condition holds now, ignoring readiness.
  local function condition(step)
    if step == "fireNovaClearcasting" then return focus ~= nil and ccUntil > now end
    if step == "lightningBoltMaelstrom" then
      return maelstrom ~= nil and mswUntil > now and msw >= maelstrom.maxStacks
    end
    if step == "searingTotem" then return totemUntil <= now and fightEnd - now >= searingMin end
    if step == "flameShock" then return fsUntil <= now end
    if step == "fireNovaMana" then return manaNow >= fnManaPercent * manaMax end
    if step == "strengthOfEarthTotem" or step == "graceOfAirTotem" then return false end
    return true
  end

  local function doCast(name)
    local sp = spells[name]
    manaNow = manaNow - costOf(name, sp)
    startCooldown(sp)
    if sp.gcd and sp.gcd > 0 then gcdReady = now + sp.gcd end
    cast[name]()
    completeCast(name)
  end

  -- Major cooldowns: Blood Fury and Rage of the Farseer as they come up, then mana potions.
  local function autocast()
    if gcdReady > now then return false end
    local castAny = false
    if bloodFury and (cooldownReady.bloodFury or -huge) <= now then
      cooldownReady.bloodFury = now + bloodFury.cooldown
      bfUntil = now + bloodFury.duration
      castAny = true
    end
    if farseer and (cooldownReady.farseer or -huge) <= now then
      cooldownReady.farseer = now + farseer.cooldown
      rotfUntil = now + farseer.duration
      setSpeed(currentSpeed())
      push(rotfUntil, EV_FARSEER_END)
      castAny = true
    end
    local regen = mana0.regenCasting
    local pot, rune = mana0.potion, mana0.rune
    if pot and potionReady <= now and manaMax - (manaNow + regen * pot.window) >= pot.gain then
      potionReady = now + pot.cooldown
      gainMana(pot.gain)
      count("manaPotion", "casts")
      castAny = true
    end
    if rune and runeReady <= now and manaMax - (manaNow + regen * rune.window) >= rune.gain then
      runeReady = now + rune.cooldown
      gainMana(rune.gain)
      count("manaRune", "casts")
      castAny = true
    end
    return castAny
  end

  local function setRotation(t)
    rotationGen = rotationGen + 1
    rotationAt = t
    push(t, EV_ROTATION, rotationGen)
  end

  -- One rotation pass at `now`. A step is ready when its spell can be cast now or queued; a
  -- spell queued in this pass blocks further queueing, and a lower step cast now replaces it.
  local function rotate()
    if rotationAt > now then return end
    local queuedNow = false
    for _ = 1, 16 do
      local acted = false
      for i = 1, nSteps do
        local step = steps[i]
        if step == "cooldowns" then
          if autocast() then acted = true break end
        elseif condition(step) then
          local name = SPELL_OF[step]
          local sp = spells[name]
          if costOf(name, sp) <= manaNow then
            local cdAt = readyAt(sp)
            if gcdReady <= now and cdAt <= now then
              queuedGen = queuedGen + 1
              queuedSpell = nil
              doCast(name)
              acted = true
              break
            end
            local at = cdAt > gcdReady and cdAt or gcdReady
            if not queuedNow and at - now <= queueWindow then
              queuedNow = true
              queuedGen = queuedGen + 1
              queuedSpell = name
              push(at + 1e-9, EV_QUEUED, queuedGen, name)
            end
          end
        end
      end
      if not acted then break end
    end
    if rotationAt <= now then
      local nextAt = now + reaction
      if gcdReady > nextAt then nextAt = gcdReady end
      setRotation(nextAt)
    end
  end

  local function afterCast()
    if gcdReady > now then setRotation(gcdReady) end
  end

  -- After a swing: the rotation runs one reaction time later at the latest.
  local function reactToSwing(mainHand)
    if mainHand and rotationAt > now then setRotation(now) end
    if mainHand then rotate() afterCast() end
    if rotationAt > now + reaction then setRotation(now + reaction) end
  end

  ----------------------------------------------------------------------------
  -- Events
  ----------------------------------------------------------------------------

  local function handle(ev)
    local kind = ev[3]
    if kind == EV_ROTATION then
      if ev[4] ~= rotationGen then return end
      rotate()
      afterCast()
    elseif kind == EV_QUEUED then
      if ev[4] ~= queuedGen then return end
      queuedSpell = nil
      local name = ev[5]
      local sp = spells[name]
      if gcdReady <= now and readyAt(sp) <= now and costOf(name, sp) <= manaNow then
        doCast(name)
        afterCast()
      end
    elseif kind == EV_FLURRY then
      if ev[4] then
        flurryCharges = flurryFx.charges
        flurryGen = flurryGen + 1
        push(now + Data.flurry.duration, EV_FLURRY_END, flurryGen)
        setSpeed(currentSpeed())
      elseif ev[5] and flurryCharges > 0 and flurryIcd <= now then
        flurryIcd = now + flurryFx.chargeIcd
        flurryCharges = flurryCharges - 1
        if flurryCharges == 0 then setSpeed(currentSpeed()) end
      end
    elseif kind == EV_FLURRY_END then
      if ev[4] == flurryGen and flurryCharges > 0 then
        flurryCharges = 0
        setSpeed(currentSpeed())
      end
    elseif kind == EV_MAELSTROM then
      if mswUntil <= now then msw = 0 end
      if msw < maelstrom.maxStacks then msw = msw + 1 end
      mswUntil = now + maelstrom.duration
    elseif kind == EV_DEVASTATION then
      edUntil = now + devastation.duration
    elseif kind == EV_CRUSADER then
      if ev[4] then hsUntilMh = now + crusader.duration else hsUntilOh = now + crusader.duration end
    elseif kind == EV_JUDGEMENT then
      gainMana(jow.mana)
    elseif kind == EV_CHILI then
      local dmg = (chili.min + (chili.max - chili.min) * rng:next() + chili.coefficient * spellPower(chili.school))
        * chili.multiplier * partial()
      count("dragonbreathChili", "casts")
      if rng:next() < char.spellMiss then
        count("dragonbreathChili", "misses")
      else
        if rng:next() < (char.spellCritPercent + chili.critBonusPercent) / 100 then
          dmg = dmg * spellCritMult
          count("dragonbreathChili", "crits")
        else
          count("dragonbreathChili", "hits")
        end
        damage = damage + dmg
        count("dragonbreathChili", "damage", dmg)
      end
    elseif kind == EV_SEARING then
      if ev[4] ~= searingGen then return end
      spellDamage("searingTotemAttack", STA, STA.average)
      local left = ev[5] - 1
      if left > 0 then push(now + ST.tickPeriod, EV_SEARING, ev[4], left) end
    elseif kind == EV_FLAMESHOCK then
      if ev[4] ~= fsGen then return end
      local dmg = fsTickBase * FSD.multiplier * partial()
      if FSD.tickCanCrit and rng:next() < (char.spellCritPercent + FSD.critBonusPercent) / 100 then
        dmg = dmg * spellCritMult
        count("flameShockDot", "crits")
      else
        count("flameShockDot", "hits")
      end
      damage = damage + dmg
      count("flameShockDot", "damage", dmg)
      fsTicksLeft = fsTicksLeft - 1
      if fsTicksLeft > 0 then push(now + FSD.tickPeriod, EV_FLAMESHOCK, ev[4]) end
    elseif kind == EV_MANA then
      gainMana(mana0.regenCasting * mana0.tickPeriod)
      push(now + mana0.tickPeriod, EV_MANA)
    elseif kind == EV_FARSEER_END then
      setSpeed(currentSpeed())
    end
  end

  ----------------------------------------------------------------------------
  -- Prepull and the fight loop
  ----------------------------------------------------------------------------

  for iter = 1, iterations do
    h, hn, seq = {}, 0, 0
    fightEnd = duration0 + variation * (2 * rng:next() - 1)
    damage = 0
    manaMax = char.mana
    manaNow = manaMax
    gcdReady, rotationAt, rotationGen, queuedGen, queuedSpell = -huge, huge, 0, 0, nil
    cooldownReady = {}
    bfUntil, rotfUntil, hsUntilMh, hsUntilOh, edUntil, ccUntil = -huge, -huge, -huge, -huge, -huge, -huge
    flurryCharges, flurryIcd, flurryGen = 0, -huge, 0
    msw, mswUntil = 0, -huge
    ssDebuffUntil, ssDebuffCharges = -huge, 0
    wftProcUntil, wftCharges, wftIcd = -huge, 0, -huge
    fsUntil, fsTicksLeft, fsTickBase, fsGen = -huge, 0, 0, 0
    totemUntil, searingGen = -huge, 0
    chiliIcd = -huge
    potionReady, runeReady = -huge, -huge
    if windfury then windfury:reset() end

    -- Prepull casts, and the mana ticks that run from the first of them.
    local first = 0
    for _, p in ipairs(rot.prepull or {}) do
      if p.at < first then first = p.at end
    end
    local tick = first + mana0.tickPeriod
    for _, p in ipairs(rot.prepull or {}) do
      while tick <= p.at do
        gainMana(mana0.regenCasting * mana0.tickPeriod)
        tick = tick + mana0.tickPeriod
      end
      now = p.at
      manaNow = manaNow - (spells[p.spell].cost or 0)
      if p.spell == "searingTotem" then cast.searingTotem() end
    end
    while tick < 0 do
      gainMana(mana0.regenCasting * mana0.tickPeriod)
      tick = tick + mana0.tickPeriod
    end
    push(tick, EV_MANA)

    -- Swings and the opening rotation.
    now = 0
    speed = char.haste
    local delay = floor(rng:next() * reaction * 1000) / 1000
    mhNext = delay
    ohNext = dualWield and (oh.speed / 2 + delay) or huge
    gcdReady = 0
    setRotation(0)

    while true do
      local t, kind = mhNext, 1
      if ohNext < t then t, kind = ohNext, 2 end
      if hn > 0 and h[1][1] < t then t, kind = h[1][1], 3 end
      if t >= fightEnd then break end
      now = t
      if kind == 1 then
        syncOffHand()
        mhNext = now + mh.speed / speed
        swing("mainHand", true)
        reactToSwing(true)
      elseif kind == 2 then
        ohNext = now + oh.speed / speed
        swing("offHand", false)
        reactToSwing(false)
      else
        local ev
        ev, hn = heapPop(h, hn)
        handle(ev)
      end
    end

    dpsValues[iter] = damage / fightEnd
  end

  return dpsValues, windfury, tally
end

return EventSim
