# Loop log

Newest at the bottom. One entry per tick: bead, what was done, what was verified, what is next, what is blocked.

## 2026-09-21 — tick 1 — `4te` oracle-crate

- Done: `oracle/` crate (protocol.rs, oracle.rs, main.rs) on `lsp-server` 0.10 / `lsp-types` 0.97; pyrefly vendored as a submodule pinned to tag `1.4.0-dev.1` (the exact rev spike 3 verified); `oracle/patches/0001-attributes-of-type.patch`; `scripts/build-oracle.sh` (idempotent patch apply, then cargo build); `tests/test_oracle_attach.lua` wired into `run.sh` with a self-skip when no binary.
- Verified: `cargo test` 4/4; `--version` prints `typescope-oracle 0.2.0 (protocol 1, pyrefly 1.4.0-dev.1)`; nvim attaches, reads serverInfo + `experimental.typescope.protocol == 1`, sees only full document sync, gets `null` from `typescope/structure` and MethodNotFound for an unknown method, shutdown honoured; `./tests/run.sh` ALL SUITES PASS; no leftover processes.
- Gotchas: the vendored tree lives *inside* `oracle/`, so cargo adopted it into our workspace and lost pyrefly's `workspace.lints` — `[workspace] exclude = ["vendor/pyrefly"]` fixes it. After a build `git status` shows the submodule as modified (the applied patch); that is expected and never committed into the submodule.
- Cost: debug build 1m33s warm cache / ~3.5 min cold; binary 30 MB debug.
- Next: `5f8` oracle-walk — port the probe walk to walk.rs + policy.rs, pydantic fixtures first.

## 2026-09-21 — tick 2 — `5f8` oracle-walk

- Done: `walk.rs` (type → Node/Scope JSON, functions/overloads/classes/unions, params by position with receiver dropped, literal defaults incl. `Field(...)`/`field(...)` unwrapping, `Required`/`NotRequired` badges, `≈` inferred, origin, locations), `policy.rs` (category, MRO cut, hidden names, kinds, terminal typeshed classes), `--probe FILE LINE COL [DEPTH] [data|all]` CLI, `scripts/oracle-tree.py`, fixture env `tests/fixtures/pyrefly.toml` + `site/pydantic` stubs, `tests/fixtures/oracle/oracle.py` (the spike fixture), `oracle/src/tests.rs` (18 tests: every `typescope:`/`typescope-params:` marker in shapes.py, plus generic/enum/inheritance/local/narrowing/typevar/depth/methods cases).
- Verified: `cargo test` 18/18; `./tests/run.sh` ALL SUITES PASS incl. the attach test now asserting a real dataclass Scope and `null` off-identifier; real pydantic 2.12.3 via the kitchen venv on `RecipeIngredientResponse` matches the source (Field sentinel vs `Field(None, gt=0)` default, inherited ↑origin, Optional unions, enum variant) — no disagreement with basedpyright's reading; formal diff is bead 9.
- Gaps the oracle closes, recorded as `typescope-oracle:` override markers (UnannotatedSelf, Conditional, Unannotated, DerivedConfig inline inheritance) so `test_shapes.lua` (old extractor) stays green until bead 10.
- Plan correction (§4): expansion = re-ask the original position with depth+1 and graft; `location` is the declaration. Asking at the declaration loses specialization.
- Gotchas: `completions` never lists `object` members or dataclass-synthesized dunders → category from the decorator text; `git mv -k` on an untracked file silently does nothing (cost one confusing test run); the mock server globs `tests/fixtures/*.py` non-recursively, so new fixtures with colliding class names go in a subdirectory.
- Next: `dmg` oracle-sync (overlays) or `12n` lua client — both ready; `12r` scopes needs this bead.

## 2026-09-21 — tick 3 — `dmg` oracle-sync

- Done: open buffers are pyrefly memory overlays. `didOpen`/`didChange` (full sync) store the text, `set_memory` the overlay, and re-run every open file at `Require::Everything`; `didClose` drops the overlay, `invalidate_disk`, and forgets the file was loaded so disk is the truth again. An open file's handle is a `ModulePath::memory` handle, so the solver reads the buffer, not the file.
- Verified: Rust test edits `status: int` → `str` in memory and the answer follows, then reverts on close (19/19); nvim test changes `port: int` to `str` with `nvim_buf_set_lines` (no save), asks, gets `str`, fixture untouched on disk; `./tests/run.sh` ALL SUITES PASS.
- Gotcha: a transaction that `set_memory`/`invalidate_disk` dirtied must `run` (even with no handles) before `commit_transaction`, or pyrefly asserts "Transaction is dirty".
- `$/cancelRequest` is accepted and ignored: requests are answered synchronously in order, so a cancel always arrives after its answer. Noted in main.rs; revisit only if a request ever runs long enough to matter.
- Next: `12r` oracle-scopes.
