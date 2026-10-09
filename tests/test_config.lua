-- config.setup: removed options warn once and are dropped, rather than
-- failing the whole setup over a key a user carried across an upgrade.
--   nvim --headless --clean --cmd "set rtp+=." -c "luafile tests/test_config.lua" -c "qa!"
local config = require("typescope.config")

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

local warnings = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then
    table.insert(warnings, msg)
  end
end
local function setup(opts)
  warnings = {}
  return config.setup(opts)
end

local cfg = setup({ ui = { layout = "tree" } })
check("ui.layout = tree warns", #warnings == 1 and warnings[1]:find("outline is the only layout") ~= nil)
check("...and is dropped", cfg.ui.layout == nil)
setup({ ui = { layout = "table" } })
check("so does the long-gone table", #warnings == 1)
cfg = setup({ ui = { layout = "outline" } })
check("any layout warns now that there is only one", #warnings == 1 and cfg.ui.layout == nil)

cfg = setup({ ui = { align = "right" } })
check("ui.align warns", #warnings == 1 and warnings[1]:find("ui.align") ~= nil)
check("...and is dropped", cfg.ui.align == nil)

check("ui.docstring defaults on", setup({}).ui.docstring == true)
check("the tree's placements both mean on", setup({ ui = { docstring = "top" } }).ui.docstring == true)
check("...bottom too", setup({ ui = { docstring = "bottom" } }).ui.docstring == true)
check("false turns it off", setup({ ui = { docstring = false } }).ui.docstring == false)
check("...without a word", #warnings == 0)
check("anything else is an error", not pcall(config.setup, { ui = { docstring = "middle" } }))

check("ui.max_height takes a positive integer", setup({ ui = { max_height = 12 } }).ui.max_height == 12)
check("...and rejects anything else", not pcall(config.setup, { ui = { max_height = 0 } }))

-- the frame's pane minimums: header, outline, inspector
check(
  "ui.min_height defaults to header 1, outline 5, inspector 1",
  vim.deep_equal(setup({}).ui.min_height, { header = 1, outline = 5, inspector = 1 })
)
check(
  "...a partial table keeps the other defaults",
  vim.deep_equal(
    setup({ ui = { min_height = { outline = 3 } } }).ui.min_height,
    { header = 1, outline = 3, inspector = 1 }
  )
)
local function setup_error(opts)
  local ok, err = pcall(config.setup, opts)
  return not ok and tostring(err) or ""
end
check(
  "a zero minimum is a setup error naming the key",
  setup_error({ ui = { min_height = { outline = 0 } } }):find("ui.min_height.outline", 1, true) ~= nil
)
check(
  "...so is a fraction",
  setup_error({ ui = { min_height = { header = 1.5 } } }):find("ui.min_height.header", 1, true) ~= nil
)
check("...and a non-table", setup_error({ ui = { min_height = 5 } }):find("ui.min_height", 1, true) ~= nil)
check(
  "...and a pane the frame doesn't have",
  setup_error({ ui = { min_height = { loupe = 2 } } }):find("ui.min_height.loupe", 1, true) ~= nil
)

vim.notify = orig_notify
config.setup({})
print(failures == 0 and "CONFIG ALL PASS" or ("CONFIG " .. failures .. " FAILURES"))
