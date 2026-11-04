# MythicSim reference fixtures

Synthetic reference results for Enhancement Shaman, produced by the MythicSim Forever engine
at the commit in `PIN`. Evidence class is `synthetic`: they pin what MythicSim computes, not
what the game does.

## Regenerate

```sh
scripts/fixtures/setup-lua                 # Lua 5.1 into build/lua/
scripts/fixtures/build-fixtures            # clones the pin into third_party/, builds, rewrites the JSON
build/lua/bin/lua tests/addon/fixture_runner.lua --engine identity
```

`build-fixtures` checks out the pinned commit, confirms the LICENSE is MIT, runs
`cargo build --release --locked`, and rewrites every `<id>.json`. Output is deterministic
(fixed seed), so a rerun gives byte-identical files.

## Fixture record

| Field | Meaning |
| --- | --- |
| `id` | Readable name |
| `pin` | MythicSim commit |
| `evidence_class` | Always `synthetic` |
| `command` | The three engine invocations (`prepare`, `check`, `sim`) |
| `input` | `request` is the exact MythicSim request, `source` and `source_sha256` name the file it came from, `edits` lists any change made to it |
| `check` | The coverage gate's verdict, which must be `supported: true` |
| `output` | `dps` (mean), `dps_stdev`, `dps_min`, `dps_max`, `iterations`, `seed`, `engine`, `weights` |
| `tolerance` | `null`. VALID sets it later from measured noise |

## Weights are derived

MythicSim's CLI reports DPS only. It has no stat weights or derivatives. `build-fixtures`
derives them: it reruns the same request with `bonusStats` raised by 100 on one stat, with the
same seed, and records `(dps_plus - dps_base) / 100`. The stats are strength, agility,
intellect, attack power, and melee hit, crit and haste rating. Treat these as finite-difference
slopes at +100, not as MythicSim's own stat weights.

## Why these five

All run at player level 60 with the Go-reference rules (`--go-rules`). Four are MythicSim's own
unmodified example requests. MythicSim's Forever-rules preparation refuses the legacy talent
strings those examples carry, so `--go-rules` is required.

| id | Source request | Covers |
| --- | --- | --- |
| `enh60-rockbiter-2h38-hitcap` | `production-enhancement-shaman` | Rockbiter preset. Two-hander, 3.8 speed. Melee hit 9.0%, exactly the special-attack cap against a level 63 target (8% miss plus 1% suppression), so hit rating weighs 0 |
| `enh60-windfury-dw26-29` | `enhancement-shaman-dual-wield-windfury-flametongue` | Windfury preset. Dual wield, 2.6 main hand and 2.9 off hand. Hit 9.0% is under the white-hit cap, so hit rating has a large weight |
| `enh60-rockbiter-dw29-hit97` | `enhancement-shaman-preset-grace-of-air` | Rockbiter on a dual wield build, 2.9/2.9, different talents. Hit 9.7%, just past the special-attack cap |
| `enh60-windfury-dw20-29` | `enhancement-shaman-iceblade-hacker` | Contrasting weapon speed. Windfury with a 2.0 main hand against the 3.8 two-hander of the first fixture |
| `enh60-rockbiter-2h38-vs60` | `production-enhancement-shaman`, target level edited 63 to 60 | The second level axis. Same build as the first, so the only change is the level gap, which moves the miss chance and the hit cap (9.0% hit is now 4 points over the special-attack cap) |

## Level limit

The pinned engine fixes the player at level 60. Its coverage gate refuses any other player
level, and the request path has no player level field. Only the target level varies (60 to 63).
The "two levels" coverage therefore comes from the target level, not the character level.
`scripts/fixtures/probe-levels` records the full level table.
