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

vim.notify = orig_notify
config.setup({})
print(failures == 0 and "CONFIG ALL PASS" or ("CONFIG " .. failures .. " FAILURES"))
