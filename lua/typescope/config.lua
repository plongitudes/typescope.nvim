---@class typescope.OllamaConfig
---@field enabled boolean
---@field autostart boolean spawn `ollama serve` (dies with nvim) when the port refuses connections
---@field host string
---@field port integer
---@field model string
---@field timeout_ms integer stall timeout: how long ollama may go SILENT, not a total budget
---@field keep_alive string how long ollama keeps the model resident after a request (RAM tradeoff)

---@class typescope.UiConfig
---@field style "unicode"|"ascii"|"minimal"|"rounded"
---@field layout "ledger"|"tree"|"table" one-line rows with a cursor-follow detail block (default) vs flowing segments vs column grid (deprecated)
---@field animations boolean
---@field align "left"|"right" name column alignment (tree layout)
---@field max_width number >1: absolute columns; <=1: fraction of editor width
---@field max_height integer
---@field border string|string[] any nvim float border value
---@field docstring "bottom"|"top"|false docstring section placement in the float
---@field hint boolean virtual-text "▸ typescope" marker on resolved call lines
---@field focus boolean explicit opens enter the float; false = momentary hover convention (second K focuses)

---@class typescope.KeymapConfig
---@field docstring string toggle full docstring section
---@field expand string toggle node under cursor
---@field expand_node string expand node under cursor (no-op on leaves)
---@field collapse_node string collapse node, or jump to + collapse parent
---@field expand_all string
---@field collapse_all string
---@field toggle_examples string
---@field llm_generate string
---@field close string
---@field help string

---@class typescope.InsertModeConfig
---@field enabled boolean insert-mode typing surface (replaces signature help)
---@field max_width? number typing surface width; >1: absolute columns, <=1: fraction of editor width (defaults to ui.max_width)

---@class typescope.Config
---@field trigger "hover"|"manual"
---@field prefetch boolean idle-cursor cache warming (CursorHold, no float)
---@field insert_mode typescope.InsertModeConfig
---@field depth integer
---@field show_examples boolean
---@field example_mode "heuristic"|"llm"|"none"
---@field ollama typescope.OllamaConfig
---@field ui typescope.UiConfig
---@field highlights table<string, vim.api.keyset.highlight>
---@field keymaps typescope.KeymapConfig

local M = {}

---@type typescope.Config
local defaults = {
  trigger = "manual", -- "hover" (CursorHold) | "manual" (keymap only)
  -- resolve the symbol under a resting cursor into the cache before any
  -- keypress, so the eventual K/open paints warm. No visible effect.
  prefetch = true,
  -- typing surface (U6): param-names block + active-param detail
  -- while the cursor is inside a call's parens — heuristics only, never
  -- focusable, zero manual controls. Opt-in while it bakes; turn off
  -- blink/core signature help when enabling. max_width (same units as
  -- ui.max_width) sizes just this surface; nil inherits ui.max_width.
  insert_mode = { enabled = false, max_width = nil },
  depth = 2,
  show_examples = true,
  -- "heuristic": pattern-table examples, E generates LLM values on demand
  -- "llm": auto-generate via ollama on open (heuristics show until they land)
  -- "none": no examples at all
  example_mode = "heuristic",
  ollama = {
    enabled = false,
    -- spawn `ollama serve` as a child process if the port refuses
    -- connections; the server dies with nvim (RAM reclaimed on quit).
    -- A server that's already running is never touched.
    autostart = false,
    host = "localhost",
    port = 11434,
    model = "qwen2.5-coder:3b",
    -- How long the server may go completely quiet before we give up -- a
    -- stall timeout, not a total budget. The reply is streamed, so a slow
    -- machine keeps bytes flowing and simply fills in slower; only a wedged
    -- server trips this. Sizing it by tokens/sec is therefore unnecessary
    -- (an 8GB M1 measured 8-12 tok/s, which a total budget could not fit).
    -- curl's low-speed check adds ~2s of fixed overhead before it engages,
    -- and one retry follows, so a wedged server is reported at roughly
    -- 2*(timeout_ms + 2s).
    timeout_ms = 8000,
    -- model residency after a request: longer = warm E presses all session,
    -- shorter = the ~2GB comes back sooner on small-RAM machines. Matches
    -- ollama's own OLLAMA_KEEP_ALIVE default. This is also the ONLY thing
    -- that reclaims the model on a server we borrowed rather than spawned —
    -- see M.shutdown — so the default stays conservative; raise it in your
    -- own config if you have the RAM.
    keep_alive = "5m",
  },
  ui = {
    style = "rounded", -- "unicode" | "ascii" | "minimal" | "rounded"
    -- "ledger" (U6, the default): one line per param (name + type + short
    -- default); the row under the cursor expands into a detail block (≈
    -- evaluation, example, origin) that follows as the cursor moves.
    -- "tree": flowing segments, type/default/example trailing the name.
    -- "table" (U5) is DEPRECATED and goes away in the next release — see
    -- the notify in validate() below.
    layout = "ledger",
    animations = true,
    align = "left", -- "left" | "right" name column alignment
    max_width = 0.5, -- fraction of editor width; values > 1 are absolute columns
    max_height = 20,
    border = "rounded",
    docstring = "bottom", -- "bottom" | "top" | false (structure first, prose last)
    hint = true,
    -- true: an explicit open (K / :TypeScope) enters the float — cursor
    -- inside, tree keys live immediately. false: momentary hover convention —
    -- the float opens unfocused (any cursor move dismisses it) and a second
    -- K focuses it. The CursorHold auto-open (trigger = "hover") never
    -- steals focus in either mode.
    focus = true,
  },
  highlights = {},
  keymaps = {
    expand = "<CR>",
    expand_node = "l",
    collapse_node = "h",
    expand_all = "L",
    collapse_all = "H",
    toggle_examples = "e",
    docstring = "d",
    llm_generate = "E",
    close = "q",
    help = "?",
  },
}

