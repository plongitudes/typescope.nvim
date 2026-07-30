# TypeScope Unification Spec

Status: **accepted** (2026-07-30) · bead: `typescope.nvim-1ko` · authors: Tony + Claude

## 1. Goal

One structured renderer serving every "tell me about this callable/type"
surface in the editor, replacing the current four-renderer patchwork:

| today | surface | renderer | content shape |
|---|---|---|---|
| A | insert-mode signature (auto on `(`/`,`) | blink.cmp signature | flat string |
| B | normal-mode `<C-k>` signature | core nvim | flat string |
| C | normal-mode `K` | TypeScope (2 floats) | tree + string anchor |
| D | completion docs | blink.cmp | flat string |

After unification: **TypeScope renders A, B, and C from one data model and
one renderer**; D stays blink's (out of scope, revisit later). The string
surfaces don't get imitated — they get replaced by strictly more capable
structure, with their unique strings (docstring, call shape) absorbed as
sections.

### Principles (established over phases 0–6)

- **Locations are structure; strings are pictures.** The declared def-site
  tree stays the skeleton (chaseable, recursable); evaluated strings decorate
  leaves (`≈`), never replace the skeleton.
- **One renderer, many triggers.** `render.lua` stays pure; surfaces differ in
  trigger, anchor, focusability, and budget — never in data model.
- **Degrade, never block.** Every enrichment (hover leaves, LLM examples) is
  progressive and optional; the tree is useful the instant it opens.

## 2. The unified float (single window)

The two-float stack (string anchor above + tree below) becomes **one float
with sections**:

```
╭─ typescope ─────────────────────────────────────────────╮
│ run(app, *, host=…, port=…, …) -> None        [2/5]     │  ← header
│ ─────────────────────────────────────────────────────── │
│ · app   ASGIApplication | Callable | str  "my_app.asgi" │  ← tree
│ · host  str = "127.0.0.1"                               │
│ …                                                       │
│ ─────────────────────────────────────────────────────── │
│ Run a uvicorn server.                                   │  ← docstring
╰─────────────────────────────────────────────────────────╯
```

- **Header**: one-line call shape built from `function_info` (not the LSP
  label): name, params in order **including `*` and `/` separators**, return
  type, and an overload indicator `[n/m]` when overloads exist. This absorbs
  surface B's entire value.
- **Docstring section**: first paragraph of the def's docstring (TreeSitter:
  first string expression in the body), placed at the **bottom** by default
  (Tony's call: structure first, prose last), `d` toggles the full text.
  Placement configurable: `ui.docstring = "bottom" | "top" | false`.
  Absorbs the anchor float's remaining value.
- **Tree**: unchanged, plus future table layout (`52n`) and pass-mode
  column (`*`/`/` info) land here.
- The separate anchor float and its `float.below()` anchoring are retired.
  `ui.anchor = "signature"` becomes meaningless → config option removed
  (breaking, pre-1.0 acceptable).

## 3. Surfaces

### 3.1 `K` / `:TypeScope` (normal mode) — the reading surface

- Trigger: manual (existing). Content: unified float, full depth, examples
  per `example_mode`, all enrichments.
- Overloads: **all stacked** — each overload's tree under its own root
  (`▸ run [1/5] (…)`), active one expanded, others collapsed. No cycling
  keymap needed for v1 of this surface (fold keys already do it).
- Budget: current (~0.8s cold, cache-assisted after `qq2`).

### 3.2 Insert-mode signware — the typing surface (replaces blink signature)

- Trigger: `(` and `,` in insert mode (and cursor movement inside call
  parens), like signature help. Auto-close on leaving the call or insert
  mode.
- Content: unified float, **budget-reduced**: header + tree with depth 1,
  **no docstring**, heuristic examples only (no LLM, no hover-enrichment
  round-trips), never focusable.
- Active param: tree row highlight auto-follows `activeParameter` per
  keystroke — extmark update only, no re-render, no re-resolve.
- Overloads: **auto-follow `activeSignature`** — the tree silently swaps to
  the overload basedpyright says matches your arguments so far.
- Budget target: **first paint < 150ms warm** — requires the `qq2` perf
  pass first: session-level resolve cache keyed on (function def location,
  buffer tick of the def buffer), parallel hover fan-out eliminated at this
  depth anyway.
- Config: `insert_mode = { enabled = false }` initially (opt-in while it
  bakes); blink's `signature.enabled` gets turned off in dotfiles when this
  is on.

### 3.3 Retirements

- lsp_signature.nvim: already removed.
- blink signature (A): retired when 3.2 is stable.
- Core `<C-k>` (B): keep the mapping, point it at `:TypeScope open` —
  same muscle memory, better answer. (Falls back to core signature help in
  non-Python buffers via the existing filetype guard pattern.)

## 4. Phasing

| phase | delivers | depends on | exit criterion |
|---|---|---|---|
| **U1** | unified single float: header + docstring section + tree; anchor float retired | — | K on `uvicorn.run` and `UserCreate` renders one float matching §2; suites green |
| **U2** | perf pass (`qq2`): resolve cache + parallel hovers | U1 | warm re-open of same function < 100ms; uvicorn cold < 500ms |
| **U3** | insert-mode surface (3.2), opt-in | U2 | typing `uvicorn.run(` paints < 150ms warm, active-param follows keystrokes, no focus steal |
| **U4** | overloads (`761`): stacked in K, auto-follow in insert | U1 (K), U3 (insert) | overloaded stdlib fn (e.g. `open`) shows [n/m] + stacked/following trees |
| **U5** | table layout (`52n`) + pass-mode column + alternating rows | U1 | Tony approves the look on uvicorn.run |

Breathing examples (`38c`) and remaining phase-7 polish ride alongside,
unblocked.

## 5. Decisions this spec makes (with rationale)

1. **Single float, sections** — the two-float "visually connected" design was
   the requirements' guess; six weeks of use showed the anchor float's only
   unique content is docstring + call shape, both absorbable. One window =
   one lifecycle = fewer bugs of the kind we've fixed twice.
2. **Header built from def-site, not LSP label** — we already parse the def;
   the label is redundant and position-less. This also fixes the `*`/`/`
   information loss (Q5) for free.
3. **Overloads: stacked (read) / auto-follow (type)** — per the 761 analysis;
   cycling keymap dropped as worst-of-both.
4. **Insert-mode is opt-in until proven** — it's the highest-risk surface
   (per-keystroke path, focus etiquette, budget).
5. **D (completion docs) out of scope** — blink owns that window; revisit
   only if the unified renderer proves itself on A–C.

## 6. Resolved with Tony (2026-07-30)

- **Q-a. Docstring**: on by default, first paragraph, at the **bottom** of
  the float (`d` expands); placement configurable (`ui.docstring`).
- **Q-b. `<C-k>`**: repointed at `:TypeScope open` with core signature help
  as the non-Python fallback (dotfiles change, alongside the K takeover).
- **Q-c. Ordering**: insert mode (U3) before table layout (U5) — the typing
  surface is the bigger capability gap; the table lands on a stable renderer.

## Appendix: measured constraints

- Full uvicorn.run resolve incl. sequential hover enrichment: ~770–810ms
  (M1 Air 8GB, warm basedpyright).
- Warm LLM batch (8 leaves): 1.3–6s; progressive fill lands uvicorn.run in
  ~20s total. Cold model load: 3.4s–30s+ under memory pressure.
- Anchor-float content latency (hover request): part of the ~800ms above.
- Insert-mode implication: per-keystroke work must be extmark-only; resolve
  must be cached; LLM/hover enrichment excluded at depth 1.
