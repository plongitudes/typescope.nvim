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

-- Same hue as the header, dimmed: blend its resolved fg ~40% toward the
-- background and drop bold. Computed (not linked) because no stock group has
-- "darker @function" — recomputed on ColorScheme via apply().
local function header_dim()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "TypeScopeHeader", link = false })
  if not ok or not hl.fg then
    return { link = "Comment" }
  end
  local okn, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  local bg = (okn and normal.bg) or 0
  local alpha = 0.6
  local function chan(div)
    local f = math.floor(hl.fg / div) % 256
    local b = math.floor(bg / div) % 256
    return math.floor(f * alpha + b * (1 - alpha) + 0.5)
  end
  return { fg = ("#%02x%02x%02x"):format(chan(65536), chan(256), chan(1)) }
end

--- Define TypeScope* groups, layering config.highlights overrides on top.
function M.apply()
  local overrides = require("typescope.config").get().highlights
  for name, attrs in pairs(groups) do
    local hl = vim.tbl_extend("force", attrs, overrides[name] or {})
    hl.default = true
    vim.api.nvim_set_hl(0, name, hl)
  end
  do -- derived group: needs TypeScopeHeader defined first
    local hl = vim.tbl_extend("force", header_dim(), overrides.TypeScopeHeaderDim or {})
    hl.default = true
    vim.api.nvim_set_hl(0, "TypeScopeHeaderDim", hl)
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