---@type typescope.Config?
local options = nil

-- vim.validate's arg-form is 0.11+ and its table-form is deprecated there,
-- so we roll a minimal checker that works identically on 0.10 and 0.11.
---@param path string dotted key path, for error messages
---@param value any
---@param expected string|string[] lua type name(s) or a list of allowed values prefixed with "enum"
local function check(path, value, expected)
  if expected == "positive_integer" then
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      error(("typescope.setup: `%s` must be a positive integer, got %s"):format(path, vim.inspect(value)), 0)
    end
    return
  end
  if type(expected) == "table" then -- enum of allowed values
    if not vim.tbl_contains(expected, value) then
      error(
        ('typescope.setup: `%s` must be one of "%s", got %s'):format(
          path,
          table.concat(expected, '", "'),
          vim.inspect(value)
        ),
        0
      )
    end
    return
  end
  if type(value) ~= expected then
    error(("typescope.setup: `%s` must be a %s, got %s"):format(path, expected, vim.inspect(value)), 0)
  end
end

---@param cfg typescope.Config
local function validate(cfg)
  check("trigger", cfg.trigger, { "hover", "manual" })
  check("prefetch", cfg.prefetch, "boolean")
  check("insert_mode", cfg.insert_mode, "table")
  check("insert_mode.enabled", cfg.insert_mode.enabled, "boolean")
  if
    cfg.insert_mode.max_width ~= nil and (type(cfg.insert_mode.max_width) ~= "number" or cfg.insert_mode.max_width <= 0)
  then
    error("typescope.setup: `insert_mode.max_width` must be a positive number (<=1 = fraction of editor width)", 0)
  end
  check("depth", cfg.depth, "positive_integer")
  check("show_examples", cfg.show_examples, "boolean")
  check("example_mode", cfg.example_mode, { "heuristic", "llm", "none" })

  check("ollama", cfg.ollama, "table")
  check("ollama.enabled", cfg.ollama.enabled, "boolean")
  check("ollama.autostart", cfg.ollama.autostart, "boolean")
  check("ollama.host", cfg.ollama.host, "string")
  check("ollama.port", cfg.ollama.port, "positive_integer")
  check("ollama.model", cfg.ollama.model, "string")
  check("ollama.timeout_ms", cfg.ollama.timeout_ms, "positive_integer")
  check("ollama.keep_alive", cfg.ollama.keep_alive, "string")

  check("ui", cfg.ui, "table")
  check("ui.style", cfg.ui.style, { "unicode", "ascii", "minimal", "rounded" })
  check("ui.layout", cfg.ui.layout, { "tree", "table", "ledger" })
  if cfg.ui.layout == "table" then
    -- Warn, do not error: someone who set this deliberately keeps working
    -- until the removal. notify_once rather than vim.deprecate because
    -- setup() may run more than once and vim.deprecate's behaviour varies
    -- across the 0.10/0.11 range this plugin supports — the same reason
    -- check() above is hand-rolled instead of using vim.validate.
    vim.notify_once(
      'typescope: `ui.layout = "table"` is deprecated and will be removed in the next release. '
        .. 'Use "ledger" (the default) or "tree".',
      vim.log.levels.WARN
    )
  end
  check("ui.animations", cfg.ui.animations, "boolean")
  check("ui.align", cfg.ui.align, { "left", "right" })
  if type(cfg.ui.max_width) ~= "number" or cfg.ui.max_width <= 0 then
    error("typescope.setup: `ui.max_width` must be a positive number (<=1 = fraction of editor width)", 0)
  end
  check("ui.max_height", cfg.ui.max_height, "positive_integer")
  if type(cfg.ui.border) ~= "string" and type(cfg.ui.border) ~= "table" then
    error("typescope.setup: `ui.border` must be a string or table (any nvim float border value)", 0)
  end
  if cfg.ui.docstring ~= false then
    check("ui.docstring", cfg.ui.docstring, { "bottom", "top" })
  end
  check("ui.hint", cfg.ui.hint, "boolean")
  check("ui.focus", cfg.ui.focus, "boolean")

  check("highlights", cfg.highlights, "table")
  check("keymaps", cfg.keymaps, "table")
  for _, key in ipairs({
    "expand",
    "expand_node",
    "collapse_node",
    "expand_all",
    "collapse_all",
    "toggle_examples",
    "docstring",
    "llm_generate",
    "close",
    "help",
  }) do
    check("keymaps." .. key, cfg.keymaps[key], "string")
  end
end

--- Merge user options over defaults. Safe to call more than once.
---@param opts? table
---@return typescope.Config
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  validate(merged)
  options = merged
  return options
end

--- Current config; initializes defaults on first access so setup() is optional.
---@return typescope.Config
function M.get()
  if not options then
    options = M.setup()
  end
  return options
end

--- A max_width value resolved to concrete columns (fractions are of the
--- current editor width, floored at 20). Defaults to ui.max_width; pass
--- e.g. insert_mode.max_width to size that surface independently.
---@param mw? number
---@return integer
function M.resolved_max_width(mw)
  mw = mw or M.get().ui.max_width
  if mw <= 1 then
    return math.max(20, math.floor(vim.o.columns * mw))
  end
  return math.floor(mw)
end

return M
