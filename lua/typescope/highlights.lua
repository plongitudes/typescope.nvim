local M = {}

-- Every group is namespaced TypeScope* and defined with default=true, so user
-- colorschemes and the config `highlights` table can override without fighting us.
local groups = {
  TypeScopeField = { link = "@variable" },
  -- params match the capture a def rendering would give them, so the tree's
  -- colors agree with syntax-highlighted signatures elsewhere in the editor
  TypeScopeParam = { link = "@variable.parameter" },
  TypeScopeType = { link = "@type" },
  TypeScopeDefault = { link = "@constant" },
  TypeScopeExample = { link = "Comment" },
  TypeScopeChrome = { link = "NonText" },
  TypeScopeKeyword = { link = "@keyword" },
  TypeScopeBadge = { link = "@attribute" },
  TypeScopeEvaluated = { link = "Comment" },
  TypeScopeHeader = { link = "@function" },
  TypeScopeDocstring = { link = "Comment" },
  TypeScopeUnresolved = { link = "DiagnosticWarn" },
  TypeScopeHint = { link = "Comment" },
  TypeScopeActive = { link = "LspSignatureActiveParameter" },
  TypeScopeTitle = { link = "FloatTitle" },
  -- table layout (U5): alternating row backgrounds. Even rows keep the
  -- float's own background; odd rows link CursorLine — subtle in most
  -- themes, and it tracks the user's colorscheme (never invented colors).
  TypeScopeRowOdd = { link = "CursorLine" },
}

local applied = false

--- Blend two 24-bit colors: alpha=1 is all `fg`, alpha=0 is all `bg`.
--- Always computed from resolved theme colors, never invented — dimming a
--- group means walking it toward the user's own background.
---@param fg integer
---@param bg integer
---@param alpha number 0..1
---@return string "#rrggbb"
function M.blend(fg, bg, alpha)
  local function chan(div)
    local f = math.floor(fg / div) % 256
    local b = math.floor(bg / div) % 256
    return math.floor(f * alpha + b * (1 - alpha) + 0.5)
  end
  return ("#%02x%02x%02x"):format(chan(65536), chan(256), chan(1))
end

---@param name string
---@return integer? fg, integer? bg
local function hl_of(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok then
    return nil, nil
  end
  return hl.fg, hl.bg
end

--- The background dimmed colors walk toward.
---
--- Normal.bg first, but a transparent theme leaves it unset, and the 0 that
--- used to stand in for it means BLACK — past the terminal's own background,
--- so the dimmest rungs of the pending wave read as holes punched in the
--- float rather than as quiet blocks (Tony, reveal.mov, gruvbox-baby with a
--- transparent background). Fall back through the other places a theme still
--- states what it thinks its background is, and only then give up.
---@return integer
local function dim_toward()
  for _, name in ipairs({ "Normal", "NormalFloat" }) do
    local _, bg = hl_of(name)
    if bg then
      return bg
    end
  end
  -- a colorscheme hands the terminal its own palette even when it paints no
  -- background of its own; ANSI 0/15 is the end of it the float sits on
  local ansi = vim.o.background == "light" and vim.g.terminal_color_15 or vim.g.terminal_color_0
  if type(ansi) == "string" then
    local n = tonumber((ansi:gsub("^#", "")), 16)
    if n then
      return n
    end
  end
  local _, cursorline = hl_of("CursorLine")
  return cursorline or (vim.o.background == "light" and 0xffffff or 0)
end

--- Resolved fg of a group (following links), and the background to dim it
--- toward. fg may be nil when the colorscheme leaves it unset.
---@param name string
---@return integer? fg, integer bg
function M.resolve(name)
  local fg = hl_of(name)
  return fg, dim_toward()
end

-- Same hue as the header, dimmed: blend its resolved fg ~40% toward the
-- background and drop bold. Computed (not linked) because no stock group has
-- "darker @function" — recomputed on ColorScheme via apply().
local function header_dim()
  local fg, bg = M.resolve("TypeScopeHeader")
  if not fg then
    return { link = "Comment" }
  end
  return { fg = M.blend(fg, bg, 0.6) }
end

-- Examples whose LLM value is still coming (38c). The placeholder is a bar of
-- block characters and the animation is a wave travelling through it, so
-- brightness has to track HEIGHT: one group per rung of the charset ramp,
-- dimmest at ▁ and the full example color at ▇. They're static — the wave
-- moves characters between them, it never recolors anything — which is what
-- lets the whole animation ride an ordinary repaint, with no highlight
-- namespace and no forced redraw (jit).
M.PENDING_STEPS = 8
M.PENDING_ALPHA = 0.3 -- the dimmest rung; the tallest sits at the full color

--- Group for a bar cell at ramp rung `i` (1 = shortest).
---@param i integer
---@return string
function M.pending_group(i)
  return "TypeScopeExamplePending" .. math.max(1, math.min(M.PENDING_STEPS, i))
end

---@param i integer
local function example_pending(i)
  return function()
    local fg, bg = M.resolve("TypeScopeExample")
    if not fg then
      return { link = "Comment" }
    end
    local t = M.PENDING_STEPS > 1 and (i - 1) / (M.PENDING_STEPS - 1) or 1
    return { fg = M.blend(fg, bg, M.PENDING_ALPHA + (1 - M.PENDING_ALPHA) * t) }
  end
end

--- Define TypeScope* groups, layering config.highlights overrides on top.
function M.apply()
  local overrides = require("typescope.config").get().highlights
  for name, attrs in pairs(groups) do
    local hl = vim.tbl_extend("force", attrs, overrides[name] or {})
    hl.default = true
    vim.api.nvim_set_hl(0, name, hl)
  end
  local derived = { TypeScopeHeaderDim = header_dim }
  for i = 1, M.PENDING_STEPS do
    derived[M.pending_group(i)] = example_pending(i)
  end
  -- the unsuffixed name is what a static (animations-off) bar uses
  derived.TypeScopeExamplePending = example_pending(math.ceil(M.PENDING_STEPS / 2))
  for name, derive in pairs(derived) do
    -- derived groups: computed from the linked groups above, so they must be
    -- defined after the loop that installs them
    local hl = vim.tbl_extend("force", derive(), overrides[name] or {})
    hl.default = true
    vim.api.nvim_set_hl(0, name, hl)
  end
  -- explicit overrides must win even after a colorscheme clears everything
  for name, attrs in pairs(overrides) do
    if not groups[name] then
      vim.api.nvim_set_hl(0, name, attrs)
    end
  end

  if not applied then
    applied = true
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("TypeScopeHighlights", { clear = true }),
      callback = M.apply,
    })
  end
end

return M
