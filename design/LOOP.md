# Loop rules for the oracle rewrite

Read this at the start of every tick. The plan is `design/oracle.md`; the work queue is `bd ready`. One bead per tick.

## Each tick

1. `bd ready`; claim the lowest-numbered ready bead **under epic `5ag`** with `bd update <id> --status=in_progress`. Other open beads (`o6s`, `5zm`, `98n`, …) are not this loop's. If no `5ag` bead is ready, the tick is a `noop` — say why. When none remain open, stop the loop with a final summary.
2. Do the bead. Commit per coherent step on the current branch (never `main`), message says what and why, attribution line included.
3. `./tests/run.sh` green (and `cargo test` in `oracle/` when Rust changed) before every commit. A commit that turns a test red is not a commit.
4. Close with `bd close <id>` — explicit id, never bare — after `bd update <id> --notes` that **reads the existing notes first** (`--notes` replaces). 5–10 bullets: decisions, gotchas, deviations.
5. Append to `design/LOG.md`: date, bead, what was done, what was verified, what is next, what is blocked. Three to six lines.
6. Kill every process you spawned (nvim, the oracle, langservers). `pgrep -fl "nvim|typescope-oracle|basedpyright"` should show nothing of yours.

## Budget

- **25 ticks** total, then stop and summarize regardless of state. A slow grind that never trips the three-tick rule is still a grind.
- One Cargo target dir: once `oracle/` builds, `cargo clean` the spike crate. Dev profile for tests; release builds only when a bead needs the shipped binary.
- Check `memory_pressure` before a release build; under ~15% free, skip the build this tick. It is an 8 GB laptop Tony is also using.
- Network only to `github.com/facebook/pyrefly` (submodule), crates.io (cargo), and this repo's GitHub Releases (download bead). Nothing else gets installed or fetched to solve a problem; that is a `QUESTIONS.md` entry.

## Scope fence

- May replace: `lua/typescope/resolve.lua`, `lua/typescope/extract/`, the resolver parts of `lua/typescope/lsp.lua`, `tests/mock_server.lua`, `tests/e2e_*.lua`, `tests/test_extract.lua`.
- May edit for the contract only: `render.lua`, `interact.lua`, `model.lua`, `insert.lua`, `config.lua`, `health.lua`, `init.lua`, `examples/`.
- New: `oracle/` (Rust), `lua/typescope/oracle.lua`, `design/LOG.md`, CI workflow.
- Do not touch: the float geometry, keymaps, layouts, styles, highlights, the examples prompts. No new features beyond `design/oracle.md`. "While I'm here" is a bead to file, not a change to make.
- **Before deleting a function from `resolve.lua` or `extract/python.lua`, read its comments.** They record the behaviors behind a hundred fixed bugs (receiver by position, the declaration-scope confusion, the stub hop, `= …`, informative inference, the cancelled-recurse restore). Each recorded behavior is either carried into `policy.rs` / a test, or written into `design/oracle.md` as deliberately dropped, before the function goes.
- `design/oracle.md` §4–§8 may be corrected as real code teaches better — with a `LOG.md` line saying what changed and why. §2 (the decisions) is never edited by the loop.

## Stop conditions — end the tick and wait

- Any change to `~/.config/nvim`, mason, or anything outside this repo and its scratchpad.
- Any external action: pushing to `main`, creating a GitHub release, opening a PR anywhere, publishing anything.
- Deleting or weakening a test instead of fixing the code.
- The next step would be a monkeypatch, a hack around something pyrefly cannot do, or a second source patch to pyrefly. Write it up in the bead and `design/QUESTIONS.md` instead.
- A pydantic or other checker-disagreement regression found by the parity gate. Report, do not work around.
- A bead has gone three ticks without a commit. Stop and explain; the decomposition is probably wrong, and that is Tony's call.

## Verification rules

- A parity claim is a fixture diff, never a sentence. Extend the `typescope:` markers in `tests/fixtures/shapes.py`; do not bypass them.
- **A marker is policy, not a test expectation.** Changing what a `typescope:` marker asserts is a behavior change: the commit message cites the `design/oracle.md` §4 rule that justifies it, or the change does not happen.
- When the full output matters — test results, `git log`, a diff you are deciding on — redirect it to a file and read that. The filtered terminal view elides lines with no marker.
- Float geometry is verified by screenshot. Headless float probes lie.
- Memory numbers come from `footprint -p`, never `ps rss`.
- No test depends on ollama. No LLM calls in the loop.
- One nvim and one oracle process at a time.

## Ask-vs-assume

Decisions listed as **DECISION** in `design/oracle.md` are answered there; do not re-open them. A new fork that is Tony's to make goes into `design/QUESTIONS.md` with the options and your recommendation, and the tick continues on work that does not depend on it. Never guess a Tony-decision to keep moving. If nothing remaining is independent of an open question, `noop` with the question named.

## Never

- Spawn agents or workflows. Install global tools. Run `bd close` without an id. Merge or push to `main`. Reflow markdown prose to a column width. Write a memory file about this loop's task state (that is what `design/LOG.md` is for).
- Force-push, rewrite history, amend a commit from an earlier tick, `git checkout -- .` or `stash drop` over uncommitted work, or commit `spikes/*/src` checkouts or any `target/`.
