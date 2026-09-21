# Loop rules for the oracle rewrite

Read this at the start of every tick. The plan is `design/oracle.md`; the work queue is `bd ready`. One bead per tick.

## Each tick

1. `bd ready`; claim the lowest-numbered oracle bead with `bd update <id> --status=in_progress`. If none is ready, the tick is a `noop` — say why.
2. Do the bead. Commit per coherent step on the current branch (never `main`), message says what and why, attribution line included.
3. `./tests/run.sh` green (and `cargo test` in `oracle/` when Rust changed) before every commit. A commit that turns a test red is not a commit.
4. Close with `bd close <id>` — explicit id, never bare — after `bd update <id> --notes` that **reads the existing notes first** (`--notes` replaces). 5–10 bullets: decisions, gotchas, deviations.
5. Append to `design/LOG.md`: date, bead, what was done, what was verified, what is next, what is blocked. Three to six lines.
6. Kill every process you spawned (nvim, the oracle, langservers). `pgrep -fl "nvim|typescope-oracle|basedpyright"` should show nothing of yours.

## Scope fence

- May replace: `lua/typescope/resolve.lua`, `lua/typescope/extract/`, the resolver parts of `lua/typescope/lsp.lua`, `tests/mock_server.lua`, `tests/e2e_*.lua`, `tests/test_extract.lua`.
- May edit for the contract only: `render.lua`, `interact.lua`, `model.lua`, `insert.lua`, `config.lua`, `health.lua`, `init.lua`, `examples/`.
- New: `oracle/` (Rust), `lua/typescope/oracle.lua`, `design/LOG.md`, CI workflow.
- Do not touch: the float geometry, keymaps, layouts, styles, highlights, the examples prompts. No new features beyond `design/oracle.md`. "While I'm here" is a bead to file, not a change to make.

## Stop conditions — end the tick and wait

- Any change to `~/.config/nvim`, mason, or anything outside this repo and its scratchpad.
- Any external action: pushing to `main`, creating a GitHub release, opening a PR anywhere, publishing anything.
- Deleting or weakening a test instead of fixing the code.
- The next step would be a monkeypatch, a hack around something pyrefly cannot do, or a second source patch to pyrefly. Write it up in the bead and `design/QUESTIONS.md` instead.
- A pydantic or other checker-disagreement regression found by the parity gate. Report, do not work around.
- A bead has gone three ticks without a commit. Stop and explain; the decomposition is probably wrong, and that is Tony's call.

## Verification rules

- A parity claim is a fixture diff, never a sentence. Extend the `typescope:` markers in `tests/fixtures/shapes.py`; do not bypass them.
- Float geometry is verified by screenshot. Headless float probes lie.
- Memory numbers come from `footprint -p`, never `ps rss`.
- No test depends on ollama. No LLM calls in the loop.
- One nvim and one oracle process at a time.

## Ask-vs-assume

Decisions listed as **DECISION** in `design/oracle.md` are answered there; do not re-open them. A new fork that is Tony's to make goes into `design/QUESTIONS.md` with the options and your recommendation, and the tick continues on work that does not depend on it. Never guess a Tony-decision to keep moving. If nothing remaining is independent of an open question, `noop` with the question named.

## Never

- Spawn agents or workflows. Install global tools. Run `bd close` without an id. Merge or push to `main`. Reflow markdown prose to a column width. Write a memory file about this loop's task state (that is what `design/LOG.md` is for).
