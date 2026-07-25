---@class typescope.OllamaConfig
---@field enabled boolean
---@field host string
---@field port integer
---@field model string
---@field timeout_ms integer

---@class typescope.UiConfig
---@field style "unicode"|"ascii"|"minimal"|"rounded"
---@field animations boolean
---@field max_width integer
---@field max_height integer
---@field border string|string[] any nvim float border value
---@field anchor "signature"|"cursor"

---@class typescope.KeymapConfig
---@field expand string
---@field toggle_examples string
---@field llm_generate string
---@field recurse string
---@field close string
---@field help string

---@class typescope.Config
---@field trigger "hover"|"manual"
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
  depth = 2,
  show_examples = true,
  example_mode = "heuristic", -- "heuristic" | "llm" | "none"
  ollama = {
    enabled = false,
    host = "localhost",
    port = 11434,
    model = "qwen2.5-coder:3b",
    timeout_ms = 8000,
  },
  ui = {
    style = "rounded", -- "unicode" | "ascii" | "minimal" | "rounded"
    animations = true,
    max_width = 60,
    max_height = 20,
    border = "rounded",
    anchor = "signature", -- "signature" | "cursor"
  },
  highlights = {},
  keymaps = {
    expand = "<CR>",
    toggle_examples = "e",
    llm_generate = "E",
    recurse = "r",
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
  check("depth", cfg.depth, "positive_integer")
  check("show_examples", cfg.show_examples, "boolean")
  check("example_mode", cfg.example_mode, { "heuristic", "llm", "none" })

  check("ollama", cfg.ollama, "table")
  check("ollama.enabled", cfg.ollama.enabled, "boolean")
  check("ollama.host", cfg.ollama.host, "string")
  check("ollama.port", cfg.ollama.port, "positive_integer")
  check("ollama.model", cfg.ollama.model, "string")
  check("ollama.timeout_ms", cfg.ollama.timeout_ms, "positive_integer")

  check("ui", cfg.ui, "table")
  check("ui.style", cfg.ui.style, { "unicode", "ascii", "minimal", "rounded" })
  check("ui.animations", cfg.ui.animations, "boolean")
  check("ui.max_width", cfg.ui.max_width, "positive_integer")
  check("ui.max_height", cfg.ui.max_height, "positive_integer")
  if type(cfg.ui.border) ~= "string" and type(cfg.ui.border) ~= "table" then
    error("typescope.setup: `ui.border` must be a string or table (any nvim float border value)", 0)
  end
  check("ui.anchor", cfg.ui.anchor, { "signature", "cursor" })

  check("highlights", cfg.highlights, "table")
  check("keymaps", cfg.keymaps, "table")
  for _, key in ipairs({ "expand", "toggle_examples", "llm_generate", "recurse", "close", "help" }) do
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

return M
