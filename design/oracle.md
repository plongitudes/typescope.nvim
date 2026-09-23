# The type oracle: replacing the syntax-reading resolver

Status: **accepted**, 2026-09-21 — Tony took every default, with decision 6 revised as written below. Written after the three spikes on `dev/oracle-spikes` (findings under `spikes/`). Each **DECISION** records the choice and the reasoning; the loop treats them as settled.

## 1. Why

TypeScope's resolver reads annotation *syntax* at definition sites (`extract/python.lua` over treesitter) and uses basedpyright only to navigate and, as a fallback, to narrate types in hover prose that regexes take apart. Every type pyright *computes* rather than the author *wrote* is a dead end: enums, specialized generics, unannotated locals and parameters (which today draw the enclosing function), properties, `Self`, forward-ref strings, narrowing. Covering them one by one is open-ended. A checker's type model is closed and small; asking a checker for structure turns an unbounded coverage problem into a bounded one. Spike 1 showed the whole class walk is ~80 lines against an evaluator and none of the gaps needed a special case.

## 2. Decision record

**DECISION 1 — backend: pyrefly, as a separate binary.** Default: yes.

| | RAM | distribution | coverage | coupling |
| --- | --- | --- | --- | --- |
| pyrefly binary | +136 MB (spike 3, kitchen) | one static binary per platform; user's LSP unchanged | full, with a 10-line patch | non-public API + the patch until upstreamed |
| basedpyright wrapper | +0 MB | user swaps LSP cmd to our node package | full, same checker as diagnostics | non-public API, pinned tag |
| node sidecar | +427 MB | node + 18 MB JS | full | non-public API |
| incremental fixes | +0 | none | partial, forever | none |

pyrefly wins on the axis Tony named as the objection — distribution — and is the cheapest second process by 3×. The wrapper is the engineering-clean answer but asks users to replace basedpyright with our package, which is the uphill climb. The node sidecar is dominated. The costs accepted with pyrefly: a source patch rebuilt from source per pyrefly release (3.5 min cold), a second checker whose answers may drift from basedpyright's around plugins (pydantic not yet probed — see §10), and a Rust toolchain in the release pipeline only (users get a binary).

**DECISION 2 — install: TypeScope downloads the release binary on first use.** Default: yes, with a manual override.

