---@class typescope.FloatHandle
---@field buf integer
---@field win integer
---@field ns integer
---@field panel? { buf: integer, win: integer } the ledger's docked detail panel, below the main window inside one frame
---@field budget? integer content rows main + panel may share (panel floats only); fixed at open so the frame never outgrows its side of the cursor
---@field frame? typescope.Frame

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

-- per-buffer signature of what each line was last painted WITH, so a line
-- whose text is unchanged but whose colors moved still gets repainted. The
-- pending heuristic pulse is exactly that case: same characters, a different
-- rung group every frame.
--
-- Declared HERE, above the functions that touch it: it used to sit below
-- _forget, so `painted[buf] = nil` there resolved to a global (nil) and threw
-- on the one call that would have bounded this table.
local painted = {} ---@type table<integer, table<integer, string>>

--- Forget a buffer's paint signatures (it's about to be wiped). Called from
--- M.close rather than left to the callers: buffer handles are NOT reused, so
--- an entry per float open is retained for the life of the session otherwise.
---@param buf integer
function M._forget(buf)
  painted[buf] = nil
end

--- Buffers currently holding paint signatures (test seam).
---@return integer
function M._painted_count()
  return vim.tbl_count(painted)
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
---
--- Only `inj.from`..`inj.to` of the snippet is on screen — the rest wrapped to
--- another line, or is still under a falling block. The whole snippet is what
--- gets parsed (a fragment parses as nothing), and the spans are then clipped
--- to the visible slice and placed relative to it. That also means a reveal
--- asks for the same snippet on every one of its frames, so it parses once.
---@param buf integer
---@param line integer 0-indexed
---@param col integer byte offset of the visible slice in the line
---@param inj typescope.Injection
---@param lang string
---@param query vim.treesitter.Query
local function inject_highlights(buf, line, col, inj, lang, query)
  local from = inj.from or 0
  local to = inj.to or #inj.text
  for _, span in ipairs(capture_spans(inj.text, lang, query)) do
    local s, e = math.max(span[1], from), math.min(span[2], to)
    if s < e then
      vim.api.nvim_buf_set_extmark(buf, ns, line, col + s - from, {
        end_col = col + e - from,
        hl_group = span[3],
        priority = 110,
      })
    end
  end
end

