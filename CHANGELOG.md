# Changelog

Notable changes to TypeScope, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/), with the usual 0.x caveat that a minor bump may break something. Each release is an annotated git tag carrying the same notes.

## [0.2.0] — Unreleased

TypeScope no longer reads types out of Python syntax. It asks a type checker. Everything this release adds follows from that one change, and so does its one new requirement.

### Changed

- **Types come from a checker now.** A small binary, `typescope-oracle` (pyrefly, wrapped), runs beside your Python language server as a second LSP server and answers one request: the structure of whatever the cursor is on. The plugin downloads the release build for your platform (Apple Silicon macOS; Linux x86_64/arm64) into `stdpath("data")/typescope/oracle/<release>/` the first time a Python buffer opens, replaces it when a plugin update pins a different release, verifies it against the release's `SHA256SUMS` before running it, and never runs an unverified file. `curl` and `sha256sum` or `shasum` are required for the download; `oracle.path` points at your own build (the way to run it on an Intel Mac, which has no release build) and `oracle.download = false` opts out. `:checkhealth typescope` has an oracle section. On a FastAPI + SQLAlchemy backend the oracle settles at about 154 MB beside basedpyright's 528.
- **basedpyright is recommended, not required.** It still supplies `signatureHelp` (the active parameter as you type) and the hover `<Plug>(TypeScopeHover)` falls back to; any Python server with those capabilities does the same. It no longer resolves anything for TypeScope.
- `depth` still means "how far to nest before an explicit expand", and expanding re-asks the oracle rather than chasing a definition, so a nested generic expands to its *specialized* members.

### Added

- Everything the syntax reader could not see: **enums** (members with their values), **generics specialized** at the use site (`Box[ServerConfig]` shows `item ServerConfig`; `first([1, 2, 3])` is `int`), **unannotated locals and parameters** drawn with the checker's inference (`≈`) instead of the enclosing function, **narrowed** types inside an `if`, **properties**, **methods** (collected under one collapsed `methods (n)` row, expanded with `l`), inherited fields tagged with their origin through any depth, `Self`, forward-reference strings, `Optional`/`Union`/`List` spellings displayed in modern syntax, docstrings of functions defined in other modules and of stubbed functions (the runtime `.py`'s docstring rides along with the `.pyi`'s signature).
- Hovering a **class under a call** (`Recipe(`) draws its constructor — the written `__init__`, or the fields a dataclass, Pydantic model, NamedTuple or TypedDict synthesizes — with the instance's shape as the return.
- Import names (`from pkg import Name`) are hoverable.
- New row highlights: `TypeScopeProperty`, `TypeScopeEnumMember`, `TypeScopeGroup`.

### Removed

- **Neovim 0.10 support.** 0.11 is the floor now, as it is for nvim-lspconfig, gitsigns and telescope; below it the plugin says so once and does not load. On Debian stable's packaged 0.10, install a current release from [neovim/neovim](https://github.com/neovim/neovim/releases).
- The deprecated `table` layout. `ui.layout = "table"` is now an error naming the replacement; `ledger` (the default) and `tree` remain. `TypeScopeRowOdd` went with it.
- The treesitter type reader (`extract/python.lua` keeps only call-site syntax), the definition/declaration chase, the hover-prose parsing, and the alias hop — all replaced by the oracle.

### Fixed

- A method row inside a class shows its receiver-less signature, `(key: str) -> bytes`, with no expand arrow that leads nowhere.
- An unannotated parameter reads `Any`; with a literal default it reads the default's type (`count=3` → `int ≈`).
- A parameter typed as a TypedDict lists its keys, with `Required`/`NotRequired` badges.
- A written alias (`data: Payload`) stays the vocabulary of its row; a leaf alias is decorated with what it resolved to.

### Development

- `oracle/`: a Rust crate over pyrefly, vendored as a git submodule pinned to a tag, with the one `pub fn` it needs applied by `scripts/build-oracle.sh`. `cargo test` asserts every `typescope:` marker in `tests/fixtures/shapes.py`. The Lua suites drive the real binary and skip without one. `design/oracle.md` records the contract and the decisions.

## [0.1.1] — 2026-09-16

### Added

- Unannotated return types and unannotated `self.` attributes get a row carrying pyright's inferred type, painted as evaluated (`≈ T`) so an inference never reads as something written down. `def test()` with no annotations no longer reports "no parameters or return annotation" while pyright is sitting on `-> tuple[Bar, None]`. Uninformative inferences (`None`, `Any`) are dropped rather than shown.
- Plain hand-written classes have a shape: attributes annotated on the receiver in `__init__` or `__post_init__` are read as fields alongside class-level declarations. A class-level declaration wins the name and the value over an `__init__` assignment, and only literal initialisers become values.
- A hover that resolved a function and found nothing to draw says so on the message line, so a deliberate decline is distinguishable from TypeScope not being involved. Non-Python and non-symbol hovers stay silent; that is K's job.
- LLM example generation can decline. The model may answer `SKIP` for a field whose type admits no literal, instead of being cornered into inventing one from the field's name.

### Fixed

- Hovering a declared variable or attribute — `self.bar: Bar`, `LOG: TextIO = sys.stderr`, an annotation in a class body — drew the enclosing function (usually `__init__`) instead of the symbol under the cursor. A declaration now resolves to what it was declared as: through a wrapper (`dict[str, A]`, `A | None`), a union, an alias, or an inferred type with no annotation at all. Where nothing structural resolves (a typeshed-blocked or builtin annotation, an empty class) the declaration draws itself as a one-row float rather than falling through. The one remaining decline is an unannotated attribute pyright could not infer.
- A method's receiver is identified by position, not by being named `self` or `cls`. `def m(numpy_test)` in a class body no longer lists its receiver as a caller-supplied parameter, and `@staticmethod` keeps its first parameter as the real argument it is.
- Receivers typed `Self@Bar` and bound TypeVars typed `T@func` are pyright notation rather than Python types, and are no longer offered for example generation, heuristic or LLM.
- A stub default `= ...` renders as `= …` in the row, matching the header, and no longer counts as a real default when deciding whether a field wants an example.
- A `= …` placeholder stays inline when its row is focused instead of hopping into the detail block, and a row whose block would have held only that marker opens no block.
- A file loaded only for parsing (K on a symbol defined in typeshed or site-packages) and then opened with `gd` or `:e` arrived with no filetype, syntax, treesitter, LSP, or swapfile: the load suppressed detection, and a loaded buffer is never read again. The buffer now replays `BufReadPost` the first time it reaches a window.
- A definition is requested once per hover rather than once per asker. Typeshed-blocked attribute hovers and bases-only classes were paying every round trip twice.

## [0.1.0] — 2026-08-27

First public release. Type structure for the Python function under your cursor: resolve through basedpyright, walk every parameter and the return, draw the fields of dataclasses, Pydantic models, TypedDicts and Protocols in a float.

- Layouts: `ledger` (default), `tree`, `table` (deprecated, removed in v0.2.0).
- Insert-mode typing surface replacing signature help, opt-in.
- Heuristic example values, with optional LLM generation through ollama.
- Four charsets, all plain Unicode/ASCII; no Nerd Font required.
- Requires Neovim 0.10+, basedpyright, and the TreeSitter python parser.

[0.2.0]: https://github.com/plongitudes/typescope.nvim/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/plongitudes/typescope.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/plongitudes/typescope.nvim/releases/tag/v0.1.0
