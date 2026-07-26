-- Example-value dispatch. Heuristic mode fills node.example.heuristic across
-- a resolved forest; LLM mode (phase 6) will fill node.example.llm through a
-- session cache keyed on model.hash(node).

local model = require("typescope.model")
local heuristic = require("typescope.examples.heuristic")

local M = {}

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

return M
