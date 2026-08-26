-- Ollama transport + response parsing for LLM example generation.
-- Plain curl against the local HTTP API (localhost-only per requirements);
-- graceful failure is the caller's job — this module just reports.

local M = {}

-- In flight right now, our own process — NOT the sticky `warmed` flag 53c344d
-- removed. That one was a client-side belief about residency, and the server
-- can invalidate it at any moment (keep_alive expiry, another client's
-- unload, a restart). This caches nothing and cannot go stale.
local warming = false
-- generates parked while that warmup resolves; see M.generate
local warm_waiters = {}

local function flush_warm_waiters()
  local queued = warm_waiters
  warm_waiters = {}
  for _, fire in ipairs(queued) do
    fire()
  end
end

--- Fire one /api/generate request. cb runs on the main loop.
---@param prompt string
---@param cfg typescope.OllamaConfig
---@param cb fun(response: string?, err: string?)
---@param gen_opts? { num_predict?: integer } sized by the caller to the leaf count
---@param _retrying? boolean internal
function M.generate(prompt, cfg, cb, gen_opts, _retrying)
  -- Never race a warmup we can see. warmup and this call are dispatched
  -- microseconds apart on float open (init.lua:331-336) and ollama serves one
  -- request at a time, so on a cold server this one used to spend its whole
  -- budget queued behind the model load and time out for a reason that had
  -- nothing to do with the request. Park it; warmup's done() releases it.
  --
  -- The wait is bounded because warmup probes for liveness BEFORE it loads:
  -- a server that will never answer costs ~1s to establish, not the 120s
  -- load budget. Parked work always runs — done() fires on every path — which
  -- matters because this callback is what releases examples.in_flight.
  if warming and not _retrying then
    table.insert(warm_waiters, function()
      M.generate(prompt, cfg, cb, gen_opts, _retrying)
    end)
    return
  end
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({
    model = cfg.model,
    prompt = prompt,
    -- Streamed on purpose, and NOT for incremental display -- the whole
    -- answer is still assembled below. It is about what a timeout can mean.
    -- An unstreamed request delivers nothing until the last token, so any
    -- budget is really a bet on tokens/sec. Measured on an 8GB M1 this model
    -- runs 8-12 tok/s, which puts a 224-token batch at 19-27s: it fails an 8s
    -- budget while generating perfectly well. Streaming keeps bytes moving
    -- for the whole generation, so we can time out on SILENCE instead.
    stream = true,
    keep_alive = cfg.keep_alive or "5m", -- residency = RAM tradeoff, user's call
    options = { temperature = 0.2, num_predict = (gen_opts and gen_opts.num_predict) or 512 },
  })
  local timeout_s = math.max(1, math.ceil(cfg.timeout_ms / 1000))
  vim.system(
    -- --speed-limit/--speed-time is curl's own stall detector: abort only if
    -- throughput stays under 1 byte/s for timeout_s. Paired with the stream
    -- above, that makes timeout_ms mean "the server went quiet" rather than
    -- "this machine is slower than we assumed" -- a slow box just fills in
    -- slower and never fails. -N stops curl buffering the stream and hiding
    -- that liveness from the very check that depends on it.
    {
      "curl",
      "-sfN",
      "--speed-limit",
      "1",
      "--speed-time",
      tostring(timeout_s),
      url,
      "-H",
      "Content-Type: application/json",
      "-d",
      body,
    },
    { text = true },
    vim.schedule_wrap(function(out)
      if out.code == 28 and not _retrying then
        -- Stalled, not slow. ollama keeps loading/holding the model after we
        -- hang up, so a stall that was really a cold load clears on the retry.
        return M.generate(prompt, cfg, cb, gen_opts, true)
      end
      if out.code == 28 then
        return cb(
          nil,
          ("ollama went silent for %ds, twice — server wedged? (ollama.timeout_ms is a stall timeout, not a total budget)"):format(
            timeout_s
          )
        )
      end
      if out.code ~= 0 then
        return cb(nil, "ollama unreachable at " .. url)
      end
      -- A streamed reply is JSON-lines: one object per token, done=true last.
      -- Collect into a table and concat once; incremental `..` here would be
      -- quadratic over a few hundred chunks.
      local parts, done = {}, false
      for line in (out.stdout or ""):gmatch("[^\n]+") do
        local ok, chunk = pcall(vim.json.decode, line)
        if ok and type(chunk) == "table" then
          if type(chunk.response) == "string" then
            table.insert(parts, chunk.response)
          end
          if chunk.done then
            done = true
          end
        end
      end
      -- No done marker means the stream was cut mid-flight (killed curl,
      -- server restart). Truncated text would parse into plausible-looking
      -- garbage values, so treat it as failure rather than accept a fragment.
      if not done then
        return cb(nil, "unexpected ollama response")
      end
      cb(table.concat(parts))
    end)
  )
