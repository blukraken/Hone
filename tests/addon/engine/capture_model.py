"""The Enhancement model inputs a snapshot carries, read from MythicSim's prepared input.

capture_mythicsim.py calls model_of() for each case and stores the result as the snapshot's
`model` field. These are the numbers a character sheet, its buffs and its spellbook give the
event path. RUNTIME will have to produce the same fields in game.

Every number comes from the prepared input of the pinned engine, or from preparing again with
one stat raised (per_point). No MythicSim source is read or copied.
"""

import json

NS = 1e9

# The weighed stats, their bonusStats index and the sheet fields a point of each may move.
SHEET_FIELDS = {
    "attackPower": "AttackPower",
    "meleeCritPercent": "PhysicalCritPercent",
    "meleeHitPercent": "PhysicalHitPercent",
    "spellDamage": "SpellDamage",
    "spellCritPercent": "SpellCritPercent",
    "spellHitPercent": "SpellHitPercent",
    "mana": "Mana",
    "meleeHasteRating": "MeleeHasteRating",
}

# Rotation steps by the spell id the priority list casts, with the condition that marks a variant.
EARTH_TOTEM, AIR_TOTEM = 25361, 25359
STORMSTRIKE, LIGHTNING_BOLT, SEARING_TOTEM = 17364, 15208, 10438
FLAME_SHOCK, FIRE_NOVA, EARTH_SHOCK = 29228, 408345, 10414


def spell_by_id(prepared, spell_id, tag=0):
    for index, spell in enumerate(prepared["player"]["spells"]):
        aid = spell.get("action_id") or {}
        if aid.get("spell_id") == spell_id and aid.get("tag", 0) == tag:
            return index, spell
    return None, None


def other_by_id(prepared, other_id, tag):
    for index, spell in enumerate(prepared["player"]["spells"]):
        aid = spell.get("action_id") or {}
        if aid.get("other_id") == other_id and aid.get("tag", 0) == tag:
            return index, spell
    return None, None


def effect(prepared, kind):
    return next((e for e in prepared["effects"] if e["kind"] == kind), None)


def aura(prepared, label):
    return next((a for a in prepared["player"]["auras"] if a["label"] == label), None)


def target_aura(prepared, label_prefix):
    return next((a for a in prepared["target"]["auras"] if a["label"].startswith(label_prefix)), None)


SCHOOLS = {1: "physical", 2: "holy", 4: "fire", 8: "nature", 16: "frost", 32: "shadow", 64: "arcane"}


def spell_numbers(spell):
    """Damage, cost and timing of one prepared spell, in seconds and Hone's names."""
    out = {
        "school": SCHOOLS.get(spell.get("school") or 0, "none"),
        "coefficient": spell.get("bonus_coefficient") or 0.0,
        "bonusSpellPower": (spell.get("bonus_base_damage") or 0.0) + (spell.get("bonus_spell_damage") or 0.0),
        "multiplier": (spell.get("damage_multiplier") or 0.0) * (spell.get("damage_multiplier_additive") or 0.0),
        "critBonusPercent": spell.get("bonus_crit_percent") or 0.0,
        "binary": "SpellFlagBinary" in (spell.get("flags") or []),
        "cost": (spell.get("default_cast") or {}).get("cost", 0.0),
        "gcd": (spell.get("default_cast") or {}).get("gcd_ns", 0) / NS,
        "castTime": (spell.get("default_cast") or {}).get("cast_time_ns", 0) / NS,
    }
    if spell.get("damage_effect"):
        out["average"] = spell["damage_effect"]["average"]
        out["variance"] = spell["damage_effect"]["variance"]
    if spell.get("cd"):
        out["cooldown"] = spell["cd"]["duration_ns"] / NS
        out["cooldownGroup"] = spell["cd"]["timer"]
    if spell.get("dot"):
        dot = spell["dot"]
        out["ticks"] = dot["base_tick_count"]
        out["tickPeriod"] = dot["base_tick_length_ns"] / NS
        out["tickCoefficient"] = dot["bonus_coefficient"]
    return out


