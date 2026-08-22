---@class typescope.FloatHandle
---@field buf integer
---@field win integer
---@field ns integer

local M = {}

local ns = vim.api.nvim_create_namespace("typescope")

local SKIP_CAPTURES = { spell = true, nospell = true, conceal = true, none = true }

-- Captures for a snippet, keyed lang\0snippet. get_string_parser() builds a
-- WHOLE new parser and tree per call, and those live on the C heap where Lua's
-- own GC accounting can't see them — 28 snippets a frame at 60fps grew RSS by
-- ~12MB per 600 frames and dragged frame time from 1.6ms to 2.3ms as the
-- pressure built. A snippet's captures are a pure function of its text, and
-- animation frames re-render the SAME text over and over, so memoising turns
-- the steady state into zero parses.
local captures = {}
local captures_n = 0
local CAPTURES_CAP = 512

--- Test seam + colorscheme/query reloads.
function M._clear_capture_cache()
  captures, captures_n = {}, 0
end

--- Forget a buffer's paint signatures (it's about to be wiped).
---@param buf integer
function M._forget(buf)
  painted[buf] = nil
end

--- Byte ranges + highlight groups for a single-line snippet.
---@param snippet string
---@param lang string
---@param query vim.treesitter.Query
---@return { [1]: integer, [2]: integer, [3]: string }[]
local function capture_spans(snippet, lang, query)
  local key = lang .. "\0" .. snippet
  local hit = captures[key]
  if hit then
    return hit
  end
  local spans = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, snippet, lang)
  local tree = ok and parser and parser:parse()[1] or nil
  if tree then
    for id, node in query:iter_captures(tree:root(), snippet) do
      local name = query.captures[id]
      if not SKIP_CAPTURES[name] and not name:match("^_") then
        local srow, scol, erow, ecol = node:range()
        if srow == 0 and erow == 0 then -- snippets are single-line
          table.insert(spans, { scol, ecol, "@" .. name })
        end
      end
    end
  end
  if captures_n >= CAPTURES_CAP then
    captures, captures_n = {}, 0 -- crude cap, same bargain as the resolve cache
  end
  captures[key] = spans
  captures_n = captures_n + 1
  return spans
end

--- Overlay real syntax highlighting on a source snippet embedded in a float
--- line, above the base block color (which remains the fallback).
---@param buf integer
---@param line integer 0-indexed
---@param col integer byte offset of the snippet in the line
---@param snippet string
---@param lang string
---@param query vim.treesitter.Query
local function inject_highlights(buf, line, col, snippet, lang, query)
  for _, span in ipairs(capture_spans(snippet, lang, query)) do
    vim.api.nvim_buf_set_extmark(buf, ns, line, col + span[1], {
      end_col = col + span[2],
      hl_group = span[3],
      priority = 110,
    })
  end
end

---@param buf integer
---@param lines string[]
---@param highlights typescope.Highlight[]
---@param injections? typescope.Injection[]
---@param lang? string
-- per-buffer signature of what each line was last painted WITH, so a line
-- whose text is unchanged but whose colors moved still gets repainted. The
-- pending heuristic pulse is exactly that case: same characters, a different
-- rung group every frame.
local painted = {} ---@type table<integer, table<integer, string>>

---@param highlights typescope.Highlight[]
---@param injections? typescope.Injection[]
---@return table<integer, string>
local function line_signatures(highlights, injections)
  local sig = {}
  for _, hl in ipairs(highlights) do
    sig[hl.line] = (sig[hl.line] or "") .. ("%d:%d:%s;"):format(hl.col_start, hl.col_end, hl.group)
  end
  for _, inj in ipairs(injections or {}) do
    sig[inj.line] = (sig[inj.line] or "") .. ("i%d:%s;"):format(inj.col_start, inj.mode or "")
  end
  return sig
end

