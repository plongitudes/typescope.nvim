-- Minimal init for recording the README demo (demo/typescope.tape).
--
--   nvim --clean -u demo/init.lua demo/demo.py
--
-- --clean keeps the user's config and plugins out of the frame; this file adds
-- back only what the demo shows: the colorscheme, basedpyright (it feeds the
-- insert surface's active parameter and overload follow) and typescope itself.

local demo = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local repo = vim.fs.dirname(demo)
local data = vim.fn.stdpath("data")

vim.opt.rtp:prepend(repo)
-- the python treesitter parser; --clean drops the data dir's site/ from rtp
vim.opt.rtp:append(data .. "/site")

vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "no"
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "IF"
-- typed call arguments must land exactly as typed
vim.o.autoindent = false
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.bo.indentexpr = ""
    vim.bo.autoindent = false
  end,
})

-- the maintainer's colorscheme, transparent so the tape's Gruvbox Dark
-- background shows through (as it does in Ghostty)
local gruvbox = data .. "/lazy/gruvbox-baby"
if vim.uv.fs_stat(gruvbox) then
  vim.opt.rtp:prepend(gruvbox)
  vim.g.gruvbox_baby_transparent_mode = 1
  vim.cmd.colorscheme("gruvbox-baby")
end

-- keypresses in a corner float, so viewers can follow along. Installed by the
-- maintainer's lazy config; skipped when absent.
local screenkey = data .. "/lazy/screenkey.nvim"
if vim.uv.fs_stat(screenkey) then
  vim.opt.rtp:prepend(screenkey)
  require("screenkey").setup({
    -- no border: an idle screenkey would otherwise leave an empty box
    win_opts = { width = 30, height = 1, border = "none", title = "" },
    group_mappings = true,
    -- typed text is already on screen, and arrives letter by letter
    disable = { modes = { "i" } },
    clear_after = 2,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
      require("screenkey").toggle()
    end,
  })
end

-- the demo calls are unfinished on purpose; nothing should be underlined
vim.diagnostic.enable(false)

vim.treesitter.language.add("python")
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function(ev)
    vim.treesitter.start(ev.buf)
  end,
})

local mason = data .. "/mason/bin/basedpyright-langserver"
vim.lsp.config("basedpyright", {
  cmd = { vim.fn.executable(mason) == 1 and mason or "basedpyright-langserver", "--stdio" },
  filetypes = { "python" },
  root_markers = { "pyrefly.toml" },
  settings = { basedpyright = { analysis = { typeCheckingMode = "off" } } },
})
vim.lsp.enable("basedpyright")

require("typescope").setup({
  oracle = { path = repo .. "/oracle/target/release/typescope-oracle" },
  depth = 1, -- so `l` has something to expand
  example_mode = "heuristic",
  insert_mode = { enabled = true },
  ollama = { enabled = true },
  ui = { max_width = 0.7 },
})

vim.keymap.set("n", "K", function()
  require("typescope").hover()
end)
