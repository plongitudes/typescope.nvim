---@class typescope.FloatHandle
---@field buf integer
---@field win integer
---@field ns integer
---@field header? typescope.HeaderPane the frame's header pane, above the outline (the handle's own buf/win are the outline)
---@field inspector? { buf: integer, win: integer } the frame's loupe, below the outline
---@field budget? integer content rows the frame's panes may share; fixed at open so the frame never outgrows its side of the cursor
---@field frame? typescope.Frame

---@class typescope.HeaderPane
---@field buf integer
---@field win integer
---@field height integer content rows, fixed at open: the tallest group's
---@field groups typescope.HeaderContent[] one per overload group, each fit to `height`
---@field shown? integer the group on display
---@field lang? string

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

-- ── the frame ────────────────────────────────────────────────────────────────
--
-- The K float is a frame of three panes stacked on one side of the cursor
-- (ADR 0001): the header, the outline, and the loupe under it (the inspector,
-- for now). Each pane is a whole box in the user's border style, so every
-- seam is two rows, the upper pane's bottom border and the lower pane's top
-- border; the panes do different jobs and are meant to read as separate.
--
-- All three are placed relative to the EDITOR at positions computed here.
-- relative = "cursor" would re-anchor to whatever window has focus on every
-- set_config (the float itself, once entered), and nvim nudges a float that
-- does not fit back on screen one window at a time, which would tear the
-- frame. So the side of the cursor is chosen once, at open, and the content
-- budget is capped to what fits there.

-- the glyph each named border draws its bottom edge with
local RULES = { single = "─", rounded = "─", double = "═", bold = "━", solid = " " }

---@class typescope.Frame
---@field border any the float's border option
---@field below boolean the frame hangs under the cursor (else sits above it); chosen at open
---@field row integer source cursor's screen row, 0-indexed
---@field col integer source cursor's screen column, 0-indexed
---@field min_height? table<string, integer> ui.min_height

