-- Spike 2 addendum: start typescope-langserver.js as the buffer's LSP, prove
-- ordinary hover still works, then send the custom request at three targets.
--
--   nvim --headless --clean -l test_wrapper.lua

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local spec = vim.json.decode(table.concat(vim.fn.readfile(here .. "targets.json"), "\n"))
local file = spec.project_root .. "/" .. spec.file

local function log(fmt, ...)
  io.stderr:write(("[wrap] " .. fmt .. "\n"):format(...))
end

vim.cmd.edit(file)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"

local t0 = vim.uv.hrtime()
local client_id = vim.lsp.start({
  name = "typescope-langserver",
  cmd = { "node", here .. "typescope-langserver.js", "--stdio" },
  root_dir = spec.project_root,
  settings = { basedpyright = { analysis = { typeCheckingMode = "off" } } },
}, { bufnr = bufnr })
local client = vim.lsp.get_client_by_id(client_id)
vim.wait(30000, function()
  return client.initialized
end, 50)
log("attached in %.0f ms; server: %s", (vim.uv.hrtime() - t0) / 1e6, vim.inspect(client.server_info))

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local function position(t)
  local s = lines[t.line]:find(t.needle, 1, true)
  return { line = t.line - 1, character = s - 1 + (t.skip or 0) }
end

local function request(method, t)
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = position(t) }
  local done, result, error
  local q0 = vim.uv.hrtime()
  client:request(method, params, function(err, res)
    done, result, error = true, res, err
  end, bufnr)
  vim.wait(60000, function()
    return done
  end, 10)
  return result, error, (vim.uv.hrtime() - q0) / 1e6
end

-- ordinary hover still answers: basedpyright is intact underneath
local hover, herr, hms = request("textDocument/hover", spec.targets[5])
log("hover %.0f ms: %s", hms, hover and hover.contents.value:gsub("\n", " "):sub(1, 80) or vim.inspect(herr))

for _, i in ipairs({ 5, 4, 1 }) do
  local t = spec.targets[i]
  local res, err, ms = request("typescope/structure", t)
  log("typescope/structure %.0f ms — %s", ms, t.label)
  if err then
    log("  error: %s", vim.inspect(err))
  else
    -- trim for the log: member names and types only, one level
    local function brief(n, indent)
      local out = {}
      table.insert(out, indent .. (n.kind or "?") .. " " .. (n.name or "") .. "  " .. (n.printed or ""))
      for _, m in ipairs(n.members or {}) do
        table.insert(out, indent .. "  · " .. (m.name or m.kind) .. (m.origin and (" ↑" .. m.origin) or "") .. "  " .. (m.type or m.printed or "") .. (m.kind ~= "field" and m.kind ~= "instance" and ("  [" .. m.kind .. "]") or "") .. (m.inferred and " [inferred]" or ""))
        if m.children then
          for _, c in ipairs(m.children) do
            table.insert(out, indent .. "      · " .. c.name .. "  " .. (c.type or "") .. (c.kind ~= "field" and ("  [" .. c.kind .. "]") or ""))
          end
        end
      end
      for _, prm in ipairs(n.params or {}) do
        table.insert(out, indent .. "  · " .. prm.name .. "  " .. (prm.type or "") .. (prm.default and ("  = " .. prm.default) or "") .. (prm.declared and "" or "  [inferred]"))
      end
      if n.returns then
        table.insert(out, indent .. "  · returns  " .. n.returns .. (n.returnsInferred and "  [inferred]" or ""))
      end
      return table.concat(out, "\n")
    end
    io.stderr:write(brief(res, "  ") .. "\n")
  end
end

-- footprint of the ONE process tree (node started directly, no launcher)
local pid = tonumber(vim.trim(vim.fn.system({ "pgrep", "-n", "-f", "typescope-langserver.js" })))
local fp = vim.fn.system({ "footprint", "-p", tostring(pid) })
log("footprint: %s MB (peak %s)", fp:match("phys_footprint:%s*([%d%.]+)"), fp:match("phys_footprint_peak:%s*([%d%.]+)"))
vim.lsp.stop_client(client_id, true)
vim.wait(500)
vim.cmd.qall({ bang = true })
