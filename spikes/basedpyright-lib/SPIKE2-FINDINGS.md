# Spike 2 — what a second analysis costs, and how not to pay it

**Bead:** typescope.nvim-ocv · **Date:** 2026-09-21 · **Machine:** 8GB M1 Air, 27% free at the time, 14M pageouts (Claude Code + Firefox resident) · **Project:** `~/github/plongitudes/kitchen/backend` — FastAPI + pydantic + SQLAlchemy + httpx, 95 source files, 156 site-packages, its own `pyrightconfig.json` (`typeCheckingMode: off`, venv at `../.venv`) · **File:** `app/services/recipe_service.py`, ten hover targets in `targets.json`.

## The metric, first

`ps rss` is the wrong number on macOS under memory pressure. Pages the compressor has taken stop counting, and the idle langserver read as **21 MB RSS while `footprint -p` said 521 MB**. Everything below is **physical footprint** (`footprint(1)`, no sudo needed, reports its own peak), which includes compressed pages and is what the process actually costs the machine. `process.memoryUsage().rss` in node has the same blind spot. The first two runs of the langserver script used RSS and are discarded.

## Numbers

| | basedpyright-langserver (mason) | sidecar (Program + evaluator) | **wrapper** (basedpyright + 1 request) |
| --- | --- | --- | --- |
| process | PyPI launcher (python) → bundled `nodejs_wheel` node | node v26.8.2 | node v26.8.2 |
| at attach / ready | 67 MB | 100 MB (379 ms from spawn) | — |
| after first hover / query | 510 MB, 1.5 s | 399 MB after 10 queries; first 612 ms | 1.4 s first hover |
| after ten | 533 MB, each < 10 ms | 399 MB; queries 0–48 ms | structure 322 / 7 / 56 ms |
| + checker pass | (already included) | 427 MB, +330 ms | (already included) |
| idle 10 s | **535 MB** peak 535 | **427 MB** peak 427 | **473 MB** peak 474 |

- **Two processes:** 535 + 427 ≈ **960 MB** for Python types. The sidecar is ~80% of the langserver: it is the same parse-and-bind of the same stubs (SQLAlchemy's are the bulk), just without the checker thread.
- **One process:** 473 MB, which is basedpyright alone on node 26 (the mason build's extra ~60 MB is the Python launcher plus its older bundled node). **Adding the structure request costs nothing measurable.**

Raw results: `langserver_result.json`, `sidecar_result.json`, `wrapper_run.txt`.

## The wrapper

`typescope-langserver.js` (≈150 lines, most of it the structure walk from spike 1 rendered to JSON) subclasses basedpyright's own `PyrightServer`, calls `super.setupConnection()`, and registers one more handler on the same connection:

```js
this.connection.onRequest('typescope/structure', async (params, token) => {
  const uri = this.convertLspUriStringToUri(params.textDocument.uri);
  const workspace = await this.getWorkspaceForFile(uri);
  return workspace.service.run((program) => structure(program, uri, params.position), token);
});
```

That is exactly how `onHover`, `onDefinition` and every other provider in `languageServerBase.ts` reach the program, so the request sees the same Program, the same open-buffer contents, the same lazily-bound imports the user's hovers already paid for. No source file of basedpyright is modified; `setupConnection` is `protected` and `getWorkspaceForFile` is public by design. `test_wrapper.lua` started it as a buffer's LSP: it identifies as `basedpyright 1.40.1`, ordinary `textDocument/hover` still answers, and `typescope/structure` on `result = await db.execute(query)` returns `Result[Tuple[Recipe]]` with `Recipe` substituted through `.t -> TupleResult[Tuple[Recipe]]` and `fetchone -> Tuple[Recipe] | None` — a generic specialized two levels deep, which the syntax resolver could never have reached.

What this changes: the plan's outcome 1 was "sidecar, if the RAM is acceptable". The wrapper makes the RAM question moot and removes the second-analysis staleness problem too (one Program, one view of the buffer). The user's LSP `cmd` becomes `typescope-langserver --stdio` instead of `basedpyright-langserver --stdio`; everything else in their config is unchanged; TypeScope's Lua calls `client:request("typescope/structure", …)` on the client it already finds with `lsp.client_for`.

Costs, honestly:

- **Distribution.** The wrapper must ship a tsc build of `pyright-internal` (18 MB + runtime deps) plus `typeshed-fallback`, pinned to a basedpyright tag. Users install *our* package instead of basedpyright from mason — same runtime (node), one more thing to trust. The mason PyPI route (`pip install basedpyright`) is not reusable: its node bundle has no exports (spike 1).
- **Version coupling.** Non-public API; a basedpyright release can move `shared`/`priv` field names. Mitigation is a pinned tag and a fixture-based test that fails loudly.
- **Users who won't swap their LSP.** A separate-sidecar mode from the same code is possible (spike 1's probe is that) at the 427 MB cost. Whether to offer both is a Decision-bead question.
- **basedpyright's future TSP** could make this a standard request one day; the wrapper's handler is the thing that would move upstream.

## Other observations

- Hover on `RecipeService.get_recipe_by_id(` at a **call site** evaluates to `CoroutineType[Any, Any, Recipe | None]` — the effective type of calling an `async def`. At the `def` it is `Recipe | None`. The oracle should present the declared return for async functions the way hover does; `FunctionType.getEffectiveReturnType` vs the call-site type is a policy choice to write down.
- The spike walks every member at depth 1 with no filter, so `AsyncSession` produced ~150 rows. Depth and filter (`_`-prefix, methods vs data, MRO cut) are the presentation policy the review already called out; a real request takes `depth` as a parameter.
- Query latency inside the process is 0–50 ms warm; the first query on a heavy site-packages class (~600 ms) is lazy binding that hover pays identically.

## Open for the Decision bead

- Wrapper (one process, swap the LSP cmd) vs sidecar (two processes, +427 MB, no config change) vs both.
- Whether spike 3 (pyrefly) is still worth running: it would be a second checker *and* a second process, so it now competes with the sidecar's cost profile rather than the wrapper's.