end

-- autostart state: the handle exists only for a server WE spawned. A server
-- that was already answering the port is never touched (and never killed).
local server_handle = nil
local ensuring = false
-- callers that arrived while a readiness run was already in flight; they get
-- that run's answer rather than starting one of their own
local ensure_waiters = {}

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
--- Non-detached keeps the supervisor tied to us, but that is NOT enough on
--- its own: `ollama serve` holds the weights in a separate `llama-server`
--- grandchild, and a bare SIGTERM to the supervisor leaves that grandchild
--- reparented to init with the model still resident. M.shutdown unloads
--- through the supervisor first for exactly this reason.
--- Single-flight; re-entry no-ops.
---@param cfg typescope.OllamaConfig
---@param cb fun(ready: boolean)
function M.ensure_server(cfg, cb)
  if ensuring then
    -- Re-entry is not an answer. This used to `return` without calling cb at
    -- all, and cb is load-bearing: warmup's done() is what clears `warming`
    -- and drains warm_waiters, so a dropped one parks every subsequent
    -- generate for the rest of the session — and leaves the pending bars
    -- breathing until PENDING_MAX_MS retires the clock three minutes later.
    -- Answering cb(false) would be a different lie: a server IS on its way
    -- up. Wait for the real answer, the way generate already waits on warmup.
    table.insert(ensure_waiters, cb)
    return
  end
  ensuring = true
  local function done(ready)
    ensuring = false
    -- drained BEFORE the callbacks run, with `ensuring` already false, so a
    -- waiter that calls ensure_server again starts a fresh run instead of
    -- queueing onto a list nothing will flush
    local queued = ensure_waiters
    ensure_waiters = {}
    cb(ready)
    for _, waiter in ipairs(queued) do
      waiter(ready)
    end
  end
  probe(cfg, function(alive)
    if alive then
      return done(true) -- someone else's server — use it, never own it
    end
    if not server_handle then
      -- stdout/stderr capture is OFF on purpose: vim.system buckets output
      -- into a lua table until the process exits, and this one never does
      local ok, handle = pcall(vim.system, { "ollama", "serve" }, { stdout = false, stderr = false })
      if not ok then
        return done(false) -- ollama binary missing
      end
      server_handle = handle
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

--- Fire the actual model-load request (empty prompt loads without
--- generating). cb(ok) on the main loop.
---@param cfg typescope.OllamaConfig
---@param cb fun(ok: boolean)
local function load_model(cfg, cb)
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({ model = cfg.model, prompt = "", stream = false, keep_alive = cfg.keep_alive or "5m" })
  vim.system(
    { "curl", "-sf", "--max-time", "120", url, "-H", "Content-Type: application/json", "-d", body },
    {},
    vim.schedule_wrap(function(out)
      cb(out.code == 0)
    end)
  )
end

--- Fire-and-forget empty-prompt generate on every float open. One request
--- does three jobs: answers residency, loads the model if keep_alive already
--- unloaded it, and resets the keep_alive clock — sliding-window residency
--- (unload N after you stop working, not N after the last real generation)
--- with the server as the only source of truth. No cached client-side state:
--- `warming` just stops overlapping calls from stacking curls. With
--- autostart, an unreachable server is spawned and the warmup retried once
--- it answers.
---@param cfg typescope.OllamaConfig
function M.warmup(cfg)
  if warming then
    return
  end
  warming = true
  M._arm_shutdown(cfg)
  local function done()
    warming = false
    flush_warm_waiters()
  end
  -- Liveness first, THEN load. The old order sent a 120s load request at a
  -- port that might have nothing on it, so establishing "this server is not
  -- going to answer" cost two minutes — and with generates now parked behind
  -- this, that stall would be the user's stall too. A probe answers the same
  -- question in a second, and only ollama's own responsiveness can tell a
  -- server busy loading a model from one that is simply wedged.
  probe(cfg, function(alive)
    if alive then
      return load_model(cfg, done)
    end
    if not cfg.autostart then
      return done()
    end
    M.ensure_server(cfg, function(ready)
      if not ready then
        return done()
      end
      load_model(cfg, done)
    end)
  end)
end

--- Blocking unload of cfg.model from whatever server is answering the port.
--- keep_alive = 0 tells ollama to drop the weights now, which terminates the
--- llama-server runner holding them — the grandchild a SIGTERM to `ollama
--- serve` would have orphaned.
---
--- This blocks, because VimLeavePre is the last moment nvim will run our
--- code: once it returns the event loop is torn down and no libuv callback
--- ever fires again. But it blocks on the *completion event*, not on a
--- duration — SystemObj:wait is vim.wait(ms, function() return done end)
--- underneath, so it returns the instant curl exits. The millisecond
--- argument is a hang guard for a wedged server, never the expected cost.
---@param cfg typescope.OllamaConfig
---@return boolean unloaded
local function unload_model(cfg)
  local url = ("http://%s:%d/api/generate"):format(cfg.host, cfg.port)
  local body = vim.json.encode({ model = cfg.model, prompt = "", stream = false, keep_alive = 0 })
  -- pcall, not just a code check: vim.system RAISES on a missing binary
  -- rather than returning nonzero, and the caller must still reach the reap
  local ok, out = pcall(function()
    return vim.system(
      { "curl", "-sf", "--max-time", "5", url, "-H", "Content-Type: application/json", "-d", body },
      { text = true }
    ):wait(6000)
  end)
  return ok and out.code == 0
end

--- Reap a server we spawned. SIGTERM then await the actual exit, so we know
--- the process is gone rather than merely signalled.
---@return boolean reaped
local function reap_server()
  if not server_handle then
    return false
  end
  local handle = server_handle
  server_handle = nil
  pcall(handle.kill, handle, "sigterm")
  local ok, out = pcall(handle.wait, handle, 4000)
  return ok and out ~= nil
end

--- Give back what we took, on the way out.
---
--- Ownership is answerable at the server level and NOT at the model level.
--- `server_handle` is non-nil only for a server we spawned, so that half is
--- exact. But "is anyone else still using this model" has no answer: ollama's
--- API is stateless, /api/ps records an expiry rather than an owner, and
--- there is no client identity for it to record. Probing residency at warmup
--- does not recover it either — a second session inside the keep_alive window
--- sees its own predecessor's residue and reads it as a stranger's.
---
--- So the split is by server, and keep_alive carries the borrowed case. That
--- is not a fallback, it is the actual definition of the thing we cannot
--- measure: nobody is using a model when nobody has asked for it in N
--- minutes. It also stays correct where an exit hook cannot — two nvim
--- windows open on different projects, where unloading on the first exit
--- would leave the second one cold.
---@param cfg typescope.OllamaConfig
function M.shutdown(cfg)
  -- Borrowed server: touch nothing. The model expires on its own clock, and
  -- any other client still working keeps refreshing that clock for us.
  if not server_handle then
    return
  end

  -- Our server: unload BEFORE the SIGTERM. The unload routes through the
  -- supervisor, which is what makes the llama-server grandchild exit; kill
  -- the supervisor first and that grandchild reparents to init and holds the
  -- model's ~2GB until the machine reboots.
  --
  -- A failed unload (wedged server, curl missing) still falls through to the
  -- reap: killing the supervisor and orphaning the runner is bad, but it is
  -- strictly better than leaving both alive. Narrowing that residual window
  -- would mean tracking the runner's pid or spawning into our own process
  -- group, and neither is worth the machinery for a path that needs the
  -- server to be broken already.
  unload_model(cfg)
  reap_server()
end

--- Register the exit hook once. Called from warmup so it covers the borrowed
--- server too — that path returns before ensure_server is ever reached.
---@param cfg typescope.OllamaConfig
function M._arm_shutdown(cfg)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("TypeScopeOllamaServer", { clear = true }),
    desc = "TypeScope: release the ollama model (and our server, if we started it)",
    callback = function()
      pcall(M.shutdown, cfg)
    end,
  })
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