def combos(prepared):
    """Stat totals by temporary aura: the aura-free sheet, each aura's additive change and Blood
    Fury's multipliers."""
    sa = effect(prepared, "stat_auras")
    labels, table = sa["auras"], sa["combos"]
    base = table[0]
    fields = sorted(base)
    delta = {}
    for bit, label in enumerate(labels):
        row = table[1 << bit]
        delta[label] = {f: row.get(f, 0.0) - base.get(f, 0.0) for f in fields
                        if abs(row.get(f, 0.0) - base.get(f, 0.0)) > 1e-9}
    bf = None
    if "Blood Fury" in labels:
        row = table[1 << labels.index("Blood Fury")]
        bf = {"attackPowerMultiplier": round(row["AttackPower"] / base["AttackPower"], 6),
              "spellDamageMultiplier": round(row["SpellDamage"] / base["SpellDamage"], 6)}
    # Additivity check on a pair of additive auras: Holy Strength (MH) with Battle Shout.
    if "Holy Strength (MH)" in labels and "Battle Shout (External)" in labels:
        a, b = labels.index("Holy Strength (MH)"), labels.index("Battle Shout (External)")
        both = table[(1 << a) | (1 << b)]["AttackPower"]
        parts = base["AttackPower"] + delta[labels[a]].get("AttackPower", 0) + delta[labels[b]].get("AttackPower", 0)
        assert abs(both - parts) < 1e-6, "stat auras are not additive in attack power"
    return labels, base, delta, bf


def rotation_of(request):
    player = request["raid"]["parties"][0]["players"][0]
    rot = player["rotation"]
    prepull = []
    for a in rot.get("prepullActions", []):
        sid = a["action"]["castSpell"]["spellId"]["spellId"]
        at = float(a["doAtValue"]["const"]["val"].rstrip("s"))
        prepull.append({"spell": {EARTH_TOTEM: "strengthOfEarthTotem", AIR_TOTEM: "graceOfAirTotem",
                                  SEARING_TOTEM: "searingTotem"}[sid], "at": at})
    steps = []
    for entry in rot["priorityList"]:
        act = entry["action"]
        if "autocastOtherCooldowns" in act:
            steps.append("cooldowns")
            continue
        sid = act["castSpell"]["spellId"]["spellId"]
        cond = json.dumps(act.get("condition", {}))
        if sid == EARTH_TOTEM:
            steps.append("strengthOfEarthTotem")
        elif sid == AIR_TOTEM:
            steps.append("graceOfAirTotem")
        elif sid == STORMSTRIKE:
            steps.append("stormstrike")
        elif sid == LIGHTNING_BOLT:
            steps.append("lightningBoltMaelstrom")
        elif sid == SEARING_TOTEM:
            steps.append("searingTotem")
        elif sid == FLAME_SHOCK:
            steps.append("flameShock")
        elif sid == FIRE_NOVA and "16246" in cond:
            steps.append("fireNovaClearcasting")
        elif sid == FIRE_NOVA and "currentManaPercent" in cond:
            steps.append("fireNovaMana")
        elif sid == EARTH_SHOCK:
            steps.append("earthShock")
        else:
            raise SystemExit("unknown rotation step %s %s" % (sid, cond))
    return {"prepull": prepull, "steps": steps, "fireNovaManaPercent": 30, "searingMinRemaining": 20}


# Melee spells a proc can hear, by prepared action id, in Hone's names.
MELEE_NAMES = {
    ("spell", 17364, 1): "stormstrikeMainHand",
    ("spell", 17364, 2): "stormstrikeOffHand",
    ("spell", 439440, 0): "windfuryMainHand",
    ("spell", 439441, 0): "windfuryOffHand",
    ("other", "OtherActionAttack", 1): "mainHand",
    ("other", "OtherActionAttack", 2): "offHand",
    ("other", "OtherActionAttack", 25584): "windfuryTotemAttack",
}


