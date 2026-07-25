---@class typescope.FloatHandle
---@field buf integer
---@field win integer
---@field ns integer

local M = {}

local ns = vim.api.nvim_create_namespace("typescope")

---@param buf integer
---@param lines string[]
---@param highlights typescope.Highlight[]
local function set_content(buf, lines, highlights)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.group,
    })
  end
end

---@class typescope.FloatOpts
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field title? string
---@field footer? string
---@field row integer
---@field col integer
---@field relative "editor"|"cursor"|"win"
---@field width integer
---@field height integer
---@field border string|string[]
---@field enter? boolean
---@field focusable? boolean

---@param opts typescope.FloatOpts
---@return typescope.FloatHandle
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "typescope"
  set_content(buf, opts.lines, opts.highlights)

  local win = vim.api.nvim_open_win(buf, opts.enter or false, {
    relative = opts.relative,
    row = opts.row,
    col = opts.col,
    width = math.max(1, opts.width),
    height = math.max(1, opts.height),
    style = "minimal",
    border = opts.border,
    title = opts.title and { { opts.title, "TypeScopeTitle" } } or nil,
    footer = opts.footer and { { opts.footer, "TypeScopeHint" } } or nil,
    focusable = opts.focusable ~= false,
    zindex = 50,
  })
  vim.wo[win].wrap = false -- render.lua wraps manually to keep highlights exact
  vim.wo[win].cursorline = opts.enter or false

  return { buf = buf, win = win, ns = ns }
end

--- Swap content and resize in one synchronous block — no scheduling between
--- buffer and window updates, so expand/collapse never shows a partial frame.
---@param handle typescope.FloatHandle
---@param opts { lines: string[], highlights: typescope.Highlight[], width?: integer, height?: integer, title?: string }
function M.update(handle, opts)
  set_content(handle.buf, opts.lines, opts.highlights)
  local cfg = {}
  if opts.width then
    cfg.width = math.max(1, opts.width)
  end
  if opts.height then
    cfg.height = math.max(1, opts.height)
  end
  if opts.title then
    cfg.title = { { opts.title, "TypeScopeTitle" } }
  end
  if next(cfg) then
    vim.api.nvim_win_set_config(handle.win, cfg)
  end
end

---@param handle typescope.FloatHandle?
function M.close(handle)
  if handle and vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  end
end

return M
