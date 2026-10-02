# typescope.nvim

See the *shape* of the types in a Python call, without leaving the call.

![TypeScope demo: the insert surface following the active parameter and the overload, then K on two classes](https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/typescope.gif)

<details>
<summary>Full-resolution video</summary>

https://github.com/user-attachments/assets/b6391f46-8bc7-4573-b6ac-5e97d5044f92

</details>

TypeScope _(like 'periscope'! Get it? ... wow, tough crowd.)_ asks a type checker what the symbol under your cursor *is* — a function's parameters and return, the structure of a class, a variable's type and innards — and shows the result in a floating pane, structured hierarchically so that you can dive further in when needed. Where a parameter is a dataclass, a Pydantic model, a TypedDict, a NamedTuple, an Enum, a Protocol or a plain class with annotated attributes, you get its fields — not just its name. Generics arrive specialized (`Box[ServerConfig]` shows `item ServerConfig`), an unannotated local shows the type the checker inferred (drawn `≈`), and a narrowed variable shows its narrowed type.

The checker is [pyrefly](https://github.com/facebook/pyrefly) wrapped in a small binary. We call this the `oracle` (it really kind of needs a name change, doesn't it), and it runs alongside your Python LSP. I use basedpyright, this repo assumes you're using that or vanilla pyright. If you're using another type checker in your nvim setup, the results from pyrefly _might_ be a bit different from your own typechecker, but I believe that most results should be satisfactory. The `oracle` is downloaded for your platform the first time you open a Python buffer (see [Requirements](#requirements)). The patch to Pyrefly is a small change that takes a function pyrefly already uses internally for attribute completion and makes it public. With that patch in place, `oracle` can ask for every attribute of a type (its own and inherited ones), each with its type filled in. It adds no type-checking logic of its own, and if pyrefly eventually makes this a public feature, oracle could be dropped in favor of vanilla pyrefly.

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/intro.png" width="470" alt="TypeScope on create_server(config, timeout=…) -> Response: config expanded to host, port and debug, then timeout and returns, over a panel for the config row">

One compact line per parameter, and a panel docked under the rows shows everything about the row your cursor is on. See [The ledger](#the-ledger).

## Requirements

These are hard requirements. TypeScope won't work very well (read: at all) without them, and `:checkhealth typescope` will tell you which is missing.

- **Neovim v0.11+**. In order for this plugin to work nicely without a lot of fuss, I made the call to only support v0.11+. I doubt this plugin will ever reach a lot of folks, so I felt okay with drawing the line there.
- **The oracle binary, `typescope-oracle`.** This is where every type comes from. With the default option `oracle.download = true`, the plugin fetches the release build for your platform (Apple Silicon macOS, or Linux on x86_64 or arm64) into `stdpath("data")/typescope/oracle/<release>/` the first time a Python buffer opens, verifies it against the release's `SHA256SUMS` before running it, and tells you once when it is in place. A plugin update that pins a new release fetches that one and removes the old. It needs `curl`, and `sha256sum` or `shasum` for the check (every Linux and macOS has one). Apologies that Intel Macs have no release build; you'll need to build it yourself and set `oracle.path`. You're welcome to just build it yourself for whatever reason, actually (see [Development](#development))! Set `oracle.path`, or set `oracle.download = false` and put the binary at that path. The oracle settles at about 150 MB of memory on a real project.
- **The TreeSitter Python parser.** The float's own highlighting and the call-site questions (is the cursor on a call? what was written in it?) read the syntax tree. `:TSInstall python`.
  - [Treesitter](https://github.com/tree-sitter/tree-sitter)
  - [Treesitter plugin for nvim](https://github.com/nvim-treesitter/nvim-treesitter)

Recommended:

- **[basedpyright](https://github.com/DetachHead/basedpyright)** attached to your Python buffers. TypeScope no longer needs it to resolve types, but it uses its `signatureHelp` to mark the active parameter as you type, and `<Plug>(TypeScopeHover)` falls back to its hover for anything that is not a symbol. Any Python language server with those two capabilities works the same way.

Optional:

- **[ollama](https://ollama.com)** if you would like moderately plausible examples in your signature and hover, you can run a small model in memory in order to receive LLM-generated example values. On an M1 Macbook Air (2020), a `qwen2.5-coder:3b` model runs pretty okay, but it's off by default. See [Examples](#examples) for what turning it on costs in RAM.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "plongitudes/typescope.nvim",
  ft = "python",
  opts = {},
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "plongitudes/typescope.nvim",
  config = function()
    require("typescope").setup({})
  end,
})
```

### About `setup()`

`setup()` is optional in the sense that the plugin loads and `:TypeScope` works without it. But three features are wired only from `setup()`, so if you don't have that set, you won't get them.

- the oracle itself — `setup()` is what attaches it to Python buffers (and downloads it the first time)
- `prefetch` — cache warming while the cursor rests, so the model is already warm by the time the plugin has to draw anything.
- warmstart — kicking basedpyright's analysis when it attaches, instead of on your first request
- the `trigger = "hover"` auto-open autocmd

If you use `lazy.nvim`, `opts = {}` calls `setup()` for you. If you configure by hand, call `require("typescope").setup({})` even when you have no overrides. Calling it more than once is safe, and turning a feature back off in a later call takes its autocmds down.

## Usage

Put the cursor on (or inside the parens of) a call and open the float. I use Typescope in place of nvim's default
hover (`K`). Feel free to set up the keys in whatever way suits you best :)

```lua
vim.keymap.set("n", "<leader>ts", "<Plug>(TypeScopeToggle)")
vim.keymap.set("n", "K", "<Plug>(TypeScopeHover)")
```

### Commands

| Command | What it does |
| --- | --- |
| `:TypeScope` | Toggle the float (same as `:TypeScope toggle`) |
| `:TypeScope open` | Open it; if already open, focus it |
| `:TypeScope close` | Close it |
| `:TypeScope hover` | Structure for functions, Neovim's built-in hover for anything else — a drop-in `K` |

### `<Plug>` mappings

Bind these rather than writing Lua callbacks:

| Mapping | Equivalent |
| --- | --- |
| `<Plug>(TypeScopeToggle)` | `:TypeScope toggle` |
| `<Plug>(TypeScopeOpen)` | `:TypeScope open` |
| `<Plug>(TypeScopeHover)` | `:TypeScope hover` |

`<Plug>(TypeScopeHover)` is the interesting one: on a function it draws the tree, and on anything else it falls through to `vim.lsp.buf.hover()`. That makes it a safe replacement for `K` in Python buffers rather than a second thing to remember.

### Inside the float

| Key | Action |
| --- | --- |
| `<CR>` | Expand / collapse the node under the cursor |
| `l` / `h` | Open one more level under the node / collapse node (or jump to the parent and collapse it) |
| `H` | Collapse all |
| `j` / `k` | Move by node, not by line |
| `e` | Ask the model for this row's example, and its neighbours' (needs ollama) |
| `d` | Docstring: show all of it in place of the rows, or go back |
| `q` / `<Esc>` | Close |
| `?` | Toggle the help overlay |

The `?` overlay is generated from your actual `keymaps` config, so it stays correct if you rebind anything.

## Configuration

Every default, as it appears in `config.lua`:

```lua
require("typescope").setup({
  trigger = "manual",        -- "hover" (CursorHold auto-open) | "manual" (keymap only)
  prefetch = true,           -- warm the cache on cursor rest; no visible effect
  depth = 2,                 -- how far to walk nested types before requiring an explicit expand
  show_examples = true,
  example_mode = "heuristic", -- "heuristic" | "llm" | "none"

  insert_mode = {
    enabled = false,         -- the insert-mode typing surface; replaces signature help
    max_width = nil,         -- same units as ui.max_width; nil inherits it
    max_detail_lines = 3,    -- cap on the wrapped detail before the shape elides
  },

  oracle = {
    path = nil,              -- an explicit typescope-oracle binary; nil = the downloaded one
    download = true,         -- fetch the release build on first use when none is found
  },

  ollama = {
    enabled = false,
    autostart = false,       -- spawn `ollama serve` if the port refuses; dies with nvim
    host = "localhost",
    port = 11434,
    model = "qwen2.5-coder:3b",
    timeout_ms = 8000,       -- STALL timeout (how long it may go silent), not a total budget
    keep_alive = "5m",       -- how long ollama keeps the model resident afterwards
  },

  ui = {
    style = "rounded",       -- "unicode" | "ascii" | "minimal" | "rounded"
    animations = true,
    max_width = 0.5,         -- <=1: fraction of editor width; >1: absolute columns
    max_height = 20,
    border = "rounded",      -- any nvim float border value
    docstring = true,        -- first sentence in the footer, d for the rest; false turns both off
    hint = true,             -- virtual-text "▸ typescope" marker on resolved call lines
    focus = true,            -- explicit opens enter the float; false = momentary hover
  },

  highlights = {},           -- overrides, merged over the defaults below

  keymaps = {
    expand = "<CR>",
    expand_node = "l",
    collapse_node = "h",
    collapse_all = "H",
    docstring = "d",
    llm_generate = "e",
    close = "q",
    help = "?",
  },
})
```

Bad values are rejected at `setup()` time with a message.

### `ui.focus`

`true` (the default) means an explicit open — `K` or `:TypeScope` will put your cursor inside the float, so the tree keys are live immediately. `false` picks the momentary-hover convention instead: the float opens unfocused, any cursor movement dismisses it, and a second `K` focuses it.

The `trigger = "hover"` auto-open never steals focus in either mode.

## The ledger

One compact line per parameter, and a small subpanel is docked at the bottom of the float, showing details of the row the cursor is on: its whole type (the row truncates ones that are too long), the evaluated shape, the full default, an example, and where it was inherited from. The detail panel changes as you move the cursor from row to row. The frame's bottom edge carries the docstring's first sentence for a little extra info, and `d` swaps the floating window's contents for the full docstring (it's a toggle). Below, the cursor is on `host`:

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/ledger.png" width="470" alt="TypeScope on create_server(config, timeout=…) -> Response, with the cursor on host: the panel under the rows shows host str, e.g. "localhost"">

The panel grows to fit the tallest node it has shown (up to five lines) and doesn't shrink back, so the rows above it stay put. The frame opens below the cursor, or above it when there is more room there.

## Insert mode

As a bonus, `insert_mode.enabled = true` replaces your signature help with a *typing surface*: every parameter name on one wrapped block, the active one highlighted, a rule, then the active parameter's detail — type, evaluated shape, default, example. It follows `textDocument/signatureHelp` silently, including overload changes, and repositions on every keystroke so it never covers the line you are typing on or the one below it.

It has no keymaps and is never focusable, by design. If you enable it, **turn off your existing signature help** (blink.cmp's, nvim-cmp's, or core's) or you will have two floats fighting over the same space.

`max_detail_lines` caps the *detail* only — the signature block above it wraps as far as it needs to keep every parameter name visible, so this is not a cap on the surface as a whole. Past the cap, the shape (the one unbounded part) elides member-by-member rather than the detail growing: a short union still shows in full, but a 53-member `Literal` won't be allowed to subsume the whole window. Raise it if you work with big `Literal`s and want more of them at a glance.

Off by default while it bakes.

## Examples

The panel shows a plausible example value for each leaf.

- `example_mode = "heuristic"` (default) — pattern-table values, matched on name and type. No network, no model, instant. Press `e` on a row to ask the model for its example (and its nearest neighbours') on demand.
- `example_mode = "llm"` — generate through ollama automatically, as you move: the row the panel is on and its nearest neighbours, one batch at a time. Heuristics show until the real values land, then swap in place. `e` on a row asks again, including rows the model had no answer for.
- `example_mode = "none"` — no examples at all.

### The RAM cost of ollama

`ollama.enabled` defaults to `false` for a good reason: if you're not already aware of how LLM models work, a loaded model stays resident in RAM. This means that however much RAM you have, the model will gobble up however much it needs in order to run, so subtract that from however much you have available normally on your device. As an example, that's roughly 2GB for the default `qwen2.5-coder:3b` model. Note that that's not the tiniest model, but it's the smallest one I can run on my 2020 M1 Macbook Air and still get decent output. `keep_alive` controls how long it stays after a request — the default `"5m"` matches ollama's own, and on a small-RAM machine it is the *only* thing that gives the memory back on a server TypeScope borrowed rather than spawned. Raise it if you have the headroom and want warm `e` presses all session.

`autostart = true` spawns `ollama serve` as a child process when the port refuses connections, and that process dies with Neovim so that the RAM comes back when you quite editing files. If you're running an ollama server for other reasons as well, Typescope will use it to call up the model you specify, but will never alter that server or ask it to shut down.

`timeout_ms` is a **stall** timeout — how long the server may go completely silent — not a total budget. The reply is streamed, so a slow machine simply fills in slower and never trips it; only a wedged server does.

## Styles

`ui.style` picks the charset: `rounded`, `unicode`, `ascii`, `minimal`. All four are plain Unicode or ASCII — no Nerd Font glyphs — so any font works. The same ledger, in each:

<table>
<tr><th align="left"><code>rounded</code> (default)</th><th align="left"><code>unicode</code></th></tr>
<tr><td>

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/style-rounded.png" width="400" alt="TypeScope on create_server(config, timeout=…) -> Response, rounded style: the last child hangs off a rounded corner">

</td><td>

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/style-unicode.png" width="400" alt="TypeScope on create_server(config, timeout=…) -> Response, unicode style: the last child hangs off a square corner">

</td></tr>
<tr><th align="left"><code>ascii</code></th><th align="left"><code>minimal</code></th></tr>
<tr><td>

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/style-ascii.png" width="400" alt="TypeScope on create_server(config, timeout=…) -> Response, ascii style: tree lines drawn with +-, | and \-">

</td><td>

<img src="https://raw.githubusercontent.com/plongitudes/typescope.nvim/assets/style-minimal.png" width="400" alt="TypeScope on create_server(config, timeout=…) -> Response, minimal style: no tree lines, indentation only">

</td></tr>
</table>

`rounded` and `unicode` differ only in the last-child corner — `╰` against `└`. `ascii` is the one to reach for over SSH, in a terminal with a partial font, or anywhere box-drawing characters come out as replacement glyphs. `minimal` drops the tree chrome entirely and leans on indentation.

## Highlights

Every group links to something sensible in your colorscheme, so TypeScope simply inherits your theme. Override any of them through `highlights`:

`TypeScopeField` `TypeScopeProperty` `TypeScopeEnumMember` `TypeScopeGroup` `TypeScopeParam` `TypeScopeType` `TypeScopeDefault` `TypeScopeExample` `TypeScopeExamplePending` `TypeScopeChrome` `TypeScopeKeyword` `TypeScopeBadge` `TypeScopeEvaluated` `TypeScopeHeader` `TypeScopeHeaderDim` `TypeScopeDocstring` `TypeScopeUnresolved` `TypeScopeHint` `TypeScopeActive` `TypeScopeTitle`

```lua
require("typescope").setup({
  highlights = {
    TypeScopeExample = { fg = "#7aa2f7", italic = true },
  },
})
```

## Health

```
:checkhealth typescope
```

Reports Neovim version, the Python parser, basedpyright (active client, or just the executable), the oracle (where the binary is, its version and protocol, whether a client is attached, and why a download failed if one did), and — only when you have enabled it — curl and ollama reachability.

## Development

```sh
scripts/build-oracle.sh              # the oracle, debug build (Rust toolchain; ~4 min cold)
scripts/build-oracle.sh --release    # the binary that ships
(cd oracle && cargo test)            # the oracle's tests: every marker in tests/fixtures/shapes.py
./tests/run.sh                       # every Lua suite, headless
stylua lua/ tests/                   # formatting; run it twice, it needs two passes to converge
```

The oracle lives in `oracle/`: a Rust crate over [pyrefly](https://github.com/facebook/pyrefly), pinned to the commit in `oracle/pyrefly.rev`. `scripts/build-oracle.sh` fetches that commit (shallow, about 35 MB), applies the one small patch in `oracle/patches/` — a `pub fn` exposing the attribute listing pyrefly computes for completion — and builds. The design, the wire contract and the decisions behind them are in `design/oracle.md`.

`tests/run.sh` adds your local `site` directory and `nvim-treesitter` to the runtimepath for the Python parser and its highlight queries. The suites that drive the real oracle (`e2e_*`, `test_oracle_*`, `test_resolve_oracle`) skip themselves when `oracle/target/debug/typescope-oracle` is not built, so the pure-Lua suites need no Rust toolchain.

## License

MIT. See [LICENSE](LICENSE).