Into `stdpath("data")/typescope/`, from GitHub Releases, verified against a checksum published alongside, platform-selected (`darwin-arm64`, `linux-x86_64`, `linux-arm64`; no `darwin-x86_64`, since GitHub's Intel macOS runners queue too long to gate a release on). Each release installs under `typescope/oracle/<release>/`, so a plugin pinning a different release (upgrade or downgrade) finds nothing at its own path and downloads; a successful install removes the other releases. `:checkhealth` reports the binary's version and path; `config.oracle.path` overrides the download for people who build it themselves; `config.oracle.download = false` turns the download off and makes health say what to install. This is how mason and several plugins already behave, so users have a model for it.

**DECISION 3 — one code path: the treesitter resolver is deleted, the binary is a hard requirement.** Default: yes.

Two paths (oracle when present, old resolver when not) would keep the plugin working for people who won't install a binary, at the cost of maintaining the syntax reader — the very thing this rewrite retires — behind every future feature. basedpyright is already a hard requirement; the binary joins it. `extract/python.lua` shrinks to `call_args` (call-site argument kinds for overload matching, pure treesitter, cheap) and is otherwise deleted; `resolve.lua` becomes an oracle client.

**DECISION 4 — what a class shows by default: data first, methods on demand.** Default: fields, properties and enum members are rows; methods are collected under one collapsed `▸ methods (n)` row per class. TypedDict/dataclass/pydantic/NamedTuple floats look as they do today. Protocols show their methods expanded, as today. This answers ym4 without turning every float into an API listing. `_`-prefixed names are dropped; dunders are dropped; the MRO walk stops at `object`, `Enum`, `BaseModel`, `Protocol`, `Generic` (the marker bases already in `MARKER_BASES`), which keeps Enum's twenty internals and pydantic's model machinery out of the float.

**DECISION 5 — hovering a class *call* draws the constructor.** Default: yes. `Recipe(` draws `__init__`'s parameters (the receiver dropped) as the roots and the instance shape as `returns`; hovering the class name in an annotation or a declaration draws the shape as today. pyrefly answers `type[Recipe]` for both, so the distinction is made on the nvim side from the call-site tree (`extract.call_args` already finds the enclosing call).

**DECISION 6 — upstream the pyrefly patch, after the parity gate, if the approach holds.** The release pipeline applies the patch for the whole rewrite; the loop never opens the PR. Once bead 9 (`parity-gate`) closes and the function's final shape is proven in `walk.rs`, Tony opens a PR against pyrefly under his own name — framed as a generalization of their `query::get_attributes` (attributes of a *type*, through the MRO, with types), with a doc comment and a fixture test in their tree — with the description written by Tony from a draft. The patch is written so it can be dropped without a code change the day the `pub fn` lands. If the PR is declined or ignored, nothing changes: the pipeline keeps applying the patch.

**DECISION 7 — this is v0.2.0.** Default: yes. New hard requirement, removal of the deprecated `table` layout (hdt) rides along, changelog entry says what changed for a user in one paragraph.

**DECISION 8 — insert-mode surface ported in the same rewrite.** Default: yes. `insert.lua` calls `function_scope` and `evaluate`; the second disappears (evaluated types arrive inline) and the first keeps its signature. It is a small port and leaving it on the old resolver would contradict decision 3.

## 3. Architecture

```
  nvim                                          typescope-oracle (Rust binary)
  ┌──────────────────────────────┐              ┌───────────────────────────────┐
  │ init / interact / render     │              │ lsp_server loop               │
  │   float, keys, examples      │              │   initialize: textDocumentSync│
  │            │                 │              │   didOpen/didChange/didClose  │
  │            ▼                 │   LSP over   │        │                      │
  │ resolve.lua (oracle client)  │◄────stdio───►│        ▼                      │
  │   typescope/structure        │              │ pyrefly State + overlays      │
  │            │                 │              │   Transaction::set_memory     │
  │ lsp.lua: basedpyright client │              │   get_type_at                 │
  │   signatureHelp only         │              │   attributes_of_type (patch)  │
  └──────────────────────────────┘              │        │                      │
                                                │        ▼                      │
                                                │ structure walk → JSON Node    │
                                                └───────────────────────────────┘
```

The oracle speaks **LSP**, not a bespoke protocol, and advertises **no capabilities except document sync**, so it never competes with basedpyright for hover, definition or diagnostics. That choice buys, for free from `vim.lsp`: spawn and restart, root detection, `didOpen`/`didChange` carrying *unsaved buffer contents*, cancellation, and `lsp.client_for`-style discovery. The one custom request is `typescope/structure`. basedpyright stays attached for `signatureHelp` (the `activeParameter` the ledger opens on) and for everything K falls through to.

Both halves are pinned to each other by a protocol version in the `initialize` result (`serverInfo.version` and a `typescope.protocol` field); the client refuses a mismatch with a health-style message rather than mis-rendering.

## 4. The contract: `typescope/structure`

Request:

```jsonc
{
  "textDocument": { "uri": "file:///…/recipe_service.py" },
  "position": { "line": 113, "character": 4 },   // 0-based, UTF-16 like LSP
  "depth": 2,                                    // config.depth; how far to nest before returning lazy nodes
  "members": "data",                             // "data" | "all" — decision 4; "all" is what expanding the methods row asks
  "call": false                                  // the cursor is on a CALL to whatever is under it — decision 5 (set from the buffer's syntax tree)
}
```

Response: `null` when nothing is under the cursor (K's job), otherwise a **Scope**:

```jsonc
{
  "scope": "function" | "class" | "declaration" | "constructor" | "empty",
  "header": "get_recipe_by_id(db, recipe_id=…, /, *, flag) -> Recipe | None",   // call-shape line; absent for class/declaration
  "docstring": "…",                                                 // absent when none
  "headers": [ "…", "…" ], "overloads": 2,                          // an overload set: `roots` are the groups (kind "overload", badge "[i/n]"), one header each — the shape `meta.headers`/`meta.overloads` already has
  "roots": [ Node… ],
  "reason": "…"                                                     // only with scope "empty": why there was nothing to draw
}
```

Scope facts established by bead 4: a callee is asked with pyrefly's declaration-preserving type, so a call site sees the function (or the whole overload set), not the chosen signature; a cursor on an `@overload` stub re-asks at the implementation `def`, where the set lives; an `async def` answers its declared return (`Coroutine[…, X]` → `X`), like hover; `self.x` inside a method — which pyrefly does not type as an assignment target — is answered through the enclosing class's view of `x`, with the receiver identified by position; a class scope's root row is the header `(category ← written bases)`, construct markers omitted; the constructor scope uses a written `__init__` when the class has one and the instance's fields otherwise (what dataclass, pydantic, NamedTuple and TypedDict synthesize); `empty` reasons keep the resolver's wording; a Module under the cursor answers `null`.

**Node** is `typescope.Node` from `lua/typescope/model.lua` with the resolver-private fields dropped and three added:

```jsonc
{
  "name": "port",
  "kind": "param" | "field" | "property" | "enum_member" | "method" | "return" | "variant" | "type" | "group",
  "type": { "display": "int", "category": "builtin" | "class" | "dataclass" | "pydantic" | "typeddict" | "namedtuple" | "protocol" | "enum" | "union" | "unresolved" },
  "default": "8000",            // literal defaults only, as today; enum members carry their value here
  "badge": "NotRequired",       // TypedDict badges, "[1/3]" overload badges, "ClassVar"
  "origin": "ServerConfig",     // inherited: the class it came from (↑ marker), absent when own
  "pass_mode": "*" | "/",       // params only
  "inferred": true,             // no annotation; pyrefly's inference — rendered ≈ as `evaluated` is today
  "resolved": "Literal['auto', 'manual']",   // when `display` is the alias the author wrote and the row has no structure of its own: what it resolved to, drawn ≈ (parity gate: "alias name kept as vocabulary")
  "location": { "uri": "…", "line": 43, "character": 6 },   // where this member is DECLARED, for navigation
  "children": [ Node… ],        // present when resolved within depth
  "expandable": true,           // children omitted for depth; see expansion below
  "path": ["function", "h", "widget"]   // on expandable nodes only: the walker's own path, sent back unchanged as `expand`
}
```

Mapping onto today's fields: `evaluated` becomes `inferred` + `type.display` holding pyrefly's answer (the ≈ rendering keys off `inferred`); `evaluated_owner` disappears (unions come back as `variant` children, so ownership is structural); `_lazy` and `source` collapse into `location` + `expandable`. `example`, `active`, `state` and `id` are nvim-side and never cross the wire; `model.new` still assigns ids.

**Expansion** (corrected in bead 2): an `expandable` node is expanded by **re-requesting the scope's original position with a larger `depth`** and grafting the deeper subtree in by id path. Asking at the member's own declaration would answer with the *unspecialized* type (`item: T` in `Box`, not `ServerConfig`), so `location` is for navigation only. The oracle keeps no per-client state; a deeper ask is sub-millisecond warm; the resolve cache keys stay `uri#line#depth`.

Policy facts established by bead 2's fixtures: members inherited from any bundled-typeshed class are cut wholesale (`object`, `tuple`, `Enum`, `dict` behind a TypedDict), not just from a marker list; a nested class (`class Config` in a pydantic model) is not a member; typeshed classes are terminal leaves (`str`, `Path`); an anonymous TypedDict (a dict literal's inferred shape) is vocabulary, not shape; the category comes from the solver's fingerprints (enum literal, `NamedTupleFallback`/`TypedDictFallback`, a `pydantic` base, `Protocol`) or, for `@dataclass` and `@pydantic.dataclasses.dataclass`, from the author's decorator, because pyrefly does not list synthesized dunders among attributes. A request whose position is not on an identifier answers `null`. A **third-party class nested as a member's type** (a project model's `Column[UUID]`, from site-packages) is `expandable`, not auto-walked — a seventeen-column SQLAlchemy model drew 1,700 rows otherwise; hovered directly, or opened on demand, it draws as any class. The expansion request names its path (`expand`) so the oracle opens exactly that node. That path is the one the oracle put on the node (`path`), echoed back unread: an earlier version rebuilt it from the plugin's row ids, which never matched the walker's own path under a function or constructor (whose walk starts at a `function`/`__init__` node that is never a row) or a declaration (whose row id mangles `self.x`), so those expansions came back empty. Bead 14 established this from the kitchen measurement.

