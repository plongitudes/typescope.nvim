-- Example-value dispatch. Heuristic mode fills node.example.heuristic across
-- a resolved forest; LLM mode fills node.example.llm via Ollama, through a
-- session cache keyed on model.hash(node) so re-opens of the same types
-- don't regenerate.

local model = require("typescope.model")
local heuristic = require("typescope.examples.heuristic")

local M = {}

-- session-lifetime LLM cache: model.hash(node) -> literal
local llm_cache = {}

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

--- Generate LLM examples for every eligible leaf in the forest (one request
--- for the whole float). done(true) when node.example.llm values are filled
--- (possibly all from cache), done(false) on any failure — callers keep
--- heuristics and tell the user once.
---@param roots typescope.Node[]
---@param token typescope.CancelToken
---@param done fun(ok: boolean, err: string?)
function M.llm(roots, token, done)
  local cfg = require("typescope.config").get()
  if not cfg.ollama.enabled then
    return done(false, "ollama is disabled — setup({ ollama = { enabled = true } })")
  end

  local leaves = visible_leaves(roots)
  local pending = {}
  for _, node in ipairs(leaves) do
    local key = model.hash(node) .. "#" .. node.name
    local cached = llm_cache[key]
    if cached then
      node.example.llm = cached
    else
      table.insert(pending, node)
    end
  end
  if #pending == 0 then
    return done(#leaves > 0)
  end

  local specs = {}
  for _, node in ipairs(pending) do
    table.insert(specs, { id = node.id, name = node.name, display = node.type.display or "Any" })
  end
  local ollama = require("typescope.examples.ollama")
  -- ~16 tokens per answer line; a 48-leaf uvicorn.run needs far more than a
  -- fixed 512 or the tail fields get silently truncated
  local budget = math.min(2048, 96 + 16 * #specs)
  ollama.generate(ollama.prompt(specs), cfg.ollama, function(response, err)
    if require("typescope.async").stale(token) then
      return
    end
    if not response then
      return done(false, err)
    end
    local values = ollama.parse(response)
    local filled = 0
    for _, node in ipairs(pending) do
      local value = values[node.id]
      if value then
        node.example.llm = value
        llm_cache[model.hash(node) .. "#" .. node.name] = value
        filled = filled + 1
      end
    end
    done(filled > 0, filled == 0 and "model returned nothing usable" or nil)
  end, { num_predict = budget })
end

return M
