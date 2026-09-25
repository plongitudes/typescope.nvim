-- The shipped oracle's cost beside basedpyright on a real project, for the
-- changelog (design/oracle.md §7). Opens scripts/footprint-targets.json's
-- file, attaches both servers, opens the float on each target through the
-- plugin, and reads physical footprint with footprint(1) — never ps rss, which
-- undercounts an idle process on a busy Mac by 10x.
--
--   TYPESCOPE_ORACLE=oracle/target/release/typescope-oracle \
--   nvim --headless --clean --cmd "set rtp+=. rtp+=~/.local/share/nvim/site rtp+=~/.local/share/nvim/lazy/nvim-treesitter" \
--        -c "luafile scripts/footprint.lua" -c "qa!"
local root = vim.fn.getcwd()
local spec = vim.json.decode(table.concat(vim.fn.readfile(root .. "/scripts/footprint-targets.json"), "\n"))
local bin = vim.env.TYPESCOPE_ORACLE or (root .. "/oracle/target/release/typescope-oracle")
local based = vim.fn.exepath("basedpyright-langserver")
if based == "" then
  based = vim.fn.expand("~/.local/share/nvim/mason/bin/basedpyright-langserver")
end
assert(vim.fn.executable(bin) == 1, "no oracle at " .. bin)
assert(vim.fn.executable(based) == 1, "no basedpyright-langserver")

local function log(fmt, ...)
  io.stderr:write(("[fp] " .. fmt .. "\n"):format(...))
end

local function tree(pid)
  local pids = { pid }
  for child in vim.fn.system({ "pgrep", "-P", tostring(pid) }):gmatch("%d+") do
    vim.list_extend(pids, tree(tonumber(child)))
  end
  return pids
end
local function footprint_mb(pid)
  local total, peak = 0, 0
  for _, p in ipairs(tree(pid)) do
    local out = vim.fn.system({ "footprint", "-p", tostring(p) })
    total = total + (tonumber(out:match("phys_footprint:%s*([%d%.]+)%s*MB")) or 0)
    peak = peak + (tonumber(out:match("phys_footprint_peak:%s*([%d%.]+)%s*MB")) or 0)
  end
  return math.floor(total), math.floor(peak)
end

require("typescope").setup({ oracle = { path = bin }, show_examples = false })
vim.cmd.edit(spec.project_root .. "/" .. spec.file)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"
local t0 = vim.uv.hrtime()
vim.lsp.start({
  name = "basedpyright",
  cmd = { based, "--stdio" },
  root_dir = spec.project_root,
  settings = { basedpyright = { analysis = { typeCheckingMode = "off" } } },
}, { bufnr = bufnr })
vim.wait(60000, function()
  local lsp = require("typescope.lsp")
  local a, b = lsp.client_for(bufnr), lsp.oracle_for(bufnr)
  return a and a.initialized and b and b.initialized
end, 50)
local ready_ms = (vim.uv.hrtime() - t0) / 1e6
local based_pid = tonumber(vim.trim(vim.fn.system({ "pgrep", "-n", "-f", "basedpyright-langserver" })))
local oracle_pid = tonumber(vim.trim(vim.fn.system({ "pgrep", "-n", "-f", "typescope-oracle" })))
log("attached in %.0f ms; basedpyright pid %s, oracle pid %s", ready_ms, based_pid, oracle_pid)
local b0 = footprint_mb(based_pid)
local o0 = footprint_mb(oracle_pid)
log("at attach: basedpyright %d MB, oracle %d MB", b0, o0)

local function float_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    end
  end
end

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local timings = {}
for i, t in ipairs(spec.targets) do
  local s = lines[t.line]:find(t.needle, 1, true)
  vim.api.nvim_win_set_cursor(0, { t.line, s - 1 + (t.skip or 0) })
  require("typescope").close()
  require("typescope.resolve").clear_cache()
  local q0 = vim.uv.hrtime()
  local reason
  require("typescope").open({
    silent = true,
    focus = false,
    on_unresolved = function(r, why)
      reason = tostring(why) .. ": " .. tostring(r)
    end,
  })
  local got
  vim.wait(30000, function()
    got = float_lines()
    return got ~= nil or reason ~= nil
  end, 10)
  local ms = (vim.uv.hrtime() - q0) / 1e6
  timings[#timings + 1] = math.floor(ms)
  log("%2d %5.0f ms  %s%s", i, ms, t.label, got and ("  (" .. #got .. " lines)") or ("  " .. tostring(reason)))
end
require("typescope").close()

vim.wait(10000, function()
  return false
end, 500)
local b1, bpeak = footprint_mb(based_pid)
local o1, opeak = footprint_mb(oracle_pid)
local size = vim.fn.getfsize(bin)
print(vim.json.encode({
  oracle_binary_mb = math.floor(size / 1048576),
  attach_ms = math.floor(ready_ms),
  first_open_ms = timings[1],
  open_ms = timings,
  footprint_mb = {
    basedpyright = { attach = b0, settled = b1, peak = bpeak },
    oracle = { attach = o0, settled = o1, peak = opeak },
  },
}))
for _, c in ipairs(vim.lsp.get_clients()) do
  if vim.fn.has("nvim-0.11") == 1 then
    c:stop(true)
  else
    vim.lsp.stop_client(c.id, true)
  end
end
vim.wait(1000)