---@param highlights typescope.Highlight[]
---@param injections? typescope.Injection[]
---@return table<integer, string>
local function line_signatures(highlights, injections)
  local sig = {}
  for _, hl in ipairs(highlights) do
    sig[hl.line] = (sig[hl.line] or "") .. ("%d:%d:%s;"):format(hl.col_start, hl.col_end, hl.group)
  end
  for _, inj in ipairs(injections or {}) do
    sig[inj.line] = (sig[inj.line] or "")
      .. ("i%d:%s:%d:%d;"):format(inj.col_start, inj.mode or "", inj.from or 0, inj.to or #inj.text)
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

---@param buf integer
---@param lines string[]
---@param highlights typescope.Highlight[]
---@param injections? typescope.Injection[]
---@param lang? string
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
        local width = (inj.to or #inj.text) - (inj.from or 0)
        replaced[("%d:%d:%d"):format(inj.line, inj.col_start, inj.col_start + width)] = true
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
        inject_highlights(buf, inj.line, inj.col_start, inj, lang, query)
      end
    end
  end
end

---@param footer? string|{ [1]: string, [2]: string }[]
---@return { [1]: string, [2]: string }[]?
local function footer_chunks(footer)
  if type(footer) == "string" then
    return { { footer, "TypeScopeHint" } }
  end
  return footer
end

-- ── the docked panel ─────────────────────────────────────────────────────
--
-- The ledger's details live in a second window under the rows, drawn as one
-- frame: the main window keeps the top of the border and loses the bottom,
-- the panel's top edge is the separator (├───┤) and it carries the bottom
-- and the footer. Floats cannot share a border, so the frame is two partial
-- ones that meet.
--
-- Both windows are placed relative to the EDITOR at positions computed here.
-- relative = "cursor" would re-anchor to whatever window has focus on every
-- set_config (the float itself, once entered), and nvim nudges a float that
-- does not fit back on screen one window at a time, which would tear the
-- frame. So the side of the cursor is chosen once, at open, and the content
-- budget is capped to what fits there.

-- corners, edges and the tees a separator needs, per named border
local FRAMES = {
  single = { "┌", "─", "┐", "│", "┘", "─", "└", "│", "├", "┤" },
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│", "├", "┤" },
  double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║", "╠", "╣" },
  bold = { "┏", "━", "┓", "┃", "┛", "━", "┗", "┃", "┣", "┫" },
  solid = { " ", " ", " ", " ", " ", " ", " ", " ", " ", " " },
}

---@class typescope.Frame
---@field main_open any border for the main window while the panel shows
---@field main_closed any border for the main window alone
---@field panel any border for the panel
---@field top integer rows the main window's border adds above its content
---@field between integer rows between the main window's content and the panel's
---@field bottom integer rows under the panel's content
---@field below boolean the frame hangs under the cursor (else sits above it)
---@field row integer source cursor's screen row, 0-indexed
---@field col integer source cursor's screen column, 0-indexed

---@param border any a float border value
---@return typescope.Frame
local function frame_for(border)
  local f = type(border) == "string" and FRAMES[border] or nil
  if f then
    return {
      main_open = { f[1], f[2], f[3], f[4], "", "", "", f[8] },
      main_closed = { f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8] },
      panel = { f[9], f[2], f[10], f[4], f[5], f[6], f[7], f[8] },
      top = 1,
      between = 1,
      bottom = 1,
    }
  end
  -- "none", "shadow", a custom array: two boxes stacked, each its own border
  local edge = (border == nil or border == "none") and 0 or 1
  return {
    main_open = border,
    main_closed = border,
    panel = border,
    top = edge,
    between = 2 * edge,
    bottom = edge,
  }
end

--- Content rows the panel float can hold on its side of the cursor.
---@param frame typescope.Frame
---@param max_height integer
---@return integer budget
local function place_frame(frame, max_height)
  local chrome = frame.top + frame.between + frame.bottom
  local screen = vim.o.lines - vim.o.cmdheight
  local below = screen - frame.row - 1
  local above = frame.row
  frame.below = below >= max_height + chrome or below >= above
  local room = (frame.below and below or above) - chrome
  return math.max(2, math.min(max_height, room))
end

---@class typescope.FloatOpts
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field lang? string treesitter language for injected snippet highlighting
---@field title? string
---@field footer? string|{ [1]: string, [2]: string }[] text, or chunks with highlight groups
---@field panel? { row: integer, col: integer, max_height: integer } open with a docked panel; row/col are the source cursor's 0-indexed SCREEN position the frame hangs from, max_height the content rows rows + panel may use (ui.max_height)
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
  -- No undo history. Every animation frame rewrites the lines it repaints, and
  -- each of those writes records an undo state on a buffer nobody can undo
  -- into — it is scratch, and nomodifiable except inside set_content. The
  -- history is never read and never trimmed, so it is pure growth: measured at
  -- 15.6 KB per frame, 188 MB over 12000 frames, none of it reclaimable by the
  -- Lua collector because it isn't Lua memory. At 60fps that is 3.4 GB an
  -- hour, which is how nvim came to be holding 20GB of a machine that had run
  -- out of it (Tony, 2026-08-24). Same load with undo off: 1.7 MB.
  vim.bo[buf].undolevels = -1
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
    footer = footer_chunks(opts.footer),
    focusable = opts.focusable ~= false,
    zindex = 50,
  })
  vim.wo[win].wrap = false -- render.lua wraps manually to keep highlights exact
  vim.wo[win].cursorline = opts.enter or false

  local handle = { buf = buf, win = win, ns = ns } ---@type typescope.FloatHandle
  if opts.panel then
    local frame = frame_for(opts.border)
    frame.row, frame.col = opts.panel.row, opts.panel.col
    handle.frame = frame
    handle.budget = place_frame(frame, opts.panel.max_height)
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[pbuf].bufhidden = "wipe"
    vim.bo[pbuf].undolevels = -1 -- repainted every animation frame; see above
    painted[pbuf] = nil
    -- not "typescope": what finds the float by filetype means the rows
    vim.bo[pbuf].filetype = "typescope_panel"
    local pwin = vim.api.nvim_open_win(pbuf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = math.max(1, opts.width),
      height = 1,
      style = "minimal",
      border = frame.panel,
      focusable = false,
      hide = true, -- laid out by the first update
      zindex = 50,
    })
    vim.wo[pwin].wrap = false
    handle.panel = { buf = pbuf, win = pwin }
  end
  return handle
