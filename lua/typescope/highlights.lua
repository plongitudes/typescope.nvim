local M = {}

-- Every group is namespaced TypeScope* and defined with default=true, so user
-- colorschemes and the config `highlights` table can override without fighting us.
local groups = {
  TypeScopeField = { link = "@variable" },
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
}

local applied = false

--- Define TypeScope* groups, layering config.highlights overrides on top.
function M.apply()
  local overrides = require("typescope.config").get().highlights
  for name, attrs in pairs(groups) do
    local hl = vim.tbl_extend("force", attrs, overrides[name] or {})
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
