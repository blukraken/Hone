#!/usr/bin/env python3
"""Captures the MythicSim side of the engine tests into committed Lua data files.

Writes
  tests/addon/engine/data/snapshots.lua         normalized snapshots, one per case
  tests/addon/engine/data/windfury_mythicsim.lua Windfury proc counts per seed, per case

MythicSim resolves the fixtures' item ids into a character sheet (prepare). Each snapshot is
that sheet in Hone's own field names, plus the per-point stat multipliers MythicSim applies
(measured by preparing again with +100 on one stat). Windfury counts come from the sim's
per-action metrics, so no MythicSim source is changed or copied.

Proc rate = Windfury procs / eligible swings
  procs           every outcome of the main hand Windfury strike (439440), halved
  eligible swings landed hits of every spell the Windfury trigger hears, except its own strike

Usage  python3 tests/addon/engine/capture_mythicsim.py [--seeds N] [--iterations N]
Needs  third_party/mythicsim-forever-engine built at the pin (scripts/fixtures/build-fixtures).
"""

import json
import os
import re
import subprocess
from collections import Counter
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
OUT_DIR = os.path.join(ROOT, "tests", "addon", "engine", "data")
CHECKOUT = os.path.join(ROOT, "third_party", "mythicsim-forever-engine")
EXE = os.path.join(CHECKOUT, "target", "release",
                   "forever-engine.exe" if os.name == "nt" else "forever-engine")

# Each case is a fixture, optionally with one request edit. "windfury" marks the T1 set.
CASES = [
    {"id": "enh60-rockbiter-2h38-hitcap", "fixture": "enh60-rockbiter-2h38-hitcap"},
    {"id": "enh60-rockbiter-2h38-vs60", "fixture": "enh60-rockbiter-2h38-vs60"},
    {"id": "enh60-rockbiter-dw29-hit97", "fixture": "enh60-rockbiter-dw29-hit97"},
    {"id": "enh60-windfury-dw20-29", "fixture": "enh60-windfury-dw20-29", "windfury": True},
    {"id": "enh60-windfury-dw26-29", "fixture": "enh60-windfury-dw26-29", "windfury": True},
    {"id": "enh60-windfury-2h38-hitcap", "fixture": "enh60-rockbiter-2h38-hitcap",
     "windfury": True, "edit": {"imbueMh": "WindfuryWeapon"}},
]

# Bonus stat index (proto.Stat order) for each stat Hone weighs, and its sheet field.
STATS = {
    "strength": (0, "Strength"),
    "agility": (1, "Agility"),
    "intellect": (3, "Intellect"),
    "attack_power": (17, "AttackPower"),
    "hit_rating": (20, "MeleeHitRating"),
    "crit_rating": (21, "MeleeCritRating"),
    "haste_rating": (22, "MeleeHasteRating"),
}
PROTO_STATS_LEN = 41
# MythicSim seeds iteration i with seed + i, so batches need seeds this far apart.
SEED_STRIDE = 1000000
OUTCOMES = ("hits", "crits", "misses", "dodges", "parries", "glances", "blocks", "blockedCrits")
LANDED = ("hits", "crits", "glances", "blocks", "blockedCrits")


def run(cmd, capture=False):
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        sys.exit("command failed (%d): %s\n%s" % (res.returncode, " ".join(cmd), res.stderr))
    return res.stdout


def request_for(case):
    with open(os.path.join(FIXTURES, case["fixture"] + ".json"), encoding="utf-8") as fh:
        request = json.load(fh)["input"]["request"]
    if "edit" in case:
        player = request["raid"]["parties"][0]["players"][0]
        player["enhancementShaman"]["options"]["classOptions"].update(case["edit"])
    return request


def prepare(request, tmp, name):
    req_path = os.path.join(tmp, name + ".request.json")
    prep_path = os.path.join(tmp, name + ".prepared.json")
    with open(req_path, "w", encoding="utf-8") as fh:
        json.dump(request, fh)
    run([EXE, "prepare", "--request", req_path, "--go-rules", "--outfile", prep_path])
    check = json.loads(run([EXE, "check", "--infile", prep_path]))
    if not check.get("supported"):
        sys.exit("check refused %s: %s" % (name, check.get("reasons")))
    with open(prep_path, encoding="utf-8") as fh:
        return json.load(fh), prep_path


def with_bonus(request, index, amount):
    req = json.loads(json.dumps(request))
    player = req["raid"]["parties"][0]["players"][0]
    stats = (player.get("bonusStats") or {}).get("stats") or [0] * PROTO_STATS_LEN
    stats = list(stats) + [0] * (PROTO_STATS_LEN - len(stats))
    stats[index] += amount
    player["bonusStats"] = {"stats": stats}
    return req


