-- load_buf: a buffer loaded for parsing that the user later walks into.
-- The parse-time half (no swapfile, no second server) is covered by the
-- comment on load_buf; this covers the other half of the buffer's life.
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

local lsp = require("typescope.lsp")

local function tmp_py(lines)
  local path = vim.fn.tempname() .. ".py"
  vim.fn.writefile(lines, path)
  return vim.uri_from_fname(path)
end

-- stands in for editorconfig, last-position restore, and anything else the
-- user hooked to "a file was read"
local read_hooks = 0
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    read_hooks = read_hooks + 1
  end,
})

-- K, then gd: the sequence that shipped a python file with no filetype
local bufnr = lsp.load_buf(tmp_py({ "def f(x: int) -> int:", "    return x" }))
check("loaded for the parse", vim.api.nvim_buf_is_loaded(bufnr))
check("parse-only load skips detection", vim.bo[bufnr].filetype == "")
check("parse-only load skips swapfile", vim.bo[bufnr].swapfile == false)
check("parse-only load fires no read hooks", read_hooks == 0)

vim.api.nvim_win_set_buf(0, bufnr)
check("entering the window detects the filetype", vim.bo[bufnr].filetype == "python")
check("entering the window restores swapfile", vim.bo[bufnr].swapfile == vim.go.swapfile)
check("entering the window replays BufReadPost once", read_hooks == 1)

vim.cmd("enew")
vim.api.nvim_win_set_buf(0, bufnr)
check("re-entering does not replay again", read_hooks == 1)

-- show_document({focus=false}) puts the buffer in a window it never enters
read_hooks = 0
local unfocused = lsp.load_buf(tmp_py({ "x = 1" }))
local win = vim.api.nvim_open_win(unfocused, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
check("an unentered window still heals", vim.bo[unfocused].filetype == "python" and read_hooks == 1)
check("and did not steal focus", vim.api.nvim_get_current_buf() ~= unfocused)
vim.api.nvim_win_close(win, true)

-- the replay processes the modeline, and swapfile restore must not clobber it
local modeline = lsp.load_buf(tmp_py({ "x = 1", "# vim: noswapfile" }))
vim.api.nvim_win_set_buf(0, modeline)
check("modeline noswapfile survives the swapfile restore", vim.bo[modeline].swapfile == false)

-- already loaded: nothing to heal, nothing to register
read_hooks = 0
local again = lsp.load_buf(vim.uri_from_bufnr(modeline))
vim.cmd("enew")
vim.api.nvim_win_set_buf(0, again)
check("a second load_buf of a loaded buffer adds no replay", again == modeline and read_hooks == 0)

if fail_count == 0 then
  print("LOAD_BUF ALL PASS")
else
  print(("LOAD_BUF %d FAILURES"):format(fail_count))
end
