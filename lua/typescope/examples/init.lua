-- Example-value dispatch. Heuristic mode fills node.example.heuristic across
-- a resolved forest; LLM mode fills node.example.llm via Ollama, through a
-- session cache keyed on model.hash(node) so re-opens of the same types
-- don't regenerate.

local model = require("typescope.model")
local heuristic = require("typescope.examples.heuristic")

local M = {}

-- session-lifetime LLM cache: model.hash(node) -> literal
local llm_cache = {}

--- Test seam: drop cached LLM values so failure paths can be exercised.
function M._clear_llm_cache()
  llm_cache = {}
end

--- Annotate every leaf in the forest with a heuristic example. Structs,
--- methods, and unresolved types get none — examples belong on concrete
--- fields. Fields with a real default are also skipped: the default is
--- already the best possible example (a `None` default doesn't count — a
--- concrete example still adds information there).
---@param roots typescope.Node[]
function M.annotate(roots)
  model.walk(roots, function(node)
    local has_real_default = node.default ~= nil and node.default ~= "None"
    if
      #node.children == 0
      and node.kind ~= "method"
      and node.type.category ~= "unresolved"
      and not has_real_default
    then
      node.example.heuristic = heuristic.value(node.name, node.type.display)
    end
  end)
end

---@param node typescope.Node
---@return boolean
local function eligible(node)
  local has_real_default = node.default ~= nil and node.default ~= "None"
  return #node.children == 0
    and node.kind ~= "method"
    and node.type.category ~= "unresolved"
    and not has_real_default
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
---@param on_progress? fun() a batch of values just landed
function M.llm(roots, token, done, on_progress)
  local _ = token
  local cfg = require("typescope.config").get()
  if not cfg.ollama.enabled then
    return done(false, "ollama is disabled — setup({ ollama = { enabled = true } })")
  end

  local leaves = visible_leaves(roots)
  local pending = {}
  for _, node in ipairs(leaves) do
    local cached = llm_cache[model.hash(node) .. "#" .. node.name]
    if cached then
      node.example.llm = cached
    else
      table.insert(pending, node)
    end
  end
  if #pending == 0 then
    return done(#leaves > 0)
  end

  local ollama = require("typescope.examples.ollama")
  local index = 1
  local any_filled = false

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
    for _, node in ipairs(batch) do
      table.insert(specs, { id = node.id, name = node.name, display = node.type.display or "Any" })
    end
    ollama.generate(ollama.prompt(specs), cfg.ollama, function(response, err)
      if not response then
        -- abort the chain but report partial success: earlier batches landed
        return done(any_filled, err)
      end
      local values = ollama.parse(response)
      local filled = 0
      for _, node in ipairs(batch) do
        local value = values[node.id]
        if value then
          node.example.llm = value
          llm_cache[model.hash(node) .. "#" .. node.name] = value
          filled = filled + 1
        end
      end
      if filled > 0 then
        any_filled = true
        if on_progress then
          on_progress()
        end
      end
      next_batch()
    end, { num_predict = math.min(2048, 96 + 16 * #specs) })
  end
  next_batch()
end

return M