def weapon(w):
    if not w or not w.get("swing_speed"):
        return None
    return {"min": w["base_damage_min"], "max": w["base_damage_max"], "speed": w["swing_speed"]}


def snapshot_of(case, request, prepared, multipliers):
    player = prepared["player"]
    sheet = player["stats"]
    melee = prepared["melee"]
    opts = request["raid"]["parties"][0]["players"][0]["enhancementShaman"]["options"]
    target = request["encounter"]["targets"][0]
    stats = {stat: sheet[field] for stat, (_, field) in STATS.items()}
    return {
        "id": case["id"],
        "class": "SHAMAN",
        "spec": "ENHANCEMENT",
        "level": player["level"],
        "targetLevel": target["level"],
        "stats": stats,
        "anchor": dict(stats),
        "sheet": {
            "attackPower": sheet["AttackPower"],
            "meleeCritPercent": sheet["PhysicalCritPercent"],
            "meleeHitPercent": sheet["PhysicalHitPercent"],
            "spellDamage": sheet["SpellDamage"],
            "spellCritPercent": sheet["SpellCritPercent"],
            "spellHitPercent": sheet["SpellHitPercent"],
        },
        "statMultipliers": multipliers,
        "weapons": {"mainHand": weapon(melee["main_hand"]),
                    "offHand": weapon(melee["off_hand"]) if melee["dual_wielding"] else None},
        "targetArmor": melee["defender_armor"],
        "imbues": {"mainHand": opts["classOptions"].get("imbueMh", "NoImbue"),
                   "offHand": opts.get("imbueOh", "NoImbue")},
        "talents": player["talents"],
        "reference": {
            "attackTable": {k: melee[k] for k in (
                "base_miss_chance", "hit_suppression", "melee_crit_suppression",
                "defender_dodge", "base_glance_chance", "glance_multiplier", "glance_spread")},
            "windfuryAttackPower": next((e["attack_power"] for e in prepared["effects"]
                                         if e["kind"] == "windfury_weapon"), None),
        },
    }


def measure_multipliers(request, tmp, base_sheet):
    out = {}
    for stat in ("strength", "agility", "intellect"):
        index, field = STATS[stat]
        prepared, _ = prepare(with_bonus(request, index, 100), tmp, "mult")
        out[stat] = round((prepared["player"]["stats"][field] - base_sheet[field]) / 100, 6)
    return out


def action_key(action_id):
    """Prepared action ids are snake_case, result metrics camelCase."""
    key = {}
    if "spell_id" in action_id:
        key["spellId"] = action_id["spell_id"]
    if "other_id" in action_id:
        key["otherId"] = action_id["other_id"]
    if "item_id" in action_id:
        key["itemId"] = action_id["item_id"]
    if "tag" in action_id:
        key["tag"] = action_id["tag"]
    return json.dumps(key, sort_keys=True)


def windfury_counts(prepared, result):
    wf = next(e for e in prepared["effects"] if e["kind"] == "windfury_weapon")
    spells = prepared["player"]["spells"]
    strike = action_key(spells[wf["main_hand_attack"]]["action_id"])
    heard = {action_key(spells[i]["action_id"]) for i in wf["trigger_spells"]} - {strike}
    metrics = {}
    for action in result["result"]["raidMetrics"]["parties"][0]["players"][0]["actions"]:
        metrics[json.dumps(action["id"], sort_keys=True)] = action["targets"][0]
    strikes = sum(metrics.get(strike, {}).get(k, 0) for k in OUTCOMES)
    if strikes % 2:
        sys.exit("odd Windfury strike count %d" % strikes)
    eligible = sum(metrics.get(key, {}).get(k, 0) for key in heard for k in LANDED)
    return strikes // 2, eligible, sorted(heard)


def metrics_of(result):
    out = {}
    for action in result["result"]["raidMetrics"]["parties"][0]["players"][0]["actions"]:
        out[json.dumps(action["id"], sort_keys=True)] = action["targets"][0]
    return out