--- Rows a pane's border adds above and below its content, and the chunk its
--- bottom edge is drawn with (nil: no edge, so no footer).
---@param border any a float border value
---@return integer edge, { [1]: string, [2]: string }? rule
local function chrome_of(border)
  if border == nil or border == "none" then
    return 0, nil
  end
  if type(border) == "string" then
    return 1, RULES[border] and { RULES[border], "FloatBorder" } or nil
  end
  -- a custom array repeats to fill eight cells; the bottom edge is the sixth
  local cell = border[(5 % #border) + 1]
  if type(cell) == "table" then
    return 1, { cell[1], cell[2] or "FloatBorder" }
  end
  return 1, { cell, "FloatBorder" }
end

-- the most rows the inspector takes from the leftovers; a minimum above it
-- still holds
local INSPECTOR_CAP = 5

--- Share `budget` content rows among the shown panes. Each pane first gets
--- its minimum, or its content if that is less (an empty pane is still a
--- row). Rows left over go to the header until it is fully wrapped, then to
--- the inspector up to INSPECTOR_CAP, then to the outline. Minimums that
--- overrun the budget give way outline first, then header, then inspector,
--- never below a row each — which the budget floor of 3 guarantees.
---@param stack { name: string, rows: integer }[]
---@param min_height table<string, integer> per pane; missing = 1
---@param budget integer
---@return table<string, integer>
local function allot(stack, min_height, budget)
  local want, got, used = {}, {}, 0
  for _, pane in ipairs(stack) do
    want[pane.name] = math.max(1, pane.rows)
    got[pane.name] = math.min(want[pane.name], math.max(1, min_height[pane.name] or 1))
    used = used + got[pane.name]
  end
  for _, name in ipairs({ "outline", "header", "inspector" }) do
    if got[name] and used > budget then
      local give = math.min(got[name] - 1, used - budget)
      got[name], used = got[name] - give, used - give
    end
  end
  local upto = {
    header = want.header,
    inspector = want.inspector and math.max(got.inspector, math.min(want.inspector, INSPECTOR_CAP)),
    outline = want.outline,
  }
  for _, name in ipairs({ "header", "inspector", "outline" }) do
    if got[name] and used < budget then
      local take = math.max(0, math.min(upto[name] - got[name], budget - used))
      got[name], used = got[name] + take, used + take
    end
  end
  return got
end

---@class typescope.FrameSpec
---@field border any the float's border option
---@field row integer source cursor's screen row, 0-indexed
---@field col integer source cursor's screen column, 0-indexed
---@field lines integer screen rows floats may use (lines - cmdheight)
---@field columns integer screen columns
---@field max_height integer content rows the panes may share (ui.max_height); borders are extra
---@field min_height? table<string, integer> rows each pane keeps before leftovers are shared (ui.min_height); missing = 1
---@field below? boolean the side chosen at open; nil chooses it
---@field width integer content width
---@field header? integer the header's content rows; nil: no header (a class hover's root row is its own)
---@field outline integer the outline's content rows
---@field inspector? integer the inspector's content rows; nil hides it (help, doc view) and the outline closes the frame

---@class typescope.PaneLayout
---@field row integer the pane's outer top edge, as an offset from the frame's top
---@field height integer content rows
---@field border any
---@field footer boolean the pane draws the frame's bottom edge, so it carries the footer

---@class typescope.FrameLayout
---@field below boolean
---@field budget integer content rows the panes can share on this side of the cursor
---@field top integer the frame's screen row
---@field col integer the frame's screen column
---@field width integer
---@field rule? { [1]: string, [2]: string } the bottom edge's glyph, which the footer ends on
---@field header? typescope.PaneLayout nil without a header
---@field outline typescope.PaneLayout
---@field inspector? typescope.PaneLayout nil while hidden

--- Where every pane of the frame goes: the side of the cursor, the content
--- budget there, and each pane's rows. Pure — reads no editor state, opens
--- nothing — so the arithmetic is testable on its own and the window code
--- only applies what this returns.
---@param spec typescope.FrameSpec
---@return typescope.FrameLayout
function M.frame_layout(spec)
  local edge, rule = chrome_of(spec.border)
  local stack = {} ---@type { name: string, rows: integer }[]
  for _, name in ipairs({ "header", "outline", "inspector" }) do
    if spec[name] then
      table.insert(stack, { name = name, rows = spec[name] })
    end
  end
  local chrome = 2 * edge * #stack
  local below_room = spec.lines - spec.row - 1
  local above_room = spec.row
  local below = spec.below
  if below == nil then
    below = below_room >= spec.max_height + chrome or below_room >= above_room
  end
  local room = (below and below_room or above_room) - chrome
  local budget = math.max(3, math.min(spec.max_height, room))
  local heights = allot(stack, spec.min_height or {}, budget)

  local layout = {
    below = below,
    budget = budget,
    col = math.max(0, math.min(spec.col, spec.columns - spec.width - 2 * edge)),
    width = math.max(1, spec.width),
    rule = rule,
  }
  local offset = 0
  for i, pane in ipairs(stack) do
    layout[pane.name] = {
      row = offset,
      height = heights[pane.name],
      border = spec.border,
      footer = i == #stack,
    }
    offset = offset + 2 * edge + heights[pane.name]
  end
  layout.top = below and (spec.row + 1) or (spec.row - offset)
  return layout
end

--- The frame's inputs that come from the editor rather than the caller.
---@param frame typescope.Frame
---@param fields table the rest of the typescope.FrameSpec
---@return typescope.FrameLayout
local function frame_layout(frame, fields)
  return M.frame_layout(vim.tbl_extend("force", {
    border = frame.border,
    row = frame.row,
    col = frame.col,
    below = frame.below,
    min_height = frame.min_height,
    lines = vim.o.lines - vim.o.cmdheight,
    columns = vim.o.columns,
  }, fields))
end

---@class typescope.HeaderContent
---@field lines string[] the header wrapped to as many rows as it needs
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field fit? fun(rows: integer): typescope.HeaderContent the header redrawn to fit `rows` (middle-elided)
---@field tag? { [1]: string, [2]: string }[] chunks for the header's bottom border, right-aligned (an overload group's `✓ [i/n]`)

