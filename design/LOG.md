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

## 2026-09-21 — tick 4 — `12r` oracle-scopes

- Done: `scope.rs` — function (roots = params + return, call-shape header with `name=…`, `/`, `*`, docstring), overload sets (groups with `[i/n]` badges, `headers`, `overloads`), class (root row `(category ← bases)` from the written bases minus markers, docstring), constructor on `call: true` (written `__init__` or the instance's fields as params, then `returns` = the instance), declaration (root named as the cursor's text, `self.x` included, ≈ when the assignment was unannotated), `empty` with the resolver's reasons; Module → null. `--probe … --call`.
- Verified: 27 Rust tests; `./tests/run.sh` ALL SUITES PASS.
- Gotchas: `get_type_at` coerces a callee to the chosen overload — `get_type_at_preserving_declaration` is the right question; an `@overload` stub's type is just that stub, the set lives at the implementation def (AST lookup of the last same-named def); pyrefly does not type `self.x` assignment targets, so those go through the enclosing class's attributes (receiver by position); pyrefly lists a written `__init__` but not a dataclass's synthesized one.
- Plan: §4 request gains `call`; Scope's overload shape aligned to what the plugin already consumes (`headers` + `overloads` + group roots).
- Next: `12n` lua-oracle-client (only bead ready besides `sjg`).

## 2026-09-21 — tick 5 — `12n` lua-oracle-client

- Done: `lua/typescope/oracle.lua` — `locate()` (config `oracle.path` → `stdpath("data")/typescope/` → a build in this checkout), `version()`, pure `protocol_ok()`, `attach()` via `vim.lsp.start` with an `on_init` protocol check that refuses and records a mismatch, `client_for()`, `request()` (vim.NIL → nil), `enable()` (FileType autocmd + sweep); `lsp.oracle_for`; `config.oracle = { path, download }` with validation; `setup()` enables it; `:checkhealth` gets an oracle section (binary, version, mismatch, client). `tests/test_oracle_client.lua` (15 checks) in `run.sh`.
- Verified: `./tests/run.sh` ALL SUITES PASS; `stylua --check` clean; no stray processes.
- Found and fixed: the oracle outlived its nvim — `io_threads.join()` waits on the writer thread, which waits on the `Connection`'s sender; drop the connection before joining. Two orphans had survived the suite run before the fix; now the binary exits on stdin EOF.
- `lsp.client_for` (basedpyright's slot) never picks the oracle because it does not advertise definition support — tested.
- Next: `4fd` lua-resolve-port (both its deps now closed).

## 2026-09-21 — tick 6 — `4fd` lua-resolve-port

- Done: `lua/typescope/resolve_oracle.lua` — same API as `resolve.lua` (`function_scope`, `recurse`, `clear_cache`, `_cache_count`): one `typescope/structure` request, Scope → `model.new` trees (inferred rides on `evaluated` + type `Any` so the renderer's ≈ works untouched until bead 7; `expandable` → lazy hook), the three-way decline, cache on position+depth+changedtick, expand policy, overload groups with the `overloadN` ids the surfaces key on, recurse = re-ask the original position at `id_depth + 2` and graft the twin's children by id path (cancelled recurse restores the hook). `extract.python.on_callee` (call-site syntax) supplies `call` for decision 5. `init.lua` picks the resolver via a TRANSITIONAL `config.resolver = "legacy" | "oracle"` (default legacy) and no longer requires basedpyright on the oracle path (signatureHelp optional). `tests/test_resolve_oracle.lua` (32 checks) in `run.sh`.
- Verified: `./tests/run.sh` ALL SUITES PASS (legacy default keeps the old e2e green); the new suite opens a real float through `typescope.open()` on the oracle path and reads the header, fields, defaults, returns; stylua clean; no stray processes.
- Deviation from the plan, logged: bead 6 said "resolve.lua rewritten"; it is rewritten as a sibling module behind a switch because bead 9 must diff old against new and bead 10 deletes the old one. The switch and the sibling go away in bead 10.
- Parity signal, for bead 9: with `resolver = "oracle"` the old `e2e_phase3.lua` passes its structural assertions (param fields, inheritance, unions, class root, docstring) and fails 29 that test mock-server mechanics the oracle replaces (alias hop, stub hop via declaration, evaluation-only expand, prefetch keyed on `client_for`) plus a few worth a look (`NotRequired` badges on sample.py, overload sections). That list is bead 9's worklist.
- Closed as re-homed: `5mq` (empty decline now covered), `yw2` (dissolved: `expandable` now means "a class with members", not "a location to chase").
- Behaviors carried from resolve.lua are listed by name at the top of resolve_oracle.lua; the dropped ones are named there too with why.
- Next: `6ii` render kinds or `lfy` insert port (both ready).
