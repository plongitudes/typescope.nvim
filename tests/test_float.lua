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

if fail_count == 0 then
  print("FLOAT ALL PASS")
else
  print(("FLOAT %d FAILURES"):format(fail_count))
end
