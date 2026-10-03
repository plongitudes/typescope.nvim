# Contributing

## Getting set up

You need the same things TypeScope needs at runtime — Neovim 0.11+, the TreeSitter Python parser, and the oracle binary — plus [stylua](https://github.com/JohnnyMorganz/StyLua) and [luacheck](https://github.com/lunarmodules/luacheck) for the two contracts CI enforces, and a Rust toolchain to build and test the oracle.

```sh
brew install stylua luacheck   # or your platform's equivalent
scripts/build-oracle.sh        # fetches pyrefly at oracle/pyrefly.rev, applies oracle/patches, builds a debug binary (~4 min cold)
```

The Lua suites find `oracle/target/debug/typescope-oracle` on their own; without it, the suites that need it skip and say so. `(cd oracle && cargo test)` runs the oracle's own tests. Build output piles up fast (`oracle/target` reaches several GB); `make clean` clears it but keeps the release binary a local `oracle.path` may point at, and `make distclean` removes that and the fetched pyrefly too. [basedpyright](https://github.com/DetachHead/basedpyright) is not needed for the tests (a stand-in serves its `signatureHelp`), but it is what you want attached while you develop.

## The three gates

CI runs exactly these, and nothing else. Run them locally and you will not be surprised:

```sh
./tests/run.sh          # every suite, headless
luacheck lua/ tests/    # 0 warnings, 0 errors
stylua --check lua/ tests/
```

`tests/run.sh` adds your local `site` directory and `nvim-treesitter` to the runtimepath, because the Python parser and its highlight queries are what the call-site and injection code paths need. If the e2e suite fails and nothing else does, that is the first thing to check.

**stylua needs two passes to converge on this tree** — the second collapses calls the first has only just unwrapped. `stylua --check` immediately after `stylua` can still be red. Run `stylua lua/ tests/` twice.

A hand-wrapped table can opt out of formatting with `-- stylua: ignore`. Stylua only splits the rows that overflow, which leaves a ragged mix of one-line and five-line entries in a table whose whole job is to be scannable. None does today; if you add one, say why in a comment beside it.

Shadowing warnings (luacheck 411/421/431) are off for `tests/` only. The suites are long files of numbered, independent sections, and each one reusing `local r` for its own fixture is the point. `lua/` is strict and clean.

## Testing conventions

Some things this suite learned the hard way:

- **New renderer fixtures should carry non-ASCII.** Every fixture in `test_render.lua` was ASCII once, which is how three separate byte-versus-cell truncation bugs passed 1278 lines of golden tests.
- **Prefer invariants to goldens for anything positional.** `check_injections` asserts that every emitted injection describes a slice that fits its line, across every result. A golden asserting the text would not have caught the bug it was written for.
- **Sweep widths rather than picking one.** A truncation only misbehaves at the widths where its cut lands mid-character. Section 14 sweeps the rows, the panel and the doc view across widths 20..80 for this reason.
- **Headless float geometry is not real geometry.** With no UI attached there is no anchor to measure against, so assert on `nvim_win_get_config` rather than on positions a headless probe reports.
- **`tests/fixtures/shapes.py` is the capability sheet.** It records every class shape the oracle draws, as `typescope:` marker comments that `cargo test` in `oracle/` asserts against. A marker is a statement of policy (`design/oracle.md` §4), not a test expectation to be edited into passing: change one only with the rule that justifies it in the commit message. Add a marker whenever you teach the oracle a new shape.

## The README demo

The demo is recorded with [VHS](https://github.com/charmbracelet/vhs) from `demo/typescope.tape`, so re-record it after a change that shows up in it: `vhs demo/typescope.tape && demo/encode.sh` from the repo root. The tape writes lossless 2x frames, and `encode.sh` turns them into `demo/typescope.gif` (1x) and `demo/typescope.mp4` (2x), neither committed to `main`. GitHub only plays video it hosts itself, so upload the mp4 by dragging it into GitHub's README editor and put the resulting `user-attachments` URL under the gif. The tape's header lists what it needs. It runs nvim under `--clean` with `demo/init.lua`, so your own config stays out of the frame. The `e` beat's value comes from the model and changes from run to run; look over the new gif before publishing it. `demo/publish.sh` pushes the gif to the orphan `assets` branch, which the README links to; it lives there so installing the plugin doesn't download it. The README's stills of the float come from `demo/shots.tape` (`vhs demo/shots.tape && demo/publish.sh`), shot from `demo/shots.py` with heuristic examples, so they come out the same every run; `publish.sh` pushes them alongside the gif.

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
| ledger | the reading float: one line per node over a panel docked under the rows, showing the cursor's row |

## Releasing

The plugin and the oracle are released together under one version. The version lives in four places: `oracle/Cargo.toml`, its entry in `oracle/Cargo.lock`, `M.RELEASE` in `lua/typescope/oracle.lua` (the release the plugin downloads its binary from), and the dated heading in `CHANGELOG.md`. `scripts/release.sh` keeps them in step, in two halves either side of the release PR's merge.

**Pick the version from `[Unreleased]`.** Versions follow semver with the 0.x convention the changelog states: anything under Removed or Upgrading, or any setting that now warns and is ignored, makes a minor bump; fixes alone make a patch. The warnings in `lua/typescope/config.lua` name the version a key went away in, so check they agree with what you pick.

```sh
git checkout -b release/v0.4.0 main
scripts/release.sh prepare 0.4.0   # bumps the four places, dates [Unreleased]
```

`prepare` refuses a malformed version, one that is already tagged or not after the latest tag, an empty `[Unreleased]`, a dirty tree, and running on main. It doesn't write the notes: finish the section it dated (an intro paragraph, then Upgrading, Removed, Changed, Added, Fixed, Deprecated, Development as they apply), commit, and merge the PR.

```sh
git checkout main && git pull --ff-only
scripts/release.sh tag             # checks, shows the version and notes, asks y/N
git push origin v0.4.0
```

`tag` reads the version back from `M.RELEASE`, checks the Cargo files agree, and refuses unless the checkout is clean and exactly `origin/main`: behind means the tag would miss the merged release, ahead means it would point at commits main doesn't have. On a yes it creates an annotated tag whose message is the changelog section. It doesn't push; pushing the tag is what publishes.

The pushed tag runs `.github/workflows/release.yml`, which checks again: the tagged commit must be on main, and `M.RELEASE` and `oracle/Cargo.toml` must match the tag. It then builds the three binaries and publishes them with `SHA256SUMS`. If it fails after the tag is pushed, fix forward on main, then delete the tag (`git push origin :refs/tags/v0.4.0 && git tag -d v0.4.0`) and run `tag` again.

## Issues

Work is tracked in [beads](https://github.com/steveyegge/beads) under `.beads/`, which is not committed. If you are opening a PR from outside, a plain GitHub issue is fine — no need to install anything.

`AGENTS.md` is instructions for AI coding agents working in this repo. It is not a contributor guide, and its workflow rules are not aimed at you.
