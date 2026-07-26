-- Lightweight "▸ typescope" eol virtual-text marker on call lines that
-- resolved successfully — a quiet signal that TypeScope has data here.
-- Extmarks ride along with edits; one marker per line, per buffer.

local M = {}

local ns = vim.api.nvim_create_namespace("typescope_hint")

---@param bufnr integer
---@param row integer 0-based line of the resolved call
function M.place(bufnr, row)
  if not require("typescope.config").get().ui.hint then
    return
  end
  local style = require("typescope.styles").get(require("typescope.config").get().ui.style)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
    virt_text = { { style.collapsed .. "typescope", "TypeScopeHint" } },
    virt_text_pos = "eol",
  })
end

---@param bufnr? integer clear one buffer, or all loaded buffers when nil
function M.clear(bufnr)
  if bufnr then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
    end
  end
end

return M
