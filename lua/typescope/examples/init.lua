-- Example-value dispatch. Heuristic mode fills node.example.heuristic across
-- a resolved forest; LLM mode fills node.example.llm via Ollama, through a
-- session cache keyed on model.hash(node) so re-opens of the same types
-- don't regenerate.

local model = require("typescope.model")
local heuristic = require("typescope.examples.heuristic")

local M = {}

-- session-lifetime LLM cache: hash#name -> literal, or false — a MISS
-- sentinel meaning "asked, model returned nothing usable". Auto-generation
-- runs on every open; without the sentinel it would re-ask the model about
-- the same whiffed leaves forever (Tony's repeated-generation report).
local llm_cache = {}
-- keys a run has claimed: queued OR with a request currently in flight.
-- Batches outlive a closed float on purpose (they pay for the next open) — a
-- reopen mid-generation must reuse them, not duplicate them. Queued-but-not-
-- yet-dispatched keys count: a reopen that only checked dispatched ones would
-- re-ask for everything still sitting behind the current batch. Doubles as
-- the "still pending" set the breathing animation renders from (38c).
local in_flight = {}
-- the one open float subscribes here (40u): a reopen mid-generation skips
-- in-flight keys, so when those batches land there is no on_progress aimed
-- at the new float — this callback is how it hears about them. It fires for
-- every landed batch (the current float's own included), making it the
-- single repaint path for arriving values.
local landed_cb = nil

---@param node typescope.Node
---@return string
local function cache_key(node)
  return model.hash(node) .. "#" .. node.name
end

--- Test seam: drop cached LLM values so failure paths can be exercised.
function M._clear_llm_cache()
  llm_cache = {}
  in_flight = {}
end

--- Is this node's example still coming? True from the moment a run claims
--- the leaf until its batch resolves (value or MISS alike). Passed into
--- render as opts.example_pending so pending rows can breathe.
---@param node typescope.Node
---@return boolean
function M.awaiting(node)
  return in_flight[cache_key(node)] == true
end

--- Is any leaf's example still coming, anywhere? Drives the breathing
--- animation's lifetime, which outlives a single run: a float reopened
--- mid-generation queues nothing (the dedup skips claimed keys) yet still has
--- values arriving, and those rows should breathe too.
---@return boolean
function M.any_awaiting()
  return next(in_flight) ~= nil
end

--- Subscribe the current float to batch landings; nil unsubscribes. One
--- subscriber only: floats are single-instance and re-subscribe on open.
---@param cb? fun()
function M.on_landed(cb)
  landed_cb = cb
end

--- Fill node.example.llm from the session cache across the forest (MISS
--- sentinels excluded). Returns true when anything NEW landed — false when
--- the nodes already carry the values, as they do when a late batch wrote
--- straight into a tree the resolve cache shares with the current float.
---@param roots typescope.Node[]
---@return boolean
function M.apply_cache(roots)
  local filled = false
  model.walk(roots, function(node)
    local cached = llm_cache[cache_key(node)]
    if cached and node.example.llm ~= cached then
      node.example.llm = cached
      filled = true
    end
  end)
  return filled
end

--- Forget MISS sentinels for this forest — an explicit E press is permission
--- to re-ask leaves the model whiffed on (the auto-run on open never does).
---@param roots typescope.Node[]
function M.retry_misses(roots)
  model.walk(roots, function(node)
    local key = cache_key(node)
    if llm_cache[key] == false then
      llm_cache[key] = nil
    end
  end)
end

--- Annotate every leaf in the forest with a heuristic example. Structs,
--- methods, and unresolved types get none — examples belong on concrete
--- fields. Fields with a real default are also skipped: the default is
--- already the best possible example (a `None` default doesn't count — a
--- concrete example still adds information there, and neither does a stub's
--- `...`, which only says "has a default, not telling": every param of a
--- stub-only package like loguru carries one).
---@param roots typescope.Node[]
---@param node typescope.Node
---@return boolean
--- pyright renders a bound TypeVar or a Self type as `Name@Owner` — `Self@Bar`
--- for a receiver, `T@func` for a type variable. Neither is a Python type
--- expression, and no literal satisfies one, so asking for an example produces
--- an answer keyed on something other than the type: the model, forbidden by the
--- prompt from declining, falls back on the field NAME. That is how a receiver
--- called numpy_test was offered `np.array([1, 2, 3, 4, 5])` (typescope.nvim-o6s).
---
--- String literals are stripped before looking, so `Literal["user@example.com"]`
--- — a perfectly good type with an @ in it — is not caught.
---@param display string?
---@return boolean
local function is_unbound_notation(display)
  if not display then
    return false
  end
  local stripped = display:gsub('"[^"]*"', ""):gsub("'[^']*'", "")
  return stripped:find("[%w_]+@[%w_]+") ~= nil
end

local function eligible(node)
  -- "…" is the normalised stub placeholder (extract/python.lua's default_text)
  -- and "..." is the raw form, still reachable from a source file rather than a
  -- stub. Neither is a value, so neither suppresses an example: a parameter
  -- whose default is unspecified is exactly one worth showing an example for.
  local d = node.default
  local has_real_default = d ~= nil and d ~= "None" and d ~= "..." and d ~= "…"
  -- _lazy placeholders are unresolved structure (an alias name standing in
  -- for a type nobody has chased yet) — an example for one is speculation,
  -- and prompting a slow local model for speculation is what made K on
  -- open() churn. Expanding resolves the node; examples follow honestly.
  return #node.children == 0
    and node.kind ~= "method"
    and node.type.category ~= "unresolved"
    and node._lazy == nil
    and not has_real_default
    and not is_unbound_notation(node.type.display)
end

function M.annotate(roots)
  model.walk(roots, function(node)
    if eligible(node) then
      local value = heuristic.value(node.name, node.type.display)
      -- a None-default doesn't block examples (eligible), but an example
      -- that IS the default restates the row — drop it
      node.example.heuristic = value ~= node.default and value or nil
    end
  end)
end

--- Eligible leaves that are actually VISIBLE (reachable through expanded
--- ancestors). E means "examples for what I'm looking at" — prompting for
--- the interior of a collapsed SQLAlchemy struct wastes a slow model's time
--- on values nobody can see. Expanding more and pressing E again covers the
--- newly visible leaves; the cache keeps repeat presses cheap.
---@param roots typescope.Node[]
---@return typescope.Node[]
local function visible_leaves(roots)
  local leaves = {}
  local function visit(node)
    if #node.children == 0 then
      if eligible(node) then
        table.insert(leaves, node)
      end
    elseif node.state.expanded then
      for _, child in ipairs(node.children) do
        visit(child)
      end
    end
  end
  for _, root in ipairs(roots) do
    visit(root)
  end
  return leaves
end

-- Leaves per request: a batch's ~8×15 output tokens finishes in a few
-- seconds even on small machines. One monolithic request for a 48-leaf
-- uvicorn.run takes 30s+ of generation — no timeout survives that, and a
-- timed-out request caches nothing (ollama cancels on disconnect).
local LLM_BATCH = 8

--- Generate LLM examples for the VISIBLE eligible leaves, in batches, filling
--- progressively: on_progress fires after each batch lands (callers
--- re-render), done fires at the end — done(true) if anything was filled
--- (cache included), done(false, err) on total failure. Staleness is the
--- callers' concern: they guard UI updates, while we always parse and cache —
--- batches that complete after the float closed still pay for the next open.
---@param roots typescope.Node[]
---@param token typescope.CancelToken
---@param done fun(ok: boolean, err: string?)
---@param on_progress? fun(batches_done: integer, batches_total: integer) a batch of values just landed
function M.llm(roots, token, done, on_progress)
  local _ = token
  local cfg = require("typescope.config").get()
  if not cfg.ollama.enabled then
    return done(false, "ollama is disabled — setup({ ollama = { enabled = true } })")
  end

  local leaves = visible_leaves(roots)
  local pending = {}
  for _, node in ipairs(leaves) do
    local key = cache_key(node)
    local cached = llm_cache[key]
    if cached then
      node.example.llm = cached
    elseif cached == nil and not in_flight[key] then
      -- false = MISS sentinel (heuristic stands); in_flight = a still-running
      -- batch from a previous open will cache it — don't ask twice
      table.insert(pending, node)
    end
  end
  if #pending == 0 then
    return done(#leaves > 0)
  end
  -- claim the whole queue up front, not batch by batch: a reopen mid-run
  -- must skip leaves this run has yet to reach, and the breathing animation
  -- wants every not-yet-landed leaf, not just the eight in the air
  for _, node in ipairs(pending) do
    in_flight[cache_key(node)] = true
  end

  local ollama = require("typescope.examples.ollama")
  local index = 1
  local any_filled = false
  local batches_total = math.ceil(#pending / LLM_BATCH)
  local batches_done = 0

  local function next_batch()
    if index > #pending then
      return done(any_filled, not any_filled and "model returned nothing usable" or nil)
    end
    local batch = {}
    for i = index, math.min(index + LLM_BATCH - 1, #pending) do
      table.insert(batch, pending[i])
    end
    index = index + LLM_BATCH

    local specs = {}
    local keys = {}
    for _, node in ipairs(batch) do
      table.insert(specs, { id = node.id, name = node.name, display = node.type.display or "Any" })
      keys[node.id] = cache_key(node)
    end
    ollama.generate(ollama.prompt(specs), cfg.ollama, function(response, err)
      for _, node in ipairs(batch) do
        in_flight[keys[node.id]] = nil
      end
      if not response then
        -- abort the chain but report partial success: earlier batches
        -- landed. Transport failures leave no sentinel — retry is fine, so
        -- release the tail of the queue too: keys nobody will ever ask about
        -- would otherwise stay claimed for the session (unaskable, and
        -- breathing forever).
        for i = index, #pending do
          in_flight[cache_key(pending[i])] = nil
        end
        return done(any_filled, err)
      end
      local values = ollama.parse(response)
      local filled = 0
      for _, node in ipairs(batch) do
        local value = values[node.id]
        if value then
          node.example.llm = value
          llm_cache[keys[node.id]] = value
          filled = filled + 1
        else
          -- asked and answered nothing usable: MISS — the heuristic stands
          -- and this session won't auto-ask again (E retries explicitly)
          llm_cache[keys[node.id]] = false
        end
      end
      batches_done = batches_done + 1
      any_filled = any_filled or filled > 0
      -- a batch resolving is a UI event even when it filled nothing: its
      -- leaves stopped being pending either way, and whatever the float drew
      -- to say "still coming" has to come down
      if on_progress then
        on_progress(batches_done, batches_total)
      end
      if landed_cb then
        landed_cb()
      end
      next_batch()
    end, { num_predict = math.min(2048, 96 + 16 * #specs) })
  end
  next_batch()
end

return M
