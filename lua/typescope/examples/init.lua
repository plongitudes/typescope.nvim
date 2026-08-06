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
-- keys with a request currently in flight. Batches outlive a closed float on
-- purpose (they pay for the next open) — a reopen mid-generation must reuse
-- them, not duplicate them.
local in_flight = {}

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
--- concrete example still adds information there).
---@param roots typescope.Node[]
---@param node typescope.Node
---@return boolean
local function eligible(node)
  local has_real_default = node.default ~= nil and node.default ~= "None"
  -- _lazy placeholders are unresolved structure (an alias name standing in
  -- for a type nobody has chased yet) — an example for one is speculation,
  -- and prompting a slow local model for speculation is what made K on
  -- open() churn. Expanding resolves the node; examples follow honestly.
  return #node.children == 0
    and node.kind ~= "method"
    and node.type.category ~= "unresolved"
    and node._lazy == nil
    and not has_real_default
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
      in_flight[keys[node.id]] = true
    end
    ollama.generate(ollama.prompt(specs), cfg.ollama, function(response, err)
      for _, node in ipairs(batch) do
        in_flight[keys[node.id]] = nil
      end
      if not response then
        -- abort the chain but report partial success: earlier batches
        -- landed. Transport failures leave no sentinel — retry is fine.
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
      if filled > 0 then
        any_filled = true
        if on_progress then
          on_progress(batches_done, batches_total)
        end
      end
      next_batch()
    end, { num_predict = math.min(2048, 96 + 16 * #specs) })
  end
  next_batch()
end

return M
