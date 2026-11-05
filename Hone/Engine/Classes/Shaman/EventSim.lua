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
--
-- Random draws
--   Every random number comes from U(site), and every site is a named S_ constant below, so
--   each draw says what it decides. Site numbers are unique across the file. opts.draws
--   picks where U reads from.
--     stream   one sequential Core/Rng stream in program order. With every option below off
--              this is main's EventSim at 11ba1ed bit for bit (tests/addon/engine/faithful.lua).
--     indexed  draw `slot` of the substream (fight, ctx * 32 + site): fight f is block f of
--              the seed's stream and the key a run inside it (Core/Rng jump-ahead). A run on a
--              perturbed snapshot then replays the base run's outcomes wherever the stat does
--              not bite, so a finite difference carries little noise.
--   Every root event calls enter(root, slot) before it draws: the fight itself, each hand's
--   k-th swing, each spell's k-th cast, each Flame Shock tick and each Searing Totem attack.
--   A nested event keeps its parent's slot and sets ctx = parent * 4 + kind: Windfury's two
--   strikes (kinds 1 and 2), the totem's extra attack (3), and the procs a hit casts,
--   Flametongue and Chili (0, on disjoint sites). Roots are numbered from 16, so a nested
--   context (64 or more) never equals a root.
--   opts.lhs = N (prime) stratifies indexed draws across the N fights of a batch. Slot k of
--   a key takes stratum (a * fight + b) mod N, with a and b drawn once per batch from the
--   key's twin run in block 0, and the plain uniform places the draw inside the stratum.
--
-- Estimator options. All off is main's behaviour.
--   tableFlip    the white table laid out dodge, glance, crit, hit, miss, so hit moves only
--                the hit/miss edge and crit only the crit/hit edge. Truncation is main's:
--                a miss wins the overlap and crit fills only what is left.
--   condDamage   rolls that change damage and nothing else take their expectation: weapon
--                roll, glance spread, spell variance, partial resists, and the miss and crit
--                of Flametongue, Searing Totem, Flame Shock ticks, Chili and Iceblade.
--   window       a fight scores the mean of D(t) / t over the duration window, in closed
--                form per damage event, instead of D at one sampled end over that end.
--   pathwise     per-fight dDamage/dAttackPower and dDamage/dSpellDamage along the path.
--   flurryFirst  Flurry hears a melee hit before Windfury and the totem (see onMeleeResult).
--   tally        the per-action tally.
--   audit        a list that receives the key, slot and value of every indexed draw (tests only).

local _, ns = ...
local Engine = ns.Engine
local Core = Engine.Core
local Shaman = Engine.Classes.Shaman
local Data = Shaman.Data
local AttackTable, SpellTable, Stats, Rng = Core.AttackTable, Core.SpellTable, Core.Stats, Core.Rng
local WindfuryWeapon = Shaman.WindfuryWeapon

local MISS, DODGE, GLANCE, CRIT, HIT = AttackTable.MISS, AttackTable.DODGE, AttackTable.GLANCE,
  AttackTable.CRIT, AttackTable.HIT
local huge, floor, log = math.huge, math.floor, math.log
local NEG_HUGE = -huge

local EventSim = {}
Shaman.EventSim = EventSim

------------------------------------------------------------------------------
-- Draw sites, roots and nested kinds
------------------------------------------------------------------------------

local S = {
  FIGHT_END = 0, SWING_DELAY = 1,
  WEAPON = 2, WHITE_TABLE = 3, GLANCE_SPREAD = 4, SPECIAL_MISS = 5, SPECIAL_CRIT = 6,
  WINDFURY_PROC = 7, TOTEM_PROC = 8, ICEBLADE_PROC = 9, ICEBLADE_PARTIAL = 10, ICEBLADE_CRIT = 11,
  MAELSTROM_PROC = 12, CRUSADER_PROC = 13, JUDGEMENT_MELEE = 14, CHILI_PROC = 15,
  SPELL_VARIANCE = 16, SPELL_PARTIAL = 17, JUDGEMENT_SPELL = 18, SPELL_MISS = 19, SPELL_CRIT = 20,
  FOCUS_PROC = 21, CHILI_DAMAGE = 22, CHILI_PARTIAL = 23, CHILI_MISS = 24, CHILI_CRIT = 25,
}
local R = {
  FIGHT = 16, MAIN_HAND = 17, OFF_HAND = 18, STORMSTRIKE = 19, LIGHTNING_BOLT = 20,
  EARTH_SHOCK = 21, FLAME_SHOCK = 22, FIRE_NOVA = 23, FLAME_SHOCK_TICK = 24, SEARING_ATTACK = 25,
}
local N = { HIT_PROCS = 0, WINDFURY_1 = 1, WINDFURY_2 = 2, TOTEM_ATTACK = 3 }
EventSim.SITES, EventSim.ROOTS, EventSim.NESTED = S, R, N

local S_FIGHT_END, S_SWING_DELAY = S.FIGHT_END, S.SWING_DELAY
local S_WEAPON, S_WHITE_TABLE, S_GLANCE_SPREAD = S.WEAPON, S.WHITE_TABLE, S.GLANCE_SPREAD
local S_SPECIAL_MISS, S_SPECIAL_CRIT = S.SPECIAL_MISS, S.SPECIAL_CRIT
local S_WINDFURY_PROC, S_TOTEM_PROC = S.WINDFURY_PROC, S.TOTEM_PROC
local S_ICEBLADE_PROC, S_ICEBLADE_PARTIAL, S_ICEBLADE_CRIT = S.ICEBLADE_PROC, S.ICEBLADE_PARTIAL, S.ICEBLADE_CRIT
local S_MAELSTROM_PROC, S_CRUSADER_PROC, S_JUDGEMENT_MELEE = S.MAELSTROM_PROC, S.CRUSADER_PROC, S.JUDGEMENT_MELEE
local S_CHILI_PROC, S_SPELL_VARIANCE, S_SPELL_PARTIAL = S.CHILI_PROC, S.SPELL_VARIANCE, S.SPELL_PARTIAL
local S_JUDGEMENT_SPELL, S_SPELL_MISS, S_SPELL_CRIT, S_FOCUS_PROC = S.JUDGEMENT_SPELL, S.SPELL_MISS,
  S.SPELL_CRIT, S.FOCUS_PROC
