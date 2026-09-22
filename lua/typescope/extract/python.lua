-- Call-site syntax for Python, over the buffer's treesitter tree: what the
-- cursor is on (a call's callee or its arguments) and what was written there.
-- Types come from the oracle (design/oracle.md); this file never reads an
-- annotation, and `:TSInstall python` stays a requirement for these two
-- questions and for the float's own highlighting.
--
-- `src` everywhere is a bufnr or a raw source string (string form lets tests
-- run on inline snippets with vim.treesitter.get_string_parser).

local M = {}

local function get_root(src)
  local ok, parser
  if type(src) == "number" then
    ok, parser = pcall(vim.treesitter.get_parser, src, "python")
  else
    ok, parser = pcall(vim.treesitter.get_string_parser, src, "python")
  end
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

local function text(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function walk_up(node, want)
  while node do
    if node:type() == want then
      return node
    end
    node = node:parent()
  end
end

local function field1(node, name)
  return node:field(name)[1]
end

---@return TSNode?
local function node_at(src, row, col)
  local root = get_root(src)
  return root and root:named_descendant_for_range(row, col, row, col) or nil
end

--- Written arguments of the call whose node contains (row, col) — the callee
--- name and anywhere inside the argument list both land inside the call node.
--- Classifies each argument's LITERAL kind for client-side overload matching
--- (h8h); any expression the parse can't judge (a variable, a call, a
--- container) is kind "other" and never disqualifies a candidate. Splat
--- arguments (*xs / **kw) defeat positional counting entirely → nil.
---@param src integer|string
---@param row integer 0-based
---@param col integer 0-based byte
---@return { positional: { kind: string }[], keywords: { name: string, kind: string }[] }?
function M.call_args(src, row, col)
  local call = walk_up(node_at(src, row, col), "call")
  local args = call and field1(call, "arguments")
  if not args then
    return nil
  end
  local function kind_of(n)
    local t = n and n:type()
    if t == "string" or t == "concatenated_string" then
      return "string"
    elseif t == "true" or t == "false" then
      return "bool"
    elseif t == "none" then
      return "none"
    elseif t == "integer" or t == "float" then
      return t
    elseif t == "unary_operator" then
      -- -3 / +2.5 keep their numeric kind
      local inner = kind_of(field1(n, "argument"))
      return (inner == "integer" or inner == "float") and inner or "other"
    end
    return "other"
  end
  local out = { positional = {}, keywords = {} }
  for i = 0, args:named_child_count() - 1 do
    local a = args:named_child(i)
    local t = a:type()
    if t == "keyword_argument" then
      table.insert(out.keywords, { name = text(field1(a, "name"), src), kind = kind_of(field1(a, "value")) })
    elseif t == "list_splat" or t == "dictionary_splat" then
      return nil
    elseif t ~= "comment" then
      table.insert(out.positional, { kind = kind_of(a) })
    end
  end
  return out
end

--- Is (row, col) on the CALLEE of a call — `Recipe(` with the cursor on
--- `Recipe`, `obj.method(` on `method`? Call-site syntax, so this stays
--- treesitter: the oracle draws a class under a call as its constructor
--- (design/oracle.md decision 5).
---@param src integer|string
---@param row integer 0-based
---@param col integer 0-based byte
---@return boolean
function M.on_callee(src, row, col)
  local node = node_at(src, row, col)
  local call = node and walk_up(node, "call")
  local callee = call and field1(call, "function")
  if not callee then
    return false
  end
  local srow, scol, erow, ecol = callee:range()
  if row < srow or row > erow or (row == srow and col < scol) or (row == erow and col >= ecol) then
    return false
  end
  -- on the callee's final identifier specifically, not an argument of a
  -- nested call inside it
  local target = callee:type() == "attribute" and field1(callee, "attribute") or callee
  local tr, tc, ter, tec = target:range()
  return row >= tr and row <= ter and (row > tr or col >= tc) and (row < ter or col < tec)
end

return M