def melee_name(prepared, index):
    aid = prepared["player"]["spells"][index].get("action_id") or {}
    if "spell_id" in aid:
        return MELEE_NAMES.get(("spell", aid["spell_id"], aid.get("tag", 0)))
    if "other_id" in aid:
        return MELEE_NAMES.get(("other", aid["other_id"], aid.get("tag", 0)))
    return None


def names_of(prepared, indices):
    return sorted({melee_name(prepared, i) for i in indices} - {None})


def chances_by_name(prepared, chances):
    out = {}
    for c in chances:
        name = melee_name(prepared, c["spell"])
        if name:
            out[name] = c["chance"]
    return out


def chance_by_hand(prepared, chances, mh_index, oh_index):
    """A per-spell proc chance list, reduced to one chance per hand's auto attack."""
    by_spell = {c["spell"]: c["chance"] for c in chances}
    return {"mainHand": by_spell.get(mh_index), "offHand": by_spell.get(oh_index)}


def model_of(prepared, request, per_point):
    player = prepared["player"]
    stats = player["stats"]
    labels, base, delta, bf = combos(prepared)
    mh_index, mh_auto = other_by_id(prepared, "OtherActionAttack", 1)
    oh_index, _ = other_by_id(prepared, "OtherActionAttack", 2)
    rotation = rotation_of(request)

    # Auras up all fight: a fixed uptime raid buff and the totems the prepull casts.
    steady_labels = [lbl for lbl in labels if lbl == "Battle Shout (External)"]
    if any(p["spell"] == "strengthOfEarthTotem" for p in rotation["prepull"]):
        steady_labels.append("Strength Of Earth Totem (Self)")
    if any(p["spell"] == "graceOfAirTotem" for p in rotation["prepull"]):
        steady_labels.append("Grace Of Air Totem (Self)")
    steady = {}
    for lbl in steady_labels:
        for f, v in delta[lbl].items():
            steady[f] = steady.get(f, 0.0) + v

    sheet = {
        "attackPower": base["AttackPower"] + steady.get("AttackPower", 0.0),
        "meleeCritPercent": base["PhysicalCritPercent"] + steady.get("PhysicalCritPercent", 0.0),
        "meleeHitPercent": stats["PhysicalHitPercent"],
        "spellDamage": base["SpellDamage"] + steady.get("SpellDamage", 0.0),
        "fireDamage": stats.get("FireDamage", 0.0),
        "natureDamage": stats.get("NatureDamage", 0.0),
        "spellCritPercent": base["SpellCritPercent"] + steady.get("SpellCritPercent", 0.0),
        "spellHitPercent": stats["SpellHitPercent"],
        "mana": player["mana"]["max"],
        "meleeCritBonusPercent": mh_auto.get("bonus_crit_percent", 0.0),
    }

    out = {
        "sheet": sheet,
        "perPoint": per_point,
        "steadyAuras": steady_labels,
        "rotation": rotation,
        "reactionTime": player["reaction_ns"] / NS,
    }

    melee = prepared["melee"]
    out["attackTable"] = {
        "miss": melee["base_miss_chance"], "dodge": melee["defender_dodge"],
        "glance": melee["base_glance_chance"], "glanceMultiplier": melee["glance_multiplier"],
        "glanceSpread": melee["glance_spread"], "hitSuppression": melee["hit_suppression"],
        "critSuppression": melee["melee_crit_suppression"],
    }
    out["armor"] = melee["defender_armor"]
    out["spellMiss"] = player["attack_table"]["base_spell_miss_chance"]

    buffs = {}
    bf_eff = effect(prepared, "blood_fury")
    if bf_eff and bf:
        a = aura(prepared, bf_eff["aura"])
        buffs["bloodFury"] = dict(bf, duration=a["duration_ns"] / NS, cooldown=a["icd"]["duration_ns"] / NS)
    rotf = effect(prepared, "rage_of_the_farseer")
    if rotf:
        a = aura(prepared, rotf["aura"])
        _, s = spell_by_id(prepared, rotf["spell_id"])
        buffs["rageOfTheFarseer"] = {"speed": rotf["melee_speed_multiplier"], "duration": a["duration_ns"] / NS,
                                     "cooldown": s["cd"]["duration_ns"] / NS}
    crusader = effect(prepared, "crusader")
    if crusader:
        a = aura(prepared, crusader["mh_aura"])
        by_spell = {c["spell"]: c["chance"] for c in crusader["chances"]}
        buffs["crusader"] = {
            "attackPower": delta[crusader["mh_aura"]]["AttackPower"],
            "duration": a["duration_ns"] / NS,
            "chance": {"mainHand": by_spell.get(mh_index), "offHand": by_spell.get(oh_index)},
            "chances": chances_by_name(prepared, crusader["chances"]),
        }
    wft = effect(prepared, "windfury_totem")
    wfw = effect(prepared, "windfury_weapon")
    if wft and not (wfw and wfw.get("blocks_windfury_totem")):
        proc = aura(prepared, wft["proc_aura"])
        trig = aura(prepared, wft["trigger_aura"])
        buffs["windfuryTotem"] = {
            "chance": wft["trigger_proc_chance"],
            "icd": trig["icd"]["duration_ns"] / NS if trig.get("icd") else 0.0,
            "attackPower": delta[wft["proc_aura"]]["AttackPower"],
            "charges": proc["max_stacks"],
            "duration": proc["duration_ns"] / NS,
            "triggers": names_of(prepared, wft["trigger_spells"]),
            "spenders": names_of(prepared, wft["spend_spells"]),
        }
    out["buffs"] = buffs

    spells = {}
    for name, sid, tag in [("stormstrike", STORMSTRIKE, 0), ("lightningBolt", LIGHTNING_BOLT, 0),
                           ("earthShock", EARTH_SHOCK, 0), ("flameShock", FLAME_SHOCK, 0),
                           ("flameShockDot", FLAME_SHOCK, 1), ("fireNova", FIRE_NOVA, 0),
                           ("searingTotem", SEARING_TOTEM, 0), ("strengthOfEarthTotem", EARTH_TOTEM, 0),
                           ("graceOfAirTotem", AIR_TOTEM, 0)]:
        _, s = spell_by_id(prepared, sid, tag)
        if s:
            spells[name] = spell_numbers(s)
    fn = effect(prepared, "fire_nova")
    if fn:
        spells["fireNova"]["average"], spells["fireNova"]["variance"] = fn["base_damage"], 0.0
    fs = effect(prepared, "flame_shock")
    if fs:
        spells["flameShockDot"]["tickBase"] = fs["tick_base"]
        spells["flameShockDot"]["tickCanCrit"] = fs["tick_can_crit"]
    st = effect(prepared, "searing_totem")
    if st:
        _, attack = spell_by_id(prepared, st["attack_spell_id"])
        spells["searingTotemAttack"] = dict(spell_numbers(attack), average=st["attack_damage"], variance=0.0)
        spells["searingTotem"]["duration"] = st["duration_ns"] / NS
    ss = effect(prepared, "stormstrike")
    if ss:
        debuff = target_aura(prepared, ss["aura"])
        spells["stormstrike"]["debuffMultiplier"] = ss["damage_multiplier"]
        spells["stormstrike"]["debuffDuration"] = debuff["duration_ns"] / NS
        spells["stormstrike"]["debuffCharges"] = debuff["max_stacks"]
    ft = effect(prepared, "flametongue_weapon")
    if ft:
        hand = ft["hands"][0]
        spells["flametongue"] = dict(spell_numbers(player["spells"][hand["spell"]]), average=hand["base_damage"],
                                     variance=0.0, triggers=names_of(prepared, hand["trigger_spells"]))
    if wfw:
        spells["windfury"] = {"attackPower": wfw["attack_power"],
                              "triggers": names_of(prepared, wfw["trigger_spells"])}
    out["spells"] = spells

    talents = {}
    ed = effect(prepared, "elemental_devastation")
    if ed:
        a = aura(prepared, ed["aura"])
        talents["elementalDevastation"] = {"meleeCritPercent": ed["melee_crit"], "duration": a["duration_ns"] / NS}
    ef = effect(prepared, "elemental_focus")
    if ef:
        a = aura(prepared, ef["aura"])
        talents["elementalFocus"] = {"chance": ef["proc_chance"], "duration": a["duration_ns"] / NS}
    mw = effect(prepared, "maelstrom_weapon")
    if mw:
        a = aura(prepared, mw["aura"])
        talents["maelstromWeapon"] = {
            "chance": chance_by_hand(prepared, mw["chances"], mh_index, oh_index),
            "chances": chances_by_name(prepared, mw["chances"]),
            "maxStacks": a["max_stacks"], "duration": a["duration_ns"] / NS}
    fl = effect(prepared, "flurry")
    if fl:
        talents["flurry"] = {"speed": fl["melee_speed_multiplier"], "charges": fl["max_stacks"],
                             "chargeIcd": fl["charge_icd_ns"] / NS}
    out["talentEffects"] = talents

    mana = player["mana"]
    jow = effect(prepared, "judgement_of_wisdom")
    pot = effect(prepared, "potion_mana")
    rune = effect(prepared, "conjured_mana")
    out["mana"] = {
        "max": mana["max"],
        "regenCasting": mana["regen_per_second_casting"],
        "tickPeriod": 2.0,
        "judgement": jow and {"chance": jow["proc_chance"], "mana": jow["mana"]},
        "potion": pot and {"gain": pot["gains"][0]["min"], "cooldown": 120.0,
                           "window": pot["regen_window_seconds"]},
        "rune": rune and rune.get("selected") and {"gain": rune["gains"][0]["min"], "cooldown": 120.0,
                                                   "window": rune["regen_window_seconds"]},
    }

    procs = []
    chili = effect(prepared, "dragonbreath_chili")
    if chili:
        _, s = spell_by_id(prepared, chili["spell_id"])
        a = aura(prepared, chili["trigger_aura"])
        procs.append({"name": "dragonbreathChili", "kind": "spell", "chance": chili["proc_chance"],
                      "icd": a["icd"]["duration_ns"] / NS, "min": chili["roll_min"], "max": chili["roll_max"],
                      "coefficient": s["bonus_coefficient"], "school": SCHOOLS[s["school"]],
                      "multiplier": s["damage_multiplier"] * s["damage_multiplier_additive"],
                      "critBonusPercent": s["bonus_crit_percent"], "delay": chili["delay_ns"] / NS,
                      "triggers": names_of(prepared, chili["trigger_spells"])})
    for e in prepared["effects"]:
        if e["kind"] == "spell_data_damage_proc":
            s = player["spells"][e["spell"]]
            hands = chance_by_hand(prepared, e["chances"], mh_index, oh_index)
            hand = "mainHand" if hands["mainHand"] else "offHand"
            procs.append({"name": e["trigger_aura"], "kind": "weaponCritOnly", "hand": hand,
                          "chance": hands[hand] * e["proc_chance"],
                          "chances": chances_by_name(prepared, e["chances"]),
                          "min": e["roll"][0], "max": e["roll"][1], "school": SCHOOLS[s["school"]],
                          "multiplier": s["damage_multiplier"] * s["damage_multiplier_additive"],
                          "critBonusPercent": s["bonus_crit_percent"]})
    out["procs"] = procs
    sync = effect(prepared, "weapon_sync")
    out["weaponSync"] = {"auto": "delay"}.get(sync["sync"], sync["sync"]) if sync else "none"
    return out


def per_point_of(base_stats, plus_stats, amount):
    return {name: round((plus_stats.get(field, 0.0) - base_stats.get(field, 0.0)) / amount, 9)
            for name, field in SHEET_FIELDS.items()
            if abs(plus_stats.get(field, 0.0) - base_stats.get(field, 0.0)) > 1e-12}