--- Lines that differ from what the buffer already shows, in text OR in paint.
--- Returns nil when the line COUNT changed — then everything below the change
--- shifts, and a full rewrite is simpler and no more expensive.
---@param buf integer
---@param lines string[]
---@param sig table<integer, string>
---@return integer[]? changed 0-indexed line numbers
local function changed_lines(buf, lines, sig)
  local have = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local was = painted[buf]
  if #have ~= #lines or not was then
    return nil
  end
  local changed = {}
  for i, line in ipairs(lines) do
    if have[i] ~= line or was[i - 1] ~= sig[i - 1] then
      table.insert(changed, i - 1)
    end
  end
  return changed
end

local function set_content(buf, lines, highlights, injections, lang)
  -- Repaint only what moved. A full rewrite every frame — set_lines over the
  -- whole buffer, clear the namespace, rebuild ~80 extmarks — churns the
  -- marktree hard enough to grow RSS by ~6MB per 600 frames on its own, and
  -- an animation frame usually touches two or three rows. Line-count changes
  -- still take the whole-buffer path: everything below the change shifts.
  local sig = line_signatures(highlights, injections)
  local touched = changed_lines(buf, lines, sig)
  painted[buf] = sig
  if touched and #touched == 0 then
    return -- nothing moved at all
  end

  vim.bo[buf].modifiable = true
  if touched then
    for _, i in ipairs(touched) do
      vim.api.nvim_buf_set_lines(buf, i, i + 1, false, { lines[i + 1] })
      vim.api.nvim_buf_clear_namespace(buf, ns, i, i + 1)
    end
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  vim.bo[buf].modifiable = false

  -- only marks belonging to a repainted line need replacing
  local repaint = nil
  if touched then
    repaint = {}
    for _, i in ipairs(touched) do
      repaint[i] = true
    end
  end

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
    if (not repaint or repaint[hl.line]) and not replaced[("%d:%d:%d"):format(hl.line, hl.col_start, hl.col_end)] then
      vim.api.nvim_buf_set_extmark(buf, ns, hl.line, hl.col_start, {
        end_col = hl.col_end,
        hl_group = hl.group,
        priority = hl.priority or 100,
      })
    end
  end
  if query and lang then
    for _, inj in ipairs(injections or {}) do
      if not repaint or repaint[inj.line] then
        inject_highlights(buf, inj.line, inj.col_start, inj.text, lang, query)
      end
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
---@field anchor? "NW"|"NE"|"SW"|"SE"

---@param opts typescope.FloatOpts
---@return typescope.FloatHandle
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  -- buffer numbers get reused; a stale signature table would convince the
  -- incremental repaint that lines it has never drawn are already correct
  painted[buf] = nil
  vim.bo[buf].filetype = "typescope"
  set_content(buf, opts.lines, opts.highlights, opts.ts_injections, opts.lang)

  local win = vim.api.nvim_open_win(buf, opts.enter or false, {
    relative = opts.relative,
    anchor = opts.anchor,
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
  -- Only reconfigure when something ACTUALLY differs. refresh() passes width
  -- and height on every animation frame, and neither changes once the float
  -- has settled — st.width only grows and the line count holds steady while
  -- the wave travels. Calling set_config anyway made nvim redo window layout
  -- and cursor placement 60x a second, which is both wasted work and a way to
  -- get the block cursor painted somewhere stale for a frame. Compared
  -- against the window's live config rather than a remembered value, so an
  -- external resize still corrects on the next frame.
  if next(cfg) then
    local ok, cur = pcall(vim.api.nvim_win_get_config, handle.win)
    local differs = not ok
      or (cfg.width and cfg.width ~= cur.width)
      or (cfg.height and cfg.height ~= cur.height)
      or cfg.title ~= nil -- title is a nested table; never worth diffing
    if differs then
      vim.api.nvim_win_set_config(handle.win, cfg)
    end
  end
end

---@param handle typescope.FloatHandle?
function M.close(handle)
  if handle and vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  end
end

return M
