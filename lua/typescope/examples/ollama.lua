-- Ollama transport + response parsing for LLM example generation.
-- Plain curl against the local HTTP API (localhost-only per requirements);
-- graceful failure is the caller's job — this module just reports.

local M = {}

--- Fire one /api/generate request. cb runs on the main loop.
---@param prompt string
---@param cfg typescope.OllamaConfig
---@param cb fun(response: string?, err: string?)
---@param gen_opts? { num_predict?: integer } sized by the caller to the leaf count
function M.generate(prompt, cfg, cb, gen_opts)
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({
    model = cfg.model,
    prompt = prompt,
    stream = false,
    options = { temperature = 0.2, num_predict = (gen_opts and gen_opts.num_predict) or 512 },
  })
  local timeout_s = tostring(math.max(1, math.ceil(cfg.timeout_ms / 1000)))
  vim.system(
    { "curl", "-sf", "--max-time", timeout_s, url, "-H", "Content-Type: application/json", "-d", body },
    { text = true },
    vim.schedule_wrap(function(out)
      if out.code ~= 0 then
        return cb(nil, "ollama unreachable at " .. url)
      end
      local ok, decoded = pcall(vim.json.decode, out.stdout or "")
      if not ok or type(decoded) ~= "table" or type(decoded.response) ~= "string" then
        return cb(nil, "unexpected ollama response")
      end
      cb(decoded.response)
    end)
  )
end

--- Build the prompt: one dotted-path line per leaf so the model answers in a
--- format we can parse back deterministically.
---@param leaves { id: string, name: string, display: string }[]
---@return string
function M.prompt(leaves)
  local lines = {
    "You generate realistic example values for Python fields.",
    "Reply with EXACTLY one line per field, in the format:",
    "path = value",
    "where value is a single valid Python literal appropriate for the type.",
    "Prefer realistic-looking values over placeholders. No prose, no code fences.",
    "",
    "Fields:",
  }
  for _, leaf in ipairs(leaves) do
    table.insert(lines, ("%s: %s"):format(leaf.id, leaf.display))
  end
  return table.concat(lines, "\n")
end

--- Parse "path = literal" lines back into a map. Tolerates prose noise and
--- code fences — anything that doesn't match the shape is skipped.
---@param text string model output
---@return table<string, string> path -> literal
function M.parse(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local path, value = line:match("^%s*([%w_%.]+)%s*=%s*(.+)$")
    if path and value then
      out[path] = vim.trim(value)
    end
  end
  return out
end

return M