end

local applied = {} ---@type table<integer, string> win -> key of the config it last got

--- Compare-then-set: set_config makes nvim redo window layout, and refresh()
--- runs 60 times a second while anything animates. `key` is whatever
--- describes the config (tables compare by identity, so callers pass a
--- string); an unchanged key is a no-op.
---@param win integer
---@param cfg table
---@param key string
local function configure(win, cfg, key)
  if applied[win] == key or not vim.api.nvim_win_is_valid(win) then
    return
  end
  applied[win] = key
  vim.api.nvim_win_set_config(win, cfg)
end

---@class typescope.PanelUpdate
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field height integer

--- Lay out a panel float: the main window and, when `panel` is given, the
--- docked panel under it, as one frame on the side of the cursor chosen at
--- open. `panel = nil` hides it (help, doc view) and closes the frame on the
--- main window instead.
---@param handle typescope.FloatHandle
---@param width integer
---@param main_h integer
---@param panel? typescope.PanelUpdate
---@param footer? { [1]: string, [2]: string }[]
---@param lang? string
local function layout(handle, width, main_h, panel, footer, lang)
  local frame = handle.frame
  local p = handle.panel
  local open = panel ~= nil and p ~= nil and vim.api.nvim_win_is_valid(p.win)
  local panel_h = open and panel.height or 0
  local total = frame.top + main_h + frame.bottom + (open and (frame.between + panel_h) or 0)
  -- the frame's outer width: content plus a column of border each side
  local side = frame.top > 0 and 1 or 0
  local col = math.max(0, math.min(frame.col, vim.o.columns - width - 2 * side))
  local top = frame.below and (frame.row + 1) or (frame.row - total)
  local fkey = vim.inspect(footer)
  configure(handle.win, {
    relative = "editor",
    row = top,
    col = col,
    width = math.max(1, width),
    height = math.max(1, main_h),
    border = open and frame.main_open or frame.main_closed,
    -- the footer belongs to whichever window draws the frame's bottom; ""
    -- takes it back off the main window when the panel opens under it
    footer = (not open and footer) or "",
  }, table.concat({ top, col, width, main_h, tostring(open), open and "" or fkey }, ":"))
  if not p or not vim.api.nvim_win_is_valid(p.win) then
    return
  end
  if not open then
    configure(p.win, { hide = true }, "hidden")
    return
  end
  set_content(p.buf, panel.lines, panel.highlights, panel.ts_injections, lang)
  configure(p.win, {
    relative = "editor",
    row = top + frame.top + main_h + frame.between - (frame.between > 0 and 1 or 0),
    col = col,
    width = math.max(1, width),
    height = math.max(1, panel_h),
    border = frame.panel,
    footer = footer,
    hide = false,
  }, table.concat({ top, col, width, main_h, panel_h, fkey }, ":"))
end

--- Swap content and resize in one synchronous block — no scheduling between
--- buffer and window updates, so expand/collapse never shows a partial frame.
---@param handle typescope.FloatHandle
---@param opts { lines: string[], highlights: typescope.Highlight[], ts_injections?: typescope.Injection[], lang?: string, width?: integer, height?: integer, title?: string, panel?: typescope.PanelUpdate, footer?: { [1]: string, [2]: string }[] }
function M.update(handle, opts)
  set_content(handle.buf, opts.lines, opts.highlights, opts.ts_injections, opts.lang)
  if handle.frame then
    layout(handle, opts.width, opts.height, opts.panel, opts.footer, opts.lang)
    return
  end
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
  if not handle then
    return
  end
  -- outside the validity check on purpose: a float dismissed by the user (:q,
  -- WinClosed) reaches here with its window already gone, and its signatures
  -- still have to be dropped. The buffer is bufhidden=wipe, so by now it may
  -- be gone too — forgetting a buffer that no longer exists is the point.
  M._forget(handle.buf)
  applied[handle.win] = nil
  if vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  end
  if handle.panel then
    M._forget(handle.panel.buf)
    applied[handle.panel.win] = nil
    if vim.api.nvim_win_is_valid(handle.panel.win) then
      vim.api.nvim_win_close(handle.panel.win, true)
    end
  end
end

return M
