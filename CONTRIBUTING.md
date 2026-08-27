# Contributing

## Getting set up

You need the same things TypeScope needs at runtime — Neovim 0.10+, [basedpyright](https://github.com/DetachHead/basedpyright), and the TreeSitter Python parser — plus [stylua](https://github.com/JohnnyMorganz/StyLua) and [luacheck](https://github.com/lunarmodules/luacheck) for the two contracts CI enforces.

```sh
brew install stylua luacheck   # or your platform's equivalent
```

## The three gates

CI runs exactly these, and nothing else. Run them locally and you will not be surprised:

```sh
./tests/run.sh          # all seven suites, headless
luacheck lua/ tests/    # 0 warnings, 0 errors
stylua --check lua/ tests/
```

`tests/run.sh` adds your local `site` directory and `nvim-treesitter` to the runtimepath, because the Python parser and its highlight queries are what the extraction and injection code paths need. If the e2e suite fails and nothing else does, that is the first thing to check.

**stylua needs two passes to converge on this tree** — the second collapses calls the first has only just unwrapped. `stylua --check` immediately after `stylua` can still be red. Run `stylua lua/ tests/` twice.

Two tables opt out of formatting with `-- stylua: ignore`: the builtins list in `extract/python.lua` and the fixture table in `spike.lua`. Both are hand-wrapped, and stylua only splits the rows that overflow, which leaves a ragged mix of one-line and five-line entries in tables whose whole job is to be scannable. If you add a similar table, mark it the same way and say why.

Shadowing warnings (luacheck 411/421/431) are off for `tests/` only. The suites are long files of numbered, independent sections, and each one reusing `local r` for its own fixture is the point. `lua/` is strict and clean.

## Testing conventions

Some things this suite learned the hard way:

- **New renderer fixtures should carry non-ASCII.** Every fixture in `test_render.lua` was ASCII once, which is how three separate byte-versus-cell truncation bugs passed 1278 lines of golden tests.
- **Prefer invariants to goldens for anything positional.** `check_injections` asserts that every emitted injection describes a slice that fits its line, across every result. A golden asserting the text would not have caught the bug it was written for.
- **Sweep widths rather than picking one.** A truncation only misbehaves at the widths where its cut lands mid-character. Section 14 sweeps every layout across widths 20..80 for this reason.
- **Headless float geometry is not real geometry.** With no UI attached there is no anchor to measure against, so assert on `nvim_win_get_config` rather than on positions a headless probe reports.
- **`tests/fixtures/shapes.py` is the capability sheet.** It records every class shape the extractor reads *and* the ones it doesn't, as `typescope:` marker comments that `test_shapes.lua` asserts against. Markers reading `fields=NONE` document real gaps on purpose: closing one turns that suite red until the marker is updated, which is how the sheet stays honest. Add a marker whenever you teach the extractor a new shape.

## Style

Beyond what stylua and luacheck enforce:

Comments here carry *why*, not *what*. A lot of them record a thing that was tried and abandoned, with the observation that killed it. That is deliberate — it is what stops the same idea being re-attempted — so when you change code that has one, update the reasoning rather than deleting it.

The vocabulary is settled and worth keeping straight, since several of these words were ambiguous until recently:

| word | means |
| --- | --- |
| typing surface | the insert-mode surface that replaces signature help |
| ramp | the glyph scale for the pending animation, least → most |
| rung | one step of the ramp |
| bar | the drawn row of cells a wave travels through |
| segment | a `{text, group}` run, the renderer's primitive |
| ledger | the reading-float layout with a cursor-follow detail block |

## Issues

Work is tracked in [beads](https://github.com/steveyegge/beads) under `.beads/`, which is not committed. If you are opening a PR from outside, a plain GitHub issue is fine — no need to install anything.

`AGENTS.md` is instructions for AI coding agents working in this repo. It is not a contributor guide, and its workflow rules are not aimed at you.