Presentation policy lives in the **oracle**, not in Lua: the member filter, the MRO cut, the async-def return rule (present the declared `Recipe | None`, not `Coroutine[…]` — spike 2's note), and the "informative inference" rule (`None`/`Any`/`Unknown` inferences are dropped, as `informative_inference` does today). Reason: the policy needs the type objects to decide, and a second language's oracle would need the same rules stated once.

## 5. The nvim side

- `resolve.lua` → an oracle client of ~150 lines: `function_scope(bufnr, win, token, pos)` sends `typescope/structure` and adapts the Scope into `(roots, meta, why)` with the same three-way decline (`stale`/`absent`/`empty`); `recurse(node, token, cb)` sends `structure(node.location)` and grafts the children; `evaluate` is deleted. The resolve cache stays as it is (keyed on the scope's location, invalidated by changedtick).
- `lsp.lua` keeps `client_for` (basedpyright, for `signatureHelp`), `signature_help`, `active_param`, `request_cb`; gains `oracle_for(bufnr)` that finds the `typescope-oracle` client; loses `definition`, `declaration`, `locate`, `hover_result_lines`, `load_buf`.
- `oracle.lua` (new): `vim.lsp.config`/`vim.lsp.enable` of the binary on `FileType python`, the download-or-locate logic (decision 2), protocol-version check, `:checkhealth` hooks.
- `extract/python.lua` → only `call_args` survives (plus the call/annotation classification decision 5 needs); everything else deleted with its tests.
- `render.lua`/`interact.lua`: render `property`/`enum_member`/`group` kinds (three small branches next to the `method` one); nothing else. (Bead 10 settled the `inferred`/`evaluated` question: `evaluated` stays the ≈ *text* the renderer draws — an inferred type, or what a written alias resolved to — and `inferred` is the flag; one producer now, no rename needed.)
- `insert.lua`: drop `evaluate`; unchanged otherwise.
- `examples/`: heuristic and LLM prompts keep reading `type.display`; `enum_member` and `property` nodes are excluded from generation the way `Self@`/`T@` are today.
- `config.lua`: `oracle = { path = nil, download = true }`; `depth` unchanged.

## 6. The Rust side: `typescope-oracle`

Lives in this repo under `oracle/` (a Cargo workspace member of one crate), so a plugin release tags both halves together.

- `main.rs`: `lsp_server` stdio loop; `initialize` answers with document sync only and `serverInfo { name: "typescope-oracle", version }`; `didOpen`/`didChange`/`didClose` maintain overlays via `Transaction::set_memory` and re-run the affected module at `Require::Everything`; `typescope/structure` dispatches to the walk. `$/cancelRequest` honoured by dropping the answer.
- `state.rs`: one pyrefly `State` per workspace root, config found by pyrefly's own finder (it reads `pyrightconfig.json` and `pyproject.toml`, spike 3), files added lazily on first request.
- `walk.rs`: the port of the spike probe's `describe`: type at position → Scope; class → members via `attributes_of_type` filtered by policy → Nodes with locations; function → params/return; union → variants; overloads → groups. Depth-limited; beyond depth emits `expandable` with `location`.
- `policy.rs`: the member filter, MRO cut, async return rule, informative-inference rule. Pure functions over `pyrefly_types`, unit-tested in Rust against the spike fixture.
- `vendor/pyrefly` pinned to the commit in `oracle/pyrefly.rev`, plus `typescope-attributes.patch` applied by `build.rs`-free means: `scripts/build-oracle.sh` does a shallow fetch of that commit into the gitignored `vendor/pyrefly`, `git apply --check`, `cargo build --release`. No build-time patching magic; the patched tree is what CI builds. (0.2.0 had it as a git submodule; plugin managers clone submodules, and pyrefly's history is ~1.9 GB, so lazy.nvim timed out mid-checkout. 0.2.1 moved the pin to a file.)
- Release: a GitHub Actions matrix builds the three targets (no Intel macOS), uploads binaries + `SHA256SUMS` to the release the plugin tag creates. Local dev builds on the M1 in 3.5 min cold.

## 7. Verification

- **Rust unit tests** on `policy.rs` and `walk.rs` against `tests/fixtures/shapes.py` and the spike fixture: the JSON for every `typescope:` marker class is asserted, so the fixture markers keep their job (they move from "what `type_at` extracts" to "what the oracle answers").
- **Lua unit tests** (`test_render`, `test_float`, `test_examples`, `test_match`) unchanged except for the `inferred`/new-kind branches.
- **e2e** replaces `mock_server.lua`'s LSP fakery with the real binary: `tests/run.sh` builds (or downloads) the oracle once, then `e2e_phase3.lua` and `e2e_declarations.lua` drive it over the fixtures. A `mock_oracle.lua` that replays recorded JSON stays for the pure-UI suites so they don't need Rust installed.
- **Parity gate**: before the old resolver is deleted, a throwaway script hovers every `typescope:` and `typescope-params:` marker in `shapes.py` through both paths and diffs the rendered floats. Differences are either policy (documented in `design/oracle.md` §4) or bugs. This is the "verify before asserting" step for the whole rewrite.
- **Screenshots** for the three new row kinds and the methods group, since headless float probes lie.
- **Parity gate result (bead 9, 2026-09-21):** `scripts/parity.lua` opened the float on all 29 markers in `shapes.py` through both resolvers against a real basedpyright. 26 targets byte-identical; the 3 differences are the documented closed gaps (`typescope-oracle:` markers). Fixed on the way: Protocol/class method rows are receiver-less signatures without children; an unannotated parameter reads `Any` (pyrefly's `Unknown` is not a name anyone wrote); a TypedDict *value* lists its keys (its attributes are `dict`'s); a written alias (`data: Payload`) stays the vocabulary with the resolution as `resolved` (≈) on leaves; an unannotated parameter with a default takes the default's type as ≈ (pyrefly types it `int | Unknown`; the `Unknown` member is the missing annotation); `returns` starts collapsed. Fixture defect found: `sample.py` never imported `overload` or `Literal` (the mock never checked). `e2e_phase3.lua` on the oracle path: 101/115; the 14 left are the mock-server stub-hop family (`sinks.py` + `sinks_stub.py`, which a real checker relates only as `sinks.pyi`), prefetch checks that read the old module's cache, the first open racing the oracle's attach, and one evaluation-only-expand mechanic the oracle has no equivalent for — all bead 10's rewrite. `e2e_declarations.lua`: 29/29. No checker disagreement on this corpus.
- **Footprint** re-measured with `footprint(1)` on the kitchen backend at the end; the number goes in CHANGELOG. **Result (bead 14, release build, 2026-09-21):** `scripts/footprint.lua` on `kitchen/backend/app/services/recipe_service.py` with both servers attached and the float opened through the plugin on the ten spike-2 targets: basedpyright-langserver 72 MB at attach → 528 MB settled; typescope-oracle (27 MB binary) 88 MB at attach → 154 MB settled, peak 154; first open 1.7 s (the module and its SQLAlchemy imports solved once), then 5–130 ms per float. The SQLAlchemy `Recipe(` constructor: 20 lines.

## 8. Beads, in loop order

Each is one tick's work with a testable done-state. Dependencies in brackets.

1. `oracle-crate` (`4te`) — `oracle/` crate skeleton, submodule + patch + build script, `initialize` handshake only; `nvim --headless` can attach and see `serverInfo`. Rust unit test harness in place.
2. `oracle-walk` (`5f8`) [1] — port the probe walk to `walk.rs` + `policy.rs`; unit tests assert JSON for every marker class in `shapes.py` and the spike fixture.
3. `oracle-sync` (`dmg`) [1] — didOpen/didChange overlays; test: edit an annotation in memory, structure answers the new type without saving.
4. `oracle-scopes` (`12r`) [2] — function / class / declaration / constructor / empty classification and headers, overload groups; async-return rule.
5. `lua-oracle-client` (`12n`) [1] — `oracle.lua` (enable, locate, version check, health), `lsp.oracle_for`.
6. `lua-resolve-port` (`4fd`) [4, 5] — `resolve.lua` rewritten onto the client; `recurse` via location; cache preserved; the three-way decline preserved.
7. `lua-render-kinds` (`6ii`) [6] — `property`, `enum_member`, `group` rows; `inferred` replaces `evaluated`; screenshots.
8. `lua-insert-port` (`lfy`) [6] — `insert.lua` off `evaluate`.
9. `parity-gate` (`1mv`) [7, 8] — the diff script over every marker; every difference filed or fixed. **Stop condition: the old resolver is not deleted until this bead closes.**
10. `delete-old-resolver` (`73q`) [9] — `extract/python.lua` → `call_args` only; `lsp.lua` shrinks; `mock_server.lua` → `mock_oracle.lua`; dead tests removed.
11. `download` (`tzb`) [5] — release-binary download with checksum, `config.oracle.path`, `download = false`; health messages.
12. `release-pipeline` (`sjg`) [1] — GitHub Actions matrix, `SHA256SUMS`, tag → release.
13. `docs-0.2.0` (`ipb`) [10, 11] — README requirements/install/config, CHANGELOG, `doc/typescope.txt`, `hdt` (table layout removal) folded in.
14. `footprint-final` (`upm`) [10] — kitchen measurement in the changelog.

`ym4` is closed by decision 4; `85g` closes with bead 10; `5mq` and `yw2` are re-homed on bead 6; `hdt` on bead 13. Epic: `5ag`.

## 9. Out of scope

A second language's oracle (the contract is designed for it, nothing is built); upstreaming the pyrefly patch; any UI redesign; changes to the examples subsystem beyond the exclusions in §5; Windows.

## 10. Open risks, named

- **pydantic.** Not probed with pyrefly. If its `BaseModel` handling differs materially from basedpyright's, the pydantic floats — the plugin's best case today — could regress. **Mitigation:** bead 2's fixture set includes the pydantic classes from `shapes.py` and one `Field(...)`-heavy model, and the parity gate diffs them first. If pyrefly is wrong there, that's a stop-and-report, not a workaround.
- **pyrefly API churn.** The library surface is documented as unstable. Pinning to a tag and vendoring makes each bump a deliberate, tested step; the patch is ten lines and moves with it.
- **Binary trust.** Downloading executables is a step some users refuse on principle; decision 2's override and opt-out exist for them, and the build is reproducible from the pinned commit and the patch.
- **Two checkers disagreeing** in a way a user notices: TypeScope's float says one thing, basedpyright's diagnostics another. Cosmetic in spike 3; the changelog says plainly that structure comes from pyrefly.
