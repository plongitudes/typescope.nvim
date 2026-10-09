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
-- Characterization: these pin how the two-pane frame (main window + docked
-- inspector) lays out today, so the layout redesign changes it on purpose.
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
    main = 8,
    inspector = 3,
  }, over or {})
end

local layout_cases = {
  -- side of the cursor
  { "room below for max_height + chrome: below", {}, { below = true, budget = 20, top = 6 } },
  {
    "short below but no shorter than above: below",
    { row = 19, max_height = 30 },
    { below = true, budget = 20 - 3 },
  },
  {
    "...but one row less room below than above: above",
    { row = 20, max_height = 30 },
    { below = false, budget = 20 - 3 },
  },
  { "more room above than below: above", { row = 30 }, { below = false, budget = 20, top = 30 - (3 + 8 + 3) } },
  {
    "a side fixed at open holds even where the other has more room",
    { row = 30, below = true },
    { below = true, budget = 6, top = 31 },
  },
  -- budget
  { "budget is capped at max_height", { max_height = 10 }, { budget = 10 } },
  { "budget is the room on the chosen side less chrome", { row = 30 }, { budget = 20 } },
  {
    "budget never drops below 2",
    { row = 2, lines = 6, below = true },
    { budget = 2 },
  },
  -- chrome per border style: rounded joins the panes with one tee row
  {
    "named border: inspector's top edge is the row under main's content",
    {},
    { main_row = 0, inspector_row = 1 + 8, main_border = "open", inspector_border = "tee" },
  },
  {
    "named border above the cursor: frame ends on the row above it",
    { row = 30 },
    { top = 30 - (1 + 8 + 1 + 3 + 1) },
  },
  -- a custom array stacks two whole boxes: two rows between the contents
  {
    "custom border: inspector's own top edge sits under main's bottom edge",
    { border = CUSTOM },
    { inspector_row = 1 + 8 + 1, main_border = CUSTOM, inspector_border = CUSTOM },
  },
  {
    "custom border above the cursor counts both boxes' edges",
    { border = CUSTOM, row = 30 },
    { top = 30 - (1 + 8 + 2 + 3 + 1) },
  },
  { "custom border chrome is 4 rows", { border = CUSTOM, row = 30, max_height = 40 }, { budget = 26 } },
  {
    "no border: panes abut, no chrome",
    { border = "none", row = 30 },
    { inspector_row = 8, top = 30 - 11, budget = 20, col = 10 },
  },
  -- inspector shown / hidden
  {
    "inspector shown: it carries the footer, main loses its bottom",
    {},
    { main_footer = false, inspector_footer = true, main_border = "open" },
  },
  {
    "inspector hidden: main closes the frame and carries the footer",
    { inspector = false },
    { inspector = "none", main_footer = true, main_border = "closed" },
  },
  {
    "inspector hidden above the cursor: frame is main alone",
    { inspector = false, row = 30 },
    { top = 30 - (1 + 8 + 1) },
  },
  -- columns
  { "left edge at the cursor column", {}, { col = 10 } },
  { "slid left only as far as the screen edge needs", { col = 90 }, { col = 100 - 30 - 2 } },
  { "never slid past column 0", { col = 5, width = 120 }, { col = 0 } },
  -- heights
  { "pane heights are the content rows asked for", {}, { main_h = 8, inspector_h = 3 } },
  { "an empty pane is still a row tall", { main = 0, inspector = 0 }, { main_h = 1, inspector_h = 1 } },
}

local BORDERS = {
  open = { "╭", "─", "╮", "│", "", "", "", "│" },
  closed = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  tee = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
}

for _, case in ipairs(layout_cases) do
  local name, over, want = case[1], case[2], case[3]
  local s = spec(over)
  if over.inspector == false then
    s.inspector = nil
  end
  local got = float.frame_layout(s)
  local view = {
    below = got.below,
    budget = got.budget,
    top = got.top,
    col = got.col,
    main_row = got.main.row,
    main_h = got.main.height,
    main_footer = got.main.footer,
    main_border = got.main.border,
    inspector = got.inspector and "some" or "none",
    inspector_row = got.inspector and got.inspector.row,
    inspector_h = got.inspector and got.inspector.height,
    inspector_footer = got.inspector and got.inspector.footer,
    inspector_border = got.inspector and got.inspector.border,
  }
  local bad = {}
  for k, v in pairs(want) do
    local expect = (k:match("border$") and BORDERS[v]) or v
    if not vim.deep_equal(view[k], expect) then
      table.insert(bad, ("%s=%s (want %s)"):format(k, vim.inspect(view[k]), vim.inspect(expect)))
    end
  end
  check("layout: " .. name .. (#bad > 0 and (" — " .. table.concat(bad, ", ")) or ""), #bad == 0)
end

-- the window code only applies the layout: a float with an inspector puts its
-- windows exactly where frame_layout says
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
    inspector = { row = 2, col = 4, max_height = 10 },
  })
  float.update(h, {
    highlights = {},
    width = 20,
    height = 3,
    inspector = { lines = { "x", "y" }, highlights = {}, height = 2 },
    footer = { { " ? help ", "TypeScopeHint" } },
  })
  local want = float.frame_layout({
    border = "rounded",
    row = 2,
    col = 4,
    lines = vim.o.lines - vim.o.cmdheight,
    columns = vim.o.columns,
    max_height = 10,
    width = 20,
    main = 3,
    inspector = 2,
  })
  local main = vim.api.nvim_win_get_config(h.win)
  local insp = vim.api.nvim_win_get_config(h.inspector.win)
  check(
    "open/update place both windows from frame_layout",
    main.height == want.main.height
      and insp.height == want.inspector.height
      and main.width == want.width
      and insp.hide == false
      and insp.footer ~= nil
      and h.budget == want.budget
  )
  float.update(h, { highlights = {}, width = 20, height = 3, footer = { { " back ", "TypeScopeHint" } } })
  check(
    "...and hiding the inspector moves the footer onto the main window",
    vim.api.nvim_win_get_config(h.inspector.win).hide == true and vim.api.nvim_win_get_config(h.win).footer ~= nil
  )
  float.close(h)
end

if fail_count == 0 then
  print("FLOAT ALL PASS")
else
  print(("FLOAT %d FAILURES"):format(fail_count))
end
