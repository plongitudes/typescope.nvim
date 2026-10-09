-- Float painting: the parts that are about the BUFFER rather than the layout.
-- render.lua's tests cover what goes on a line; this covers what repainting a
-- line for hours does to the editor holding it.
local ok_count, fail_count = 0, 0
local function check(name, cond)
  if cond then
    ok_count = ok_count + 1
    print("PASS " .. name)
  else
    fail_count = fail_count + 1
    print("FAIL " .. name)
  end
end

local float = require("typescope.float")

-- Roughly the shape of a real float mid-animation: a dozen-odd rows, each as
-- wide as the window, each changing every frame. Undo's cost is per replaced
-- line and scales with its length, so a three-line toy float understates it by
-- more than an order of magnitude and would pass either way.
local ROWS, WIDTH = 14, 76
local function paint(handle, n)
  local lines, highlights = {}, {}
  for i = 1, ROWS do
    local text = ("row %d frame %d "):format(i, n)
    lines[i] = text .. string.rep("·", WIDTH - #text)
    highlights[i] = { line = i - 1, col_start = 0, col_end = #lines[i], group = "TypeScopeExample" }
  end
  float.update(handle, { lines = lines, highlights = highlights, width = WIDTH, height = ROWS })
end

local handle = float.open({
  lines = { "placeholder" },
  highlights = {},
  width = WIDTH,
  height = ROWS,
  relative = "editor",
  row = 1,
  col = 1,
})

-- The animation repaints at 60fps for as long as a value is still coming, and
-- every repaint rewrites the lines that moved. On a buffer with undo those
-- writes pile up states nobody can ever undo into: 15.6 KB a frame, 3.4 GB an
-- hour, and not Lua memory, so no collector touches it. That is how nvim came
-- to be holding 20GB (Tony, 2026-08-24).
check("the float buffer keeps no undo history", vim.bo[handle.buf].undolevels == -1)

-- Counting undo states would miss it: fifty repaints in a row make ONE undo
-- block (nothing syncs between them), and every replaced line is appended to
-- that block as an entry. The block is what grows, so undolevels never trims
-- it. Weigh the process instead.
local FRAMES = 4000
local function rss_mb()
  return vim.uv.resident_set_memory() / 1024 / 1024
end
paint(handle, 0) -- first paint costs one-off allocations; measure after it
collectgarbage("collect")
local before = rss_mb()
for i = 1, FRAMES do
  paint(handle, i)
end
collectgarbage("collect")
local grew = rss_mb() - before
-- the gap between undo on and undo off is roughly 30x here, so a ceiling this
-- loose still fails the moment undo comes back
check(("...and %d repaints grow the process by under 8 MB (grew %.1f)"):format(FRAMES, grew), grew < 8)
-- the repaints have to have actually happened, or the check above is vacuous
check(
  "...having actually repainted",
  vim.api.nvim_buf_get_lines(handle.buf, 0, 1, false)[1]:find("frame " .. FRAMES, 1, true) ~= nil
)

float.close(handle)

-- Paint signatures are keyed by buffer, and nvim does NOT reuse buffer
-- handles — a wiped buffer's number never comes back. So an entry that
-- outlives its float is retained for the whole session: small individually, a
-- table with one entry per float ever opened by the end of a long one. There
-- was a _forget for exactly this, but it referenced `painted` from above the
-- local's declaration, so it resolved to a global and threw on the one call
-- that would have bounded the table. Nothing called it, so nothing noticed.
check("forgetting a buffer's signatures does not throw", pcall(float._forget, 1))

local function cycle()
  local h = float.open({
    lines = { "a", "b" },
    highlights = {},
    width = 10,
    height = 2,
    relative = "editor",
    row = 1,
    col = 1,
  })
  float.update(h, { lines = { "a", "c" }, highlights = {}, width = 10, height = 2 })
  float.close(h)
  return h
end
for _ = 1, 50 do
  cycle()
end
check(
  ("50 open/update/close cycles leave nothing behind (holding %d)"):format(float._painted_count()),
  float._painted_count() == 0
)

-- ...and the same for a float the USER dismissed: :q and WinClosed both reach
-- M.close with the window already invalid, which is why the cleanup cannot sit
-- behind the validity check that guards the window close
local dismissed = float.open({
  lines = { "x" },
  highlights = {},
  width = 6,
  height = 1,
  relative = "editor",
  row = 1,
  col = 1,
})
vim.api.nvim_win_close(dismissed.win, true)
float.close(dismissed)
check("a user-dismissed float is forgotten too", float._painted_count() == 0)

-- ── frame layout ─────────────────────────────────────────────────────────────
--
-- The three-pane frame (ADR 0001): header, outline, loupe, each a whole box in
-- the user's border style, so every seam is a bottom border then a top border.
-- Screen is 40 rows by 100 columns unless a case says otherwise.
local CUSTOM = { "+", "-", "+", "|", "+", "-", "+", "|" }
local function spec(over)
  return vim.tbl_extend("force", {
    border = "rounded",
    row = 5,
    col = 10,
    lines = 40,
    columns = 100,
    max_height = 20,
    width = 30,
    header = 1,
    outline = 8,
    inspector = 3,
    min_height = { header = 1, outline = 5, inspector = 1 },
  }, over or {})
end

-- rounded, all three panes: 2 rows of edge per pane
local layout_cases = {
  -- side of the cursor
  { "room below for max_height + chrome: below", {}, { below = true, budget = 20, top = 6 } },
  {
    "short below but no shorter than above: below",
    { row = 19, max_height = 30 },
    { below = true, budget = 20 - 6 },
  },
  {
    "...but one row less room below than above: above",
    { row = 20, max_height = 30 },
    { below = false, budget = 20 - 6 },
  },
  {
    "more room above than below: above",
    { row = 30 },
    { below = false, budget = 20, top = 30 - (3 + 10 + 5) },
  },
  {
    "a side fixed at open holds even where the other has more room",
    { row = 30, below = true },
    { below = true, budget = 3, top = 31 },
  },
  -- budget
  { "budget is capped at max_height", { max_height = 10 }, { budget = 10 } },
  { "budget is the room on the chosen side less chrome", { row = 30, max_height = 40 }, { budget = 30 - 6 } },
  {
    "budget never drops below 3",
    { row = 2, lines = 6, below = true },
    { budget = 3 },
  },
  -- seams: every pane is a whole box, so a seam is two rows
  {
    "named border: each pane's top edge sits under the last one's bottom edge",
    {},
    {
      header_row = 0,
      outline_row = 1 + 1 + 1,
      inspector_row = 3 + 1 + 8 + 1,
      header_border = "rounded",
      outline_border = "rounded",
      inspector_border = "rounded",
    },
  },
  {
    "named border above the cursor: frame ends on the row above it",
    { row = 30 },
    { top = 30 - (3 + 10 + 5) },
  },
  {
    "custom border: the same stacked boxes, in the user's array",
    { border = CUSTOM },
    {
      outline_row = 3,
      inspector_row = 13,
      header_border = CUSTOM,
      outline_border = CUSTOM,
      inspector_border = CUSTOM,
    },
  },
  {
    "custom border above the cursor counts every pane's edges",
    { border = CUSTOM, row = 30 },
    { top = 30 - (3 + 10 + 5) },
  },
  { "custom border chrome is 6 rows", { border = CUSTOM, row = 30, max_height = 40 }, { budget = 24 } },
  {
    "no border: panes abut, no chrome",
    { border = "none", row = 30 },
    { outline_row = 1, inspector_row = 9, top = 30 - 12, budget = 20, col = 10 },
  },
  -- the footer: on the bottom pane only, with the border's own rule glyph
  {
    "inspector shown: it carries the footer",
    {},
    { header_footer = false, outline_footer = false, inspector_footer = true },
  },
  {
    "inspector hidden: the outline closes the frame and carries the footer",
    { inspector = false },
    { inspector = "none", outline_footer = true, header_footer = false },
  },
  {
    "inspector hidden above the cursor: frame is header + outline",
    { inspector = false, row = 30 },
    { top = 30 - (3 + 10) },
  },
  { "the footer's rule is the bottom edge's glyph", {}, { rule = { "─", "FloatBorder" } } },
  { "...double's is its own", { border = "double" }, { rule = { "═", "FloatBorder" } } },
  { "...and a custom array's its sixth", { border = CUSTOM }, { rule = { "-", "FloatBorder" } } },
  {
    "...keeping a custom edge's highlight",
    { border = { "+", { "=", "MyEdge" }, "+", "|" } },
    { rule = { "=", "MyEdge" } },
  },
  { "no border, no rule", { border = "none" }, { rule = "none" } },
  -- no header (a class hover: its root row is the header)
  {
    "no header: the outline opens the frame",
    { header = false },
    { header = "none", outline_row = 0, inspector_row = 10 },
  },
  { "no header above the cursor", { header = false, row = 30 }, { top = 30 - (10 + 5) } },
  -- columns
  { "left edge at the cursor column", {}, { col = 10 } },
  { "slid left only as far as the screen edge needs", { col = 90 }, { col = 100 - 30 - 2 } },
  { "never slid past column 0", { col = 5, width = 120 }, { col = 0 } },
  -- heights
  { "pane heights are the content rows asked for", {}, { header_h = 1, outline_h = 8, inspector_h = 3 } },
  {
    "an empty pane is still a row tall",
    { header = 0, outline = 0, inspector = 0 },
    { header_h = 1, outline_h = 1, inspector_h = 1 },
  },
  -- minimums and the leftover rows (ui.min_height, default 1 / 5 / 1)
  {
    "a pane with less content than its minimum shrinks to fit",
    { outline = 2, inspector = 1 },
    { outline_h = 2, inspector_h = 1, outline_row = 3, inspector_row = 3 + 1 + 2 + 1 },
  },
  {
    "leftovers go to the header first, until it is fully wrapped",
    { max_height = 10, header = 6, outline = 8, inspector = 4 },
    { header_h = 1 + 3, inspector_h = 1, outline_h = 5 },
  },
  {
    "...then to the inspector",
    { max_height = 14, header = 6, outline = 8, inspector = 4 },
    { header_h = 6, inspector_h = 1 + 2, outline_h = 5 },
  },
  {
    "...up to its cap of 5, and the outline takes the rest",
    { max_height = 20, header = 6, outline = 20, inspector = 8 },
    { header_h = 6, inspector_h = 5, outline_h = 5 + 4 },
  },
  {
    "the inspector's cap holds with rows to spare",
    { max_height = 30, outline = 3, inspector = 8 },
    { inspector_h = 5, outline_h = 3 },
  },
  {
    "a minimum above the cap still holds",
    { min_height = { header = 1, outline = 5, inspector = 7 }, inspector = 9 },
    { inspector_h = 7 },
  },
  {
    "the minimums are configurable",
    {
      max_height = 10,
      header = 6,
      outline = 8,
      inspector = 1,
      min_height = { header = 1, outline = 2, inspector = 1 },
    },
    { header_h = 6, inspector_h = 1, outline_h = 3 },
  },
  {
    "minimums that overrun the budget squash the outline first",
    { row = 30, lines = 42, below = true },
    { budget = 5, header_h = 1, outline_h = 3, inspector_h = 1 },
  },
  {
    "...and at the floor every pane is one row",
    { row = 30, below = true, header = 4 },
    { budget = 3, header_h = 1, outline_h = 1, inspector_h = 1 },
  },
  {
    "max_height counts content rows only: borders are extra",
    { max_height = 10, header = 6, outline = 8, inspector = 4 },
    { content = 10, extent = 10 + 6 },
  },
  {
    "...above the cursor too",
    { max_height = 10, header = 6, outline = 8, inspector = 4, row = 30 },
    { content = 10, top = 30 - 16 },
  },
}

for _, case in ipairs(layout_cases) do
  local name, over, want = case[1], case[2], case[3]
  local s = spec(over)
  for _, pane in ipairs({ "header", "inspector" }) do
    if over[pane] == false then
      s[pane] = nil
    end
  end
  local got = float.frame_layout(s)
  local view = {
    below = got.below,
    budget = got.budget,
    top = got.top,
    col = got.col,
    rule = got.rule or "none",
    content = 0,
  }
  for _, pane in ipairs({ "header", "outline", "inspector" }) do
    local p = got[pane]
    if p then
      view.content = view.content + p.height
      -- the frame's outer rows: down to the last pane's bottom edge
      view.extent = p.row + p.height + (got.rule and 2 or 0)
    end
    view[pane] = p and "some" or "none"
    view[pane .. "_row"] = p and p.row
    view[pane .. "_h"] = p and p.height
    view[pane .. "_footer"] = p and p.footer
    view[pane .. "_border"] = p and p.border
  end
  local bad = {}
  for k, v in pairs(want) do
    if not vim.deep_equal(view[k], v) then
      table.insert(bad, ("%s=%s (want %s)"):format(k, vim.inspect(view[k]), vim.inspect(v)))
    end
  end
  check("layout: " .. name .. (#bad > 0 and (" — " .. table.concat(bad, ", ")) or ""), #bad == 0)
end

-- the window code only applies the layout: a frame puts its three panes
-- exactly where frame_layout says, findable by filetype
do
  local h = float.open({
    lines = { "a", "b", "c" },
    highlights = {},
    width = 20,
    height = 3,
    relative = "editor",
    row = 0,
    col = 0,
    border = "rounded",
    frame = { row = 2, col = 4, max_height = 10 },
    header = { lines = { "f(a, b, c)" }, highlights = {} },
  })
  local help = { { " ? help ", "TypeScopeHint" } }
  float.update(h, {
    highlights = {},
    width = 20,
    height = 3,
    inspector = { lines = { "x", "y" }, highlights = {}, height = 2 },
    footer = help,
  })
  local want = float.frame_layout({
    border = "rounded",
    row = 2,
    col = 4,
    lines = vim.o.lines - vim.o.cmdheight,
    columns = vim.o.columns,
    max_height = 10,
    width = 20,
    header = 1,
    outline = 3,
    inspector = 2,
  })
  local hdr = vim.api.nvim_win_get_config(h.header.win)
  local main = vim.api.nvim_win_get_config(h.win)
  local insp = vim.api.nvim_win_get_config(h.inspector.win)
  check("the header is its own window", vim.bo[h.header.buf].filetype == "typescope_header")
  check(
    "...holding the signature",
    vim.deep_equal(vim.api.nvim_buf_get_lines(h.header.buf, 0, -1, false), { "f(a, b, c)" })
  )
  check(
    "open/update place all three panes from frame_layout",
    hdr.height == want.header.height
      and main.height == want.outline.height
      and insp.height == want.inspector.height
      and hdr.row == want.top + want.header.row
      and main.row == want.top + want.outline.row
      and insp.row == want.top + want.inspector.row
      and main.width == want.width
      and insp.hide == false
      and h.budget == want.budget
  )
  local function footer_of(cfg)
    local text = ""
    for _, chunk in ipairs(type(cfg.footer) == "table" and cfg.footer or {}) do
      text = text .. chunk[1]
    end
    return text
  end
  check(
    "the footer is `? help` and one rule glyph, right-justified, on the loupe only",
    footer_of(insp) == " ? help ─" and insp.footer_pos == "right" and footer_of(main) == "" and footer_of(hdr) == ""
  )
  float.update(h, { highlights = {}, width = 20, height = 3, footer = help })
  check(
    "...and hiding the inspector moves the footer onto the outline",
    vim.api.nvim_win_get_config(h.inspector.win).hide == true
      and footer_of(vim.api.nvim_win_get_config(h.win)) == " ? help ─"
  )
  float.close(h)
  check("closing the frame closes the header too", not vim.api.nvim_win_is_valid(h.header.win))
end

if fail_count == 0 then
  print("FLOAT ALL PASS")
else
  print(("FLOAT %d FAILURES"):format(fail_count))
end
