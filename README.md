# Hone

A World of Warcraft: Forever addon that keeps your stat weights personal and current.
Hone recalculates them from a combat model whenever your gear, talents or trained
spells change, and shows them on the character sheet and on item tooltips. There's
nothing to import, no Sim button and nothing to reset.

Enhancement Shaman is the first supported spec. Hone is in early development and has
no release yet.

## Layout

| Path | Contents |
| --- | --- |
| `Hone/` | The addon itself. Release packages contain only this folder. |
| `tests/addon/` | Unit tests for the addon's Lua code |
| `tests/fixtures/` | Frozen reference results the model is checked against |
| `scripts/` | Build and CI scripts |

## How the numbers are computed

A `METHODOLOGY.md` explaining the model, its reference checks and how to rerun them
will be published before the first release.

## License

MIT. See `LICENSE`.
