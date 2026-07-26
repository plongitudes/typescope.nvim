---@class typescope.TypeInfo
---@field raw string exact annotation text from source (fallback display)
---@field display string normalized form, e.g. "int | None"
---@field category "builtin"|"generic"|"typeddict"|"dataclass"|"pydantic"|"namedtuple"|"protocol"|"unresolved"
---@field args? typescope.TypeInfo[] generic type arguments

---@class typescope.NodeState
---@field expanded boolean
---@field loaded boolean children resolved (false + source set = lazy-recursion hook)
---@field loading boolean
---@field error? string

---@class typescope.Node
---@field id string stable path id, e.g. "root.config.host" (preserves expand state across re-renders)
---@field kind "param"|"field"|"return"|"method"|"variant"
---@field name string
---@field type typescope.TypeInfo
---@field default? string source text of the default value
---@field badge? string e.g. "NotRequired" for TypedDict fields
---@field source? { uri: string, range: table } where the type is declared
---@field children typescope.Node[]
---@field state typescope.NodeState
---@field example { heuristic?: string, llm?: string }
---@field active boolean synced with signatureHelp activeParameter

local M = {}

-- Rewrite a subtree's ids to be rooted under `prefix` — ids are dotted paths
-- and every structural attach must keep the whole subtree consistent.
local function reid(node, prefix)
  node.id = prefix .. "." .. node.name
  for _, child in ipairs(node.children) do
    reid(child, node.id)
  end
end

--- Build a Node from a sparse spec, filling structural defaults.
---@param spec table
---@return typescope.Node
function M.new(spec)
  local node = {
    id = spec.id or spec.name,
    kind = spec.kind or "field",
    name = spec.name,
    type = spec.type or { raw = "?", display = "?", category = "unresolved" },
    default = spec.default,
    badge = spec.badge,
    source = spec.source,
    children = {},
    state = {
      expanded = spec.expanded or false,
      loaded = spec.loaded ~= false,
      loading = false,
      error = nil,
    },
    example = spec.example or {},
    active = spec.active or false,
  }
  for _, child_spec in ipairs(spec.children or {}) do
    local child = child_spec.state and child_spec or M.new(child_spec)
    reid(child, node.id) -- grandchildren too, not just the direct child
    table.insert(node.children, child)
  end
  return node
end

--- Append a constructed child, rewriting its (and its subtree's) ids to be
--- rooted under the parent so expand-state and cursor-follow stay stable.
---@param parent typescope.Node
---@param child typescope.Node
function M.add_child(parent, child)
  reid(child, parent.id)
  table.insert(parent.children, child)
end

--- Canonical type-structure string, used as the example-cache key.
--- Children are sorted by name so field order changes don't bust the cache.
---@param node typescope.Node
---@return string
function M.hash(node)
  local parts = { node.type.display or node.type.raw or "?" }
  local names = {}
  for _, child in ipairs(node.children) do
    table.insert(names, child.name .. ":" .. M.hash(child))
  end
  table.sort(names)
  if #names > 0 then
    table.insert(parts, "{" .. table.concat(names, ",") .. "}")
  end
  return table.concat(parts)
end

--- A node can be opened if it has children now, or could lazily resolve some.
---@param node typescope.Node
---@return boolean
function M.is_expandable(node)
  return #node.children > 0 or (not node.state.loaded and node.source ~= nil)
end

--- Depth-first visit over a list of root nodes.
---@param roots typescope.Node[]
---@param fn fun(node: typescope.Node, depth: integer)
function M.walk(roots, fn)
  local function visit(node, depth)
    fn(node, depth)
    for _, child in ipairs(node.children) do
      visit(child, depth + 1)
    end
  end
  for _, root in ipairs(roots) do
    visit(root, 0)
  end
end

--- Parent of a node, resolved through its dotted path id (Python identifiers
--- cannot contain dots, so splitting on "." is unambiguous).
---@param roots typescope.Node[]
---@param id string
---@return typescope.Node?
function M.parent(roots, id)
  local parent_id = id:match("^(.*)%.[^.]+$")
  return parent_id and M.find(roots, parent_id) or nil
end

--- Find a node by id in a forest.
---@param roots typescope.Node[]
---@param id string
---@return typescope.Node?
function M.find(roots, id)
  local found
  M.walk(roots, function(node)
    if node.id == id then
      found = node
    end
  end)
  return found
end

return M
