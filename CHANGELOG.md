# Changelog

Notable changes to TypeScope, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/), with the usual 0.x caveat that a minor bump may break something. Each release is an annotated git tag carrying the same notes.

## [Unreleased]

Nothing yet. The deprecated `table` layout is scheduled for removal in v0.2.0.

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

[Unreleased]: https://github.com/plongitudes/typescope.nvim/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/plongitudes/typescope.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/plongitudes/typescope.nvim/releases/tag/v0.1.0