local S_CHILI_DAMAGE, S_CHILI_PARTIAL, S_CHILI_MISS, S_CHILI_CRIT = S.CHILI_DAMAGE, S.CHILI_PARTIAL,
  S.CHILI_MISS, S.CHILI_CRIT

-- Indexed draws read keys ctx * KEY_SITES + site.
local KEY_SITES = 32

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
-- Stratification design
------------------------------------------------------------------------------

-- (a, b) per key and slot for one batch, cached for the last (seed, N) so a batch's base and
-- perturbed runs share it.
local designFor = { seed = nil, n = nil, keys = nil }

local function batchDesign(seed, n)
  if designFor.seed ~= seed or designFor.n ~= n then
    local s1, s2 = Rng.blockState(seed, 0)
    designFor.seed, designFor.n, designFor.keys = seed, n, {}
    designFor.s1, designFor.s2 = s1, s2
  end
  return designFor
end

-- The design list of one key: d[2k - 1] = a in [1, N - 1], d[2k] = b in [0, N - 1].
local function designOf(design, key, k)
  local d = design.keys[key]
  if not d then
    local M1, M2 = Rng.M1, Rng.M2
    local j1, j2 = Rng.keyMultipliers(Rng.twinKey(key))
    d = { n = 0, s1 = Rng.mulmod(design.s1, j1, M1), s2 = Rng.mulmod(design.s2, j2, M2) }
    design.keys[key] = d
  end
  if k > d.n then
    local A1, A2, M1, M2 = Rng.A1, Rng.A2, Rng.M1, Rng.M2
    local n = design.n
    local s1, s2 = d.s1, d.s2
    for i = d.n + 1, k do
      s1, s2 = (A1 * s1) % M1, (A2 * s2) % M2
      local ua = ((s1 - s2) % (M1 - 1)) / (M1 - 1)
      s1, s2 = (A1 * s1) % M1, (A2 * s2) % M2
      local ub = ((s1 - s2) % (M1 - 1)) / (M1 - 1)
      d[2 * i - 1], d[2 * i] = 1 + floor(ua * (n - 1)), floor(ub * n)
    end
    d.s1, d.s2, d.n = s1, s2, k
  end
  return d
end

------------------------------------------------------------------------------
-- Event kinds. Kind 1 (rotation) lives in its own slot and never enters the queue.
------------------------------------------------------------------------------

local EV_QUEUED, EV_FLURRY, EV_MAELSTROM, EV_DEVASTATION = 2, 3, 4, 5
local EV_CRUSADER, EV_JUDGEMENT, EV_CHILI, EV_SEARING, EV_FLAMESHOCK = 6, 7, 8, 9, 10
local EV_MANA, EV_FARSEER_END, EV_FLURRY_END = 11, 12, 13

------------------------------------------------------------------------------
-- Fights
------------------------------------------------------------------------------