---@class typescope.FloatOpts
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field lang? string treesitter language for injected snippet highlighting
---@field title? string
---@field footer? string|{ [1]: string, [2]: string }[] text, or chunks with highlight groups
---@field frame? { row: integer, col: integer, max_height: integer, min_height?: table<string, integer> } open as the K float's frame (header, outline, inspector); row/col are the source cursor's 0-indexed SCREEN position the frame hangs from, max_height the content rows the panes may share (ui.max_height), min_height each pane's minimum (ui.min_height)
---@field headers? typescope.HeaderContent[] the frame's header pane, one per overload group (a plain callable has one); nil opens the frame without one
---@field header_shown? integer the group the header opens on (default 1)
---@field row integer
---@field col integer
---@field relative "editor"|"cursor"|"win"
---@field width integer
---@field height integer
---@field border string|string[]
---@field enter? boolean
---@field focusable? boolean
---@field anchor? "NW"|"NE"|"SW"|"SE"

--- A pane other than the outline: a scratch buffer in a window that is
--- placed, and shown, by the first update.
---@param filetype string
---@param border any
---@return { buf: integer, win: integer }
local function pane_window(filetype, border)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].undolevels = -1 -- repainted every animation frame; see M.open
  painted[buf] = nil
  vim.bo[buf].filetype = filetype
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 1,
    height = 1,
    style = "minimal",
    border = border,
    focusable = false,
    hide = true,
    zindex = 50,
  })
  vim.wo[win].wrap = false
  return { buf = buf, win = win }
end

--- Draw overload group `i` into the header pane. Its tag rides the pane's
--- bottom border, which the next layout places.
---@param hdr typescope.HeaderPane
---@param i integer
local function show_header(hdr, i)
  local head = hdr.groups[i]
  if not head or i == hdr.shown then
    return
  end
  hdr.shown = i
  set_content(hdr.buf, head.lines, head.highlights, head.ts_injections, hdr.lang)
