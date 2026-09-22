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

## 2026-09-21 — tick 7 — `6ii` lua-render-kinds

- Done: `render.lua` gains `name_group_of()` / `type_injectable()` (one mapping for the three layouts) with `property` → `TypeScopeProperty` (`@property`), `enum_member` → `TypeScopeEnumMember` (`@constant`), `group` → `TypeScopeGroup` (`NonText`, the fold reads as chrome); a group's "(n)" is never treesitter-injected. `examples` never target an enum member (its value is the example) or a group. `model.Node.inferred` documented and set by the oracle client. `tests/test_render_kinds.lua` renders both layouts, collapsed and opened, asserts rows and highlight groups, and prints the floats.
- Verified: `./tests/run.sh` ALL SUITES PASS; stylua clean.
- Screenshots: NOT taken — this session has no terminal to render into. The suite prints the exact float lines for each layout (row content is what the buffer holds; the geometry warning is about anchors, which these rows do not touch). Tony: open a Python buffer with an enum and a class with a property, press K, and eyeball the three rows once — that is the visual check this bead cannot do headless.
- Deferred to bead 10 with reason: "`inferred` replaces `evaluated`" in the renderer. Until the treesitter resolver is deleted both producers exist, and the ≈ drawing is driven by `evaluated`, which the oracle client sets alongside `inferred`; collapsing to one field is bead 10's cleanup.
- Next: `lfy` insert port.

## 2026-09-21 — tick 8 — `lfy` lua-insert-port

- Done: `insert.lua` goes through `typescope._resolver()` / `_can_resolve()` like the float; basedpyright is optional on the oracle path (it still supplies `signatureHelp` for the active param when attached, and `refresh_active` already guarded its absence). `ensure_shape` calls `evaluate` only when the resolver offers it — the oracle's inferred types arrive inline and its lazy nodes are structure — so the legacy path keeps its ≈ fetch until bead 10 deletes `evaluate` with the old resolver. `function_scope`'s signature unchanged.
- Verified: `./tests/run.sh` ALL SUITES PASS (legacy insert e2e untouched); the oracle suite drives `insert._update()` inside `ServerConfig("h")` and reads the constructor's params off the typing surface; stylua clean; no stray processes.
- Next: `1mv` parity gate (both deps closed).

## 2026-09-21 — tick 9 — `1mv` parity-gate

- Done: `scripts/parity.lua` (throwaway; goes with resolve.lua) diffs the rendered float on every `shapes.py` marker through legacy (real basedpyright, fixture stubs on extraPaths) and oracle. 26/29 identical; the 3 differences are the documented closed gaps. pydantic identical.
- Fixed in the oracle from the diff and the old e2e on the oracle path: method rows as receiver-less signatures (leaf, `(key: str) -> bytes`); `Unknown` → `Any`; TypedDict values list their keys (query the class instance, not the dict-shaped value); written alias kept as vocabulary with `resolved` (new wire field, drawn ≈) on leaves — type variables excluded so `Box[ServerConfig].item` still reads `ServerConfig`; unannotated param with a default → the default's type, ≈ (pyrefly's `int | Unknown` with the `Unknown` member dropped); union displays keep pyrefly's grouped literal spelling unless a member was dropped. Port bug: `returns` now starts collapsed.
- Fixture defect: `sample.py` lacked `overload` and `Literal` imports — a mock never checked; a real checker sees an unknown decorator and the overload stubs stop being functions. Imported them (legacy suite unaffected).
- `e2e_phase3.lua` with `resolver = "oracle"`: 101/115 (was 83/115 at tick 6). Remaining 14, all classified for bead 10: stub-hop family ×10 (`sinks.py`/`sinks_stub.py` + `attach()` with no import — rewrite as `sinks.pyi`), prefetch ×2 (the test reads `typescope.resolve._cache_count`), first-open attach race ×1, evaluation-only expand ×1 (no oracle equivalent). `e2e_declarations.lua`: 29/29.
- No checker disagreement on this corpus. The stop condition did not fire.
- Verified: cargo test 32/32; `./tests/run.sh` ALL SUITES PASS; stylua clean; no stray processes.
- Decision 6 checkpoint: the parity gate is closed; the pyrefly PR conversation can happen outside the loop whenever Tony wants.
- Next: `73q` delete-old-resolver.

## 2026-09-21 — tick 10 — `73q` delete-old-resolver

- Deleted: `resolve.lua` (the treesitter pipeline, 909 lines), most of `extract/python.lua` (945 → 131: `call_args` and `on_callee` remain, call-site syntax only), `lsp.lua`'s definition/declaration/locate/hover/load_buf/range_start helpers, `config.resolver` and `init._resolver`, `insert.ensure_shape`/`evaluate`, `tests/test_extract.lua`, `tests/test_shapes.lua` (the markers are asserted by `cargo test`), `tests/test_load_buf.lua`, `scripts/parity.lua`, the `typescope-oracle:` override markers (folded into single markers). `resolve_oracle.lua` → `resolve.lua`.
- Before each deletion the comments were read; the header of `resolve.lua` lists what was carried and what was dropped and why; `extract/python.lua`'s rules now live in `walk.rs`/`policy.rs`/`scope.rs` (receiver by position, `= …`, `/` and `*` shape tokens, Field()/field() unwrapping, Required/NotRequired, total=False, dunder filter, decorator categories, docstring dedent, self-stripped method signatures, alias vocabulary).
- Test infrastructure: `mock_server.lua` → `mock_basedpyright.lua` (serves signatureHelp and a hover line, advertises definition so `client_for` picks it, answers definition with nothing); `e2e_phase3.lua` and `e2e_declarations.lua` drive the real binary and skip without one; fixture pairs `sinks_stub.py`/`prompting_stub.py` became real `sinks.pyi`/`prompting.pyi` with the imports `sample.py` always needed; `declarations/typeshed_io.py` (a file whose *path* said "typeshed") replaced by real `pathlib.Path`; `declarations/pyrefly.toml` added.
- Oracle fixes surfaced by the rewrite: docstrings were searched in the *request's* module — now the def's own, with the `.pyi` → sibling `.py` fallback (the resolver's "runtime docstring rides the hop"); an overload set is named/located by its first signature; a declaration annotated as exactly one class draws the class as the float (olj), unannotated targets keep their ≈ row; a user class among a builtin wrapper's type args nests as a variant (`dict[str, Bar]` → `▸ Bar`).
- Retired with reasons in place: the evaluation-only expand mechanic (the ≈ arrives from the first paint), the per-position definition round-trip count, the treesitter `normalize` section (pinned as a Rust test of pyrefly's display).
- Verified: cargo test 33/33; `./tests/run.sh` ALL SUITES PASS (10 suites); stylua clean; no stray processes.
- Next: `tzb` download and `sjg` release pipeline (both ready), then `ipb` docs.
