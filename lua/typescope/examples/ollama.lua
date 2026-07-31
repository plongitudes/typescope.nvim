-- Ollama transport + response parsing for LLM example generation.
-- Plain curl against the local HTTP API (localhost-only per requirements);
-- graceful failure is the caller's job — this module just reports.

local M = {}

--- Fire one /api/generate request. cb runs on the main loop.
---@param prompt string
---@param cfg typescope.OllamaConfig
---@param cb fun(response: string?, err: string?)
---@param gen_opts? { num_predict?: integer } sized by the caller to the leaf count
---@param _retrying? boolean internal
function M.generate(prompt, cfg, cb, gen_opts, _retrying)
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({
    model = cfg.model,
    prompt = prompt,
    stream = false,
    keep_alive = "30m", -- stay resident through a working session
    options = { temperature = 0.2, num_predict = (gen_opts and gen_opts.num_predict) or 512 },
  })
  local timeout_s = math.max(1, math.ceil(cfg.timeout_ms / 1000))
  vim.system(
    { "curl", "-sf", "--max-time", tostring(timeout_s), url, "-H", "Content-Type: application/json", "-d", body },
    { text = true },
    vim.schedule_wrap(function(out)
      if out.code == 28 and not _retrying then
        -- curl timeout — but ollama keeps loading/holding the model even
        -- after we hang up, so a single retry usually lands on a warm model
        return M.generate(prompt, cfg, cb, gen_opts, true)
      end
      if out.code == 28 then
        return cb(
          nil,
          ("ollama timed out twice (%ds each) — cold model on a small machine? raise ollama.timeout_ms"):format(
            timeout_s
          )
        )
      end
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

-- autostart state: the handle exists only for a server WE spawned. A server
-- that was already answering the port is never touched (and never killed).
local server_handle = nil
local ensuring = false

--- One cheap liveness probe. cb(ok) on the main loop.
---@param cfg typescope.OllamaConfig
---@param cb fun(ok: boolean)
local function probe(cfg, cb)
  local url = ("http://%s:%d/api/version"):format(cfg.host, cfg.port)
  vim.system(
    { "curl", "-sf", "--max-time", "1", url },
    {},
    vim.schedule_wrap(function(out)
      cb(out.code == 0)
    end)
  )
end

--- Spawn `ollama serve` as a plain child process and wait for it to answer.
--- Non-detached is the point: nvim tears the child down on ANY exit path
--- (:q, ZZ, :qa, ...), reclaiming the model's RAM; the VimLeavePre kill is
--- just an explicit graceful SIGTERM on top. Single-flight; re-entry no-ops.
---@param cfg typescope.OllamaConfig
---@param cb fun(ready: boolean)
function M.ensure_server(cfg, cb)
  if ensuring then
    return
  end
  ensuring = true
  local function done(ready)
    ensuring = false
    cb(ready)
  end
  probe(cfg, function(alive)
    if alive then
      return done(true) -- someone else's server — use it, never own it
    end
    if not server_handle then
      local ok, handle = pcall(vim.system, { "ollama", "serve" }, {})
      if not ok then
        return done(false) -- ollama binary missing
      end
      server_handle = handle
      vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("TypeScopeOllamaServer", { clear = true }),
        callback = function()
          pcall(server_handle.kill, server_handle, "sigterm")
        end,
      })
    end
    -- ~10s readiness budget (500ms polls); the port binds well before the
    -- model loads, so this only covers process startup
    local attempts = 0
    local function poll()
      probe(cfg, function(up)
        if up then
          return done(true)
        end
        attempts = attempts + 1
        if attempts >= 20 then
          return done(false)
        end
        vim.defer_fn(poll, 500)
      end)
    end
    poll()
  end)
end

local warmed = false

--- Fire the actual model-load request (empty prompt loads without
--- generating). cb(ok) on the main loop.
---@param cfg typescope.OllamaConfig
---@param cb fun(ok: boolean)
local function load_model(cfg, cb)
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({ model = cfg.model, prompt = "", stream = false, keep_alive = "30m" })
  vim.system(
    { "curl", "-sf", "--max-time", "120", url, "-H", "Content-Type: application/json", "-d", body },
    {},
    vim.schedule_wrap(function(out)
      cb(out.code == 0)
    end)
  )
end

--- Fire-and-forget model load so the first E press doesn't pay the cold
--- start. `warmed` flips optimistically (so overlapping calls don't stack
--- curls) but resets on failure — a server started later still gets warmed
--- by the next float open. With autostart, an unreachable server is spawned
--- and the warmup retried once it answers.
---@param cfg typescope.OllamaConfig
function M.warmup(cfg)
  if warmed then
    return
  end
  warmed = true
  load_model(cfg, function(ok)
    if ok then
      return
    end
    warmed = false
    if not cfg.autostart then
      return
    end
    M.ensure_server(cfg, function(ready)
      if not ready then
        return
      end
      warmed = true
      load_model(cfg, function(ok2)
        if not ok2 then
          warmed = false
        end
      end)
    end)
  end)
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