def combat_of(prepared, tmp):
    """In-combat sheet values, as the game shows them with the fight's buffs up.

    attackPower is the most frequent melee AP the first iteration's log prints, which is the
    value with the steady raid buffs and no short procs. meleeCritPercent is the main hand
    auto attack's crit share plus the crit suppression the table took off it.
    """
    prepared = json.loads(json.dumps(prepared))
    prepared["sim"]["debug_first_iteration"] = True
    prep_path = os.path.join(tmp, "combat.prepared.json")
    out_path = os.path.join(tmp, "combat.result.json")
    with open(prep_path, "w", encoding="utf-8") as fh:
        json.dump(prepared, fh)
    run([EXE, "sim", "--infile", prep_path, "--gate", "--outfile", out_path])
    with open(out_path, encoding="utf-8") as fh:
        result = json.load(fh)
    maps = Counter(float(m) for m in re.findall(r"MAP: ([\d.]+)", result["result"]["logs"]))
    metrics = metrics_of(result)
    mh = metrics[json.dumps({"otherId": "OtherActionAttack", "tag": 1}, sort_keys=True)]
    crit = mh.get("crits", 0) / mh["casts"] + prepared["melee"]["melee_crit_suppression"]
    iterations = result["result"]["iterationsDone"]
    per_fight = {}
    for key, m in metrics.items():
        if m.get("casts"):
            per_fight[key] = round(m["casts"] / iterations, 4)
    reference = {
        "dps": result["result"]["raidMetrics"]["dps"]["avg"],
        "dpsStdev": result["result"]["raidMetrics"]["dps"]["stdev"],
        "iterations": iterations,
        "seed": prepared["sim"]["seed"],
        "castsPerFight": per_fight,
        "avgDuration": result["result"]["avgIterationDuration"],
    }
    combat = {"attackPower": maps.most_common(1)[0][0], "meleeCritPercent": round(crit * 100, 4)}
    return combat, reference


def lua(value, indent=""):
    if isinstance(value, dict):
        inner = indent + "  "
        parts = ["%s[%s] = %s," % (inner, json.dumps(k), lua(value[k], inner)) for k in sorted(value)]
        return "{\n" + "\n".join(parts) + "\n" + indent + "}"
    if isinstance(value, list):
        return "{ " + ", ".join(lua(v, indent) for v in value) + " }"
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return json.dumps(value)


def write_lua(path, header, value):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(header)
        fh.write("return " + lua(value) + "\n")


def main():
    seeds = 10
    iterations = 3000
    argv = sys.argv[1:]
    if "--seeds" in argv:
        seeds = int(argv[argv.index("--seeds") + 1])
    if "--iterations" in argv:
        iterations = int(argv[argv.index("--iterations") + 1])
    version = run([EXE, "version"]).strip()
    pin = run(["git", "-C", CHECKOUT, "rev-parse", "HEAD"]).strip()

    snapshots, windfury = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        for case in CASES:
            request = request_for(case)
            prepared, _ = prepare(request, tmp, "base")
            mult = measure_multipliers(request, tmp, prepared["player"]["stats"])
            snap = snapshot_of(case, request, prepared, mult)
            snap["combat"], snap["reference"]["mythicsim"] = combat_of(prepared, tmp)
            snapshots[case["id"]] = snap
            if not case.get("windfury"):
                continue
            runs = []
            for k in range(seeds):
                seed = 42 + k * SEED_STRIDE
                prepared["sim"]["seed"] = seed
                prepared["sim"]["iterations"] = iterations
                prepared["sim"]["debug_first_iteration"] = False
                prep_path = os.path.join(tmp, "seed.prepared.json")
                out_path = os.path.join(tmp, "seed.result.json")
                with open(prep_path, "w", encoding="utf-8") as fh:
                    json.dump(prepared, fh)
                run([EXE, "sim", "--infile", prep_path, "--gate", "--outfile", out_path])
                with open(out_path, encoding="utf-8") as fh:
                    result = json.load(fh)
                procs, eligible, heard = windfury_counts(prepared, result)
                runs.append({"seed": seed, "iterations": iterations,
                             "procs": procs, "eligible": eligible})
                print("%-28s seed %d procs %d eligible %d rate %.5f" % (
                    case["id"], seed, procs, eligible, procs / eligible))
            windfury[case["id"]] = {"heard": heard, "runs": runs}

    head = ("-- Generated by tests/addon/engine/capture_mythicsim.py. Do not edit by hand.\n"
            "-- MythicSim %s at %s.\n" % (version, pin))
    os.makedirs(OUT_DIR, exist_ok=True)
    write_lua(os.path.join(OUT_DIR, "snapshots.lua"), head, snapshots)
    write_lua(os.path.join(OUT_DIR, "windfury_mythicsim.lua"), head,
              {"engine": version, "pin": pin, "cases": windfury})


if __name__ == "__main__":
    main()
