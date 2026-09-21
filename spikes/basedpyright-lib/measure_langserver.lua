-- Spike 2, langserver side: drive the REAL basedpyright-langserver the way
-- nvim does (same settings as ~/.config/nvim's vim.lsp.config.basedpyright),
-- open the target file, hover the ten targets, and sample the server's RSS.
--
--   nvim --headless --clean -l measure_langserver.lua
--
-- Prints one JSON line at the end; human-readable progress on stderr.

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local spec = vim.json.decode(table.concat(vim.fn.readfile(here .. "targets.json"), "\n"))
local root = spec.project_root
local file = root .. "/" .. spec.file

local function log(fmt, ...)
  io.stderr:write(("[ls] " .. fmt .. "\n"):format(...))
end

-- Mason installs basedpyright from PyPI: `basedpyright-langserver` is a
-- Python launcher that spawns the real server, a bundled nodejs_wheel node.
-- Measure the whole tree under the launcher; the node child is the number.
local function tree(pid)
  local pids = { pid }
  local out = vim.fn.system({ "pgrep", "-P", tostring(pid) })
  for child in out:gmatch("%d+") do
    vim.list_extend(pids, tree(tonumber(child)))
  end
  return pids
end

-- `ps rss` is the WRONG number on macOS under memory pressure: pages the
-- compressor has taken stop counting, and an idle server on this 8GB machine
-- read as 21 MB while `footprint` said 521. Physical footprint (which
-- includes compressed pages) is what the process actually costs.
local function footprint_mb(pid)
  local total, peak = 0, 0
  for _, p in ipairs(tree(pid)) do
    local out = vim.fn.system({ "footprint", "-p", tostring(p) })
    total = total + (tonumber(out:match("phys_footprint:%s*([%d%.]+)%s*MB")) or 0)
    peak = peak + (tonumber(out:match("phys_footprint_peak:%s*([%d%.]+)%s*MB")) or 0)
  end
  return total, peak
end
local function rss_kb(pid)
  return (footprint_mb(pid)) * 1024
end

local function server_pid()
  -- newest launcher; the user's own nvim (if running) started its own earlier
  local out = vim.fn.system({ "pgrep", "-n", "-f", "basedpyright-langserver" })
  return tonumber(vim.trim(out))
end

local t_start = vim.uv.hrtime()
local function ms_since(t)
  return (vim.uv.hrtime() - t) / 1e6
end

vim.cmd.edit(file)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"

local client_id = vim.lsp.start({
  name = "basedpyright",
  cmd = { vim.fn.expand("~/.local/share/nvim/mason/bin/basedpyright-langserver"), "--stdio" },
  root_dir = root,
  settings = {
    basedpyright = {
      disableOrganizeImports = true,
      analysis = {
        autoImportCompletions = true,
        typeCheckingMode = "off",
        diagnosticSeverityOverrides = { reportMissingImports = "warning" },
        extraPaths = { vim.fn.expand("~/.dotfiles/python_stubs/stubs") },
      },
    },
  },
}, { bufnr = bufnr })
assert(client_id, "vim.lsp.start returned nil")
local client = vim.lsp.get_client_by_id(client_id)
vim.wait(30000, function()
  return client.initialized and #vim.lsp.get_clients({ bufnr = bufnr }) > 0
end, 50)
local pid = server_pid()
log("attached in %.0f ms, launcher pid %s, tree %s, rss %d MB", ms_since(t_start), pid, table.concat(tree(pid), ","), rss_kb(pid) / 1024)

local samples = { attach = rss_kb(pid) }
local peak = samples.attach
local function sample(label)
  local r = rss_kb(pid)
  peak = math.max(peak, r)
  samples[label] = r
  return r
end

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local function position(t)
  local text = lines[t.line]
  local s = text:find(t.needle, 1, true)
  assert(s, "needle not on line " .. t.line .. ": " .. t.needle)
  return { line = t.line - 1, character = s - 1 + (t.skip or 0) }
end

local function hover(t)
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = position(t) }
  local done, result
  local t0 = vim.uv.hrtime()
  client:request("textDocument/hover", params, function(err, res)
    done, result = true, (not err) and res or nil
  end, bufnr)
  vim.wait(60000, function()
    return done
  end, 10)
  local text = result and result.contents and (result.contents.value or result.contents) or ""
  if type(text) == "table" then
    text = table.concat(text, " ")
  end
  return ms_since(t0), text:gsub("\n", " "):sub(1, 90)
end

-- cold start: first hover carries the server's initial analysis of the file
-- and every import it pulls in
local first_ms, first_text = hover(spec.targets[1])
log("first hover %.0f ms: %s", first_ms, first_text)
sample("after_first_hover")

local timings = { first_ms }
for i = 2, #spec.targets do
  local ms, text = hover(spec.targets[i])
  timings[#timings + 1] = ms
  log("hover %d %.0f ms: %s", i, ms, text)
end
sample("after_10_hovers")

-- settle: the background analysis thread may still be working
vim.wait(10000, function()
  return false
end, 200)
sample("after_10s_idle")

print(vim.json.encode({
  side = "langserver",
  pid = pid,
  tree = tree(pid),
  metric = "phys_footprint via footprint(1), launcher + node summed",
  footprint_peak_mb = math.floor(select(2, footprint_mb(pid))),
  footprint_mb = {
    attach = math.floor(samples.attach / 1024),
    after_first_hover = math.floor(samples.after_first_hover / 1024),
    after_10_hovers = math.floor(samples.after_10_hovers / 1024),
    after_10s_idle = math.floor(samples.after_10s_idle / 1024),
    peak = math.floor(peak / 1024),
  },
  first_hover_ms = math.floor(first_ms),
  hover_ms = vim.tbl_map(math.floor, timings),
}))
vim.lsp.stop_client(client_id, true)
vim.wait(1000)
vim.cmd.qall({ bang = true })
