---@class typescope.FloatHandle
---@field buf integer
---@field win integer
---@field ns integer

local M = {}

local ns = vim.api.nvim_create_namespace("typescope")

local SKIP_CAPTURES = { spell = true, nospell = true, conceal = true, none = true }

--- Overlay real syntax highlighting on a source snippet embedded in a float
--- line: parse it with the language's TS parser and emit one extmark per
--- capture, above the base block color (which remains the fallback).
---@param buf integer
---@param line integer 0-indexed
---@param col integer byte offset of the snippet in the line
---@param snippet string
---@param lang string
---@param query vim.treesitter.Query
local function inject_highlights(buf, line, col, snippet, lang, query)
  local ok, parser = pcall(vim.treesitter.get_string_parser, snippet, lang)
  if not ok or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end
  for id, node in query:iter_captures(tree:root(), snippet) do
    local name = query.captures[id]
    if not SKIP_CAPTURES[name] and not name:match("^_") then
      local srow, scol, erow, ecol = node:range()
      if srow == 0 and erow == 0 then -- snippets are single-line
        vim.api.nvim_buf_set_extmark(buf, ns, line, col + scol, {
          end_col = col + ecol,
          hl_group = "@" .. name,
          priority = 110,
        })
      end
    end
  end
end

---@param buf integer
---@param lines string[]
---@param highlights typescope.Highlight[]
---@param injections? typescope.Injection[]
---@param lang? string
local function set_content(buf, lines, highlights, injections, lang)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local ok, query = pcall(vim.treesitter.query.get, lang or "", "highlights")
  query = ok and query or nil

  -- when real syntax highlighting will cover a span in "replace" mode, its
  -- base block mark is dropped entirely — otherwise attributes (bold/italic)
  -- from the semantic group bleed through under the syntax colors and the
  -- float stops matching normal code rendering
  local replaced = {}
  if query then
    for _, inj in ipairs(injections or {}) do
      if inj.mode ~= "overlay" then
        replaced[("%d:%d:%d"):format(inj.line, inj.col_start, inj.col_start + #inj.text)] = true
      end
    end
  end

  for _, hl in ipairs(highlights) do
    if not replaced[("%d:%d:%d"):format(hl.line, hl.col_start, hl.col_end)] then
      vim.api.nvim_buf_set_extmark(buf, ns, hl.line, hl.col_start, {
        end_col = hl.col_end,
        hl_group = hl.group,
        priority = 100,
      })
    end
  end
  if query and lang then
    for _, inj in ipairs(injections or {}) do
      inject_highlights(buf, inj.line, inj.col_start, inj.text, lang, query)
    end
  end
end

---@class typescope.FloatOpts
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field lang? string treesitter language for injected snippet highlighting
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
  set_content(buf, opts.lines, opts.highlights, opts.ts_injections, opts.lang)

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
---@param opts { lines: string[], highlights: typescope.Highlight[], ts_injections?: typescope.Injection[], lang?: string, width?: integer, height?: integer, title?: string }
function M.update(handle, opts)
  set_content(handle.buf, opts.lines, opts.highlights, opts.ts_injections, opts.lang)
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

--- Open the anchor float from markdown lines (signatureHelp or hover
--- content). Built with stable utils (open_floating_preview) instead of the
--- deprecated builtin handlers — same rendered content, and we get the winid
--- and own the lifecycle (close_events = {}).
---@param lines string[] markdown lines
---@param opts { border: string|string[], max_width: integer, max_height?: integer }
---@return typescope.FloatHandle?
function M.open_markdown(lines, opts)
  local ok, buf, win = pcall(vim.lsp.util.open_floating_preview, lines, "markdown", {
    border = opts.border,
    max_width = opts.max_width,
    max_height = opts.max_height or 8, -- anchor stays compact; docstrings can be long
    focusable = false,
    close_events = {},
  })
  if not ok or not win then
    return nil
  end
  return { buf = buf, win = win, ns = ns }
end

--- Editor-grid row/col where an anchored float should open to sit directly
--- below `win` (border rows accounted for), left edges aligned.
---@param win integer
---@return integer row, integer col, integer width
function M.below(win)
  local pos = vim.api.nvim_win_get_position(win)
  local height = vim.api.nvim_win_get_height(win)
  local cfg = vim.api.nvim_win_get_config(win)
  local border_rows = (cfg.border and cfg.border ~= "none") and 2 or 0
  return pos[1] + height + border_rows, pos[2], vim.api.nvim_win_get_width(win)
end

return M