end

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
  if opts.frame then
    local frame = { ---@type typescope.Frame
      border = opts.border,
      row = opts.frame.row,
      col = opts.frame.col,
      min_height = opts.frame.min_height,
    }
    -- the header is as tall as the tallest group, so the outline never
    -- shifts as the cursor crosses from one group to another
    local tallest = nil
    for _, head in ipairs(opts.headers or {}) do
      tallest = math.max(tallest or 0, #head.lines)
    end
    -- the side is chosen with every pane shown; the first update decides the rest
    local placed = frame_layout(frame, {
      max_height = opts.frame.max_height,
      width = opts.width,
      header = tallest,
      outline = opts.height,
      inspector = 1,
    })
    frame.below = placed.below
    handle.frame = frame
    handle.budget = placed.budget
    -- not "typescope": what finds the float by filetype means the outline
    handle.inspector = pane_window("typescope_inspector", opts.border)
    if tallest then
      -- the header's height is fixed here, for the life of the float: as
      -- many rows as the tallest group wraps to, unless the budget allots it
      -- fewer, and then every group past them is redrawn cut to them
      local rows = placed.header.height
      local groups = {}
      for i, head in ipairs(opts.headers) do
        groups[i] = #head.lines > rows and head.fit and vim.tbl_extend("keep", head.fit(rows), head) or head
      end
      handle.header = pane_window("typescope_header", opts.border)
      handle.header.height = rows
      handle.header.groups = groups
      handle.header.lang = opts.lang
      show_header(handle.header, opts.header_shown or 1)
    end
  end
  return handle
end

--- The rows the frame's panes get for this content, on the side and budget
--- fixed at open — what the next update will lay out, for callers that cut
--- content to fit before handing it over (the inspector's `…`).
---@param handle typescope.FloatHandle a frame
---@param outline integer the outline's content rows
---@param inspector? integer the inspector's content rows; nil: hidden
---@return typescope.FrameLayout
function M.heights(handle, outline, inspector)
  return frame_layout(handle.frame, {
    max_height = handle.budget,
    width = 1,
    header = handle.header and handle.header.height or nil,
    outline = outline,
    inspector = inspector,
  })
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

---@class typescope.InspectorUpdate
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections? typescope.Injection[]
---@field height integer

--- Lay out the frame: the header, the outline, and, when `inspector` is
--- given, the inspector under them, on the side of the cursor chosen at open.
--- `inspector = nil` hides it (help, doc view) and the outline closes the
--- frame instead.
---@param handle typescope.FloatHandle
---@param width integer
---@param outline_h integer
---@param inspector? typescope.InspectorUpdate
---@param footer? { [1]: string, [2]: string }[]
---@param lang? string
local function layout(handle, width, outline_h, inspector, footer, lang)
  local p = handle.inspector
  local open = inspector ~= nil and p ~= nil and vim.api.nvim_win_is_valid(p.win)
  local hdr = handle.header
  local placed = frame_layout(handle.frame, {
    max_height = handle.budget,
    width = width,
    header = hdr and hdr.height or nil,
    outline = outline_h,
    inspector = open and inspector.height or nil,
  })
  -- right-justified on a bottom edge, ending one rule glyph short of the
  -- corner: ╰────── ? help ─╯
  local function on_rule(chunks)
    if chunks and placed.rule then
      return vim.list_extend(vim.list_extend({}, chunks), { placed.rule })
    end
  end
  footer = on_rule(footer)

  ---@param pane typescope.PaneLayout
  ---@param tag? { [1]: string, [2]: string }[] the pane's own bottom-edge chunks (the header's `✓ [i/n]`)
  local function place(win, pane, tag)
    local chunks = pane.footer and footer or on_rule(tag)
    local row = placed.top + pane.row
    local cfg = {
      relative = "editor",
      row = row,
      col = placed.col,
      width = placed.width,
      height = pane.height,
      border = pane.border,
      hide = false,
    }
    -- the footer belongs to whichever pane draws the frame's bottom; "" takes
    -- it back off the outline when the inspector opens under it. A border-less
    -- frame has no edge to carry one.
    if placed.rule then
      cfg.footer = chunks or ""
      cfg.footer_pos = "right"
    end
    configure(win, cfg, table.concat({ row, placed.col, placed.width, pane.height, vim.inspect(chunks) }, ":"))
  end

  place(handle.win, placed.outline)
  if hdr and placed.header and vim.api.nvim_win_is_valid(hdr.win) then
    local shown = hdr.groups[hdr.shown]
    place(hdr.win, placed.header, shown and shown.tag)
  end
  if not p or not vim.api.nvim_win_is_valid(p.win) then
    return
  end
  if not placed.inspector then
    configure(p.win, { hide = true }, "hidden")
    return
  end
  set_content(p.buf, inspector.lines, inspector.highlights, inspector.ts_injections, lang)
  place(p.win, placed.inspector)
end

--- Swap content and resize in one synchronous block — no scheduling between
--- buffer and window updates, so expand/collapse never shows a partial frame.
---@param handle typescope.FloatHandle
---@param opts { lines?: string[], highlights: typescope.Highlight[], ts_injections?: typescope.Injection[], lang?: string, width?: integer, height?: integer, title?: string, inspector?: typescope.InspectorUpdate, footer?: { [1]: string, [2]: string }[], header?: integer } lines = nil: the outline's content is unchanged (only the inspector or the frame moved); header: the overload group the header shows (nil: unchanged)
function M.update(handle, opts)
  if opts.lines then
    set_content(handle.buf, opts.lines, opts.highlights, opts.ts_injections, opts.lang)
  end
  if opts.header and handle.header then
    show_header(handle.header, opts.header)
  end
  if handle.frame then
    layout(handle, opts.width, opts.height, opts.inspector, opts.footer, opts.lang)
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
  for _, pane in ipairs({ handle.header or false, handle.inspector or false }) do
    if pane then
      M._forget(pane.buf)
      applied[pane.win] = nil
      if vim.api.nvim_win_is_valid(pane.win) then
        vim.api.nvim_win_close(pane.win, true)
      end
    end
  end
end

return M
