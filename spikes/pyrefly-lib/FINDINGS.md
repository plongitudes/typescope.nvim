# Spike 3 — pyrefly as a library

**Bead:** typescope.nvim-uxy · **Date:** 2026-09-21 · **Verdict: PASS with a one-function patch; PARTIAL on the public API alone.** Same fixture and the same ten kitchen targets as spikes 1 and 2, so the numbers compare directly.

## Versions

- pyrefly `main` at clone time, crate version **1.4.0-dev.1** (latest tag 1.3.1). Not on crates.io as a real crate: the `pyrefly` entry there is a 0.0.1 placeholder ("Coming soon"). Library use is a git/path dependency on the workspace; `cargo add pyrefly` does not work.
- rustc 1.98.1 stable (the workspace pins `stable`, edition 2024). The probe is an external crate at `probe/` with path dependencies into the checkout, so it exercises exactly what an outside consumer would see.
- Cold `cargo build --release` of the whole tree: **3.5 min wall, ~1.3 GB across compiler processes**; incremental rebuild after touching the pyrefly crate itself: 2 min; probe-only change: 3–6 s. Binary: **26 MB, static, no runtime**.

## What is public, and what is not

`pyrefly` is a `[lib]` crate and exposes `pub mod state` (doc-hidden), `pub mod alt`, `pub mod binding`, `pub mod query`, plus a `library::library::library::library` re-export module whose doc says outright: *"This interface is NOT stable and should not be relied upon. It will change during minor version increments."* The `query` module header says *"Just experimenting for the moment — not intended for external use."* So the stability posture is the same as pyright-internal's: usable, pinned, no promises.

Reachable from outside, and enough to build a State and ask questions:

- `State::new(default_config_finder(None), ThreadCount)`, `new_committable_transaction` → `run(handles, Require::Everything)` → `commit_transaction`, then `state.transaction()`. Mirrors `Query::add_files`.
- `Transaction::get_type_at(handle, TextSize) -> Option<Type>` — the type at any position, narrowed at use sites, declared at declarations, with type args.
- `Transaction::get_class_fields(handle, &Class) -> Option<ClassFields>` — a class's **own** field names, `field_decl_range`, `is_field_annotated`.
- `pyrefly_types` is a normal public crate: `Type` (Display), `ClassType::{class_object, targs, substitution}`, `Substitution::substitute_into`, `Function{signature, metadata}` including `property_metadata`.

**Not** reachable: the MRO (an answer behind `Answers::get_idx`, `pub(crate)`), and the solver (`Transaction::ad_hoc_solve`, `pub(crate)`), which is what turns "a class" into "every attribute with its specialized type". `Query::get_attributes` exists but is own-fields-only, by class *name*, annotation as a string — a Pysa/Glean helper. pyrefly's TSP implementation (`lib/tsp/`) has the same three type-at-node queries as pyright's and no member listing.

## Phase 1 — public API only (`probe_output_public.txt`)

| Target | Answer |
| --- | --- |
| `Box[ServerConfig]` | `item ServerConfig`, `count int` — substituted via `ClassType::substitution()` |
| `Color` (Enum) | `RED Literal[1]`, `GREEN Literal[2]` |
| `Derived` | `debug bool` only — **inherited `host`/`port` missing** (no MRO) |
| `resp` unannotated local | `Response`; `status int`, `ok (self) -> bool` — **`self.body` / `self.parsed` missing** (`get_type_at` at an `__init__` attribute target returns nothing) |
| `first([1,2,3])` | `int` |
| `def first` | `[T](xs: list[T]) -> T` |
| `maybe` / `narrowed` | `Response \| None`, then `Response` inside the guard |
| `int` (typeshed) | class found, **every member empty** — builtins was loaded at `Require::Exports`, so per-declaration answers are not retained |

So the public surface gets the *type at the cursor* right everywhere, but the class walk is "own annotated fields of modules you solved yourself", reconstructed by hand. That is roughly the coverage of the syntax resolver with better inference, not the closed-vocabulary win.

## Phase 2 — one `pub fn` (`typescope-attributes.patch`, `probe_output_patched.txt`)

