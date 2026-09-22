-- The parity gate (design/oracle.md §7, bead 1mv): open the float on every
-- marker in tests/fixtures/shapes.py through BOTH resolvers and dump the
-- lines, so the two can be diffed. Throwaway: goes with the old resolver.
--
--   nvim --headless --clean --cmd "set rtp+=. rtp+=~/.local/share/nvim/site rtp+=~/.local/share/nvim/lazy/nvim-treesitter" \
--        -c "luafile scripts/parity.lua" -c "qa!"
--
-- Writes PARITY_OUT (default /tmp/typescope-parity) with legacy.txt and
-- oracle.txt; `diff` them. Needs basedpyright-langserver on PATH (mason)
-- and a built oracle.
local out_dir = vim.env.PARITY_OUT or "/tmp/typescope-parity"
vim.fn.mkdir(out_dir, "p")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/shapes.py"
local bin = root .. "/oracle/target/debug/typescope-oracle"
local based = vim.fn.exepath("basedpyright-langserver")
if based == "" then
  based = vim.fn.expand("~/.local/share/nvim/mason/bin/basedpyright-langserver")
end
assert(vim.fn.executable(bin) == 1, "no oracle binary")
assert(vim.fn.executable(based) == 1, "no basedpyright-langserver")

require("typescope").setup({ resolver = "legacy", oracle = { path = bin }, show_examples = false, ui = { max_width = 90 } })
vim.cmd.edit(fixture)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"

-- basedpyright, with the fixture's stub dir on its search path
vim.lsp.start({
  name = "basedpyright",
  cmd = { based, "--stdio" },
  root_dir = root .. "/tests/fixtures",
  settings = { basedpyright = { analysis = { typeCheckingMode = "off", extraPaths = { root .. "/tests/fixtures/site" } } } },
}, { bufnr = bufnr })
vim.wait(30000, function()
  local lsp = require("typescope.lsp")
  local a, b = lsp.client_for(bufnr), lsp.oracle_for(bufnr)
  return a and a.initialized and b and b.initialized
end, 50)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- targets: (label, row1, col0) for every class marker and params marker
local targets = {}
for i, l in ipairs(lines) do
  if l:match("^# typescope:") or l:match("^    # typescope%-params:") or l:match("^# typescope%-params:") then
    local j = i + 1
    while lines[j] and (lines[j]:match("^%s*#") or lines[j]:match("^%s*@")) do
      j = j + 1
    end
    local target = lines[j]
    local col = target:find("class ") or target:find("def ")
    if col then
      local name = target:match("class ([%w_]+)") or target:match("def ([%w_]+)")
      local kw = target:match("class ") and 6 or 4
      table.insert(targets, { label = name, row = j, col = col - 1 + kw })
    end
  end
end
io.stderr:write(("[parity] %d targets\n"):format(#targets))

local function float_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    end
  end
end

local function dump(resolver)
  require("typescope.config").setup({ resolver = resolver, oracle = { path = bin }, show_examples = false, ui = { max_width = 90 } })
  local out = {}
  for _, t in ipairs(targets) do
    require("typescope").close()
    require("typescope").open({ silent = true, focus = false })
    -- nothing to await on directly: poll for the float or a decline
    vim.wait(50)
    vim.api.nvim_win_set_cursor(0, { t.row, t.col })
    require("typescope").close()
    local reason
    require("typescope").open({
      silent = true,
      focus = false,
      on_unresolved = function(r, why)
        reason = ("<%s: %s>"):format(tostring(why), tostring(r))
      end,
    })
    local got
    vim.wait(20000, function()
      got = float_lines()
      return got ~= nil or reason ~= nil
    end, 20)
    table.insert(out, ("=== %s (%d:%d)"):format(t.label, t.row, t.col))
    if got then
      for _, l in ipairs(got) do
        table.insert(out, (l:gsub("%s+$", "")))
      end
    else
      table.insert(out, reason or "<no float, no reason>")
    end
    require("typescope").close()
    require("typescope")._resolver().clear_cache()
  end
  vim.fn.writefile(out, ("%s/%s.txt"):format(out_dir, resolver))
  io.stderr:write(("[parity] wrote %s/%s.txt\n"):format(out_dir, resolver))
end

dump("legacy")
dump("oracle")