-- Runs `iterations` fights. `source` is an Rng for stream draws (its state advances as main's
-- did) or a seed number for either mode. Returns per-fight dps, the Windfury rule, the
-- per-action tally (opts.tally) and, with opts.pathwise, { dAP = {...}, dSP = {...} } per
-- fight in dps per point.
function EventSim.run(char, scenario, source, iterations, opts)
  opts = opts or {}
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

  -- Fight-invariant numbers read in the hot path.
  local dodgeChance, glanceMult = char.dodge, char.glanceMultiplier
  local specialMiss, spellMiss, spellCritPct = char.specialMiss, char.spellMiss, char.spellCritPercent
  local baseAP, baseHaste = char.attackPower, char.haste
  local apPerDps = Data.attackPowerPerDps

  local tableFlip, condDamage, window, pathwise = opts.tableFlip, opts.condDamage, opts.window, opts.pathwise
  local flurryFirst = opts.flurryFirst
  local scoring = window or pathwise

  ----------------------------------------------------------------------------
  -- Random draws (see the file header)
  ----------------------------------------------------------------------------

  -- enter(root, k) starts root event k; setCtx(c) moves into or back out of a nested context.
  local ctx, slot, fightNo = 0, 0, 0
  local enter, setCtx

  local rng = type(source) == "table" and source or nil
  local U, startFight
  local s1, s2
  do
    local A1, A2, M1, M2 = Rng.A1, Rng.A2, Rng.M1, Rng.M2
    local M1m1 = M1 - 1
    local keyMultipliers = Rng.keyMultipliers
    local indexed = opts.draws == "indexed"
    local seed = not rng and source or nil
    if indexed then
      assert(type(seed) == "number", "indexed draws need a seed number")
    elseif not rng then
      rng = Rng.new(seed)
    end
    if not indexed then
      enter = function(root, k) ctx, slot = root, k end
      setCtx = function(c) ctx = c end
      -- Core/Rng's step on local state, the same arithmetic in the same order. The state is
      -- written back to the rng when the run ends.
      s1, s2 = rng.s1, rng.s2
      U = function()
        s1 = (40014 * s1) % 2147483563
        s2 = (40692 * s2) % 2147483399
        return ((s1 - s2) % 2147483562) / 2147483562
      end
    else
      local lhs = opts.lhs
      local design = lhs and batchDesign(seed, lhs)
      local fightS1, fightS2
      local KEY_LIMIT = Rng.KEY_LIMIT
      -- Site states per context, indexed by site + 1. `cur` is the current context's list.
      local byCtx, cur = {}, nil
      setCtx = function(c)
        ctx = c
        local list = byCtx[c]
        if not list then
          list = {}
          byCtx[c] = list
        end
        cur = list
      end
      enter = function(root, k)
        slot = k
        setCtx(root)
      end
      -- A site state is { s1, s2, slot drawn, fight, design list, the key's jump multipliers
      -- split into 16-bit halves (hi1, lo1, hi2, lo2), key }.
      U = function(site)
        local st = cur[site + 1]
        if not st then
          local key = ctx * KEY_SITES + site
          if key >= KEY_LIMIT then error("draw key " .. key .. " past the substream limit") end
          local j1, j2 = keyMultipliers(key)
          local h1, h2 = floor(j1 / 65536), floor(j2 / 65536)
          st = { 0, 0, 0, -1, design and designOf(design, key, 0) or false, h1, j1 - h1 * 65536,
                 h2, j2 - h2 * 65536, key }
          cur[site + 1] = st
        end
        local k = slot
        local a1, a2, n
        if st[4] == fightNo and st[3] <= k then
          a1, a2, n = st[1], st[2], st[3]
        else
          -- The key's start in this fight's block: Rng.mulmod(fightS, j) on the stored halves.
          a1 = ((fightS1 * st[6]) % M1 * 65536 + fightS1 * st[7]) % M1
          a2 = ((fightS2 * st[8]) % M2 * 65536 + fightS2 * st[9]) % M2
          n = 0
          st[4] = fightNo
        end
        for _ = n + 1, k do
          a1 = (A1 * a1) % M1
          a2 = (A2 * a2) % M2
        end
        st[1], st[2], st[3] = a1, a2, k
        local u = ((a1 - a2) % M1m1) / M1m1
        if lhs then
          local d = st[5]
          if k > d.n then designOf(design, st[10], k) end
          return ((d[2 * k - 1] * fightNo + d[2 * k]) % lhs + u) / lhs
        end
        return u
      end
      if opts.audit then
        local audit, plainU = opts.audit, U
        U = function(site)
          local u = plainU(site)
          audit[#audit + 1] = { fight = fightNo, key = ctx * KEY_SITES + site, ctx = ctx, site = site, slot = slot,
                                u = u }
          return u
        end
      end
      -- Fight f reads block f of the seed's stream.
      startFight = function(f)
        fightS1, fightS2 = Rng.blockState(seed, f)
      end
    end
  end

  -- Imbues and procs.
  local windfury = (char.imbues.mainHand == "WindfuryWeapon") and WindfuryWeapon.new(char.talents) or nil
  if windfury and spells.windfury then windfury.attackPower = spells.windfury.attackPower end
  local ft = dualWield and char.imbues.offHand == "FlametongueWeapon" and spells.flametongue or nil
  local wft = buffs.windfuryTotem
  local crusader = buffs.crusader
  local bloodFury, farseer = buffs.bloodFury, buffs.rageOfTheFarseer
  local devastation = talentFx.elementalDevastation
  local focus = talentFx.elementalFocus
  local maelstrom = talentFx.maelstromWeapon
  local flurryFx = talentFx.flurry
  local jow = mana0.judgement
  local chili, iceblade
  for _, p in ipairs(model.procs or {}) do
    if p.name == "dragonbreathChili" then chili = p
    elseif p.kind == "weaponCritOnly" then iceblade = p end
  end



  -- Spells the rotation casts.
  local SS, LB, ES, FS, FSD = spells.stormstrike, spells.lightningBolt, spells.earthShock,
    spells.flameShock, spells.flameShockDot
  local FN, ST, STA = spells.fireNova, spells.searingTotem, spells.searingTotemAttack

  -- Per-action tallies only with opts.tally; `count` is nil otherwise.
  local tally = {}
  local count
  if opts.tally then
    count = function(name, field, amount)
      local row = tally[name]
      if not row then
        row = { casts = 0, hits = 0, crits = 0, misses = 0, dodges = 0, glances = 0, damage = 0, boosted = 0 }
        tally[name] = row
      end
      row[field] = row[field] + (amount or 1)
    end
  end

  local dpsValues, slopes = {}, pathwise and { dAP = {}, dSP = {} } or nil
  local duration0, variation = scenario.duration, scenario.durationVariation
  local tMin, tMax = duration0 - variation, duration0 + variation
  local lnFull = window and log(tMax / tMin)

  -- Fight state, reset by each fight.
  local h, hn, seq
  local now, fightEnd, damage
  local winScore, dAP, dSP, wAt, wNow
  local mhNext, ohNext, speed
  local manaNow, manaMax
  local gcdReady, rotationAt, rotationGen, queuedGen
  local rotT, rotSeq
  local cooldownReady
  local bfUntil, rotfUntil, hsUntilMh, hsUntilOh, edUntil, ccUntil
  local flurryCharges, flurryIcd, flurryGen
  local msw, mswUntil
  local ssDebuffUntil, ssDebuffCharges
  local wftProcUntil, wftCharges, wftIcd
  local fsUntil, fsTicksLeft, fsTickBase, fsTickSlope, fsGen, fsCast
  local totemUntil, searingGen
  local chiliIcd
  local potionReady, runeReady
  local mhSwings, ohSwings, casts

  -- Weapon sync "delay" (spells/weapon_sync.rs), run as the main hand swing's replacement, so
  -- before each main hand swing and each totem extra attack: an off hand swing more than
  -- Flurry's charge cooldown away waits until just after the next main hand swing.
  local syncOffHand
  do
    local syncDelay = dualWield and model.weaponSync == "delay"
    local syncWait = flurryFx and flurryFx.chargeIcd or Data.flurry.chargeIcd
    syncOffHand = function()
      if syncDelay and ohNext - now > syncWait then
        local nextOh = now + mh.speed / speed + Data.weaponSyncLag
        if nextOh > ohNext then ohNext = nextOh end
      end
    end
  end

  -- Event tables come from a free list that handled events return to.
  local free, nFree = {}, 0
  local function push(t, kind, a, b)
    seq = seq + 1
    local ev
    if nFree > 0 then
      ev = free[nFree]
      free[nFree] = nil
      nFree = nFree - 1
      ev[1], ev[2], ev[3], ev[4], ev[5] = t, seq, kind, a, b
    else
      ev = { t, seq, kind, a, b }
    end
    -- Sorted insert: h[hn] is the earliest event. A new event has the highest sequence
    -- number, so it goes before every event at or before its time.
    local i = hn
    while i > 0 do
      local e = h[i]
      if e[1] > t then break end
      h[i + 1] = e
      i = i - 1
    end
    h[i + 1] = ev
    hn = hn + 1
  end

  -- Window weight and slopes of one damage event. Damage itself is added by the caller.
  local function score(dmg, dap, dsp)
    local w = 1
    if window then
      if now ~= wAt then
        wAt = now
        wNow = now <= tMin and lnFull or log(tMax / now)
      end
      w = wNow
      winScore = winScore + dmg * w
    end
    if pathwise then
      dAP = dAP + dap * w
      dSP = dSP + dsp * w
    end
  end

  ----------------------------------------------------------------------------
  -- Stats that change in the fight
  ----------------------------------------------------------------------------

  local function attackPower()
    local ap = baseAP
    if crusader then
      if hsUntilMh > now then ap = ap + crusader.attackPower end
      if hsUntilOh > now then ap = ap + crusader.attackPower end
    end
    if wft and wftProcUntil > now and wftCharges > 0 then ap = ap + wft.attackPower end
    if bloodFury and bfUntil > now then ap = ap * bloodFury.attackPowerMultiplier end
    return ap
  end

  -- d(attack power)/d(sheet attack power) and the same for spell damage.
  local function apSlope()
    if bloodFury and bfUntil > now then return bloodFury.attackPowerMultiplier end
    return 1
  end
  local function spSlope()
    if bloodFury and bfUntil > now then return bloodFury.spellDamageMultiplier end
    return 1
  end

  local spellPower
  do
    local baseSpellDamage, fireDamage, natureDamage = char.spellDamage, char.fireDamage, char.natureDamage
    spellPower = function(school)
      local sp = baseSpellDamage
      if bloodFury and bfUntil > now then sp = sp * bloodFury.spellDamageMultiplier end
      if school == "fire" then return sp + fireDamage end
      if school == "nature" then return sp + natureDamage end
      return sp
    end
  end

  -- Physical crit chance. Elemental Devastation raises only melee attacks, not item procs.
  local meleeCrit
  do
    local critSuppression, meleeCritPct = char.critSuppression, char.meleeCritPercent
    meleeCrit = function(noDevastation)
      local c = meleeCritPct
      if devastation and edUntil > now and not noDevastation then c = c + devastation.meleeCritPercent end
      c = c / 100 - critSuppression
      return c > 0 and c or 0
    end
  end

  local function currentSpeed()
    local s = baseHaste
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

  local partial
  do
    local partialNone, partialQuarter, partialHalf = SpellTable.partialThresholds(char.resistCoefficient)
    local partialMean = SpellTable.partialMean(char.resistCoefficient)
    local partialMultiplier = SpellTable.partialMultiplier
    partial = function(site)
      if condDamage then return partialMean end
      return partialMultiplier(U(site), partialNone, partialQuarter, partialHalf)
    end
  end

  -- A magic hit and crit roll for a spell table entry `sp`. `base` is the roll before spell
  -- power. `free` marks a spell whose miss and crit reach nothing but damage, so condDamage
  -- takes their expectation. Returns damage dealt and whether it landed and crit.
  local function spellDamage(name, sp, base, targetMult, direct, free)
    if direct and jow and U(S_JUDGEMENT_SPELL) < jow.chance then push(now + batch, EV_JUDGEMENT) end
    local dmg = (base + sp.coefficient * (spellPower(sp.school) + (sp.bonusSpellPower or 0))) * sp.multiplier
    local pm = 1
    if not sp.binary then
      pm = partial(S_SPELL_PARTIAL)
      dmg = dmg * pm
    end
    dmg = dmg * (targetMult or 1)
    if count then
      count(name, "casts")
      if targetMult and targetMult ~= 1 then count(name, "boosted") end
    end
    local critChance = (spellCritPct + sp.critBonusPercent) / 100
    local mult
    if free and condDamage then
      mult = (1 - spellMiss) * (1 + critChance * (spellCritMult - 1))
      dmg = dmg * mult
      if count then count(name, "hits") end
      damage = damage + dmg
      if scoring then score(dmg, 0, sp.coefficient * spSlope() * sp.multiplier * pm * (targetMult or 1) * mult) end
      if count then count(name, "damage", dmg) end
      return dmg, true, false
    end
    if U(S_SPELL_MISS) < spellMiss then
      if count then count(name, "misses") end
      return 0, false, false
    end
    local crit = U(S_SPELL_CRIT) < critChance
    mult = 1
    if crit then
      dmg = dmg * spellCritMult
      mult = spellCritMult
      if count then count(name, "crits") end
    else
      if count then count(name, "hits") end
    end
    damage = damage + dmg
    if scoring then score(dmg, 0, sp.coefficient * spSlope() * sp.multiplier * pm * (targetMult or 1) * mult) end
    if count then count(name, "damage", dmg) end
    return dmg, true, crit
  end

  local function roll(sp)
    local v = sp.variance or 0
    if v == 0 or condDamage then return sp.average end
    local lo = sp.average * (1 - v / 2)
    return lo + sp.average * v * U(S_SPELL_VARIANCE)
  end

  local function weaponDamage(weapon, ap)
    local r = condDamage and 0.5 or U(S_WEAPON)
    return weapon.min + (weapon.max - weapon.min) * r + weapon.speed * ap / apPerDps
  end

  ----------------------------------------------------------------------------
  -- Melee results and what they trigger
  ----------------------------------------------------------------------------

  local swing, windfuryStrikes

  local onMeleeResult
  do
    -- Which hits each listener hears, by action name.
    local function set(list)
      local out = {}
      for _, name in ipairs(list or {}) do out[name] = true end
      return out
    end
    local wfHears = set(spells.windfury and spells.windfury.triggers)
    local ftHears = set(ft and ft.triggers)
    local wftTriggers, wftSpenders = set(wft and wft.triggers), set(wft and wft.spenders)
    local chiliHears = set(chili and chili.triggers)
    local crusaderChance = crusader and crusader.chances or {}
    local maelstromChance = maelstrom and maelstrom.chances or {}
    local icebladeChance = iceblade and iceblade.chances or {}

    local function iceblades(name)
      local chance = icebladeChance[name]
      if chance and U(S_ICEBLADE_PROC) < chance then
        local dmg = iceblade.min * iceblade.multiplier * partial(S_ICEBLADE_PARTIAL)
        if count then count(iceblade.name, "casts") end
        if condDamage then
          dmg = dmg * (1 + meleeCrit(true) * (critMult - 1))
          if count then count(iceblade.name, "hits") end
        elseif U(S_ICEBLADE_CRIT) < meleeCrit(true) then
          dmg = dmg * critMult
          if count then count(iceblade.name, "crits") end
        else
          if count then count(iceblade.name, "hits") end
        end
        damage = damage + dmg
        if scoring then score(dmg, 0, 0) end
        if count then count(iceblade.name, "damage", dmg) end
      end
    end

    onMeleeResult = function(name, outcome, dealt, white, mainHand)
      local landed = outcome >= GLANCE
      -- Flurry hears the hit first, before Windfury's strikes or the totem's extra attack, so the
      -- swing's own charge is spent before a strike's crit grants new ones. MythicSim calls a
      -- hit's listeners in the order their auras came up (core/fight/aura.rs:494-497, 1393-1405),
      -- and the Flurry Trigger comes up with the talents (prepare/talents.rs:622), ahead of the
      -- Windfury Imbue (prepare/imbues.rs:149).
      if flurryFirst and flurryFx then push(now + batch, EV_FLURRY, outcome == CRIT, white) end
      -- Windfury Weapon (WindfuryWeapon:onHit, inline).
      if windfury and landed and wfHears[name] and name ~= "windfuryMainHand" then
        local wf = windfury
        wf.eligible = wf.eligible + 1
        if wf.readyAt <= now then
          wf.rolls = wf.rolls + 1
          local chance = wf.chance
          if chance >= 1 or (chance > 0 and U(S_WINDFURY_PROC) < chance) then
            wf.readyAt = now + wf.icd
            wf.procs = wf.procs + 1
            if wf.strikes > 0 then windfuryStrikes(wf.strikes) end
          end
        end
      end
      -- Party Windfury Totem: charges spent by landed hits, then a new proc.
      if wft then
        if wftSpenders[name] and landed and dealt > 0 and wftProcUntil > now and wftCharges > 0 then
          wftCharges = wftCharges - 1
        end
        if wftTriggers[name] and landed and dealt > 0 and wftIcd <= now then
          if U(S_TOTEM_PROC) < wft.chance then
            wftIcd = now + wft.icd
            wftProcUntil = now + wft.duration
            wftCharges = wft.charges - (white and 1 or 0)
            syncOffHand()
            local parent = ctx
            setCtx(parent * 4 + N.TOTEM_ATTACK)
            swing("windfuryTotemAttack", true)
            setCtx(parent)
          end
        end
      end
      -- Flametongue Weapon.
      if ft and ftHears[name] and landed then
        local parent = ctx
        setCtx(parent * 4 + N.HIT_PROCS)
        spellDamage("flametongue", ft, ft.average, nil, nil, true)
        setCtx(parent)
      end
      -- Iceblade-style weapon procs: a fixed hit with the physical crit roll.
      if iceblade and landed and dealt > 0 then iceblades(name) end
      -- Delayed procs.
      if not flurryFirst and flurryFx then push(now + batch, EV_FLURRY, outcome == CRIT, white) end
      if maelstrom and landed then
        local chance = maelstromChance[name]
        if chance and U(S_MAELSTROM_PROC) < chance then push(now + batch, EV_MAELSTROM) end
      end
      if crusader and landed then
        local chance = crusaderChance[name]
        if chance and U(S_CRUSADER_PROC) < chance then push(now + batch, EV_CRUSADER, mainHand) end
      end
      if jow and U(S_JUDGEMENT_MELEE) < jow.chance then push(now + batch, EV_JUDGEMENT) end
      if chili and chiliHears[name] and landed and chiliIcd <= now then
        if U(S_CHILI_PROC) < chili.chance then
          chiliIcd = now + chili.icd
          push(now + chili.delay, EV_CHILI, ctx, slot)
        end
      end
    end
  end

  -- Damage of a strike and its multiplier on base damage.
  local function strikeDamage(base, outcome)
    if outcome == CRIT then return base * armor * critMult, armor * critMult end
    if outcome >= GLANCE then return base * armor, armor end
    return 0, 0
  end

  -- Called only when the tally is on.
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
  local whiteMiss, glanceChance, glanceSpread = char.whiteMiss, char.glance, char.glanceSpread
  swing = function(name, mainHand)
    local weapon = mainHand and mh or oh
    local base = weaponDamage(weapon, attackPower())
    local half = mainHand and 1 or 0.5
    if not mainHand then base = base * 0.5 end
    local r = U(S_WHITE_TABLE)
    local crit = meleeCrit()
    local outcome
    if tableFlip then
      -- [dodge | glance | crit | hit | miss]; a miss wins where crit would reach it.
      local edge = dodgeChance
      if r < edge then outcome = DODGE
      else
        edge = edge + glanceChance
        if r < edge then outcome = GLANCE
        elseif r >= 1 - whiteMiss then outcome = MISS
        elseif r < edge + crit then outcome = CRIT
        else outcome = HIT end
      end
    else
      local edge = whiteMiss
      if r < edge then outcome = MISS
      else
        edge = edge + dodgeChance
        if r < edge then outcome = DODGE
        else
          edge = edge + glanceChance
          if r < edge then outcome = GLANCE
          elseif r < edge + crit then outcome = CRIT
          else outcome = HIT end
        end
      end
    end
    local dealt, mult
    if outcome == GLANCE then
      local g = condDamage and glanceMult or (glanceMult + glanceSpread * (2 * U(S_GLANCE_SPREAD) - 1))
      dealt, mult = base * armor * g, armor * g
    else
      dealt, mult = strikeDamage(base, outcome)
    end
    damage = damage + dealt
    if scoring then score(dealt, weapon.speed * apSlope() / apPerDps * half * mult, 0) end
    if count then tallyMelee(name, outcome, dealt) end
    onMeleeResult(name, outcome, dealt, true, mainHand)
  end

  -- A special attack's crit-only roll after a landed cast. `apBonus` adds to attack power.
  local function special(name, weapon, apBonus, canMiss)
    local outcome
    if canMiss then
      local r = U(S_SPECIAL_MISS)
      if tableFlip then
        if r < dodgeChance then outcome = DODGE
        elseif r >= 1 - specialMiss then outcome = MISS end
      else
        if r < specialMiss then outcome = MISS
        elseif r < specialMiss + dodgeChance then outcome = DODGE end
      end
    end
    local dealt, mult = 0, 0
    if not outcome then
      local base = weaponDamage(weapon, attackPower() + apBonus)
      outcome = U(S_SPECIAL_CRIT) < meleeCrit() and CRIT or HIT
      dealt, mult = strikeDamage(base, outcome)
    end
    damage = damage + dealt
    if scoring then score(dealt, weapon.speed * apSlope() / apPerDps * mult, 0) end
    if count then tallyMelee(name, outcome, dealt) end
    return outcome, dealt
  end

  windfuryStrikes = function(n)
    local parent = ctx
    for j = 1, n do
      setCtx(parent * 4 + (j == 1 and N.WINDFURY_1 or N.WINDFURY_2))
      local outcome, dealt = special("windfuryMainHand", mh, windfury.attackPower, true)
      onMeleeResult("windfuryMainHand", outcome, dealt, false, true)
    end
    setCtx(parent)
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
      if FOCUS_ROLLS[name] and U(S_FOCUS_PROC) < focus.chance then ccUntil = now + focus.duration end
    end
  end

  -- The k-th cast of a spell is its root slot.
  local function castSlot(name)
    local k = (casts[name] or 0) + 1
    casts[name] = k
    return k
  end

  local cast = {}

  function cast.stormstrike()
    enter(R.STORMSTRIKE, castSlot("stormstrike"))
    local r = U(S_SPECIAL_MISS)
    if count then count("stormstrike", "casts") end
    local missed, dodged
    if tableFlip then
      dodged = r < dodgeChance
      missed = not dodged and r >= 1 - specialMiss
    else
      missed = r < specialMiss
      dodged = not missed and r < specialMiss + dodgeChance
    end
    if missed then
      if count then count("stormstrike", "misses") end
      return
    end
    if dodged then
      if count then count("stormstrike", "dodges") end
      return
    end
    if count then count("stormstrike", "hits") end
    ssDebuffUntil = now + SS.debuffDuration
    ssDebuffCharges = SS.debuffCharges
    local outcome, dealt = special("stormstrikeMainHand", mh, 0, false)
    onMeleeResult("stormstrikeMainHand", outcome, dealt, false, true)
  end

  local function stormstrikeMultiplier(spends)
    if ssDebuffUntil > now and ssDebuffCharges > 0 then
      return SS.debuffMultiplier, spends
    end
    return 1, false
  end

  function cast.lightningBolt()
    enter(R.LIGHTNING_BOLT, castSlot("lightningBolt"))
    local mult, spends = stormstrikeMultiplier(true)
    local dmg, landed, crit = spellDamage("lightningBolt", LB, roll(LB), mult, true)
    if spends and landed and dmg > 0 then ssDebuffCharges = ssDebuffCharges - 1 end
    msw, mswUntil = 0, -huge
    devastate(crit)
  end

  function cast.earthShock()
    enter(R.EARTH_SHOCK, castSlot("earthShock"))
    local mult = stormstrikeMultiplier(false)
    local _, _, crit = spellDamage("earthShock", ES, roll(ES), mult, true)
    devastate(crit)
  end

  function cast.flameShock()
    fsCast = castSlot("flameShock")
    enter(R.FLAME_SHOCK, fsCast)
    local _, landed, crit = spellDamage("flameShock", FS, roll(FS), 1, true)
    if landed then
      fsGen = fsGen + 1
      fsTicksLeft = FSD.ticks
      fsTickBase = FSD.tickBase + FSD.tickCoefficient * spellPower(FSD.school)
      fsTickSlope = FSD.tickCoefficient * spSlope()
      fsUntil = now + FSD.ticks * FSD.tickPeriod
      push(now + FSD.tickPeriod, EV_FLAMESHOCK, fsGen)
    end
    devastate(crit)
  end

  function cast.fireNova()
    enter(R.FIRE_NOVA, castSlot("fireNova"))
    spellDamage("fireNova", FN, roll(FN), 1, true)
  end

  function cast.searingTotem()
    totemUntil = now + ST.duration
    searingGen = searingGen + 1
    push(now + ST.tickPeriod, EV_SEARING, searingGen, ST.ticks)
  end

  function cast.strengthOfEarthTotem() end
  function cast.graceOfAirTotem() end

  local function doCast(name)
    local sp = spells[name]
    manaNow = manaNow - costOf(name, sp)
    startCooldown(sp)
    if sp.gcd and sp.gcd > 0 then gcdReady = now + sp.gcd end
    cast[name]()
    completeCast(name)
  end

  local autocast
  do
    -- Mana a potion or rune must leave room for: the regen over its window.
    local pot, rune = mana0.potion, mana0.rune
    local potReserve = pot and mana0.regenCasting * pot.window
    local runeReserve = rune and mana0.regenCasting * rune.window

    -- Major cooldowns: Blood Fury and Rage of the Farseer as they come up, then mana potions.
    autocast = function()
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
      if pot and potionReady <= now and manaMax - (manaNow + potReserve) >= pot.gain then
        potionReady = now + pot.cooldown
        gainMana(pot.gain)
        if count then count("manaPotion", "casts") end
        castAny = true
      end
      if rune and runeReady <= now and manaMax - (manaNow + runeReserve) >= rune.gain then
        runeReady = now + rune.cooldown
        gainMana(rune.gain)
        if count then count("manaRune", "casts") end
        castAny = true
      end
      return castAny
    end
  end

  -- Only the newest rotation event is live (the others fail the generation check and do
  -- nothing), so it waits in its own slot with its time and sequence number.
  local function setRotation(t)
    rotationGen = rotationGen + 1
    rotationAt = t
    seq = seq + 1
    rotT, rotSeq = t, seq
  end

  local rotate
  do
    local steps = rot.steps
    local nSteps = #steps
    local fnManaPercent = (rot.fireNovaManaPercent or 30) / 100
    local searingMin = rot.searingMinRemaining or 20
    local SPELL_OF = {
      stormstrike = "stormstrike", lightningBoltMaelstrom = "lightningBolt", earthShock = "earthShock",
      flameShock = "flameShock", fireNovaClearcasting = "fireNova", fireNovaMana = "fireNova",
      searingTotem = "searingTotem", strengthOfEarthTotem = "strengthOfEarthTotem",
      graceOfAirTotem = "graceOfAirTotem",
    }

    -- The rotation steps compiled once per run: a condition code, the spell name and table,
    -- its base cost and cooldown group, and the two costOf exceptions. The totem steps whose
    -- condition is always false never act, so they are left out.
    local CODE_OF = {
      cooldowns = 1, stormstrike = 2, earthShock = 2, fireNovaClearcasting = 3, lightningBoltMaelstrom = 4,
      searingTotem = 5, flameShock = 6, fireNovaMana = 7,
    }
    local stepCode, stepName, stepCost, stepGroup, stepCC, stepLB = {}, {}, {}, {}, {}, {}
    local nCompiled = 0
    for i = 1, nSteps do
      local step = steps[i]
      if step ~= "strengthOfEarthTotem" and step ~= "graceOfAirTotem" then
        local code = assert(CODE_OF[step], "unknown rotation step " .. tostring(step))
        nCompiled = nCompiled + 1
        stepCode[nCompiled] = code
        if code ~= 1 then
          local name = SPELL_OF[step]
          local sp = spells[name]
          stepName[nCompiled] = name
          stepCost[nCompiled] = sp.cost or 0
          stepGroup[nCompiled] = sp.cooldownGroup or false
          stepCC[nCompiled] = CONSUMES_CLEARCASTING[name] or false
          stepLB[nCompiled] = name == "lightningBolt"
        end
      end
    end
    local mswMax = maelstrom and maelstrom.maxStacks

    -- One rotation pass at `now`. A step is ready when its spell can be cast now or queued; a
    -- spell queued in this pass blocks further queueing, and a lower step cast now replaces it.
    rotate = function()
      local t = now
      if rotationAt > t then return end
      local queuedNow = false
      for _ = 1, 16 do
        local acted = false
        -- State a pass reads. Only a cast or a successful autocast changes it, and both end
        -- the pass. Codes: 1 cooldowns, 2 always, 3 Fire Nova on Clearcasting, 4 Lightning Bolt
        -- on full Maelstrom, 5 Searing Totem, 6 Flame Shock, 7 Fire Nova on mana.
        local ccActive = focus ~= nil and ccUntil > t
        local mswFull = maelstrom ~= nil and mswUntil > t and msw >= mswMax
        local gcd, mana = gcdReady, manaNow
        local gcdOk = gcd <= t
        for i = 1, nCompiled do
          local code = stepCode[i]
          local ok
          if code == 2 then ok = true
          elseif code == 1 then
            if gcdOk and autocast() then acted = true break end
            ok = false
          elseif code == 3 then ok = ccActive
          elseif code == 4 then ok = mswFull
          elseif code == 5 then ok = totemUntil <= t and fightEnd - t >= searingMin
          elseif code == 6 then ok = fsUntil <= t
          else ok = mana >= fnManaPercent * manaMax end
          if ok then
            local cost
            if ccActive and stepCC[i] then cost = 0
            elseif mswFull and stepLB[i] then cost = 0
            else cost = stepCost[i] end
            if cost <= mana then
              local group = stepGroup[i]
              local cdAt = group and cooldownReady[group] or NEG_HUGE
              if gcdOk and cdAt <= t then
                queuedGen = queuedGen + 1
                  doCast(stepName[i])
                acted = true
                break
              end
              if not queuedNow then
                local at = cdAt > gcd and cdAt or gcd
                if at - t <= queueWindow then
                  queuedNow = true
                  queuedGen = queuedGen + 1
                  local name = stepName[i]
                  push(at + 1e-9, EV_QUEUED, queuedGen, name)
                end
              end
            end
          end
        end
        if not acted then break end
      end
      if rotationAt <= t then
        local nextAt = t + reaction
        if gcdReady > nextAt then nextAt = gcdReady end
        setRotation(nextAt)
      end
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

  -- Chili lands one delay after its trigger and draws in the trigger's proc context.
  local function chiliHit(ev)
    slot = ev[5] or 0
    setCtx((ev[4] or 0) * 4 + N.HIT_PROCS)
    local v = condDamage and 0.5 or U(S_CHILI_DAMAGE)
    local pm = partial(S_CHILI_PARTIAL)
    local dmg = (chili.min + (chili.max - chili.min) * v + chili.coefficient * spellPower(chili.school))
      * chili.multiplier * pm
    local dsp = chili.coefficient * spSlope() * chili.multiplier * pm
    if count then count("dragonbreathChili", "casts") end
    local critChance = (spellCritPct + chili.critBonusPercent) / 100
    if condDamage then
      local e = (1 - spellMiss) * (1 + critChance * (spellCritMult - 1))
      dmg = dmg * e
      damage = damage + dmg
      if scoring then score(dmg, 0, dsp * e) end
      if count then
        count("dragonbreathChili", "hits")
        count("dragonbreathChili", "damage", dmg)
      end
    elseif U(S_CHILI_MISS) < spellMiss then
      if count then count("dragonbreathChili", "misses") end
    else
      if U(S_CHILI_CRIT) < critChance then
        dmg, dsp = dmg * spellCritMult, dsp * spellCritMult
        if count then count("dragonbreathChili", "crits") end
      else
        if count then count("dragonbreathChili", "hits") end
      end
      damage = damage + dmg
      if scoring then score(dmg, 0, dsp) end
      if count then count("dragonbreathChili", "damage", dmg) end
    end
  end

  local function flameShockTick(gen)
    enter(R.FLAME_SHOCK_TICK, fsCast * 32 + (FSD.ticks - fsTicksLeft + 1))
    local pm = partial(S_SPELL_PARTIAL)
    local dmg = fsTickBase * FSD.multiplier * pm
    local dsp = fsTickSlope * FSD.multiplier * pm
    if FSD.tickCanCrit and condDamage then
      local e = 1 + (spellCritPct + FSD.critBonusPercent) / 100 * (spellCritMult - 1)
      dmg, dsp = dmg * e, dsp * e
      if count then count("flameShockDot", "hits") end
    elseif FSD.tickCanCrit and U(S_SPELL_CRIT) < (spellCritPct + FSD.critBonusPercent) / 100 then
      dmg, dsp = dmg * spellCritMult, dsp * spellCritMult
      if count then count("flameShockDot", "crits") end
    else
      if count then count("flameShockDot", "hits") end
    end
    damage = damage + dmg
    if scoring then score(dmg, 0, dsp) end
    if count then count("flameShockDot", "damage", dmg) end
    fsTicksLeft = fsTicksLeft - 1
    if fsTicksLeft > 0 then push(now + FSD.tickPeriod, EV_FLAMESHOCK, gen) end
  end

  local handle
  do
    local flurryDuration = Data.flurry.duration
    local manaTickPeriod = mana0.tickPeriod
    local manaTick = mana0.regenCasting * mana0.tickPeriod
    -- Rotation events never reach here (see setRotation). Kinds are tested most frequent first.
    handle = function(ev)
      local kind = ev[3]
      if kind == EV_FLURRY then
        if ev[4] then
          flurryCharges = flurryFx.charges
          flurryGen = flurryGen + 1
          push(now + flurryDuration, EV_FLURRY_END, flurryGen)
          setSpeed(currentSpeed())
        elseif ev[5] and flurryCharges > 0 and flurryIcd <= now then
          flurryIcd = now + flurryFx.chargeIcd
          flurryCharges = flurryCharges - 1
          if flurryCharges == 0 then setSpeed(currentSpeed()) end
        end
      elseif kind == EV_JUDGEMENT then
        gainMana(jow.mana)
      elseif kind == EV_QUEUED then
        if ev[4] ~= queuedGen then return end
        local name = ev[5]
        local sp = spells[name]
        if gcdReady <= now and readyAt(sp) <= now and costOf(name, sp) <= manaNow then
          doCast(name)
          afterCast()
        end
      elseif kind == EV_MANA then
        gainMana(manaTick)
        push(now + manaTickPeriod, EV_MANA)
      elseif kind == EV_MAELSTROM then
        if mswUntil <= now then msw = 0 end
        if msw < maelstrom.maxStacks then msw = msw + 1 end
        mswUntil = now + maelstrom.duration
      elseif kind == EV_SEARING then
        if ev[4] ~= searingGen then return end
        enter(R.SEARING_ATTACK, ev[4] * 64 + (ST.ticks - ev[5] + 1))
        spellDamage("searingTotemAttack", STA, STA.average, nil, nil, true)
        local left = ev[5] - 1
        if left > 0 then push(now + ST.tickPeriod, EV_SEARING, ev[4], left) end
      elseif kind == EV_FLAMESHOCK then
        if ev[4] ~= fsGen then return end
        flameShockTick(ev[4])
      elseif kind == EV_FLURRY_END then
        if ev[4] == flurryGen and flurryCharges > 0 then
          flurryCharges = 0
          setSpeed(currentSpeed())
        end
      elseif kind == EV_DEVASTATION then
        edUntil = now + devastation.duration
      elseif kind == EV_CRUSADER then
        if ev[4] then hsUntilMh = now + crusader.duration else hsUntilOh = now + crusader.duration end
      elseif kind == EV_CHILI then
        chiliHit(ev)
      elseif kind == EV_FARSEER_END then
        setSpeed(currentSpeed())
      end
    end
  end

  ----------------------------------------------------------------------------
  -- Prepull and the fight loop
  ----------------------------------------------------------------------------

  for iter = 1, iterations do
    fightNo = iter
    if startFight then startFight(iter) end
    if h then
      for i = 1, hn do
        nFree = nFree + 1
        free[nFree] = h[i]
        h[i] = nil
      end
    else
      h = {}
    end
    hn, seq = 0, 0
    mhSwings, ohSwings, casts = 0, 0, {}
    enter(R.FIGHT, 1)
    fightEnd = duration0 + variation * (2 * U(S_FIGHT_END) - 1)
    local stopAt = window and tMax or fightEnd
    damage, winScore, dAP, dSP, wAt, wNow = 0, 0, 0, 0, nil, 0
    manaMax = char.mana
    manaNow = manaMax
    gcdReady, rotationAt, rotationGen, queuedGen = -huge, huge, 0, 0
    rotT, rotSeq = huge, 0
    cooldownReady = {}
    bfUntil, rotfUntil, hsUntilMh, hsUntilOh, edUntil, ccUntil = -huge, -huge, -huge, -huge, -huge, -huge
    flurryCharges, flurryIcd, flurryGen = 0, -huge, 0
    msw, mswUntil = 0, -huge
    ssDebuffUntil, ssDebuffCharges = -huge, 0
    wftProcUntil, wftCharges, wftIcd = -huge, 0, -huge
    fsUntil, fsTicksLeft, fsTickBase, fsTickSlope, fsGen, fsCast = -huge, 0, 0, 0, 0, 0
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
    speed = baseHaste
    local delay = floor(U(S_SWING_DELAY) * reaction * 1000) / 1000
    mhNext = delay
    ohNext = dualWield and (oh.speed / 2 + delay) or huge
    gcdReady = 0
    setRotation(0)

    while true do
      local t, kind = mhNext, 1
      if ohNext < t then t, kind = ohNext, 2 end
      local et, ekind = huge, 3
      local top = h[hn]
      if top then et = top[1] end
      if rotT < et or (rotT == et and top and rotSeq < top[2]) then et, ekind = rotT, 4 end
      if et < t then t, kind = et, ekind end
      if t >= stopAt then break end
      now = t
      if kind == 1 then
        syncOffHand()
        mhNext = now + mh.speed / speed
        mhSwings = mhSwings + 1
        enter(R.MAIN_HAND, mhSwings)
        swing("mainHand", true)
        reactToSwing(true)
      elseif kind == 2 then
        ohNext = now + oh.speed / speed
        ohSwings = ohSwings + 1
        enter(R.OFF_HAND, ohSwings)
        swing("offHand", false)
        reactToSwing(false)
      elseif kind == 4 then
        rotT = huge
        rotate()
        afterCast()
      else
        local ev = h[hn]
        h[hn] = nil
        hn = hn - 1
        handle(ev)
        nFree = nFree + 1
        free[nFree] = ev
      end
    end

    if window then
      local span = tMax - tMin
      dpsValues[iter] = winScore / span
      if pathwise then slopes.dAP[iter], slopes.dSP[iter] = dAP / span, dSP / span end
    else
      dpsValues[iter] = damage / fightEnd
      if pathwise then slopes.dAP[iter], slopes.dSP[iter] = dAP / fightEnd, dSP / fightEnd end
    end
  end

  if rng then rng.s1, rng.s2 = s1, s2 end
  return dpsValues, windfury, tally, slopes
end

return EventSim