```rust
pub fn attributes_of_type(&self, handle: &Handle, ty: Type) -> Option<Vec<AttrInfo>> {
    self.ad_hoc_solve(handle, "typescope_attributes", |solver| solver.completions(ty, None, true))
}
```

Ten lines on `Transaction`, wrapping what attribute completion already computes. With it, every gap above closes and the answers match basedpyright's from spike 1: `Derived` → `debug`, `host ↑ServerConfig`, `port ↑ServerConfig`; `Response` → `status int`, `ok bool`, `body bytes`, `parsed dict[str, int]`; `Color` → `Literal[Color.RED]`, `Literal[Color.GREEN]`, `name ↑Enum str`, `value ↑Enum int`; `int` → all 59 members with bound signatures (`to_bytes(length: SupportsIndex = 1, …) -> bytes`); and **every attribute carries a definition location** (`AttrDefinition::FullyResolved { cls, range }`), which is the thing the hover-prose ceiling never had.

Note the property came back as `ok bool` — the solver hands you the getter's result type directly, so property-vs-field needs the `AttrDefinition`/class field, not the type. Minor.

## Cost on the real project (`probe_output_kitchen.txt`)

Same `kitchen/backend`, same file, same ten targets as spike 2. pyrefly found the venv through the project's `pyrightconfig.json` (its config crate reads pyright and mypy configs) and resolved SQLAlchemy the same way basedpyright did: `Result[tuple[Recipe]]`, `InstrumentedAttribute[Any]`, `fetchone -> Row[tuple[Recipe]] | None`, `keys ↑_WithKeys`.

| | basedpyright-langserver | node sidecar | basedpyright wrapper | **pyrefly binary** |
| --- | --- | --- | --- | --- |
| settled footprint | 535 MB | 427 MB | 473 MB | **136 MB** |
| cold to ready | — | 379 ms | — | **841 ms** (solves the whole module + imports up front) |
| first answer | 1.5 s | 612 ms | 1.4 s | **0.1 ms** after ready |
| warm query | <10 ms | 0–50 ms | 7–56 ms | **<0.2 ms** |
| second process? | — | yes | no | yes |
| ships as | pip/npm | node + 18 MB JS | node + 18 MB JS | **one 26 MB static binary** |

Two processes with pyrefly: 535 + 136 ≈ **670 MB**, against 960 for the node sidecar and 473 for the wrapper.

## Where it disagrees with basedpyright

Small on this corpus, and all cosmetic so far: `Coroutine[Unknown, Unknown, Recipe | None]` where pyright prints `CoroutineType[Any, Any, Recipe | None]`; `tuple[Recipe]` vs `Tuple[Recipe]`; `Literal['big', 'little']` ordering; `Self@Response` spelled the same. pyrefly bundles its own typeshed snapshot, so stub-level differences will appear over time. Not measured: pydantic-heavy code, where pyright's plugin behaviour and pyrefly's `binding/pydantic.rs` may diverge more.

## Implications for the Decision bead

- **Coverage:** equal to basedpyright's evaluator, but only with the patch. Without it, pyrefly is a better type-at-cursor oracle than the current resolver and nothing more.
- **The patch is the cost.** Ten lines, but it is a source patch on a moving `main`, rebuilt from source per pyrefly release (3.5 min cold). Upstreaming a `pub fn` that wraps an existing computation is the most plausible kind of PR to land in a Meta-run repo that already exposes an experimental `query` module — and it is small enough to be reviewed on its merits regardless of who typed it. Until then the build is `git apply` + `cargo build`.
- **Distribution is where pyrefly wins outright**, and that was the objection to the wrapper: a single static binary per platform, released on GitHub, no node, no swap of the user's LSP. TypeScope would spawn it like it spawns ollama today.
- **RAM:** 136 MB resident is the cheapest second process by 3×, and cheaper than the wrapper's *marginal* cost only in the sense that the wrapper's cost is zero — the wrapper still wins on RAM, pyrefly wins on distribution.
- **Second opinion:** real but small here. The oracle's answers would come from pyrefly while diagnostics come from basedpyright; the two agree on everything that mattered in this corpus.
- Not probed: unsaved-buffer contents (`Transaction::set_memory(files)` exists for overlays), incremental re-solve after an edit (`change_files` in `Query` shows the pattern), and pydantic.
